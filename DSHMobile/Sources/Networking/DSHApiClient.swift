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

    func validate(config: ServerConfig) async throws { try await Task.sleep(for: .milliseconds(400)) }

    func createConversation() async throws -> String { "mock-" + UUID().uuidString }

    func conversations() async throws -> [Conversation] {
        [
            Conversation(id: "a", title: "DSH Mobile build plan", snippet: "Plan written to PLAN.md — Phase 0 gate first…", updatedAt: clock.addingTimeInterval(-3 * 60), isArchived: false),
            Conversation(id: "b", title: "email-manager 405 fix", snippet: "Switched to /api/email fetch routes…", updatedAt: clock.addingTimeInterval(-5 * 3600), isArchived: false),
            Conversation(id: "c", title: "Gmail app password cleanup", snippet: "Deleted duplicate Keychain entries…", updatedAt: clock.addingTimeInterval(-2 * 86_400), isArchived: false),
            Conversation(id: "d", title: "Archived: Legacy proxy spike", snippet: "Deprecated reverse proxy spike notes…", updatedAt: clock.addingTimeInterval(-10 * 86_400), isArchived: true),
        ]
    }

    func messages(conversationId: String) async throws -> MessagePage {
        let demo: [Message] = [
            Message(id: "m1", role: .user, parts: [
                .plain("Can you show me what a full transcript looks like?"),
                MessagePart(kind: .image, name: "IMG_1976.HEIC", mediaType: "image/png"),
            ], createdAt: clock.addingTimeInterval(-600)),
            Message(id: "m2", role: .assistant, parts: [
                MessagePart(kind: .think, text: "The user wants a demo of the transcript rendering. Exercise every row type once."),
                MessagePart(kind: .text, text: "Sure — let me take it apart piece by piece."),
                MessagePart(kind: .tool, name: "Code", title: "List workspace files", status: .ok, sub: [
                    SubCall(name: "Bash", title: "ls -la", status: .ok, exitCode: 0),
                    SubCall(name: "Read", title: "PLAN.md", status: .ok),
                ]),
                MessagePart(kind: .tool, name: "Code", title: "Check bridge health", status: .error, error: "curl: (7) Failed to connect to 127.0.0.1 port 8328: Connection refused", sub: [
                    SubCall(name: "Bash", title: "curl -s localhost:8328/health", status: .error, exitCode: 7),
                ]),
                MessagePart(kind: .context, label: "user-approval/runtime-context/time-context"),
                MessagePart(kind: .text, text: "That covers reasoning, prose, tool steps, a failed call, injected context and attachments."),
            ], createdAt: clock.addingTimeInterval(-590)),
        ]
        let plain: [Message] = [
            Message(id: "m1", role: .user, text: "Summarize where the iOS app stands.", createdAt: clock.addingTimeInterval(-600)),
            Message(id: "m2", role: .assistant, text: "PLAN.md is written. Phase 0 proves LAN reachability from Safari; Phase 1 captures the RPC wire format. Design tokens are in flight.", createdAt: clock.addingTimeInterval(-590)),
        ]
        return MessagePage(messages: conversationId == "a" ? demo : plain, model: conversationId == "a" ? "GPT OSS 120B" : nil)
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
