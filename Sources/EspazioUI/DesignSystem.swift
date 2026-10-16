import SwiftUI

/// Espazio design tokens (see docs/DESIGN_SYSTEM.md).
///
/// The notch surface is always near-black so it merges with the camera housing, in light and
/// dark mode alike. Windows that are not attached to the notch (settings, Quick Actions) follow
/// the system appearance using semantic colors. The only chromatic colors are `deny` and
/// `allow`, reserved for the AI decision buttons.
public enum EZColor {
    // Notch surface (always dark).
    public static let notchBackground = Color(white: 0.0)
    public static let notchRaised = Color(white: 0.11)
    public static let notchRaisedHover = Color(white: 0.16)
    public static let notchStroke = Color.white.opacity(0.08)
    public static let notchPrimary = Color.white
    public static let notchSecondary = Color.white.opacity(0.62)
    public static let notchTertiary = Color.white.opacity(0.40)
    public static let notchTrack = Color.white.opacity(0.18)

    // Adaptive surfaces (settings, palette).
    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary

    // The two allowed chromatic exceptions.
    public static let deny = Color(red: 0.84, green: 0.19, blue: 0.19)
    public static let allow = Color(red: 0.16, green: 0.62, blue: 0.30)
}

public enum EZFont {
    public static let title = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 12, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 12, weight: .medium)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let captionEmphasis = Font.system(size: 11, weight: .semibold)
    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let peek = Font.system(size: 12, weight: .semibold)
}

public enum EZMetrics {
    public static let cardRadius: CGFloat = 14
    public static let buttonRadius: CGFloat = 9
    public static let padding: CGFloat = 14
    public static let spacing: CGFloat = 10
    public static let hairline: CGFloat = 0.5
}

/// Animations honoring "Reduce Motion": callers pass the environment flag.
public enum EZMotion {
    public static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    public static func quick(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.18)
    }

    /// Duration used by the window layer to shrink the panel after the collapse animation.
    public static let collapseDuration: TimeInterval = 0.40
}

/// Neutral button used everywhere in the notch.
public struct EZButtonStyle: ButtonStyle {
    public enum Kind { case neutral, subtle, deny, allow }
    let kind: Kind

    public init(_ kind: Kind = .neutral) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EZFont.bodyEmphasis)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: EZMetrics.buttonRadius, style: .continuous)
                    .fill(background(pressed: configuration.isPressed)))
            .contentShape(RoundedRectangle(cornerRadius: EZMetrics.buttonRadius, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .neutral, .subtle: return EZColor.notchPrimary
        case .deny, .allow: return .white
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .neutral: return pressed ? EZColor.notchRaisedHover : EZColor.notchRaised
        case .subtle: return pressed ? EZColor.notchRaised : .clear
        case .deny: return EZColor.deny.opacity(pressed ? 0.8 : 1)
        case .allow: return EZColor.allow.opacity(pressed ? 0.8 : 1)
        }
    }
}

/// Small round icon button (media controls, header actions).
public struct EZIconButton: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    public init(_ symbol: String, label: String, size: CGFloat = 14, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2.1, height: size * 2.1)
                .foregroundStyle(EZColor.notchPrimary)
                .background(Circle().fill(hovering ? EZColor.notchRaisedHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Raised card container used in the expanded notch.
public struct EZCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: EZMetrics.cardRadius, style: .continuous)
                    .fill(EZColor.notchRaised.opacity(0.65)))
            .overlay(
                RoundedRectangle(cornerRadius: EZMetrics.cardRadius, style: .continuous)
                    .strokeBorder(EZColor.notchStroke, lineWidth: EZMetrics.hairline))
    }
}

/// Thin monochrome progress bar.
public struct EZProgressBar: View {
    let value: Double

    public init(value: Double) { self.value = value }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(EZColor.notchTrack)
                Capsule().fill(EZColor.notchPrimary)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int((value * 100).rounded())) %")
    }
}

/// Empty / unavailable state placeholder.
public struct EZPlaceholder: View {
    let symbol: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(symbol: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(EZColor.notchTertiary)
            Text(title).font(EZFont.bodyEmphasis).foregroundStyle(EZColor.notchSecondary)
            if let message {
                Text(message).font(EZFont.caption).foregroundStyle(EZColor.notchTertiary)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(EZButtonStyle()).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Opening choreography echoing the 3 layers of the logo: content appears in up to 3 tiers,
/// 40 ms apart, inside the 0.38 s spring (never lengthening it). Reduce Motion: plain 0.12 s fade.
struct StaggeredAppear: ViewModifier {
    let tier: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : -6)
            .onAppear {
                let animation: Animation = reduceMotion
                    ? .easeInOut(duration: 0.12)
                    : .easeOut(duration: 0.24).delay(0.04 * Double(min(max(tier, 0), 2)))
                withAnimation(animation) { visible = true }
            }
    }
}

extension View {
    /// `tier` 0, 1 or 2 (header, primary content, secondary content).
    func staggeredAppear(_ tier: Int) -> some View {
        modifier(StaggeredAppear(tier: tier))
    }
}

/// Discreet white dot under the collapsed notch while an AI decision is pending. Pulses only
/// while shown; static with Reduce Motion. Never interactive, never takes focus.
struct PendingDecisionDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dot.opacity(0.9)
            } else {
                dot.phaseAnimator([0.35, 1.0]) { content, phase in
                    content.opacity(phase)
                } animation: { _ in .easeInOut(duration: 0.9) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Décision d’agent en attente")
    }

    private var dot: some View {
        Circle().fill(Color.white).frame(width: 5, height: 5)
    }
}
