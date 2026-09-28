// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import AVFoundation
import Carbon.HIToolbox

/// OpenScribe: press the shortcut, speak, press it again, and the words land
/// where the caret is. Audio is recorded to a private temporary file, sent to
/// the transcription endpoint the user chose, optionally tidied by a language
/// model, then pasted into the focused app (or copied, by choice or when
/// Accessibility is missing). Nothing records or listens at rest: the
/// microphone is only open between the two presses.
final class OpenScribeService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = OpenScribeService()

    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing
        case polishing

        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle
    /// Smoothed input level in 0...1 for the recording pill.
    @Published private(set) var level: Float = 0
    @Published private(set) var shortcutRegistrationFailed = false
    @Published private(set) var endpoints: [OpenScribeEndpoint] = []
    /// Kept in memory only, so a paste that went to the wrong place can be
    /// recovered from Settings. Never written to disk or preferences.
    @Published private(set) var lastTranscript = ""

    private let hotkey = QuickToolHotkey(id: 96)
    /// Esc is claimed only while a dictation is running, so it cancels without
    /// taking the key from other apps the rest of the time.
    private let cancelHotkey = QuickToolHotkey(id: 97)
    private static let cancelShortcut = GlobalShortcut(keyCode: Int64(kVK_Escape), modifiers: [])
    private static let cancelStorageKey = "openScribeCancelShortcut"

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var work: Task<Void, Never>?
    private var targetApplication: NSRunningApplication?
    private var stopReason: StopReason = .user
    private var defaultsObserver: NSObjectProtocol?

    private enum StopReason { case user, limit }

    private var strings: OpenScribeFeatureStrings { FeatureStrings.openScribe(L10n.shared.language) }

    private override init() {
        super.init()
        endpoints = OpenScribeSupport.decodeEndpoints(
            UserDefaults.standard.data(forKey: DefaultsKey.openScribeEndpoints))
        hotkey.onPress = { [weak self] in self?.toggle() }
        cancelHotkey.onPress = { [weak self] in self?.cancel() }
        // A settings import replaces the endpoint list underneath the service.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadEndpointsIfChanged()
        }
    }

    // MARK: Lifecycle

    func syncWithPreferences() {
        let available = AppFeature.openScribe.isAvailable
        let enabled = available && UserDefaults.standard.bool(forKey: DefaultsKey.openScribeShortcutEnabled)
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.openScribeShortcut, fallback: .openScribeDefault)
        shortcutRegistrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut,
                                                  storageKey: DefaultsKey.openScribeShortcut)
        if !available { discard(showingMessage: false) }
    }

    /// Quit, self-uninstall and the hub all end here: nothing keeps the
    /// microphone open or a request in flight after the feature goes away.
    func suspend() {
        hotkey.unregister()
        discard(showingMessage: false)
    }

    // MARK: Endpoints

    var transcriptionEndpoint: OpenScribeEndpoint? {
        OpenScribeSupport.selected(.transcription,
                                   id: UserDefaults.standard.string(forKey: DefaultsKey.openScribeTranscriptionEndpoint),
                                   in: endpoints)
    }

    var cleanupEndpoint: OpenScribeEndpoint? {
        OpenScribeSupport.selected(.cleanup,
                                   id: UserDefaults.standard.string(forKey: DefaultsKey.openScribeCleanupEndpoint),
                                   in: endpoints)
    }

    /// Adds or replaces an endpoint. A nil key leaves the stored key alone;
    /// an empty one removes it. The first endpoint of a role becomes the
    /// selected one so a fresh setup works without another click.
    func save(_ endpoint: OpenScribeEndpoint, key: String?) {
        var list = endpoints
        if let index = list.firstIndex(where: { $0.id == endpoint.id }) {
            list[index] = endpoint
        } else {
            list.append(endpoint)
        }
        if let key { OpenScribeKeychain.setKey(key, for: endpoint.id) }
        persist(list)
        switch endpoint.role {
        case .transcription:
            if transcriptionEndpoint == nil || list.filter({ $0.role == .transcription }).count == 1 {
                UserDefaults.standard.set(endpoint.id.uuidString, forKey: DefaultsKey.openScribeTranscriptionEndpoint)
            }
        case .cleanup:
            if list.filter({ $0.role == .cleanup }).count == 1 {
                UserDefaults.standard.set(endpoint.id.uuidString, forKey: DefaultsKey.openScribeCleanupEndpoint)
            }
        }
        objectWillChange.send()
    }

    func remove(_ endpoint: OpenScribeEndpoint) {
        OpenScribeKeychain.removeKey(for: endpoint.id)
        persist(endpoints.filter { $0.id != endpoint.id })
        for key in [DefaultsKey.openScribeTranscriptionEndpoint, DefaultsKey.openScribeCleanupEndpoint]
        where UserDefaults.standard.string(forKey: key) == endpoint.id.uuidString {
            UserDefaults.standard.set("", forKey: key)
        }
        objectWillChange.send()
    }

    func select(_ endpoint: OpenScribeEndpoint?, for role: OpenScribeEndpointRole) {
        let key = role == .transcription ? DefaultsKey.openScribeTranscriptionEndpoint
                                         : DefaultsKey.openScribeCleanupEndpoint
        UserDefaults.standard.set(endpoint?.id.uuidString ?? "", forKey: key)
        objectWillChange.send()
    }

    func needsKey(_ endpoint: OpenScribeEndpoint) -> Bool {
        OpenScribeSupport.requiresKey(endpoint) && !OpenScribeKeychain.hasKey(for: endpoint.id)
    }

    func test(_ endpoint: OpenScribeEndpoint, key: String?) async throws {
        let stored = key?.isEmpty == false ? key : OpenScribeKeychain.key(for: endpoint.id)
        try await OpenScribeClient().test(endpoint, key: stored)
    }

    private func persist(_ list: [OpenScribeEndpoint]) {
        endpoints = list
        UserDefaults.standard.set(OpenScribeSupport.encodeEndpoints(list), forKey: DefaultsKey.openScribeEndpoints)
    }

    private func reloadEndpointsIfChanged() {
        let stored = OpenScribeSupport.decodeEndpoints(
            UserDefaults.standard.data(forKey: DefaultsKey.openScribeEndpoints))
        if stored != endpoints { endpoints = stored }
    }

    // MARK: Dictation

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: finish()
        case .transcribing, .polishing: break
        }
    }

    func start() {
        guard AppFeature.openScribe.isAvailable, phase == .idle else { return }
        guard let endpoint = transcriptionEndpoint else {
            QuickToolHUD.show(icon: "waveform.badge.exclamationmark", message: strings.needsEndpoint)
            openSettings()
            return
        }
        if needsKey(endpoint) {
            QuickToolHUD.show(icon: "key", message: String(format: strings.needsKeyFormat, endpoint.displayName))
            openSettings()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            Permissions.shared.requestMicrophone { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    QuickToolHUD.show(icon: "mic.slash", message: self.strings.microphoneDenied)
                }
            }
        default:
            QuickToolHUD.show(icon: "mic.slash", message: strings.microphoneDenied)
            Permissions.shared.openMicrophoneSettings()
        }
    }

    func finish() {
        guard case .recording(let since) = phase, let recorder else { return }
        let duration = Date().timeIntervalSince(since)
        stopReason = .user
        recorder.stop()
        stopMetering()
        guard duration >= OpenScribeSupport.minimumRecordingDuration else {
            discard(showingMessage: false)
            QuickToolHUD.show(icon: "waveform", message: strings.nothingHeard)
            return
        }
        transcribeRecording()
    }

    func cancel() {
        guard phase.isBusy else { return }
        discard(showingMessage: true)
    }

    private func beginRecording() {
        guard phase == .idle, AppFeature.openScribe.isAvailable else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        targetApplication = front?.processIdentifier == own ? nil : front

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VorssaintOpenScribe-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: OpenScribeSupport.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(),
                  recorder.record(forDuration: OpenScribeSupport.maximumRecordingDuration)
            else {
                try? FileManager.default.removeItem(at: url)
                QuickToolHUD.show(icon: "mic.slash", message: strings.microphoneUnavailable)
                return
            }
            self.recorder = recorder
            recordingURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            QuickToolHUD.show(icon: "mic.slash", message: strings.microphoneUnavailable)
            return
        }
        stopReason = .user
        phase = .recording(since: Date())
        cancelHotkey.sync(enabled: true, shortcut: Self.cancelShortcut, storageKey: Self.cancelStorageKey)
        startMetering()
        OpenScribeRecordingPanel.shared.show()
    }

    /// Reaching the time limit ends the recording the same way a second press does.
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, recorder === self.recorder, case .recording = self.phase else { return }
            self.stopReason = .limit
            self.stopMetering()
            if flag {
                self.transcribeRecording()
            } else {
                self.discard(showingMessage: false)
                QuickToolHUD.show(icon: "mic.slash", message: self.strings.microphoneUnavailable)
            }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, recorder === self.recorder else { return }
            self.discard(showingMessage: false)
            QuickToolHUD.show(icon: "mic.slash", message: self.strings.microphoneUnavailable)
        }
    }

    private func transcribeRecording() {
        guard let url = recordingURL, let endpoint = transcriptionEndpoint else {
            discard(showingMessage: false)
            return
        }
        recorder = nil
        phase = .transcribing
        let cleanup = cleanupEndpoint
        let defaults = UserDefaults.standard
        let options = OpenScribeClient.Options(
            language: defaults.string(forKey: DefaultsKey.openScribeLanguage) ?? "",
            vocabulary: OpenScribeSupport.vocabularyTerms(
                defaults.string(forKey: DefaultsKey.openScribeVocabulary) ?? ""))
        let reachedLimit = stopReason == .limit
        let transcriptionKey = OpenScribeKeychain.key(for: endpoint.id)
        let cleanupKey = cleanup.flatMap { OpenScribeKeychain.key(for: $0.id) }
        let strings = self.strings

        // State changes stay on the main actor; the requests themselves run
        // off it inside the client. Cancelling the task cancels the requests.
        work = Task { @MainActor [weak self] in
            let client = OpenScribeClient()
            do {
                let raw = try await Self.transcribe(url, client: client, endpoint: endpoint,
                                                    key: transcriptionKey, options: options)
                guard !raw.isEmpty else {
                    self?.complete(text: nil, note: nil)
                    return
                }
                var text = raw
                var note: String?
                if let cleanup {
                    self?.phase = .polishing
                    do {
                        text = try await client.cleanUp(raw, endpoint: cleanup, key: cleanupKey,
                                                        vocabulary: options.vocabulary)
                    } catch where Self.isCancellation(error) {
                        throw error
                    } catch {
                        note = strings.cleanupFailed
                    }
                    try Task.checkCancellation()
                }
                if reachedLimit, note == nil { note = strings.recordingLimit }
                self?.complete(text: text, note: note)
            } catch where Self.isCancellation(error) {
                // A cancel already reset the state and removed the audio.
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Reads the recording, deletes it, then uploads it: the audio never
    /// outlives the request, whether it succeeds, fails or is cancelled.
    private static func transcribe(_ url: URL, client: OpenScribeClient, endpoint: OpenScribeEndpoint,
                                   key: String?, options: OpenScribeClient.Options) async throws -> String {
        let audio: Data
        do {
            audio = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        try Task.checkCancellation()
        return try await client.transcribe(audio: audio, fileName: "dictation.wav",
                                           endpoint: endpoint, key: key, options: options)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private func complete(text: String?, note: String?) {
        guard phase.isBusy else { return }
        let target = targetApplication
        reset()
        guard let text, !text.isEmpty else {
            QuickToolHUD.show(icon: "waveform", message: strings.nothingHeard)
            return
        }
        lastTranscript = text
        deliver(text, to: target, note: note)
    }

    private func fail(_ error: Error) {
        guard phase.isBusy else { return }
        reset()
        let detail = OpenScribeClient.message(for: error, strings)
        QuickToolHUD.show(icon: "exclamationmark.triangle", message: String(format: strings.failedFormat, detail))
    }

    private func deliver(_ text: String, to target: NSRunningApplication?, note: String?) {
        let delivery = OpenScribeDelivery.sanitized(
            UserDefaults.standard.string(forKey: DefaultsKey.openScribeDelivery))
        guard delivery == .paste else {
            copy(text)
            QuickToolHUD.show(icon: "doc.on.clipboard", message: note ?? strings.copied)
            return
        }
        guard AXIsProcessTrusted() else {
            copy(text)
            QuickToolHUD.show(icon: "doc.on.clipboard", message: strings.copiedNeedsAccessibility)
            return
        }
        // Clicking the pill or Settings may have brought this app forward;
        // the text belongs to the app that had focus when dictation began.
        let own = ProcessInfo.processInfo.processIdentifier
        var delay: TimeInterval = 0
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == own,
           let target, !target.isTerminated {
            target.activate()
            delay = 0.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let started = TransientPaste.shared.paste(text, didPostShortcut: {
                QuickToolHUD.show(icon: "text.insert", message: note ?? self.strings.inserted)
            }, didFail: {
                self.copy(text)
                QuickToolHUD.show(icon: "doc.on.clipboard", message: self.strings.copied)
            })
            if !started {
                self.copy(text)
                QuickToolHUD.show(icon: "doc.on.clipboard", message: self.strings.copied)
            }
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        copy(lastTranscript)
        QuickToolHUD.show(icon: "doc.on.clipboard", message: strings.copied)
    }

    private func copy(_ text: String) {
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Stops everything in flight and deletes the audio.
    private func discard(showingMessage: Bool) {
        let wasBusy = phase.isBusy
        work?.cancel()
        work = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        reset()
        if showingMessage, wasBusy {
            QuickToolHUD.show(icon: "xmark.circle", message: strings.cancelled)
        }
    }

    private func reset() {
        stopMetering()
        cancelHotkey.unregister()
        work = nil
        recorder = nil
        recordingURL = nil
        targetApplication = nil
        level = 0
        phase = .idle
        OpenScribeRecordingPanel.shared.hide()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0, min(1, (power + 50) / 50))
            self.level = self.level * 0.4 + normalized * 0.6
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    func openSettings() {
        SettingsRouter.shared.page = .openScribe
        appDelegate()?.openSettingsWindow()
    }
}
