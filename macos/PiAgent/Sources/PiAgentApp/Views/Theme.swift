import SwiftUI

/// Shared visual tokens for the chat surface. Everything is built on system
/// fonts, semantic colors, and materials so light/dark mode, Increase
/// Contrast, and Dynamic Type follow the system automatically.
enum Theme {
    enum Spacing {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 18
    }

    static let codeFont = Font.system(.callout, design: .monospaced)
    static let codeCaptionFont = Font.system(.caption, design: .monospaced)
    /// Inline code chips sit inside body text, so they stay one step smaller
    /// to keep line height even.
    static let inlineCodeFont = Font.system(.callout, design: .monospaced)
}

/// A quiet container: translucent semantic fill plus a hairline stroke.
struct SubtleCard: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.medium

    func body(content: Content) -> some View {
        content
            .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

extension View {
    func subtleCard(cornerRadius: CGFloat = Theme.Radius.medium) -> some View {
        modifier(SubtleCard(cornerRadius: cornerRadius))
    }
}

/// Hover tracking held as an ObservableObject because the build toolchain
/// cannot expand the macro-based `@State` property wrapper.
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// Three-dot activity indicator. When Reduce Motion is on it stays a static
/// row of dots instead of animating.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let interval: TimeInterval = 0.35

    var body: some View {
        if reduceMotion {
            dots(activeIndex: -1)
        } else {
            TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                dots(activeIndex: Int(context.date.timeIntervalSinceReferenceDate / Self.interval) % 3)
                    .animation(.easeInOut(duration: 0.25), value: context.date)
            }
        }
    }

    private func dots(activeIndex: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(activeIndex < 0 ? 0.6 : (activeIndex == index ? 1 : 0.3))
            }
        }
        .accessibilityHidden(true)
    }
}
