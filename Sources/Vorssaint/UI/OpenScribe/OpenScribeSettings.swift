// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Settings for OpenScribe: how dictation starts, which endpoints it uses and
/// where the text goes. Endpoints are listed by role with their key state, and
/// each one can be tested before it is relied on.
struct OpenScribeSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = OpenScribeService.shared
    @AppStorage(DefaultsKey.openScribeShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.openScribeDelivery) private var deliveryRaw = OpenScribeDelivery.paste.rawValue
    @AppStorage(DefaultsKey.openScribeLanguage) private var language = ""
    @AppStorage(DefaultsKey.openScribeVocabulary) private var vocabulary = ""
    @State private var editing: EndpointDraft?

    private var strings: OpenScribeFeatureStrings { FeatureStrings.openScribe(l10n.language) }

    var body: some View {
        Form {
            Section {
                Button {
                    service.toggle()
                } label: {
                    Label(service.phase == .idle ? strings.start : strings.stop,
                          systemImage: service.phase == .idle ? "mic" : "stop.circle")
                }
                .disabled(service.phase == .transcribing || service.phase == .polishing)
                Toggle(strings.shortcutToggle, isOn: $shortcutEnabled)
                    .onChange(of: shortcutEnabled) { _, _ in service.syncWithPreferences() }
                ShortcutPreferenceRow(role: .openScribe, isEnabled: shortcutEnabled) {
                    service.syncWithPreferences()
                }
                if shortcutEnabled, service.shortcutRegistrationFailed {
                    Text(l10n.s.shortcutUnavailable)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(strings.shortcutCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if permissions.microphone != .granted {
                    PermissionRow(kind: .microphone)
                }
                if OpenScribeDelivery.sanitized(deliveryRaw) == .paste, !permissions.accessibility {
                    PermissionRow(kind: .accessibility)
                }
            } header: {
                Text(strings.title)
            }

            Section {
                endpointList(.transcription)
                endpointList(.cleanup)
                Menu {
                    ForEach(OpenScribeEndpointRole.allCases) { role in
                        Section(roleTitle(role)) {
                            ForEach(OpenScribePreset.presets(for: role)) { preset in
                                Button(preset.name) { editing = EndpointDraft(preset: preset) }
                            }
                            Button(strings.presetCustom) { editing = EndpointDraft(role: role) }
                        }
                    }
                } label: {
                    Label(strings.addEndpoint, systemImage: "plus")
                }
                .fixedSize()
                Text(strings.endpointsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(strings.endpointsTitle)
            }

            Section {
                Picker(strings.transcribeWith, selection: selection(.transcription)) {
                    ForEach(service.endpoints.filter { $0.role == .transcription }) { endpoint in
                        Text(endpoint.displayName).tag(Optional(endpoint.id))
                    }
                    if service.transcriptionEndpoint == nil {
                        Text("–").tag(UUID?.none)
                    }
                }
                Picker(strings.cleanUpWith, selection: selection(.cleanup)) {
                    Text(strings.cleanupOff).tag(UUID?.none)
                    ForEach(service.endpoints.filter { $0.role == .cleanup }) { endpoint in
                        Text(endpoint.displayName).tag(Optional(endpoint.id))
                    }
                }
                Text(strings.cleanupCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(strings.deliveryTitle, selection: $deliveryRaw) {
                    Text(strings.deliveryPaste).tag(OpenScribeDelivery.paste.rawValue)
                    Text(strings.deliveryCopy).tag(OpenScribeDelivery.copy.rawValue)
                }
                Picker(strings.languageTitle, selection: $language) {
                    ForEach(OpenScribeSupport.languageCodes, id: \.self) { code in
                        Text(languageName(code)).tag(code)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings.vocabularyTitle)
                    TextField(strings.vocabularyPlaceholder, text: $vocabulary, axis: .vertical)
                        .lineLimit(1...3)
                        .labelsHidden()
                }
            }

            if !service.lastTranscript.isEmpty {
                Section {
                    Text(service.lastTranscript)
                        .textSelection(.enabled)
                        .lineLimit(6)
                    Button(strings.copy) { service.copyLastTranscript() }
                } header: {
                    Text(strings.lastTranscript)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            OpenScribeEndpointEditor(draft: draft)
        }
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private func endpointList(_ role: OpenScribeEndpointRole) -> some View {
        let list = service.endpoints.filter { $0.role == role }
        if list.isEmpty {
            if role == .transcription {
                Text(strings.noEndpoints)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(list) { endpoint in
                HStack(spacing: 10) {
                    Image(systemName: role == .transcription ? "waveform" : "text.badge.checkmark")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.displayName)
                        Text("\(roleTitle(role)) · \(endpoint.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if service.needsKey(endpoint) {
                        Text(strings.keyMissing)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        editing = EndpointDraft(endpoint: endpoint)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(strings.editEndpoint)
                    Button {
                        service.remove(endpoint)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(strings.removeEndpoint)
                }
            }
        }
    }

    private func selection(_ role: OpenScribeEndpointRole) -> Binding<UUID?> {
        Binding(get: {
            role == .transcription ? service.transcriptionEndpoint?.id : service.cleanupEndpoint?.id
        }, set: { id in
            service.select(service.endpoints.first { $0.id == id }, for: role)
        })
    }

    private func roleTitle(_ role: OpenScribeEndpointRole) -> String {
        role == .transcription ? strings.roleTranscription : strings.roleCleanup
    }

    private func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return strings.languageAuto }
        let locale = Locale(identifier: l10n.language.rawValue)
        return locale.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}

/// The editable copy of an endpoint behind the editor sheet.
struct EndpointDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var role: OpenScribeEndpointRole
    var api: OpenScribeEndpointAPI
    var baseURL: String
    var model: String

    init(preset: OpenScribePreset) {
        let endpoint = preset.endpoint()
        self.init(endpoint: endpoint, isNew: true)
    }

    init(role: OpenScribeEndpointRole) {
        self.init(endpoint: OpenScribeEndpoint(name: "", role: role, api: .openAICompatible,
                                               baseURL: "https://", model: ""),
                  isNew: true)
    }

    init(endpoint: OpenScribeEndpoint, isNew: Bool = false) {
        id = endpoint.id
        self.isNew = isNew
        name = endpoint.name
        role = endpoint.role
        api = endpoint.api
        baseURL = endpoint.baseURL
        model = endpoint.model
    }

    var endpoint: OpenScribeEndpoint {
        OpenScribeEndpoint(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           role: role, api: api,
                           baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isValid: Bool {
        OpenScribeSupport.validatedBaseURL(baseURL) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && api.roles.contains(role)
    }
}

private struct OpenScribeEndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var l10n = L10n.shared
    @State private var draft: EndpointDraft
    @State private var key = ""
    @State private var hasStoredKey: Bool
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?

    private enum TestState: Equatable {
        case idle, testing, succeeded
        case failed(String)
    }

    init(draft: EndpointDraft) {
        _draft = State(initialValue: draft)
        _hasStoredKey = State(initialValue: !draft.isNew && OpenScribeKeychain.hasKey(for: draft.id))
    }

    private var strings: OpenScribeFeatureStrings { FeatureStrings.openScribe(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isNew ? strings.addEndpoint : strings.editEndpoint)
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                TextField(strings.nameLabel, text: $draft.name)
                Picker(strings.roleLabel, selection: $draft.role) {
                    Text(strings.roleTranscription).tag(OpenScribeEndpointRole.transcription)
                    Text(strings.roleCleanup).tag(OpenScribeEndpointRole.cleanup)
                }
                .onChange(of: draft.role) { _, role in
                    if !draft.api.roles.contains(role) { draft.api = .openAICompatible }
                    testState = .idle
                }
                Picker(strings.apiLabel, selection: $draft.api) {
                    ForEach(OpenScribeEndpointAPI.available(for: draft.role)) { api in
                        Text(api.title(strings)).tag(api)
                    }
                }
                .onChange(of: draft.api) { _, _ in testState = .idle }
                TextField(strings.baseURLLabel, text: $draft.baseURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                if !draft.baseURL.isEmpty, OpenScribeSupport.validatedBaseURL(draft.baseURL) == nil {
                    Text(strings.invalidURL).font(.caption).foregroundStyle(.orange)
                } else if OpenScribeSupport.isUnencryptedRemote(draft.baseURL) {
                    Text(strings.insecureWarning).font(.caption).foregroundStyle(.orange)
                }
                TextField(strings.modelLabel, text: $draft.model)
                    .autocorrectionDisabled()
                SecureField(strings.apiKeyLabel, text: $key,
                            prompt: Text(hasStoredKey ? strings.apiKeySaved
                                         : (OpenScribeSupport.requiresKey(draft.endpoint) ? "" : strings.apiKeyOptional)))
                testRow
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(strings.cancel) {
                    testTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(strings.save) {
                    testTask?.cancel()
                    OpenScribeService.shared.save(draft.endpoint, key: key.isEmpty ? nil : key)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onDisappear { testTask?.cancel() }
    }

    @ViewBuilder
    private var testRow: some View {
        HStack(spacing: 8) {
            Button(strings.test) { runTest() }
                .disabled(!draft.isValid || testState == .testing)
            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
                Text(strings.testing).font(.caption).foregroundStyle(.secondary)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(strings.testSucceeded).font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private func runTest() {
        testTask?.cancel()
        testState = .testing
        let endpoint = draft.endpoint
        let typed = key
        let strings = self.strings
        testTask = Task {
            do {
                try await OpenScribeService.shared.test(endpoint, key: typed)
                await MainActor.run { testState = .succeeded }
            } catch is CancellationError {
            } catch {
                let message = OpenScribeClient.message(for: error, strings)
                await MainActor.run { testState = .failed(message) }
            }
        }
    }
}
