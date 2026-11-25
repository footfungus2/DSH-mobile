import Foundation

/// Server endpoint configuration, entered once on the Connect screen.
struct ServerConfig: Codable, Equatable {
    /// Bridge base URL (or legacy tokenized `dsh web` URL), e.g. http://192.168.1.20:8328
    var tokenURL: String

    var authority: URL? { URL(string: tokenURL) }
}

/// The app talks to the `@local/mobile-bridge` plugin's REST surface:
/// /health, /sessions, /sessions/:id/messages, /sessions/:id/prompt.
protocol DSHServicing {
    func validate(config: ServerConfig) async throws
    func createConversation() async throws -> String
    func conversations() async throws -> [Conversation]
    func messages(conversationId: String) async throws -> MessagePage
    func models() async throws -> [ModelInfo]
    func setModel(conversationId: String, name: String) async throws
    func setArchived(conversationId: String, archived: Bool) async throws
    func setPinned(conversationId: String, pinned: Bool) async throws
    func send(conversationId: String, text: String, model: String) -> AsyncThrowingStream<String, Error>
    func attachmentData(sha: String, mediaType: String) async throws -> Data
    func bridgeInfo() async throws -> BridgeInfo
    var lastPromptModel: String? { get }
}

struct BridgeInfo: Decodable {
    let ok: Bool
    let name: String?
    let version: String?

    var display: String? {
        guard ok, let name, let version else { return nil }
        return "\(name) \(version)"
    }
}

extension DSHServicing {
    func attachmentData(sha: String, mediaType: String) async throws -> Data {
        throw DSHError.notConfigured
    }
    func bridgeInfo() async throws -> BridgeInfo {
        BridgeInfo(ok: false, name: nil, version: nil)
    }
    func setArchived(conversationId: String, archived: Bool) async throws {}
    func setPinned(conversationId: String, pinned: Bool) async throws {}
    var lastPromptModel: String? { nil }
}

enum DSHError: LocalizedError {
    case notConfigured
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server configured."
        case .handshakeFailed(let why): "Bridge request failed: \(why)"
        }
    }
}

