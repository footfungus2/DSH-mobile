import SwiftUI

/// Renders one message the way the desktop harness does: prose stays in the
/// bubble, while reasoning, tool steps, context injections and attachments get
/// their own dim/full-width rows.
struct MessageBubble: View {
    let message: Message
    var maxWidth: CGFloat
    @AppStorage("bubbleTextSize") private var bubbleTextSize = 16.0
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolSteps") private var showToolSteps = true
    @AppStorage("showContextRows") private var showContextRows = true
    @AppStorage("showImagePreviews") private var showImagePreviews = true

    private var visibleParts: [MessagePart] {
        message.parts.filter { part in
            switch part.kind {
            case .text: true
            case .think: showThinking
            case .tool: showToolSteps
            case .context: showContextRows
            case .image: showImagePreviews
            }
        }
    }

    var body: some View {
        let isUser = message.role == .user
        HStack(alignment: .bottom) {
            if !isUser { assistantColumn }
            Spacer(minLength: DSHSpacing.lg)
            if isUser { userColumn }
        }
        .padding(.horizontal, DSHSpacing.base)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((isUser ? "You said: " : "Response: ") + message.text)
    }

    private var userColumn: some View {
        VStack(alignment: .trailing, spacing: DSHSpacing.xs) {
            ForEach(Array(visibleParts.enumerated()), id: \.offset) { _, part in
                switch part.kind {
                case .image: AttachmentView(part: part)
                default:
                    if let text = part.text, !text.isEmpty {
                        bubble(text: text, isUser: true)
                    }
                }
            }
        }
    }

    private var assistantColumn: some View {
        VStack(alignment: .leading, spacing: DSHSpacing.sm) {
            ForEach(Array(visibleParts.enumerated()), id: \.offset) { index, part in
                let isLast = index == visibleParts.count - 1
                switch part.kind {
                case .text:
                    if let text = part.text, !text.isEmpty {
                        bubble(text: text, isUser: false)
                            .overlay(alignment: .bottomTrailing) {
                                if message.isStreaming && isLast {
                                    StreamingCaret()
                                        .padding(.trailing, DSHSpacing.sm)
                                        .padding(.bottom, 10)
                                }
                            }
                    } else if message.isStreaming && isLast {
                        StreamingCaret()
                    }
                case .think: ThinkRow(text: part.text ?? "")
                case .tool: ToolRow(part: part)
                case .context: ContextRow(label: part.label ?? "")
                case .image: AttachmentView(part: part)
                }
            }
        }
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.system(size: bubbleTextSize, weight: .regular))
            .foregroundStyle(isUser ? DSHColor.userBubbleText : DSHColor.assistantBubbleText)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.horizontal, isUser ? DSHSpacing.md : 14)
            .padding(.vertical, isUser ? 10 : 12)
            .background(isUser ? DSHColor.userBubble : DSHColor.assistantBubble)
            .clipShape(UnevenRoundedRectangle.bubble(anchorBottomTrailing: isUser))
            .overlay {
                if !isUser {
                    UnevenRoundedRectangle.bubble(anchorBottomTrailing: false)
                        .strokeBorder(DSHColor.borderSubtle, lineWidth: 0.5)
                }
            }
            .frame(maxWidth: maxWidth * (isUser ? 0.76 : 0.88), alignment: isUser ? .trailing : .leading)
    }
}

private struct ThinkRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DSHSpacing.sm) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(DSHColor.textQuaternary)
                .padding(.top, 3)
            Text(text)
                .font(DSHTypography.subheadline)
                .foregroundStyle(DSHColor.textSecondary)
                .italic()
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.leading, DSHSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking: \(text)")
    }
}

private struct ToolRow: View {
    let part: MessagePart

