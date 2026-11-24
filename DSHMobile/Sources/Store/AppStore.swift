import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppStore {
    enum ConnectionState: Equatable {
        case offline, connecting, connected(String), failed(String)
    }

    var server: ServerConfig?
    var connection: ConnectionState = .offline
    var conversations: [Conversation] = []
    var selected: Conversation?
    var messages: [Message] = []
    var models: [ModelInfo] = []
    /// The selected conversation's live model label, as the harness reports it.
    var sessionModelLabel: String?
    var defaultModel: String = UserDefaults.standard.string(forKey: "defaultModel") ?? "deepseek-chat" {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "defaultModel") }
    }
    var streamTask: Task<Void, Never>?
    var lastHandshake: Date?

    var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
    var archived: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "archived") ?? [])

    let client: DSHServicing
    var usesMock: Bool { client is MockDSHClient }

    init(client: DSHServicing) {
        self.client = client
        if let data = UserDefaults.standard.data(forKey: "serverConfig"),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            self.server = config
        } else {
            #if targetEnvironment(simulator)
            self.server = ServerConfig(tokenURL: "http://127.0.0.1:8328")
            #endif
        }
    }

    func isArchived(_ id: String) -> Bool {
        if archived.contains(id) { return true }
        if let match = conversations.first(where: { $0.id == id }), match.isArchived == true {
            return true
        }
        return false
    }

    func isPinned(_ id: String) -> Bool {
        if pinned.contains(id) { return true }
        if let match = conversations.first(where: { $0.id == id }), match.isPinned == true {
            return true
        }
        return false
    }

    func toggleArchive(_ id: String) {
        let shouldArchive = !isArchived(id)
        if shouldArchive {
            archived.insert(id)
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].isArchived = true
            }
            if pinned.remove(id) != nil {
                UserDefaults.standard.set(Array(pinned), forKey: "pinned")
            }
        } else {
            archived.remove(id)
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].isArchived = false
            }
        }
        UserDefaults.standard.set(Array(archived), forKey: "archived")
        Task { try? await client.setArchived(conversationId: id, archived: shouldArchive) }
    }

    func togglePin(_ id: String) {
        let shouldPin = !isPinned(id)
        if shouldPin { pinned.insert(id) } else { pinned.remove(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
        Task { try? await client.setPinned(conversationId: id, pinned: shouldPin) }
    }

    func clearLocalChatState() {
        pinned.removeAll()
        archived.removeAll()
        UserDefaults.standard.set([], forKey: "pinned")
        UserDefaults.standard.set([], forKey: "archived")
    }

    /// Clears every preference except the saved server, so a reset never
    /// signs the user out of the bridge.
    static func resetSettings() {
        let keep: Set<String> = ["serverConfig", "bridgeURL"]
        for key in UserDefaults.standard.dictionaryRepresentation().keys where !keep.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func delete(_ id: String) {
        conversations.removeAll { $0.id == id }
        togglePinContainsRemoval(id)
        if archived.remove(id) != nil {
            UserDefaults.standard.set(Array(archived), forKey: "archived")
        }
    }

    private func togglePinContainsRemoval(_ id: String) {
        if pinned.remove(id) != nil {
            UserDefaults.standard.set(Array(pinned), forKey: "pinned")
        }
    }

    func newConversation() {
        Task {
            let id = (try? await client.createConversation()) ?? "local-" + UUID().uuidString
            let fresh = Conversation(id: id, title: "New chat", snippet: "", updatedAt: .now)
            selected = fresh
            sessionModelLabel = nil
            messages = []
        }
    }

    func connect(with config: ServerConfig) async {
        connection = .connecting
        do {
            try await client.validate(config: config)
            server = config
            lastHandshake = .now
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: "serverConfig") // TODO(phase3): Keychain
            }
            connection = .connected(config.authority?.host ?? "connected")
            await refresh()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        if server == nil {
            if let data = UserDefaults.standard.data(forKey: "serverConfig"),
               let config = try? JSONDecoder().decode(ServerConfig.self, from: data) {
                await connect(with: config)
            } else if let bridge = UserDefaults.standard.string(forKey: "bridgeURL") {
                await connect(with: ServerConfig(tokenURL: bridge))
            } else {
                #if targetEnvironment(simulator)
                await connect(with: ServerConfig(tokenURL: "http://127.0.0.1:8328"))
                #else
                if usesMock {
                    conversations = (try? await client.conversations()) ?? []
                    models = (try? await client.models()) ?? []
                }
                #endif
            }
            if server == nil && !usesMock { return }
        }
        do {
            async let convs = client.conversations()
            async let catalog = client.models()
            let fetchedConvs = try await convs
            let fetchedCatalog = try await catalog
            conversations = fetchedConvs
            models = fetchedCatalog
            if let first = models.first, !models.contains(where: { $0.name == defaultModel }) {
                defaultModel = first.name
            }
        } catch {
            // Degrade gracefully if offline
        }
    }

    func select(model: ModelInfo) {
        defaultModel = model.name
        sessionModelLabel = model.label
        guard let conv = selected, !conv.id.hasPrefix("local-"), conv.id != "new" else { return }
        Task { try? await client.setModel(conversationId: conv.id, name: model.name) }
    }

    func open(_ conversation: Conversation) async {
        selected = conversation
        sessionModelLabel = conversation.model
        if let page = try? await client.messages(conversationId: conversation.id) {
            messages = page.messages
            if let model = page.model { sessionModelLabel = model }
        } else {
            messages = []
        }
    }

    func send(_ text: String) {
        let user = Message(id: UUID().uuidString, role: .user, text: text)
        messages.append(user)
        let assistant = Message(id: UUID().uuidString, role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let aid = assistant.id
        streamTask = Task {
            let convId = selected?.id ?? "new"
            let model = defaultModel
            var tick = 0
            do {
                for try await chunk in client.send(conversationId: convId, text: text, model: model) {
                    tick += 1
                    if tick % 20 == 0, UserDefaults.standard.bool(forKey: "streamingHaptics") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    guard let idx = messages.firstIndex(where: { $0.id == aid }) else { continue }
                    if messages[idx].parts.isEmpty { messages[idx].parts = [.plain("")] }
                    messages[idx].parts[0].text = (messages[idx].parts[0].text ?? "") + chunk
                }
                if let model = client.lastPromptModel { sessionModelLabel = model }
            } catch {
                guard let idx = messages.firstIndex(where: { $0.id == aid }) else { return }
                messages[idx].parts[0].text = "⚠︎ " + error.localizedDescription
            }
            if let idx = messages.firstIndex(where: { $0.id == aid }) {
                messages[idx].isStreaming = false
            }
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }
}