final class DSHApiClient: DSHServicing {
    private var config: ServerConfig?
    private(set) var lastPromptModel: String?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.timeoutIntervalForRequest = 200
        return URLSession(configuration: cfg)
    }()

    func configure(_ config: ServerConfig) { self.config = config }

    private func base() throws -> URL {
        guard let url = config?.authority else { throw DSHError.notConfigured }
        guard let scheme = url.scheme, let host = url.host else { return url }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url ?? url
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let b = try base()
        let root = b.absoluteString.hasSuffix("/") ? String(b.absoluteString.dropLast()) : b.absoluteString
        guard let target = URL(string: root + "/" + path) else {
            throw DSHError.handshakeFailed("bad URL for \(path)")
        }
        var req = URLRequest(url: target)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = body
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DSHError.handshakeFailed("no HTTP response from \(path)")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw DSHError.handshakeFailed(detail ?? "HTTP \(http.statusCode) on \(path)")
        }
        return data
    }

    private struct ErrorResponse: Decodable { let error: String }

    func validate(config: ServerConfig) async throws {
        self.config = config
        struct Health: Decodable { let ok: Bool }
        let health = try await request("health")
        guard (try? JSONDecoder().decode(Health.self, from: health))?.ok == true else {
            throw DSHError.handshakeFailed("bridge at \(config.tokenURL) did not answer /health")
        }
    }

    func bridgeInfo() async throws -> BridgeInfo {
        try JSONDecoder().decode(BridgeInfo.self, from: try await request("health"))
    }

    /// The bridge creates the session lazily on the first prompt, so a fresh
    /// chat can start with a placeholder id.
    func createConversation() async throws -> String {
        "new"
    }

    func conversations() async throws -> [Conversation] {
        struct SessionDTO: Decodable {
            let id: String
            let title: String?
            let snippet: String?
            let updatedAt: Double?
            let archived: Bool?
            let pinned: Bool?
            let model: String?
            let running: Bool?
        }
        struct Response: Decodable { let ok: Bool; let sessions: [SessionDTO] }
        let data = try await request("sessions")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.sessions.map {
            Conversation(
                id: $0.id,
                title: $0.title ?? "Untitled",
                snippet: $0.snippet ?? "",
                updatedAt: $0.updatedAt.map(Date.init(msSince1970:)) ?? .now,
                isArchived: $0.archived ?? false,
                isPinned: $0.pinned ?? false,
                model: $0.model
            )
        }
    }

    func messages(conversationId: String) async throws -> MessagePage {
        struct MessageDTO: Decodable {
            let role: String
            let time: Double
            var model: String?
            let parts: [MessagePart]?
            // Legacy fallback shape (plain text, no typed parts).
            let text: String?
        }
        struct Response: Decodable { let ok: Bool; let messages: [MessageDTO]; let model: String? }
        let data = try await request("sessions/\(conversationId)/messages")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let messages = decoded.messages.enumerated().map { index, dto in
            let parts = dto.parts ?? [MessagePart.plain(dto.text ?? "")]
            return Message(id: "\(conversationId)-\(index)-\(Int(dto.time))",
                           role: Role(rawValue: dto.role) ?? .assistant,
                           parts: parts,
                           createdAt: Date(msSince1970: dto.time))
        }
        return MessagePage(messages: messages, model: decoded.model)
    }

    /// Real sessions store images on the host; mocks embed base64 inline.
    func attachmentData(sha: String, mediaType: String) async throws -> Data {
        let encoded = sha.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sha
        return try await request("attachments/\(encoded)?type=\(mediaType)")
    }

    func models() async throws -> [ModelInfo] {
        struct ModelDTO: Decodable { let name: String; let label: String; let provider: String? }
        struct Response: Decodable { let ok: Bool; let models: [ModelDTO] }
        let data = try await request("models")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.models.map { ModelInfo(name: $0.name, label: $0.label, provider: $0.provider) }
    }

    func setModel(conversationId: String, name: String) async throws {
        guard !conversationId.hasPrefix("local-"), conversationId != "new" else { return }
        let body = try JSONEncoder().encode(["name": name])
        _ = try await request("sessions/\(conversationId)/model", method: "POST", body: body)
    }

    func setArchived(conversationId: String, archived: Bool) async throws {
        try await setState(conversationId: conversationId, action: archived ? "archive" : "unarchive")
    }

    func setPinned(conversationId: String, pinned: Bool) async throws {
        try await setState(conversationId: conversationId, action: pinned ? "pin" : "unpin")
    }

    private func setState(conversationId: String, action: String) async throws {
        guard !conversationId.hasPrefix("local-"), !conversationId.hasPrefix("mock-"), conversationId != "new" else { return }
        _ = try await request("sessions/\(conversationId)/\(action)", method: "POST", body: Data("{}".utf8))
    }

    func send(conversationId: String, text: String, model: String) -> AsyncThrowingStream<String, Error> {
        struct Response: Decodable { let ok: Bool; let reply: String?; let model: String? }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var path = "sessions/\(conversationId)/prompt"
                    if conversationId.hasPrefix("local-") { path = "sessions/new/prompt" }
                    let body = try JSONEncoder().encode(["text": text, "model": model])
                    let data = try await self.request(path, method: "POST", body: body)
                    let decoded = try JSONDecoder().decode(Response.self, from: data)
                    self.lastPromptModel = decoded.model
                    let reply = decoded.reply ?? ""
                    for chunk in reply.chunked(by: 3) {
                        try await Task.sleep(for: .milliseconds(40))
                        continuation.yield(chunk + " ")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// In-repo fake so every screen stays runnable without a bridge on the network.
final class MockDSHClient: DSHServicing {
    private let clock = Date.now

    func bridgeInfo() async throws -> BridgeInfo { BridgeInfo(ok: true, name: "DSH Mobile Bridge", version: "0.1.0") }

    private static let attachmentBase64 = "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"

    func validate(config: ServerConfig) async throws { try await Task.sleep(for: .milliseconds(400)) }

    func createConversation() async throws -> String { "mock-" + UUID().uuidString }

    func conversations() async throws -> [Conversation] {
        [
            Conversation(id: "a", title: "Show me a full transcript", snippet: "That covers reasoning, prose, tool steps, a failed call, injected context and attach…", updatedAt: clock.addingTimeInterval(-3 * 60)),
            Conversation(id: "b", title: "Debug flaky CI on main", snippet: "The timeout only fires on the arm64 runner — I traced it to the checkout step…", updatedAt: clock.addingTimeInterval(-5 * 3600), isPinned: true),
            Conversation(id: "c", title: "Kyoto trip itinerary", snippet: "Three days: Fushimi at dawn, Arashiyama bamboo, one rainy-day museum slot…", updatedAt: clock.addingTimeInterval(-2 * 86_400)),
            Conversation(id: "d", title: "Explain this stack trace", snippet: "A tokio task panic wrapping a borrow-checker false alarm — harmless but noisy…", updatedAt: clock.addingTimeInterval(-3 * 86_400)),
            Conversation(id: "e", title: "Legacy proxy spike notes", snippet: "Notes from the deprecated reverse-proxy experiment, kept for the archive…", updatedAt: clock.addingTimeInterval(-10 * 86_400), isArchived: true),
        ]
    }

    func messages(conversationId: String) async throws -> MessagePage {
        let demo: [Message] = [
            Message(id: "m1", role: .user, parts: [
                .plain("Can you show me what a full transcript looks like?"),
                MessagePart(kind: .image, name: "IMG_2048.jpg", mediaType: "image/jpeg", data: Self.attachmentBase64),
            ], createdAt: clock.addingTimeInterval(-600)),
            Message(id: "m2", role: .assistant, parts: [
                MessagePart(kind: .think, text: "The user wants a demo of the transcript rendering. Exercise every row type once."),
                MessagePart(kind: .text, text: "Sure — let me take it apart piece by piece."),
                MessagePart(kind: .tool, name: "Code", title: "List workspace files", status: .ok, sub: [
                    SubCall(name: "Bash", title: "ls -la", status: .ok, exitCode: 0),
                    SubCall(name: "Read", title: "README.md", status: .ok),
                ]),
                MessagePart(kind: .tool, name: "Code", title: "Check bridge health", status: .error, error: "curl: (7) Failed to connect to 127.0.0.1 port 8328: Connection refused", sub: [
                    SubCall(name: "Bash", title: "curl -s localhost:8328/health", status: .error, exitCode: 7),
                ]),
                MessagePart(kind: .context, label: "user-approval/runtime-context/time-context"),
                MessagePart(kind: .text, text: "That covers reasoning, prose, tool steps, a failed call, injected context and attachments."),
            ], createdAt: clock.addingTimeInterval(-590)),
        ]
        let plain: [Message] = [
            Message(id: "m1", role: .user, text: "Summarize where the refactor stands.", createdAt: clock.addingTimeInterval(-600)),
            Message(id: "m2", role: .assistant, text: "The middleware sits behind a feature flag, token rotation has tests, and the legacy path can go once CI is green.", createdAt: clock.addingTimeInterval(-590)),
        ]
        return MessagePage(messages: conversationId == "a" ? demo : plain, model: conversationId == "a" ? "DeepSeek-V4-Pro" : nil)
    }

    func models() async throws -> [ModelInfo] {
        [
            ModelInfo(name: "deepseek-account/deepseek-flash", label: "DeepSeek-V4.1-Flash", provider: "deepseek-account"),
            ModelInfo(name: "deepseek-account/deepseek-v4-pro", label: "DeepSeek-V4-Pro", provider: "deepseek-account"),
            ModelInfo(name: "openai/gpt-4o", label: "GPT-4o", provider: "openai"),
            ModelInfo(name: "anthropic/claude-3-5-sonnet", label: "Claude 3.5 Sonnet", provider: "anthropic"),
            ModelInfo(name: "deepseek-chat", label: "DeepSeek Chat", provider: "deepseek"),
            ModelInfo(name: "deepseek-reasoner", label: "DeepSeek Reasoner", provider: "deepseek")
        ]
    }

    func setModel(conversationId: String, name: String) async throws {}

    func send(conversationId: String, text: String, model: String) -> AsyncThrowingStream<String, Error> {
        let words = ("Streaming works end to end in the mock client. Next stop: the real bridge capture. " + text).split(separator: " ").map(String.init)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in words {
                    try? await Task.sleep(for: .milliseconds(60))
                    if Task.isCancelled { break }
                    continuation.yield(word + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension Date {
    init(msSince1970: Double) { self.init(timeIntervalSince1970: msSince1970 / 1000) }
}

private extension String {
    /// Group whitespace-separated words into chunks of at most `size`.
    func chunked(by size: Int) -> [String] {
        let words = split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }
        return stride(from: 0, to: words.count, by: size).map {
            words[$0..<min($0 + size, words.count)].joined(separator: " ")
        }
    }
}
