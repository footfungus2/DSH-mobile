import SwiftUI

// Components per design/DESIGN.md §3 — token values are normative, not vibes.

struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.25)
            .fill(DSHColor.accentPrimary)
            .frame(width: 2.5, height: 17)
            .opacity(reduceMotion ? 1 : (pulse ? 1.0 : 0.25))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

struct ModelChip: View {
    let name: String
    var showChevron = true

    var body: some View {
        HStack(spacing: DSHSpacing.xs) {
            Text(name)
                .font(DSHTypography.captionSemibold)
                .foregroundStyle(DSHColor.accentPrimary)
            if showChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(DSHColor.accentSubtle)
        .clipShape(Capsule())
        .accessibilityLabel("Active model: \(name)")
        .accessibilityHint("Double tap to choose another model")
    }
}

struct ComposerBar: View {
    @Binding var text: String
    let isStreaming: Bool
    let modelName: String
    let onPickModel: () -> Void
    let onSend: (String) -> Void
    let onStop: () -> Void

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: DSHSpacing.sm) {
            Button(action: onPickModel) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DSHColor.accentPrimary)
                    .frame(width: 28, height: 28)
                    .background(DSHColor.surfaceTertiary)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Model: \(modelName)")
            .accessibilityHint("Double tap to choose another model")

            TextField("Message DeepSeek…", text: $text, axis: .vertical)
                .font(DSHTypography.bubbleText)
                .lineLimit(1...5)

            Button(action: sendOrStop) {
                Image(systemName: isStreaming ? "square.fill" : "arrow.up")
                    .font(.system(size: isStreaming ? 12 : 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(buttonFill)
                    .clipShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!isStreaming && trimmed.isEmpty)
            .accessibilityLabel(isStreaming ? "Stop generating response" : "Send")
            .accessibilityHint(isStreaming ? "Interrupts current model output" : "Sends your message")
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: DSHRadius.composer, style: .continuous)
                .fill(.regularMaterial)
                .overlay(Color.dsGlassTint)
                .shadow(color: Color.dsComposerShadow, radius: 12, x: 0, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSHRadius.composer, style: .continuous)
                .strokeBorder(DSHColor.borderStrong, lineWidth: 0.5)
        }
        .padding(.horizontal, DSHSpacing.md)
        .padding(.bottom, DSHSpacing.sm)
    }

    private var buttonFill: Color {
        if isStreaming { return DSHColor.statusError }
        return trimmed.isEmpty ? DSHColor.accentPrimary.opacity(0.35) : DSHColor.accentPrimary
    }

    private func sendOrStop() {
        if isStreaming {
            onStop()
        } else {
            let payload = trimmed
            guard !payload.isEmpty else { return }
            text = ""
            onSend(payload)
        }
    }
}

enum BannerKind: Equatable {
    case connecting, connected(String), reconnecting, authExpired, failed(String)

    var icon: String {
        switch self {
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .reconnecting: "exclamationmark.triangle.fill"
        case .authExpired: "lock.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .connecting: "Connecting to Mac…"
        case .connected(let host): "Connected (\(host))"
        case .reconnecting: "Reconnecting… Retry (Tap)"
        case .authExpired: "Token expired. Tap to reconnect."
        case .failed(let why): why
        }
    }

    var fill: Color {
        switch self {
        case .connecting: DSHColor.canvasSecondary
        case .connected: DSHColor.statusSuccessBg
        case .reconnecting: DSHColor.statusWarningBg
        case .authExpired, .failed: DSHColor.statusErrorBg
        }
    }

    var foreground: Color {
        switch self {
        case .connecting: DSHColor.statusConnecting
        case .connected: DSHColor.statusSuccess
        case .reconnecting: DSHColor.statusWarning
        case .authExpired, .failed: DSHColor.statusError
        }
    }

    var showsToast: Bool { if case .connected = self { return true }; return false }
}

struct ConnectionStatusBanner: View {
    let kind: BannerKind
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DSHSpacing.sm) {
                if kind == .connecting {
                    SpinningIcon()
                } else {
                    Image(systemName: kind.icon)
                }
                Text(kind.label)
                    .font(DSHTypography.footnote)
                Spacer()
            }
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, DSHSpacing.base)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(kind.fill)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSHColor.borderSubtle).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct SpinningIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turn = true }
            }
    }
}

extension Color {
    static let dsGlassTint = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 22/255, green: 27/255, blue: 34/255, alpha: 0.85)
        : UIColor(red: 1, green: 1, blue: 1, alpha: 0.85) })
    static let dsComposerShadow = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.black.withAlphaComponent(0.40)
        : UIColor.black.withAlphaComponent(0.08) })
}
