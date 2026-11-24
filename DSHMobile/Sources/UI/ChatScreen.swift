import SwiftUI

enum ModelSortOption: String, CaseIterable, Identifiable {
    case provider = "Provider"
    case name = "Name"
    case defaultOrder = "Default"
    var id: String { rawValue }
}

struct ChatScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("modelSortOrder") private var modelSortOrder: ModelSortOption = .provider
    @AppStorage("autoScroll") private var autoScroll = true
    @State private var modelSearchQuery = ""
    @State private var draft = ""
    @State private var nearBottom = true
    @State private var showModelSheet = false
    @State private var showConnect = false

    private var bannerKind: BannerKind? {
        switch store.connection {
        case .connecting: .connecting
        case .failed(let why): .failed(why)
        default: nil
        }
    }

    private var modelLabel: String {
        if let session = store.sessionModelLabel { return session }
        if let match = store.models.first(where: { $0.name == store.defaultModel }) { return match.label }
        return store.defaultModel.components(separatedBy: "/").last ?? store.defaultModel
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if let kind = bannerKind {
                    ConnectionStatusBanner(kind: kind, onTap: { showConnect = true })
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(store.messages) { message in
                                MessageBubble(message: message, maxWidth: geo.size.width)
                            }
                            Color.clear
                                .frame(height: 0)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: BottomKey.self,
                                                           value: g.frame(in: .global).minY)
                                })
                        }
                        .padding(.vertical)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(BottomKey.self) { anchorY in
                        let viewportBottom = geo.frame(in: .global).maxY
                        nearBottom = anchorY - viewportBottom < 40
                    }
                    .onChange(of: store.messages.last?.text) { _, _ in
                        guard autoScroll, nearBottom, let id = store.messages.last?.id else { return }
                        if reduceMotion {
                            proxy.scrollTo(id, anchor: .bottom)
                        } else {
                            withAnimation(DSHMotion.bubbleEntry) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let id = store.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                ComposerBar(
                    text: $draft,
                    isStreaming: store.messages.last?.isStreaming ?? false,
                    modelName: modelLabel,
                    onPickModel: { showModelSheet = true },
                    onSend: store.send(_:),
                    onStop: store.stopStreaming
                )
            }
        }
        .background(DSHColor.canvasSecondary)
        .navigationTitle(store.selected?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { principalTitle }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showModelSheet = true } label: {
                    ModelChip(name: modelLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showModelSheet) { modelSheet }
        .fullScreenCover(isPresented: $showConnect) { ConnectView() }
    }

    private var principalTitle: some View {
        VStack(spacing: 1) {
            Text(store.selected?.title ?? "Chat")
                .font(DSHTypography.footnote)
                .lineLimit(1)
            Text("\(modelLabel) • LAN")
                .font(.system(size: 11))
                .foregroundStyle(DSHColor.textSecondary)
        }
    }

    private var filteredModels: [ModelInfo] {
        if modelSearchQuery.isEmpty {
            return store.models
        }
        return store.models.filter {
            $0.label.localizedCaseInsensitiveContains(modelSearchQuery) ||
            $0.name.localizedCaseInsensitiveContains(modelSearchQuery) ||
            $0.providerDisplayName.localizedCaseInsensitiveContains(modelSearchQuery)
        }
    }

    private var providerGroups: [ModelGroup] {
        ModelGrouping.groups(filteredModels)
    }

    private var modelSheet: some View {
        NavigationStack {
            List {
                if modelSortOrder == .provider {
                    ForEach(providerGroups) { group in
                        Section(header: Text(group.displayName).font(DSHTypography.captionSemibold)) {
                            ForEach(group.models) { model in
                                modelRow(model)
                            }
                        }
                    }
                } else if modelSortOrder == .name {
                    let sorted = filteredModels.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
                    ForEach(sorted) { model in
                        modelRow(model)
                    }
                } else {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                    }
                }
            }
            .searchable(text: $modelSearchQuery, prompt: "Search models…")
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort By", selection: $modelSortOrder) {
                            Label("Sort by Provider", systemImage: "folder").tag(ModelSortOption.provider)
                            Label("Sort by Name", systemImage: "textformat").tag(ModelSortOption.name)
                            Label("Default Order", systemImage: "arrow.up.arrow.down").tag(ModelSortOption.defaultOrder)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(modelSortOrder.rawValue)
                                .font(DSHTypography.footnote)
                        }
                        .foregroundStyle(DSHColor.accentPrimary)
                    }
                    .accessibilityLabel("Sort models, currently \(modelSortOrder.rawValue)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showModelSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(DSHColor.surfaceElevated)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        Button {
            store.select(model: model)
            showModelSheet = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label).font(DSHTypography.sectionHeader)
                        .foregroundStyle(DSHColor.textPrimary)
                    Text(model.name).font(DSHTypography.caption)
                        .foregroundStyle(DSHColor.textTertiary)
                }
                Spacer()
                if model.name == store.defaultModel {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSHColor.accentPrimary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

private struct BottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
