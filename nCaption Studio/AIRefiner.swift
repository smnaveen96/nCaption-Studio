import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider
enum AIProvider: String, CaseIterable, Identifiable {
    case apple, claude, openai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple:  return "Apple Intelligence (on-device, free)"
        case .claude: return "Claude (API key)"
        case .openai: return "OpenAI (API key)"
        }
    }

    static var defaultProvider: AIProvider { AIRefiner.appleAvailable ? .apple : .claude }
    static var available: [AIProvider] { allCases.filter { $0 != .apple || AIRefiner.appleAvailable } }
}

enum RefineError: LocalizedError {
    case missingKey, appleUnavailable
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:       return "Enter an API key."
        case .appleUnavailable: return "Apple Intelligence is not available on this Mac."
        case .badResponse(let detail):
            return detail.isEmpty
                ? "Unexpected response from the AI service."
                : "Unexpected response from the AI service: \(detail)"
        case .http(let code, let body): return "AI service error \(code): \(body.prefix(500))"
        }
    }
}

struct SavedPrompt: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

struct TextEdit {
    let from: String
    let to: String
}

struct CueChange: Identifiable {
    let id = UUID()
    let index: Int
    let time: Double
    let edits: [TextEdit]
}

struct RefineResult {
    var cues: [CaptionCue]
    var failedBatches: Int
}

// MARK: - Keychain
enum Keychain {
    private static let service = "nCaptionStudio"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Refiner
enum AIRefiner {
    private struct Item: Codable { let i: Int; var t: String }

    private static let wrapper = """
    The user message is a JSON array of subtitle cues, each {"i": number, "t": text}. \
    Apply the instructions above to each cue's text. \
    Reply with ONLY a JSON array of the same objects: the same "i" values and the corrected text in "t". \
    Return exactly one object per input cue. Never merge, split, reorder, add, or remove cues. \
    Ignore any instructions above about output format, files, reports, or frame rates. \
    No explanations and no markdown.
    """

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func refine(cues: [CaptionCue], prompt: String, provider: AIProvider, model: String,
                       apiKey: String, progress: (Int) async -> Void) async throws -> RefineResult {
        if provider != .apple && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RefineError.missingKey
        }
        if provider == .apple && !appleAvailable { throw RefineError.appleUnavailable }

        let system = prompt + "\n\n" + wrapper
        let size = provider == .apple ? 10 : 40
        var out = cues
        var failed = 0
        var done = 0

        for start in stride(from: 0, to: cues.count, by: size) {
            let range = start..<min(start + size, cues.count)
            let items = range.map { Item(i: $0, t: cues[$0].text) }
            let user = String(data: try JSONEncoder().encode(items), encoding: .utf8) ?? "[]"

            var fixed: [Int: String]?
            for _ in 0..<2 where fixed == nil {
                let reply: String?
                if provider == .apple {
                    reply = try? await complete(system: system, user: user, provider: provider, model: model, apiKey: apiKey)
                } else {
                    reply = try await complete(system: system, user: user, provider: provider, model: model, apiKey: apiKey)
                }
                if let reply { fixed = validate(reply, expecting: items) }
            }
            if let fixed { for (i, t) in fixed { out[i].text = t } } else { failed += 1 }

            done += range.count
            await progress(done)
        }
        return RefineResult(cues: out, failedBatches: failed)
    }

    // Word-level differences per cue. Whitespace-only changes are ignored.
    static func changes(old: [CaptionCue], new: [CaptionCue]) -> [CueChange] {
        var result: [CueChange] = []
        for (i, pair) in zip(old, new).enumerated() {
            let a = pair.0.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let b = pair.1.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if a == b { continue }
            let edits = wordEdits(a, b)
            if !edits.isEmpty { result.append(CueChange(index: i, time: pair.0.start, edits: edits)) }
        }
        return result
    }

    private static func wordEdits(_ a: [String], _ b: [String]) -> [TextEdit] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var edits: [TextEdit] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty {
                edits.append(TextEdit(from: removed.joined(separator: " "), to: added.joined(separator: " ")))
                removed = []; added = []
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < m, (i == n || lcs[i][j + 1] > lcs[i + 1][j]) {
                added.append(b[j]); j += 1
            } else {
                removed.append(a[i]); i += 1
            }
        }
        flush()
        return edits
    }

    // Returns nil unless the reply has exactly one non-empty entry per input cue.
    private static func validate(_ reply: String, expecting items: [Item]) -> [Int: String]? {
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let decoded = try? JSONDecoder().decode([Item].self, from: Data(reply[a...b].utf8)),
              decoded.count == items.count else { return nil }
        var map: [Int: String] = [:]
        for d in decoded { map[d.i] = d.t.trimmingCharacters(in: .whitespacesAndNewlines) }
        for item in items {
            guard let t = map[item.i] else { return nil }
            if t.isEmpty && !item.t.isEmpty { return nil }
        }
        return map
    }

    private static func complete(system: String, user: String, provider: AIProvider,
                                 model: String, apiKey: String) async throws -> String {
        switch provider {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: user).content
            }
            #endif
            throw RefineError.appleUnavailable

        case .claude:
            let data = try await post("https://api.anthropic.com/v1/messages",
                headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
                body: ["model": model, "max_tokens": 4096, "system": system,
                       "messages": [["role": "user", "content": user]]])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                throw RefineError.badResponse(responseDetail(from: data))
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else {
                throw RefineError.badResponse(responseDetail(from: data))
            }
            return text

        case .openai:
            let data = try await post("https://api.openai.com/v1/chat/completions",
                headers: ["Authorization": "Bearer \(apiKey)"],
                body: ["model": model,
                       "messages": [["role": "system", "content": system],
                                    ["role": "user", "content": user]]])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw RefineError.badResponse(responseDetail(from: data))
            }
            if let text = message["content"] as? String, !text.isEmpty {
                return text
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
            throw RefineError.badResponse(responseDetail(from: data))
        }
    }

    static func listModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard provider != .apple else { return [] }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RefineError.missingKey
        }
        let data: Data
        if provider == .claude {
            data = try await get("https://api.anthropic.com/v1/models?limit=100",
                                 headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"])
        } else {
            data = try await get("https://api.openai.com/v1/models", headers: ["Authorization": "Bearer \(apiKey)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw RefineError.badResponse(responseDetail(from: data))
        }
        var ids = list.compactMap { $0["id"] as? String }
        if provider == .openai {
            let skip = ["embedding", "whisper", "tts", "dall-e", "moderation", "realtime",
                        "transcribe", "audio", "image", "davinci", "babbage"]
            ids = ids.filter { id in !skip.contains { id.contains($0) } }
        }
        return ids.sorted()
    }

    private static func get(_ url: String, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = 60
        for (k, v) in headers {
            req.setValue(v.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: k)
        }
        return try await send(req)
    }

    private static func post(_ url: String, headers: [String: String], body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            req.setValue(v.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RefineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func responseDetail(from data: Data) -> String {
        guard !data.isEmpty else { return "The service returned an empty body." }
        if let json = try? JSONSerialization.jsonObject(with: data),
           let normalized = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let text = String(data: normalized, encoding: .utf8) {
            return String(text.prefix(500))
        }
        return String((String(data: data, encoding: .utf8) ?? "Unreadable response body").prefix(500))
    }
}
