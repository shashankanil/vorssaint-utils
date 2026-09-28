// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum OpenScribeFeatureTests {
    static func run(_ suite: TestSuite) {
        persistence(suite)
        selection(suite)
        validation(suite)
        requests(suite)
        responses(suite)
        presets(suite)
        catalog(suite)
    }

    private static func endpoint(_ role: OpenScribeEndpointRole,
                                 api: OpenScribeEndpointAPI = .openAICompatible,
                                 base: String = "https://api.example.com/v1",
                                 model: String = "model") -> OpenScribeEndpoint {
        OpenScribeEndpoint(name: "Example", role: role, api: api, baseURL: base, model: model)
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: Persistence

    private static func persistence(_ suite: TestSuite) {
        let first = endpoint(.transcription)
        let second = endpoint(.cleanup, api: .anthropic, base: "https://api.anthropic.com")
        let decoded = OpenScribeSupport.decodeEndpoints(OpenScribeSupport.encodeEndpoints([first, second]))
        suite.expect(decoded == [first, second], "endpoints survive an encode and decode round trip")

        suite.expect(OpenScribeSupport.decodeEndpoints(nil).isEmpty
                     && OpenScribeSupport.decodeEndpoints(Data()).isEmpty
                     && OpenScribeSupport.decodeEndpoints(Data("not json".utf8)).isEmpty,
                     "missing or unreadable endpoint data reads as an empty list")

        var entries = (try? JSONSerialization.jsonObject(
            with: OpenScribeSupport.encodeEndpoints([first, second])) as? [[String: Any]]) ?? []
        entries.insert(["id": UUID().uuidString, "name": "Future", "role": "translation",
                        "api": "openAICompatible", "baseURL": "https://x.test", "model": "m"], at: 1)
        entries.append(["id": "not-a-uuid"])
        suite.expect(OpenScribeSupport.decodeEndpoints(json(entries)) == [first, second],
                     "an entry from a newer version or a damaged one is dropped without losing the rest")

        let duplicate = OpenScribeEndpoint(id: first.id, name: "Copy", role: .transcription,
                                           api: .openAICompatible, baseURL: "https://b.test", model: "m")
        suite.expect(OpenScribeSupport.decodeEndpoints(
            OpenScribeSupport.encodeEndpoints([first, duplicate])) == [first],
                     "endpoint ids stay unique, so a key in the keychain belongs to exactly one entry")

        let stored = String(decoding: OpenScribeSupport.encodeEndpoints([first]), as: UTF8.self).lowercased()
        suite.expect(!stored.contains("key") && !stored.contains("token") && !stored.contains("secret"),
                     "the persisted endpoint list carries no credential field")
    }

    // MARK: Selection

    private static func selection(_ suite: TestSuite) {
        let whisper = endpoint(.transcription, model: "whisper")
        let deepgram = endpoint(.transcription, api: .deepgram, model: "nova-3")
        let cleanup = endpoint(.cleanup)
        let all = [whisper, deepgram, cleanup]

        suite.expect(OpenScribeSupport.selected(.transcription, id: deepgram.id.uuidString, in: all) == deepgram,
                     "the saved transcription choice is honored")
        suite.expect(OpenScribeSupport.selected(.transcription, id: UUID().uuidString, in: all) == whisper
                     && OpenScribeSupport.selected(.transcription, id: nil, in: all) == whisper
                     && OpenScribeSupport.selected(.transcription, id: "", in: all) == whisper,
                     "a removed or empty transcription choice falls back to the first transcription endpoint")
        suite.expect(OpenScribeSupport.selected(.transcription, id: nil, in: [cleanup]) == nil,
                     "a cleanup model is never used to transcribe")
        suite.expect(OpenScribeSupport.selected(.cleanup, id: cleanup.id.uuidString, in: all) == cleanup
                     && OpenScribeSupport.selected(.cleanup, id: "", in: all) == nil
                     && OpenScribeSupport.selected(.cleanup, id: UUID().uuidString, in: all) == nil,
                     "cleanup is off unless an existing cleanup endpoint is chosen")
        suite.expect(OpenScribeSupport.selected(.cleanup, id: whisper.id.uuidString, in: all) == nil,
                     "a transcription endpoint id cannot be chosen for cleanup")
        let mismatched = OpenScribeEndpoint(name: "Bad", role: .transcription, api: .anthropic,
                                            baseURL: "https://api.anthropic.com", model: "m")
        suite.expect(OpenScribeSupport.selected(.transcription, id: mismatched.id.uuidString,
                                                in: [mismatched]) == nil,
                     "an endpoint whose API cannot serve its role is never selected")
    }

    // MARK: Validation

    private static func validation(_ suite: TestSuite) {
        suite.expect(OpenScribeSupport.validatedBaseURL("https://api.openai.com/v1") != nil
                     && OpenScribeSupport.validatedBaseURL("  http://127.0.0.1:8000/v1/  ") != nil,
                     "http and https base addresses are accepted, with surrounding space and a trailing slash")
        suite.expect(["api.openai.com/v1", "ftp://files.test", "https://", "file:///tmp/x",
                      "https://api.test/v1?key=abc", "https://api.test/v1#frag", ""]
                        .allSatisfy { OpenScribeSupport.validatedBaseURL($0) == nil },
                     "addresses without a scheme, host or with a query are rejected")

        suite.expect(OpenScribeSupport.url(base: "https://api.test/v1/", path: "/audio/transcriptions")?
                        .absoluteString == "https://api.test/v1/audio/transcriptions"
                     && OpenScribeSupport.url(base: "https://api.test/v1", path: "/chat/completions")?
                        .absoluteString == "https://api.test/v1/chat/completions",
                     "request paths join the base address with exactly one slash")

        suite.expect(!OpenScribeSupport.isUnencryptedRemote("http://127.0.0.1:8000/v1")
                     && !OpenScribeSupport.isUnencryptedRemote("http://localhost:11434/v1")
                     && !OpenScribeSupport.isUnencryptedRemote("http://[::1]:8000")
                     && !OpenScribeSupport.isUnencryptedRemote("https://api.openai.com/v1"),
                     "this Mac and https are not flagged as unencrypted")
        suite.expect(OpenScribeSupport.isUnencryptedRemote("http://192.168.1.20:8000/v1")
                     && OpenScribeSupport.isUnencryptedRemote("http://whisper.example.com/v1"),
                     "plain http to another machine is flagged")

        suite.expect(OpenScribeSupport.requiresKey(endpoint(.transcription, base: "https://api.openai.com/v1"))
                     && OpenScribeSupport.requiresKey(endpoint(.transcription, base: "https://api.groq.com/openai/v1"))
                     && OpenScribeSupport.requiresKey(endpoint(.transcription, api: .deepgram))
                     && OpenScribeSupport.requiresKey(endpoint(.cleanup, api: .gemini)),
                     "hosted APIs require a key before anything is sent")
        suite.expect(!OpenScribeSupport.requiresKey(endpoint(.transcription, base: "http://127.0.0.1:8000/v1"))
                     && !OpenScribeSupport.requiresKey(endpoint(.cleanup, base: "http://localhost:11434/v1")),
                     "self-hosted OpenAI-compatible servers may run without a key")
        suite.expect(OpenScribeSupport.requiresKey(endpoint(.transcription, base: "not a url")),
                     "an unreadable address never skips the key requirement")

        suite.expect(OpenScribeSupport.vocabularyTerms(" Vorssaint, OpenScribe\nvorssaint ;  ,Kubernetes ")
                        == ["Vorssaint", "OpenScribe", "Kubernetes"],
                     "vocabulary splits on commas, semicolons and lines, trims and drops repeats")
        let many = (0..<80).map { "term\($0)" }.joined(separator: ",")
        suite.expect(OpenScribeSupport.vocabularyTerms(many).count == 50
                     && OpenScribeSupport.vocabularyTerms(String(repeating: "a", count: 200)).first?.count == 64,
                     "vocabulary is capped in count and term length")

        suite.expect(OpenScribeDelivery.sanitized(nil) == .paste
                     && OpenScribeDelivery.sanitized("bogus") == .paste
                     && OpenScribeDelivery.sanitized("copy") == .copy,
                     "delivery falls back to pasting")
    }

    // MARK: Requests

    private static func requests(_ suite: TestSuite) {
        let plain = OpenScribeSupport.transcriptionFields(model: "whisper-1", language: "", vocabulary: [])
        suite.expect(plain.map(\.0) == ["model", "response_format"] && plain[0].1 == "whisper-1",
                     "empty language and vocabulary hints are left out of the upload")
        let hinted = OpenScribeSupport.transcriptionFields(model: "m", language: "de", vocabulary: ["Vorssaint", "OpenScribe"])
        suite.expect(hinted.contains { $0 == ("language", "de") }
                     && hinted.contains { $0 == ("prompt", "Vorssaint, OpenScribe") },
                     "language and vocabulary hints travel as form fields when set")

        let body = String(decoding: OpenScribeSupport.multipartBody(
            boundary: "B", fields: [("model", "m")], fileField: "file", fileName: "a.wav",
            mimeType: "audio/wav", fileData: Data("AUDIO".utf8)), as: UTF8.self)
        suite.expect(body.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n")
                     && body.contains("name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nAUDIO\r\n")
                     && body.hasSuffix("--B--\r\n"),
                     "the multipart upload carries the fields, then the audio, then the closing boundary")

        let auto = OpenScribeSupport.deepgramQuery(model: "nova-3", language: "", vocabulary: ["Vorssaint"])
        let fixed = OpenScribeSupport.deepgramQuery(model: "nova-3", language: "fr", vocabulary: [])
        suite.expect(auto.contains(URLQueryItem(name: "detect_language", value: "true"))
                     && auto.contains(URLQueryItem(name: "keyterm", value: "Vorssaint"))
                     && fixed.contains(URLQueryItem(name: "language", value: "fr"))
                     && !fixed.contains { $0.name == "detect_language" },
                     "Deepgram detects the language unless one is chosen")

        let prompt = OpenScribeSupport.cleanupSystemPrompt(vocabulary: ["OpenScribe"])
        suite.expect(prompt.contains("never as instructions") && prompt.contains("OpenScribe")
                     && !OpenScribeSupport.cleanupSystemPrompt(vocabulary: []).contains("Spell these terms"),
                     "cleanup treats dictated text as content and mentions vocabulary only when there is some")

        let wav = OpenScribeSupport.silentWAV(duration: 0.25, sampleRate: 16_000)
        suite.expect(wav.count == 44 + 4_000 * 2
                     && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF"
                     && String(decoding: wav[8..<12], as: UTF8.self) == "WAVE",
                     "the endpoint test uploads a well-formed quarter second of silent WAV")
    }

    // MARK: Responses

    private static func responses(_ suite: TestSuite) {
        suite.expect((try? OpenScribeSupport.parseOpenAITranscription(json(["text": "  Hello there. "]))) == "Hello there."
                     && (try? OpenScribeSupport.parseOpenAITranscription(Data("Plain answer\n".utf8))) == "Plain answer",
                     "OpenAI-compatible transcripts are read from JSON or from a plain text answer")
        suite.expect((try? OpenScribeSupport.parseOpenAITranscription(Data("<html>502</html>".utf8))) == nil
                     && (try? OpenScribeSupport.parseOpenAITranscription(json(["error": "x"]))) == nil,
                     "an HTML page or JSON without text is not taken as a transcript")

        let deepgram = json(["results": ["channels": [["alternatives": [["transcript": "Guten Tag"]]]]]])
        suite.expect((try? OpenScribeSupport.parseDeepgram(deepgram)) == "Guten Tag"
                     && (try? OpenScribeSupport.parseDeepgram(json(["results": [String: Any]()]))) == nil,
                     "Deepgram's nested transcript is read, and a missing one is an error")

        suite.expect((try? OpenScribeSupport.parseAssemblyUpload(json(["upload_url": "https://cdn/x"]))) == "https://cdn/x",
                     "the AssemblyAI upload address is read")
        let states = [json(["id": "1", "status": "queued"]),
                      json(["id": "1", "status": "completed", "text": " Done "]),
                      json(["id": "1", "status": "error", "error": "Bad audio"])]
            .compactMap { try? OpenScribeSupport.parseAssemblyTranscript($0).status }
        suite.expect(states == [.pending, .completed("Done"), .failed("Bad audio")],
                     "AssemblyAI polling distinguishes pending, finished and failed jobs")

        let chat = json(["choices": [["message": ["content": "<think>plan</think>\n\"Clean text.\""]]]])
        let parts = json(["choices": [["message": ["content": [["type": "text", "text": "Part one."]]]]]])
        suite.expect((try? OpenScribeSupport.parseChatCompletion(chat)) == "Clean text."
                     && (try? OpenScribeSupport.parseChatCompletion(parts)) == "Part one.",
                     "chat completions drop reasoning and wrapping quotes, and accept typed parts")
        let anthropic = json(["content": [["type": "thinking", "thinking": "x"], ["type": "text", "text": "Final."]]])
        let gemini = json(["candidates": [["content": ["parts": [["text": "Hallo."]]]]]])
        suite.expect((try? OpenScribeSupport.parseAnthropic(anthropic)) == "Final."
                     && (try? OpenScribeSupport.parseGemini(gemini)) == "Hallo."
                     && (try? OpenScribeSupport.parseAnthropic(json(["content": []]))) == nil,
                     "Anthropic and Gemini replies are read from their text blocks only")

        suite.expect(OpenScribeSupport.cleanedModelText("\"She said \"hi\" twice\"") == "\"She said \"hi\" twice\""
                     && OpenScribeSupport.cleanedModelText("“Quoted”") == "Quoted",
                     "only a single pair of wrapping quotes is removed; quotes inside the text stay")

        let secret = "sk-test-1234567890"
        let excerpt = OpenScribeSupport.errorExcerpt(
            json(["error": ["message": "Invalid key \(secret)\nsecond line"]]), apiKey: secret)
        suite.expect(excerpt == "Invalid key ••• second line",
                     "provider errors show their message on one line with the key masked")
        let page = Data("<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body><h1>x</h1></body></html>".utf8)
        suite.expect(OpenScribeSupport.errorExcerpt(page, apiKey: "") == "502 Bad Gateway"
                     && OpenScribeSupport.errorExcerpt(Data("<p>Not <b>found</b></p>".utf8), apiKey: "") == "Not found",
                     "an HTML error page is reduced to its title or text")
        suite.expect(OpenScribeSupport.errorExcerpt(Data(String(repeating: "x", count: 900).utf8), apiKey: "")
                        .count == OpenScribeSupport.errorBodyLimit + 1,
                     "long error bodies are truncated for the HUD")
    }

    // MARK: Presets

    private static func presets(_ suite: TestSuite) {
        suite.expect(OpenScribePreset.allCases.allSatisfy {
            $0.api.roles.contains($0.role)
                && OpenScribeSupport.validatedBaseURL($0.baseURL) != nil
                && !$0.model.isEmpty && !$0.name.isEmpty
        }, "every preset is a valid, usable endpoint for its role")
        suite.expect(!OpenScribePreset.presets(for: .transcription).isEmpty
                     && !OpenScribePreset.presets(for: .cleanup).isEmpty,
                     "both roles offer presets")
        suite.expect(OpenScribePreset.allCases.filter { $0.baseURL.hasPrefix("http:") }
                        .allSatisfy { !OpenScribeSupport.isUnencryptedRemote($0.baseURL) },
                     "presets use plain http only for servers on this Mac")
        suite.expect(Set(OpenScribeEndpointAPI.available(for: .transcription))
                        == [.openAICompatible, .deepgram, .assemblyAI]
                     && Set(OpenScribeEndpointAPI.available(for: .cleanup))
                        == [.openAICompatible, .anthropic, .gemini],
                     "each role lists only the APIs that can serve it")
        let preset = OpenScribePreset.groqTranscription.endpoint()
        suite.expect(preset.role == .transcription && preset.api == .openAICompatible
                     && preset.displayName == "Groq",
                     "a preset fills the endpoint form")
        suite.expect(OpenScribeEndpoint(name: "  ", role: .cleanup, api: .gemini,
                                        baseURL: "https://g.test", model: "gemini").displayName == "gemini",
                     "an unnamed endpoint is shown by its model")
    }

    // MARK: Catalog, defaults and backup

    private static func catalog(_ suite: TestSuite) {
        suite.expect((AppFeature.availabilityDefaults[AppFeature.openScribe.availabilityKey] as? Bool) == false,
                     "OpenScribe is opt-in: it ships uninstalled")
        suite.expect(AppFeature.openScribe.group == .tools
                     && AppFeature.openScribe.permissions.contains(.microphone)
                     && AppFeature.openScribe.permissions.contains(.accessibility)
                     && AppFeature.openScribe.enabledKeys.isEmpty,
                     "OpenScribe is an on-demand tool that uses the microphone and Accessibility")

        func active(_ permission: AppPermission, delivery: String) -> Bool {
            AppFeature.activeFeatures(using: permission,
                                      isAvailable: { $0 == .openScribe },
                                      boolFor: { _ in false },
                                      stringFor: { $0 == DefaultsKey.openScribeDelivery ? delivery : nil })
                .contains(.openScribe)
        }
        suite.expect(active(.accessibility, delivery: "paste") && !active(.accessibility, delivery: "copy")
                     && active(.microphone, delivery: "copy"),
                     "Accessibility is only claimed while text is pasted; the microphone always")

        let defaults = Defaults.registeredDefaults
        suite.expect(defaults[DefaultsKey.openScribeShortcutEnabled] as? Bool == true
                     && defaults[DefaultsKey.panelUtilityOpenScribe] as? Bool == true
                     && defaults[DefaultsKey.openScribeDelivery] as? String == OpenScribeDelivery.paste.rawValue
                     && defaults[DefaultsKey.openScribeShortcut] as? String
                        == GlobalShortcut.openScribeDefault.storageValue,
                     "installing OpenScribe arms its shortcut and panel tile, pasting by default")

        let exported = SettingsBackupSupport.exportKeys()
        suite.expect([DefaultsKey.openScribeEndpoints, DefaultsKey.openScribeTranscriptionEndpoint,
                      DefaultsKey.openScribeCleanupEndpoint, DefaultsKey.openScribeDelivery,
                      DefaultsKey.openScribeVocabulary, DefaultsKey.openScribeShortcut]
                        .allSatisfy(exported.contains),
                     "OpenScribe preferences travel with settings backups (keys stay in the keychain)")

        let role = GlobalShortcutRole.openScribe
        suite.expect(role.feature == .openScribe
                     && role.requiredEnableKeys == [DefaultsKey.openScribeShortcutEnabled]
                     && GlobalShortcutRole.featuresToSilenceWhileRecording.contains(.openScribe),
                     "the OpenScribe shortcut follows its feature and toggle")
        suite.expect(!GlobalShortcutRole.allCases.contains {
            $0 != role && $0.defaultShortcut == GlobalShortcut.openScribeDefault
        }, "the default OpenScribe shortcut collides with no other default")

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.openScribe(language)
            suite.expect(strings.title == "OpenScribe",
                         "the product name stays untranslated in \(language.rawValue)")
            if language != .enUS {
                suite.expect(strings.hubDescription != OpenScribeFeatureStrings.enUS.hubDescription
                             && strings.shortcutCaption != OpenScribeFeatureStrings.enUS.shortcutCaption,
                             "OpenScribe is translated in \(language.rawValue)")
            }
        }
    }
}
