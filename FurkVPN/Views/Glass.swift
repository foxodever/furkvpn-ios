import SwiftUI
import UIKit

// Liquid Glass on iOS/tvOS 26 (when built with Xcode 26), the flat look of the earlier versions elsewhere.
// Glass is for what floats above the background: the connect button, the server picker, the cards of the
// main screen (plan, announcement), the shortcuts, chips and messages.
// Settings → Интерфейс → «Стекло» (iOS/tvOS 26+): liquid (the default; it follows the system's own setting —
// Clear/Tinted in 26, the slider in 27, Reduce Transparency — by itself), matte (a blur without
// the lensing) or none (the flat look of earlier versions).
// iOS 26 draws glass of its own that the app's surfaces don't cover: the bars' buttons («Готово», «Закрыть»)
// and the sheets (glass at half height). With matte or none the app takes that glass away too (barItem,
// sheetGlass) — otherwise the setting changed the main screen only. With liquid they are the system's, the
// same as in every app; the back button of a pushed screen stays the system's in every style.

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

    /** What the screens use: flat before iOS/tvOS 26 (or a build without its SDK) whatever is chosen. */
    static var current: GlassStyle {
        #if compiler(>=6.2)
        if #available(iOS 26.0, tvOS 26.0, *) { return GlassStyle(rawValue: Store.defaults.string(forKey: key) ?? "") ?? .liquid }
        #endif
        return .flat
    }

    /** The choice is offered only where there is glass to choose. */
    static var available: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, tvOS 26.0, *) { return true }
        #endif
        return false
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, tvOS 26.0, *)
private func glass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    #if !os(tvOS)
    if interactive { glass = glass.interactive() }
    #endif
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
        if #available(iOS 26.0, tvOS 26.0, *) {
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
        if #available(iOS 26.0, tvOS 26.0, *) {
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
        #if os(tvOS)
        content.buttonStyle(TVGlassActionButtonStyle(prominent: prominent))
        #elseif compiler(>=6.2)
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

/** barItem, barGroup: the bar's buttons keep the system's glass capsule only with liquid glass. */
private struct BarButtons<Item: View>: ViewModifier {
    var placement: ToolbarItemPlacement
    var group: Bool
    var item: () -> Item
    @AppStorage(GlassStyle.key, store: Store.defaults) private var chosen = GlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if !os(tvOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // The same branch for every style: the screen keeps its state when the style changes in Settings.
            let glass: Visibility = (GlassStyle(rawValue: chosen) ?? .liquid) == .liquid ? .automatic : .hidden
            if group {
                content.toolbar { ToolbarItemGroup(placement: placement, content: item).sharedBackgroundVisibility(glass) }
            } else {
                content.toolbar { ToolbarItem(placement: placement, content: item).sharedBackgroundVisibility(glass) }
            }
        } else {
            plain(content)
        }
        #else
        plain(content)
        #endif
    }

    @ViewBuilder
    private func plain(_ content: Content) -> some View {
        if group {
            content.toolbar { ToolbarItemGroup(placement: placement, content: item) }
        } else {
            content.toolbar { ToolbarItem(placement: placement, content: item) }
        }
    }
}

