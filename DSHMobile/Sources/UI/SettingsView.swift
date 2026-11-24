import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("faceID") private var faceID = true
    @AppStorage("streamingHaptics") private var haptics = false
    @AppStorage("contextWindow") private var contextWindow = "64k"
    @AppStorage("bubbleTextSize") private var bubbleTextSize = 16.0
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolSteps") private var showToolSteps = true
    @AppStorage("showContextRows") private var showContextRows = true
    @AppStorage("showImagePreviews") private var showImagePreviews = true
    @AppStorage("autoScroll") private var autoScroll = true
    @AppStorage("modelSortOrder") private var modelSortOrder: ModelSortOption = .provider
    @AppStorage("lastTestLatency") private var lastTestLatency = ""
    @State private var showConnect = false
    @State private var showResetConfirm = false
    @State private var updates = UpdateChecker()
    @State private var testResult: BannerKind?
    @State private var bridgeDisplay: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Authority") {
                    LabeledContent("Current host") {
                        HStack(spacing: DSHSpacing.sm) {
                            Text(store.server?.authority?.hostPort ?? "—")
                            if store.server != nil {
                                Text("Verified")
                                    .font(DSHTypography.captionSemibold)
                                    .foregroundStyle(DSHColor.statusSuccess)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(DSHColor.statusSuccessBg)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    LabeledContent("Bridge", value: bridgeDisplay ?? "probing…")
                    if let handshake = store.lastHandshake {
                        LabeledContent("Last handshake", value: handshake.formatted(date: .omitted, time: .shortened))
                    }
                    if !lastTestLatency.isEmpty {
                        LabeledContent("Last test", value: lastTestLatency)
                    }
                    Button("Test Connection") {
                        Task { await runConnectionTest() }
                    }
                    Button("Re-authenticate with New URL…") { showConnect = true }
                }

                Section("Model Defaults") {
                    Picker("Sort models by", selection: $modelSortOrder) {
                        ForEach(ModelSortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker("Default model", selection: Bindable(store).defaultModel) {
                        ForEach(ModelGrouping.groups(store.models)) { group in
                            Section(group.displayName) {
                                ForEach(group.models) { model in
                                    Text(model.label).tag(model.name)
                                }
                            }
                        }
                    }
                    Picker("Context window", selection: $contextWindow) {
                        Text("64k").tag("64k")
                        Text("128k").tag("128k")
                    }
                }

                Section("Chat Transcript") {
                    Picker("Bubble text size", selection: $bubbleTextSize) {
                        Text("Small").tag(14.0)
                        Text("Default").tag(16.0)
                        Text("Large").tag(18.0)
                    }
                    Toggle("Reasoning lines", isOn: $showThinking)
                    Toggle("Tool steps", isOn: $showToolSteps)
                    Toggle("Context injections", isOn: $showContextRows)
                    Toggle("Image previews", isOn: $showImagePreviews)
                }

                Section("Chat Behavior") {
                    Toggle("Auto-scroll to latest", isOn: $autoScroll)
                    Toggle("Streaming haptics", isOn: $haptics)
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Security") {
                    Toggle("Face ID Lock", isOn: $faceID)
                }

                Section("Data") {
                    Button("Clear Pinned & Archived Flags") {
                        store.clearLocalChatState()
                    }
                    Button("Reset All Settings", role: .destructive) {
                        showResetConfirm = true
                    }
                }

                Section("Updates") {
                    LabeledContent("Installed", value: updates.installedVersion)
                    Button {
                        Task { await updates.checkAndInstall() }
                    } label: {
                        switch updates.state {
                        case .checking:
                            HStack { ProgressView(); Text("Checking…") }
                        case .upToDate(let v):
                            Text("Up to date (\(v))")
                        case .available(let v):
                            Text("Install \(v) via SideStore…")
                        case .handedOff:
                            Text("Handed to SideStore…")
                        case .failed:
                            Text("Check for updates")
                        case .idle:
                            Text("Check for updates")
                        }
                    }
                    .disabled(updates.state == .checking || updates.state == .handedOff)
                    if case .failed(let why) = updates.state {
                        Text(why)
                            .font(DSHTypography.footnote)
                            .foregroundStyle(DSHColor.statusError)
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Launch command") {
                        Button {
                            UIPasteboard.general.string =
                                "dsh --profile web --host <local-ip> --port 8328 --no-open"
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            // Headless-sim quirk: mid-Form layout changes from async state never
            // repaint the LCD, so rebuild the whole Form when probe data lands.
            .id("\(bridgeDisplay ?? "pending")|\(lastTestLatency)")
            .navigationTitle("Settings")
            .fullScreenCover(isPresented: $showConnect) { ConnectView() }
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { AppStore.resetSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Preferences return to defaults. Your saved bridge address stays put.")
            }
            .task(id: store.server?.tokenURL) { await probeBridge() }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let testResult {
                    ConnectionStatusBanner(kind: testResult, onTap: { self.testResult = nil })
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            self.testResult = nil
                        }
                }
            }
        }
    }

    private func runConnectionTest() async {
        guard let config = store.server else { return }
        let start = Date.now
        await store.connect(with: config)
        guard case .connected = store.connection else { return }
        let ms = Int(Date.now.timeIntervalSince(start) * 1000)
        lastTestLatency = "\(ms) ms round-trip"
        testResult = .connected("OK in \(ms) ms")
    }

    private func probeBridge() async {
        bridgeDisplay = "probing…"
        for attempt in 1...2 {
            let info = store.server == nil ? nil : try? await store.client.bridgeInfo()
            bridgeDisplay = info?.display ?? "no response"
            if info?.display != nil { break }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView {
            ConversationListView()
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(DSHColor.accentPrimary)
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

private extension URL {
    var hostPort: String {
        guard let host else { return absoluteString }
        return port.map { "\(host):\($0)" } ?? host
    }
}
