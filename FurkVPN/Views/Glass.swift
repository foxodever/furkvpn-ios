import SwiftUI

// Liquid Glass on iOS 26 (when built with Xcode 26), the flat look of the earlier versions elsewhere.
// Glass is for what floats above the background: the connect button, the server picker, the cards of the
// main screen (plan, announcement), the shortcuts, chips and messages.
// Settings → Интерфейс → «Стекло» (iOS 26+): liquid (the default; it follows the system's own setting —
// Clear/Tinted in iOS 26, the slider in iOS 27, Reduce Transparency — by itself), matte (a blur without
// the lensing) or none (the flat look of iOS 15–18).

enum GlassStyle: String, CaseIterable {
    case liquid, matte, flat

    static let key = "glassStyle"

    var title: String {
        switch self {
        case .liquid: return "Жидкое стекло"
        case .matte: return "Матовое стекло"
        case .flat: return "Без стекла"
        }
    }

    /** What the screens use: flat before iOS 26 (or a build without its SDK) whatever is chosen. */
    static var current: GlassStyle {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return GlassStyle(rawValue: Store.defaults.string(forKey: key) ?? "") ?? .liquid }
        #endif
        return .flat
    }

    /** The choice is offered only where there is glass to choose. */
    static var available: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func glass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

/** glassSurface: re-rendered when the style changes in Settings. */
private struct GlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    var fallback: Color
    @AppStorage(GlassStyle.key, store: Store.defaults) private var chosen = GlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            switch GlassStyle(rawValue: chosen) ?? .liquid {
            case .liquid: content.glassEffect(glass(tint: tint, interactive: interactive), in: shape)
            case .matte: content.background(tint.map { AnyShapeStyle($0.opacity(0.75)) } ?? AnyShapeStyle(.regularMaterial), in: shape)
            case .flat: content.background(tint ?? fallback, in: shape)
            }
        } else {
            content.background(tint ?? fallback, in: shape)
        }
        #else
        content.background(tint ?? fallback, in: shape)
        #endif
    }
}

/** cardSurface: re-rendered when the style changes in Settings. */
private struct CardSurface<S: Shape>: ViewModifier {
    var shape: S
    var color: Color
    @AppStorage(GlassStyle.key, store: Store.defaults) private var chosen = GlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            switch GlassStyle(rawValue: chosen) ?? .liquid {
            case .liquid: content.glassEffect(Glass.regular.tint(color.opacity(0.8)), in: shape)
            case .matte: content.background(color.opacity(0.6), in: shape).background(.ultraThinMaterial, in: shape)
            case .flat: content.background(color, in: shape)
            }
        } else {
            content.background(color, in: shape)
        }
        #else
        content.background(color, in: shape)
        #endif
    }
}

/** glassButtonStyle: re-rendered when the style changes in Settings. */
private struct GlassButton: ViewModifier {
    var prominent: Bool
    @AppStorage(GlassStyle.key, store: Store.defaults) private var chosen = GlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if chosen == GlassStyle.liquid.rawValue || GlassStyle(rawValue: chosen) == nil {
                if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
            } else {
                legacy(content)
            }
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

extension View {
    /**
     * A control's surface: glass on iOS 26 (a blur with matte glass, [tint] or [fallback] without glass), the
     * shape filled with [fallback] (or [tint]) before.
     */
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Color = .card) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }

    /**
     * A card of the main screen: glass tinted with [color] on iOS 26, strongly enough that what is behind it
     * doesn't change its color — plain glass took on the backdrop's glow, so a card low on the screen came out
     * lighter than the ones above it. Matte glass: [color] over a blur; without glass and before iOS 26: [color].
     */
    func cardSurface<S: Shape>(_ shape: S, color: Color) -> some View {
        modifier(CardSurface(shape: shape, color: color))
    }

    /** Glass buttons on iOS 26 with liquid glass; bordered (prominent: filled) otherwise. */
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
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
