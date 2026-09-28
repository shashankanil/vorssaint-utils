// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Talks to the endpoints the user configured. Every request goes only to
/// the saved base address; the key travels in the header each API expects.
struct OpenScribeClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case missingKey(String)
        case http(Int, String)
        case unreadable
        case provider(String)

        func message(_ strings: OpenScribeFeatureStrings) -> String {
            switch self {
            case .invalidURL: return strings.invalidURL
            case .missingKey(let name): return String(format: strings.needsKeyFormat, name)
            case .http(let status, let body): return String(format: strings.httpErrorFormat, status, body)
            case .unreadable: return strings.unreadableResponse
            case .provider(let message): return message
            }
        }

        var errorDescription: String? { message(FeatureStrings.openScribe(L10n.shared.language)) }
    }

    struct Options {
        var language = ""
        var vocabulary: [String] = []
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func message(for error: Error, _ strings: OpenScribeFeatureStrings) -> String {
        if let error = error as? ClientError { return error.message(strings) }
        return error.localizedDescription
    }

    // MARK: Transcription

    func transcribe(audio: Data, fileName: String, endpoint: OpenScribeEndpoint, key: String?,
                    options: Options) async throws -> String {
        let key = try resolvedKey(key, for: endpoint)
        switch endpoint.api {
        case .openAICompatible:
            return try await transcribeOpenAI(audio: audio, fileName: fileName, endpoint: endpoint,
                                              key: key, options: options)
        case .deepgram:
            return try await transcribeDeepgram(audio: audio, endpoint: endpoint, key: key, options: options)
        case .assemblyAI:
            return try await transcribeAssembly(audio: audio, endpoint: endpoint, key: key, options: options)
        case .anthropic, .gemini:
            throw ClientError.invalidURL
        }
    }

    private func transcribeOpenAI(audio: Data, fileName: String, endpoint: OpenScribeEndpoint,
                                  key: String, options: Options) async throws -> String {
        guard let url = OpenScribeSupport.url(base: endpoint.baseURL, path: "/audio/transcriptions") else {
            throw ClientError.invalidURL
        }
        let boundary = "Vorssaint-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorizeBearer(&request, key: key, endpoint: endpoint)
        request.httpBody = OpenScribeSupport.multipartBody(
            boundary: boundary,
            fields: OpenScribeSupport.transcriptionFields(model: endpoint.model,
                                                          language: options.language,
                                                          vocabulary: options.vocabulary),
            fileField: "file", fileName: fileName, mimeType: "audio/wav", fileData: audio)
        let data = try await send(request, key: key)
        return try parse { try OpenScribeSupport.parseOpenAITranscription(data) }
    }

    private func transcribeDeepgram(audio: Data, endpoint: OpenScribeEndpoint, key: String,
                                    options: Options) async throws -> String {
        guard let base = OpenScribeSupport.url(base: endpoint.baseURL, path: "/listen"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw ClientError.invalidURL }
        components.queryItems = OpenScribeSupport.deepgramQuery(model: endpoint.model,
                                                                language: options.language,
                                                                vocabulary: options.vocabulary)
        guard let url = components.url else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        let data = try await send(request, key: key)
        return try parse { try OpenScribeSupport.parseDeepgram(data) }
    }

    private func transcribeAssembly(audio: Data, endpoint: OpenScribeEndpoint, key: String,
                                    options: Options) async throws -> String {
        guard let uploadURL = OpenScribeSupport.url(base: endpoint.baseURL, path: "/upload"),
              let transcriptURL = OpenScribeSupport.url(base: endpoint.baseURL, path: "/transcript")
        else { throw ClientError.invalidURL }
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(key, forHTTPHeaderField: "Authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = audio
        let uploadData = try await send(upload, key: key)
        let audioURL = try parse { try OpenScribeSupport.parseAssemblyUpload(uploadData) }

        var payload: [String: Any] = ["audio_url": audioURL, "speech_model": endpoint.model]
        if options.language.isEmpty {
            payload["language_detection"] = true
        } else {
            payload["language_code"] = options.language
        }
        if !options.vocabulary.isEmpty { payload["word_boost"] = options.vocabulary }
        var create = try jsonRequest(transcriptURL, payload)
        create.setValue(key, forHTTPHeaderField: "Authorization")
        let createData = try await send(create, key: key)
        var state = try parse { try OpenScribeSupport.parseAssemblyTranscript(createData) }

        // Poll with a total bound; the whole dictation is also cancellable.
        for _ in 0..<120 {
            switch state.status {
            case .completed(let text): return text
            case .failed(let message): throw ClientError.provider(message)
            case .pending: break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let pollURL = OpenScribeSupport.url(base: endpoint.baseURL, path: "/transcript/\(state.id)")
            else { throw ClientError.invalidURL }
            var poll = URLRequest(url: pollURL)
            poll.setValue(key, forHTTPHeaderField: "Authorization")
            let pollData = try await send(poll, key: key)
            state = try parse { try OpenScribeSupport.parseAssemblyTranscript(pollData) }
        }
        throw URLError(.timedOut)
    }

    // MARK: Cleanup

    func cleanUp(_ text: String, endpoint: OpenScribeEndpoint, key: String?,
                 vocabulary: [String]) async throws -> String {
        let key = try resolvedKey(key, for: endpoint)
        let system = OpenScribeSupport.cleanupSystemPrompt(vocabulary: vocabulary)
        let result: String
        switch endpoint.api {
        case .openAICompatible:
            guard let url = OpenScribeSupport.url(base: endpoint.baseURL, path: "/chat/completions") else {
                throw ClientError.invalidURL
            }
            var request = try jsonRequest(url, [
                "model": endpoint.model,
                "temperature": 0.1,
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": text]],
            ])
            authorizeBearer(&request, key: key, endpoint: endpoint)
            let data = try await send(request, key: key)
            result = try parse { try OpenScribeSupport.parseChatCompletion(data) }
        case .anthropic:
            guard let url = OpenScribeSupport.url(base: endpoint.baseURL, path: "/v1/messages") else {
                throw ClientError.invalidURL
            }
            var request = try jsonRequest(url, [
                "model": endpoint.model,
                "max_tokens": 4096,
                "temperature": 0.1,
                "system": system,
                "messages": [["role": "user", "content": text]],
            ])
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await send(request, key: key)
            result = try parse { try OpenScribeSupport.parseAnthropic(data) }
        case .gemini:
            let model = endpoint.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? endpoint.model
            guard let url = OpenScribeSupport.url(base: endpoint.baseURL,
                                                  path: "/v1beta/models/\(model):generateContent") else {
                throw ClientError.invalidURL
            }
            var request = try jsonRequest(url, [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["temperature": 0.1],
            ])
            // The header keeps the key out of URLs, logs and proxies.
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let data = try await send(request, key: key)
            result = try parse { try OpenScribeSupport.parseGemini(data) }
        case .deepgram, .assemblyAI:
            throw ClientError.invalidURL
        }
        guard !result.isEmpty else { throw ClientError.unreadable }
        return result
    }

    // MARK: Testing an endpoint

    /// A minimal real call: a quarter second of silence for transcription, a
    /// one-word edit for cleanup. Success means the address, model and key work.
    func test(_ endpoint: OpenScribeEndpoint, key: String?) async throws {
        switch endpoint.role {
        case .transcription:
            _ = try await transcribe(audio: OpenScribeSupport.silentWAV(), fileName: "test.wav",
                                     endpoint: endpoint, key: key, options: Options())
        case .cleanup:
            _ = try await cleanUp("hello", endpoint: endpoint, key: key, vocabulary: [])
        }
    }

    // MARK: Plumbing

    private func resolvedKey(_ key: String?, for endpoint: OpenScribeEndpoint) throws -> String {
        let key = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && OpenScribeSupport.requiresKey(endpoint) {
            throw ClientError.missingKey(endpoint.displayName)
        }
        return key
    }

    private func authorizeBearer(_ request: inout URLRequest, key: String, endpoint: OpenScribeEndpoint) {
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if URL(string: endpoint.baseURL)?.host?.lowercased().hasSuffix("openrouter.ai") == true {
            request.setValue("https://github.com/vorssaint/vorssaint-utils", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Vorssaint", forHTTPHeaderField: "X-Title")
        }
    }

    private func jsonRequest(_ url: URL, _ payload: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func send(_ request: URLRequest, key: String) async throws -> Data {
        var request = request
        request.timeoutInterval = OpenScribeSupport.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, OpenScribeSupport.errorExcerpt(data, apiKey: key))
        }
        return data
    }

    private func parse<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch OpenScribeSupport.ParseError.provider(let message) {
            throw ClientError.provider(message)
        } catch {
            throw ClientError.unreadable
        }
    }
}
