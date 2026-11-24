import SwiftUI
import UIKit

struct ConnectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var busy = false

    private var connected: Bool {
        if case .connected = store.connection { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DSHSpacing.xl) {
                    VStack(spacing: DSHSpacing.md) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(DSHColor.accentPrimary)
                        Text("Connect to DeepSeek Harness")
                            .font(DSHTypography.screenTitle)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, DSHSpacing.xxl)

                    VStack(alignment: .leading, spacing: DSHSpacing.sm) {
                        TextField(
                            "Paste bridge URL\n(e.g. http://192.168.1.50:8328)",
                            text: $url, axis: .vertical
                        )
                        .font(DSHTypography.codeBlock)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                        HStack {
                            Button {
                                if let pasted = UIPasteboard.general.string { url = pasted }
                            } label: {
                                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button {
                                Task {
                                    busy = true
                                    await store.connect(with: ServerConfig(tokenURL: url))
                                    busy = false
                                    if connected { try? await Task.sleep(for: .seconds(0.9)); dismiss() }
                                }
                            } label: {
                                if busy { ProgressView() } else { Text("Connect") }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DSHColor.accentPrimary)
                            .disabled(url.isEmpty || busy)
                        }
                    }
                    .padding(DSHSpacing.base)
                    .background(DSHColor.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))

                    validationRows

                    if !busy {
                        Text("Run `dsh web` on your Mac and paste the URL printed in the terminal.")
                            .font(DSHTypography.footnote)
                            .foregroundStyle(DSHColor.textTertiary)
                    }

                    Spacer()

                    Label("Credentials stored exclusively in the iOS Keychain. Traffic stays on your local network or Tailnet.",
                          systemImage: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(DSHColor.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, DSHSpacing.lg)
                }
                .padding(.horizontal, DSHSpacing.base)
            }
            .background(DSHColor.canvasSecondary)
            .toolbar {
                if connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var validationRows: some View {
        let reachedHTTP = busy || connected
        let reachedToken = connected
        let reachedRPC: Bool = {
            if case .failed = store.connection { return false }
            return connected
        }()
        VStack(alignment: .leading, spacing: DSHSpacing.sm) {
            step("HTTP connection", done: reachedHTTP)
            step("Token exchange → dsh-auth cookie", done: reachedToken)
            step("Session RPC ping", done: reachedRPC)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ title: String, done: Bool) -> some View {
        HStack(spacing: DSHSpacing.sm) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? DSHColor.statusSuccess : DSHColor.textQuaternary)
            Text(title)
                .font(DSHTypography.subheadline)
                .foregroundStyle(DSHColor.textSecondary)
        }
    }
}
