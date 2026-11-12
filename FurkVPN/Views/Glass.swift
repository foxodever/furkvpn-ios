import SwiftUI

// Liquid Glass on iOS 26 (when built with Xcode 26), the flat look of the earlier versions elsewhere.
// Glass is for what floats above the background: the connect button, the server picker, the cards of the
// main screen (plan, announcement), the shortcuts, chips and messages.

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func glass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /** A control's surface: glass on iOS 26, the shape filled with [fallback] (or [tint]) before. */
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Color = .card) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(tint ?? fallback, in: shape)
        }
        #else
        self.background(tint ?? fallback, in: shape)
        #endif
    }

    /** Glass buttons on iOS 26; bordered (prominent: filled) before. */
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            legacyButtonStyle(prominent: prominent)
        }
        #else
        legacyButtonStyle(prominent: prominent)
        #endif
    }

    @ViewBuilder
    private func legacyButtonStyle(prominent: Bool) -> some View {
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
    }

    /** Half-height sheet that can be pulled up (iOS 16+); on iOS 26 it is a glass sheet. */
    @ViewBuilder
    func resizableSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}

/** Glass shapes next to each other blend and morph together on iOS 26. */
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/** Background of the main and welcome screens: the brand color with a soft glow for the glass to bend. */
struct BrandBackdrop: View {
    var body: some View {
        ZStack {
            Color.brandBackground
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.good.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}