    private var failed: Bool { part.status == .error || part.status == .fail }
    private var running: Bool { part.status == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: DSHSpacing.xs) {
                Image(systemName: failed ? "xmark.circle.fill"
                      : running ? "clock"
                      : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                headerText
                    .lineLimit(1)
                Spacer(minLength: DSHSpacing.sm)
            }
            if let error = part.error, !error.isEmpty {
                Text(error)
                    .font(DSHTypography.caption)
                    .foregroundStyle(DSHColor.statusError)
                    .padding(.leading, 18)
            }
            ForEach(Array((part.sub ?? []).enumerated()), id: \.offset) { _, child in
                SubCallRow(child: child)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.leading, DSHSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// One concatenated Text so name and title can never be laid out (or
    /// vanish) independently — mirrors the harness's inline "# Code title".
    private var headerText: Text {
        let name = Text((part.name ?? "Code") + "  ")
            .font(DSHTypography.footnote)
            .foregroundColor(failed ? DSHColor.statusError : DSHColor.textPrimary)
        let title = Text(part.title ?? "")
            .font(DSHTypography.subheadline)
            .foregroundColor(DSHColor.textSecondary)
        return name + title
    }

    private var statusColor: Color {
        if failed { return DSHColor.statusError }
        if running { return DSHColor.statusConnecting }
        return DSHColor.statusSuccess
    }
}

private struct SubCallRow: View {
    let child: SubCall

    private var failed: Bool { child.status == .error || child.status == .fail }

    var body: some View {
        HStack(spacing: DSHSpacing.xs) {
            Circle()
                .fill(failed ? DSHColor.statusError : DSHColor.statusSuccess)
                .frame(width: 5, height: 5)
            Text(child.name ?? "Call")
                .font(DSHTypography.captionSemibold)
                .foregroundStyle(failed ? DSHColor.statusError : DSHColor.textSecondary)
            Text("·")
                .foregroundStyle(DSHColor.textQuaternary)
            Text(child.title ?? "")
                .font(DSHTypography.caption)
                .foregroundStyle(DSHColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let exit = child.exitCode {
                Text("exit code \(exit)")
                    .font(DSHTypography.caption)
                    .foregroundStyle(exit == 0 ? DSHColor.textTertiary : DSHColor.statusError)
            }
        }
        .padding(.leading, 18)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DSHColor.borderSubtle)
                .frame(width: 2)
                .padding(.leading, 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ContextRow: View {
    let label: String

    var body: some View {
        HStack(spacing: DSHSpacing.xs) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 10))
            Text(label.isEmpty ? "Context injection" : "Context injection · \(label)")
                .font(DSHTypography.caption)
        }
        .foregroundStyle(DSHColor.textTertiary)
        .padding(.leading, DSHSpacing.xs)
        .accessibilityLabel("Context injected: \(label)")
    }
}

private struct AttachmentView: View {
    let part: MessagePart
    @Environment(AppStore.self) private var store
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous)
                            .strokeBorder(DSHColor.borderSubtle, lineWidth: 0.5)
                    }
            } else if loadFailed {
                HStack(spacing: DSHSpacing.xs) {
                    Image(systemName: "photo")
                    Text(part.name ?? "attachment")
                        .lineLimit(1)
                }
                .font(DSHTypography.captionSemibold)
                .foregroundStyle(DSHColor.textSecondary)
                .padding(.horizontal, DSHSpacing.md)
                .padding(.vertical, DSHSpacing.sm)
                .background(DSHColor.surfaceTertiary)
                .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous)
                    .fill(DSHColor.surfaceTertiary)
                    .frame(width: 160, height: 120)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .task(id: part.attachmentId ?? part.data) { await load() }
    }

    private func load() async {
        if image != nil { return }
        if let data = part.data, let raw = Data(base64Encoded: data) {
            image = UIImage(data: raw)
            loadFailed = image == nil
            return
        }
        guard let sha = part.attachmentId else {
            loadFailed = true
            return
        }
        do {
            let raw = try await store.client.attachmentData(sha: sha, mediaType: part.mediaType ?? "image/png")
            image = UIImage(data: raw)
            loadFailed = image == nil
        } catch {
            loadFailed = true
        }
    }
}
