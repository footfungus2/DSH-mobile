import Foundation

struct Conversation: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var snippet: String
    var updatedAt: Date
    var isArchived: Bool?
    var isPinned: Bool?
    var model: String?

    init(id: String, title: String, snippet: String, updatedAt: Date, isArchived: Bool? = false, isPinned: Bool? = false, model: String? = nil) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.model = model
    }
}

enum Role: String, Codable {
    case user, assistant
}

enum PartKind: String, Codable {
    case text, think, tool, context, image
}

enum PartStatus: String, Codable {
    case ok, fail, error, running
}

struct SubCall: Codable, Hashable {
    var name: String?
    var title: String?
    var status: PartStatus?
    var exitCode: Int?
    var error: String?
}

/// One rendered row of a transcript message, mirroring the desktop harness:
/// prose, reasoning, tool steps (with nested PTC sub-calls), context
/// injections, and user image attachments.
struct MessagePart: Codable, Hashable {
    var kind: PartKind = .text
    var text: String?
    var name: String?
    var title: String?
    var status: PartStatus?
    var exitCode: Int?
    var error: String?
    var label: String?
    var sub: [SubCall]?
    var attachmentId: String?
    var mediaType: String?
    var data: String?

    static func plain(_ string: String) -> MessagePart { MessagePart(kind: .text, text: string) }
}

struct Message: Identifiable, Codable, Hashable {
    let id: String
    var role: Role
    var parts: [MessagePart]
    var createdAt: Date
    var isStreaming: Bool

    var text: String {
        parts.filter { $0.kind == .text }.compactMap(\.text).joined()
    }

    init(id: String, role: Role, text: String, createdAt: Date = .now, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.parts = [.plain(text)]
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }

    init(id: String, role: Role, parts: [MessagePart], createdAt: Date = .now, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}

struct MessagePage: Hashable {
    var messages: [Message]
    var model: String?
}

struct ModelInfo: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let label: String
    var provider: String?

    init(name: String, label: String, provider: String? = nil) {
        self.name = name
        self.label = label
        self.provider = provider
    }

    /// Extracted or fallback provider identifier (e.g. "deepseek-account", "openai")
    var effectiveProvider: String {
        if let p = provider, !p.isEmpty { return p }
        if let slash = name.firstIndex(of: "/") {
            return String(name[..<slash])
        }
        if name.lowercased().contains("deepseek") {
            return "deepseek"
        }
        return "other"
    }

    /// Formatted human-readable provider name for section headers and badges
    var providerDisplayName: String {
        let raw = effectiveProvider
        let lower = raw.lowercased()
        if lower == "deepseek-account" { return "DeepSeek Account" }
        if lower == "deepseek" { return "DeepSeek" }
        if lower == "openai" { return "OpenAI" }
        if lower == "anthropic" { return "Anthropic" }
        if lower == "ollama" { return "Ollama" }
        if lower == "openrouter" { return "OpenRouter" }
        if lower == "groq" { return "Groq" }
        return raw.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }
}

struct ModelGroup: Identifiable, Hashable {
    let provider: String
    let displayName: String
    let models: [ModelInfo]
    var id: String { provider }
}

/// Shared provider grouping for the chat sheet and the Settings picker.
enum ModelGrouping {
    static func groups(_ models: [ModelInfo]) -> [ModelGroup] {
        let grouped = Dictionary(grouping: models, by: { $0.effectiveProvider })
        return grouped.keys.sorted { k1, k2 in
            if k1.contains("deepseek") && !k2.contains("deepseek") { return true }
            if !k1.contains("deepseek") && k2.contains("deepseek") { return false }
            return k1.localizedCaseInsensitiveCompare(k2) == .orderedAscending
        }.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            let sortedItems = items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            let displayName = items.first?.providerDisplayName ?? key.capitalized
            return ModelGroup(provider: key, displayName: displayName, models: sortedItems)
        }
    }
}
