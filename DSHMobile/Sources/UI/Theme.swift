// Design tokens from design/DESIGN.md (Gemini design pass).
import SwiftUI

enum DSHColor {
    static let canvasPrimary = Color(light: 0xFFFFFF, dark: 0x0D1117)
    static let canvasSecondary = Color(light: 0xF6F8FC, dark: 0x161B22)
    static let surfaceElevated = Color(light: 0xFFFFFF, dark: 0x21262D)
    static let surfaceTertiary = Color(light: 0xEEF2F6, dark: 0x282E39)
    static let surfaceGlass = Color(light: 0xFFFFFF, dark: 0x161B22).opacity(0.85)
    // DESIGN.md's #F1F5F9 assistant card reads as a wash on the #F6F8FC canvas;
    // pulled to the inset-surface value so the bubble stays a distinct card.
    static let assistantBubble = Color(light: 0xE8EDF3, dark: 0x1B2028)

    static let accentPrimary = Color(light: 0x1E66F5, dark: 0x3B82F6)
    static let accentHover = Color(light: 0x1753C7, dark: 0x60A5FA)
    static let accentSubtle = Color(light: 0xEBF2FE, dark: 0x1E293B)
    static let accentOnAccent = Color.white

    static let userBubble = Color(light: 0x1E66F5, dark: 0x2563EB)
    static let userBubbleText = Color.white
    static let assistantBubbleText = Color(light: 0x0F172A, dark: 0xF8FAFC)

    static let textPrimary = Color(light: 0x0F172A, dark: 0xF8FAFC)
    static let textSecondary = Color(light: 0x475569, dark: 0x94A3B8)
    static let textTertiary = Color(light: 0x8290A2, dark: 0x64748B)
    static let textQuaternary = Color(light: 0xCBD5E1, dark: 0x334155)

    static let borderSubtle = Color(light: 0xE2E8F0, dark: 0x2E353F)
    static let borderStrong = Color(light: 0xCBD5E1, dark: 0x484F58)

    static let statusSuccess = Color(light: 0x10B981, dark: 0x34D399)
    static let statusSuccessBg = Color(light: 0xECFDF5, dark: 0x064E3B)
    static let statusWarning = Color(light: 0xF59E0B, dark: 0xFBBF24)
    static let statusWarningBg = Color(light: 0xFFFBEB, dark: 0x78350F)
    static let statusError = Color(light: 0xEF4444, dark: 0xF87171)
    static let statusErrorBg = Color(light: 0xFEF2F2, dark: 0x7F1D1D)
    static let statusConnecting = Color(light: 0x3B82F6, dark: 0x60A5FA)

    static let codeSurface = Color(light: 0xE8EDF5, dark: 0x14181F)
    static let codeText = Color(light: 0x0F172A, dark: 0xE2E8F0)
    static let codeBorder = Color(light: 0xCBD5E1, dark: 0x2B323D)
}

enum DSHTypography {
    static let largeTitle = Font.system(.largeTitle, weight: .bold)
    static let screenTitle = Font.system(.title2, weight: .bold)
    static let sectionHeader = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body, weight: .regular)
    static let bubbleText = Font.system(size: 16, weight: .regular)
    static let subheadline = Font.system(.subheadline, weight: .regular)
    static let footnote = Font.system(.footnote, weight: .medium)
    static let caption = Font.system(.caption, weight: .regular)
    static let captionSemibold = Font.system(.caption, weight: .semibold)
    static let codeBlock = Font.system(.footnote, design: .monospaced, weight: .regular)
    static let codeHeader = Font.system(.caption2, design: .monospaced, weight: .semibold)
}

enum DSHSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let base: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum DSHRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let bubble: CGFloat = 18
    static let composer: CGFloat = 24
    static let full: CGFloat = 999
}

enum DSHMotion {
    static let bubbleEntry = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let buttonMorph = Animation.spring(response: 0.28, dampingFraction: 0.75)
    static let composerExpand = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let bannerSlide = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let listAppear = Animation.spring(response: 0.38, dampingFraction: 0.88)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension UnevenRoundedRectangle {
    static func bubble(anchorBottomTrailing: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DSHRadius.bubble,
            bottomLeadingRadius: anchorBottomTrailing ? DSHRadius.bubble : DSHRadius.xs,
            bottomTrailingRadius: anchorBottomTrailing ? DSHRadius.xs : DSHRadius.bubble,
            topTrailingRadius: DSHRadius.bubble,
            style: .continuous
        )
    }
}
