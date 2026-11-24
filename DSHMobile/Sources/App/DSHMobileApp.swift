import SwiftUI
import LocalAuthentication

@main
struct DSHMobileApp: App {
    @State private var store = AppStore(client: ClientFactory.make())
    @AppStorage("faceID") private var faceID = true
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = DSHMobileApp.lockGateEnabled

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    // The simulator fakes biometrics availability, so the gate would only
    // ever annoy dev runs; real-device/release builds keep it.
    #if DEBUG
    private static let lockGateEnabled = false
    #else
    private static let lockGateEnabled = true
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView().environment(store)
                if locked {
                    LockView {
                        Task { await unlock() }
                    }
                    .transition(.opacity)
                }
            }
            .preferredColorScheme(colorScheme)
            .onChange(of: scenePhase) { _, phase in
                guard Self.lockGateEnabled else { return }
                switch phase {
                case .background: if faceID { locked = true }
                case .active: if faceID { Task { await unlock() } } else { locked = false }
                default: break
                }
            }
            .task { if Self.lockGateEnabled, faceID { await unlock() } }
        }
    }

    private func unlock() async {
        let context = LAContext()
        var error: NSError?
        let hasBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard faceID, hasBiometrics else {
            // No biometrics enrolled (default simulator, fresh device): skip the gate.
            locked = false
            return
        }
        context.localizedFallbackTitle = "Use Passcode"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock DSH Mobile")
            locked = !ok
        } catch {
            #if DEBUG
            locked = false // Never deadlock the dev build on a cancelled prompt.
            #endif
        }
    }
}

private struct LockView: View {
    var onUnlockAttempt: () -> Void

    var body: some View {
        VStack(spacing: DSHSpacing.lg) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(DSHColor.accentPrimary)
            Text("DSH Mobile").font(DSHTypography.screenTitle)
            Button("Unlock", action: onUnlockAttempt)
                .buttonStyle(.borderedProminent)
                .tint(DSHColor.accentPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSHColor.canvasPrimary)
    }
}

enum ClientFactory {
    /// Live bridge client once a server URL is known; mock until then so every
    /// screen stays runnable.
    static func make() -> DSHServicing {
        if let data = UserDefaults.standard.data(forKey: "serverConfig"),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            let client = DSHApiClient()
            client.configure(config)
            return client
        }
        if let bridge = UserDefaults.standard.string(forKey: "bridgeURL") {
            let client = DSHApiClient()
            client.configure(ServerConfig(tokenURL: bridge))
            return client
        }
        #if targetEnvironment(simulator)
        let client = DSHApiClient()
        client.configure(ServerConfig(tokenURL: "http://127.0.0.1:8328"))
        return client
        #else
        return MockDSHClient()
        #endif
    }
}

#Preview("Chat") {
    let store = AppStore(client: MockDSHClient())
    return ChatScreen().environment(store)
        .task {
            await store.connect(with: ServerConfig(tokenURL: "http://192.168.1.20:8328/?token=demo"))
            await store.refresh()
            if let first = store.conversations.first { await store.open(first) }
            store.send("Show me the design system")
        }
}