/** sheetGlass: the sheet's background by the style; liquid leaves the system's glass sheet. */
private struct SheetGlass: ViewModifier {
    @AppStorage(GlassStyle.key, store: Store.defaults) private var chosen = GlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, tvOS 26.0, *) {
            // Asked for by a view behind the content, so that the content stays the same view when the style
            // changes: Settings is such a sheet itself, and it would jump back to the top.
            content.background {
                switch GlassStyle(rawValue: chosen) ?? .liquid {
                case .liquid: Color.clear
                case .matte: Color.clear.presentationBackground(.regularMaterial)
                case .flat:
                    #if os(tvOS)
                    Color.clear.presentationBackground(Color.brandBackground)
                    #else
                    Color.clear.presentationBackground(Color(UIColor.systemGroupedBackground))
                    #endif
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(tvOS)
/**
 * Action button style for tvOS matching iOS .glassProminent / .glass while preserving Color.onAccent contrast
 * against the light dark-mode AccentColor on tvOS 26+ Liquid Glass and earlier tvOS versions.
 */
private struct TVGlassActionButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let tint: Color? = prominent ? .accentColor : nil
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundColor(prominent ? .onAccent : .primary)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .glassSurface(shape, tint: tint, fallback: prominent ? .accentColor : .cardHigh)
            .overlay(
                shape.strokeBorder(
                    isFocused ? Color.primary.opacity(prominent ? 0.85 : 0.65) : .clear,
                    lineWidth: 3
                )
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.05 : 1.0))
            .shadow(
                color: .black.opacity(isFocused ? 0.34 : 0),
                radius: isFocused ? 22 : 0,
                y: isFocused ? 10 : 0
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/**
 * Focus-aware button presentation for custom glass/card buttons on Apple TV (connect button, filter chips,
 * server rows, header controls, whitelist card): preserves the shared component look while lifting cleanly
 * under Siri Remote focus.
 */
struct TVFocusButtonStyle<S: InsettableShape>: ButtonStyle {
    var shape: S
    var scale: CGFloat = 1.05
    var ringColor: Color = .primary
    var ringOpacity: Double = 0.65
    var ringWidth: CGFloat = 3
    var shadowRadius: CGFloat = 22
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                shape.strokeBorder(
                    isFocused ? ringColor.opacity(ringOpacity) : .clear,
                    lineWidth: ringWidth
                )
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? scale : 1.0))
            .shadow(
                color: .black.opacity(isFocused ? 0.32 : 0),
                radius: isFocused ? shadowRadius : 0,
                y: isFocused ? shadowRadius * 0.45 : 0
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
#endif

extension View {
    /**
     * A control's surface: glass on iOS/tvOS 26 (a blur with matte glass, [tint] or [fallback] without glass),
     * the shape filled with [fallback] (or [tint]) before.
     */
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Color = .card) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }

    /**
     * A card of the main screen: glass tinted with [color] on iOS/tvOS 26, strongly enough that what is behind it
     * doesn't change its color — plain glass took on the backdrop's glow, so a card low on the screen came out
     * lighter than the ones above it. Matte glass: [color] over a blur; without glass and before 26: [color].
     */
    func cardSurface<S: Shape>(_ shape: S, color: Color) -> some View {
        modifier(CardSurface(shape: shape, color: color))
    }

    /** Glass buttons on iOS/tvOS 26 with liquid glass; bordered (prominent: filled) otherwise. */
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }

    /**
     * A button of the navigation bar. iOS 26 puts it on a glass capsule of its own; with matte glass or
     * without glass the capsule is taken away (the button looks as it did before iOS 26).
     */
    func barItem<Item: View>(_ placement: ToolbarItemPlacement, @ViewBuilder _ item: @escaping () -> Item) -> some View {
        modifier(BarButtons(placement: placement, group: false, item: item))
    }

    /** Several buttons of the navigation bar in one place, see barItem. */
    func barGroup<Item: View>(_ placement: ToolbarItemPlacement, @ViewBuilder _ item: @escaping () -> Item) -> some View {
        modifier(BarButtons(placement: placement, group: true, item: item))
    }

    /**
     * For a sheet's content: iOS 26 makes a sheet of glass (seen at half height); matte glass asks for a blur
     * instead, no glass for the plain background.
     */
    func sheetGlass() -> some View {
        modifier(SheetGlass())
    }

    /** Half-height sheet that can be pulled up (iOS 16+); on iOS 26 it is a glass sheet. */
    @ViewBuilder
    func resizableSheet() -> some View {
        #if !os(tvOS)
        if #available(iOS 16.0, *) {
            self.presentationDetents(SheetDetents.resizable).presentationDragIndicator(.visible)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /** Inline navigation title on iOS/iPadOS/Mac; no-op on tvOS where display modes do not apply. */
    @ViewBuilder
    func inlineNavigationBar() -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /** Large control size on iOS/iPadOS/Mac; no-op on tvOS where controls already use 10-foot sizing. */
    @ViewBuilder
    func largeControlSize() -> some View {
        #if os(tvOS)
        self
        #else
        self.controlSize(.large)
        #endif
    }

    /** Focus-aware custom button style on tvOS; plain + pointer hover on iOS/iPadOS/Mac. */
    @ViewBuilder
    func glassInteractiveButton<S: InsettableShape>(
        _ shape: S,
        scale: CGFloat = 1.05,
        ringColor: Color = .primary,
        ringOpacity: Double = 0.65,
        liftHover: Bool = false
    ) -> some View {
        #if os(tvOS)
        self.buttonStyle(TVFocusButtonStyle(shape: shape, scale: scale, ringColor: ringColor, ringOpacity: ringOpacity))
        #else
        self
            .buttonStyle(.plain)
            .hoverEffect(liftHover ? .lift : .highlight)
        #endif
    }

    /** Pointer hover shape on iOS/iPadOS/Mac; no-op on tvOS. */
    @ViewBuilder
    func pointerHoverShape<S: Shape>(_ shape: S) -> some View {
        #if os(tvOS)
        self
        #else
        self.contentShape(.hoverEffect, shape)
        #endif
    }
}

#if !os(tvOS)
private enum SheetDetents {
    @available(iOS 16.0, *)
    static var resizable: Set<PresentationDetent> {
        #if DEMO
        // Screenshots of the whole list: the sheet as if pulled all the way up.
        if Demo.serversFull { return [.large] }
        #endif
        return [.medium, .large]
    }
}
#endif

/** Glass shapes next to each other blend and morph together on iOS/tvOS 26. */
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, tvOS 26.0, *) {
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
    #if os(tvOS)
    private static let topRadius: CGFloat = 960
    private static let bottomRadius: CGFloat = 820
    #else
    private static let topRadius: CGFloat = 420
    private static let bottomRadius: CGFloat = 380
    #endif

    var body: some View {
        ZStack {
            Color.brandBackground
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: Self.topRadius)
            RadialGradient(colors: [Color.good.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: Self.bottomRadius)
        }
        .ignoresSafeArea()
    }
}
