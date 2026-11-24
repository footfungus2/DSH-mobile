import SwiftUI

struct ConversationListView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var path: [Conversation] = []
    @State private var showArchived = false

    private var visible: [Conversation] {
        let base = store.conversations.filter { convo in
            let archived = store.isArchived(convo.id)
            return showArchived ? archived : !archived
        }
        let filtered = query.isEmpty ? base :
            base.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.snippet.localizedCaseInsensitiveContains(query)
            }
        return filtered.sorted { a, b in
            let pa = store.isPinned(a.id), pb = store.isPinned(b.id)
            if pa != pb { return pa }
            return a.updatedAt > b.updatedAt
        }
    }

    private struct Group: Identifiable {
        let title: String
        let items: [Conversation]
        var id: String { title }
    }

    private var groups: [Group] {
        if showArchived {
            return [Group(title: "Archived Chats", items: visible)]
        }
        let now = Date.now, cal = Calendar.current
        func days(_ c: Conversation) -> Int { cal.dateComponents([.day], from: c.updatedAt, to: now).day ?? 999 }
        let free = visible.filter { !store.isPinned($0.id) }
        return [
            Group(title: "Pinned", items: visible.filter { store.isPinned($0.id) }),
            Group(title: "Recent", items: free.filter { days($0) == 0 }),
            Group(title: "Previous 7 Days", items: free.filter { (1...7).contains(days($0)) }),
            Group(title: "Earlier", items: free.filter { days($0) > 7 }),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { convo in
                            ConversationRow(
                                conversation: convo,
                                isPinned: store.isPinned(convo.id),
                                isArchived: store.isArchived(convo.id)
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .toolbarBackground(DSHColor.canvasSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(DSHColor.canvasSecondary)
            .searchable(text: $query, prompt: showArchived ? "Search archived chats…" : "Search sessions…")
            .navigationTitle(showArchived ? "Archived" : "Conversations")
            .navigationDestination(for: Conversation.self) { convo in
                ChatScreen().task { await store.open(convo) }
            }
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    filterMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.newConversation() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .overlay {
                if visible.isEmpty { emptyState }
            }
            .task {
                await store.refresh()
                if UserDefaults.standard.bool(forKey: "previewChat"), let first = visible.first {
                    path.append(first)
                }
            }
        }
    }

    private var filterMenu: some View {
        let archivedCount = store.conversations.filter { store.isArchived($0.id) }.count
        return Menu {
            Button {
                showArchived = false
            } label: {
                Label("Active Chats", systemImage: !showArchived ? "checkmark" : "bubble.left.and.bubble.right")
            }
            Button {
                showArchived = true
            } label: {
                Label("Archived Chats (\(archivedCount))", systemImage: showArchived ? "checkmark" : "archivebox")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showArchived ? "archivebox.fill" : "line.3.horizontal.decrease.circle")
                if showArchived {
                    Text("Archived")
                        .font(DSHTypography.footnote)
                }
            }
            .foregroundStyle(DSHColor.accentPrimary)
        }
        .accessibilityLabel(showArchived ? "Showing archived chats" : "Filter chats")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(showArchived ? "No Archived Chats" : "No Conversations Yet",
                  systemImage: showArchived ? "archivebox" : "bubble.left.and.bubble.right")
        } description: {
            Text(showArchived ? "Chats you archive will appear here." : "Start a new conversation with your local DeepSeek model.")
        } actions: {
            if !showArchived {
                Button("New Chat") { store.newConversation() }
                    .buttonStyle(.borderedProminent)
                    .tint(DSHColor.accentPrimary)
            } else {
                Button("Show Active Chats") { showArchived = false }
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct ConversationRow: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    let isPinned: Bool
    let isArchived: Bool

    var body: some View {
        NavigationLink(value: conversation) {
            HStack(spacing: DSHSpacing.md) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DSHColor.accentPrimary)
                    .frame(width: 40, height: 40)
                    .background(DSHColor.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(conversation.title)
                            .font(DSHTypography.sectionHeader)
                            .foregroundStyle(DSHColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(DSHTypography.caption)
                            .foregroundStyle(DSHColor.textTertiary)
                    }
                    Text(conversation.snippet)
                        .font(DSHTypography.subheadline)
                        .foregroundStyle(DSHColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, DSHSpacing.md)
            .frame(minHeight: 72)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(conversation.id)
            } label: { Label("Delete", systemImage: "trash") }

            Button {
                store.toggleArchive(conversation.id)
            } label: {
                Label(isArchived ? "Unarchive" : "Archive",
                      systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            if !isArchived {
                Button {
                    store.togglePin(conversation.id)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: "pin.fill")
                }
                .tint(DSHColor.accentPrimary)
            }
        }
    }
}
