import SwiftUI
import UIKit

/**
 * Glass style on tvOS 26+ (mirrors FurkVPN/Views/Glass.swift): shares the same Store preference key
 * ("glassStyle") and falls back to the flat brand palette on tvOS 17–25.
 */
enum TVGlassStyle: String, CaseIterable {
    case liquid, matte, flat

    static let key = "glassStyle"

    var title: String {
        switch self {
        case .liquid: return "Жидкое стекло"
        case .matte: return "Матовое стекло"
        case .flat: return "Без стекла"
        }
    }

    static var current: TVGlassStyle {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            return TVGlassStyle(rawValue: Store.defaults.string(forKey: key) ?? "") ?? .liquid
        }
        #endif
        return .flat
    }

    static var available: Bool {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) { return true }
        #endif
        return false
    }
}

/** Layout metrics of the 1920×1080 living-room canvas, shared by every screen. */
enum TVMetrics {
    /** Side margin of the screens that lay out their own content edge to edge (the title-safe width). */
    static let sideMargin: CGFloat = 80
    /** Above the top bar: a little inside the 60 pt overscan inset, which only the pills' glass reaches. */
    static let topMargin: CGFloat = 46
    /** Below the dashboard's columns: their cards end here, while lists scroll on under a soft fade. */
    static let bottomMargin: CGFloat = 40
    /** Between the dashboard and the server list. */
    static let columnGap: CGFloat = 48
    /** The dashboard column: wide enough for the connect button beside the status. */
    static let homeColumn: CGFloat = 780
    /** Room left around focusable content inside a clipping scroll view for the focus lift and its shadow. */
    static let focusRoom: CGFloat = 22
    static let cardRadius: CGFloat = 30
    static let cardPadding: CGFloat = 24
}

extension Color {
    /** Rows on the server pane: a step lighter than the pane in both themes (as Color.paneRow on iOS). */
    static let tvPaneRow = Color(UIColor { traits in
        UIColor(named: traits.userInterfaceStyle == .dark ? "CardHigh" : "Background")
            ?? (traits.userInterfaceStyle == .dark ? .darkGray : .white)
    })

    /** A focused card or row: clearly lifted above its neighbours from across the room. */
    static let tvFocusFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.290, green: 0.306, blue: 0.341, alpha: 1)
            : .white
    })
}

/**
 * Brand backdrop scaled for the 1080p Apple TV canvas: the brand color with a soft accent glow for the glass to
 * bend. The dashboard moves the glow behind the connect button and warms it up while connected.
 */
struct TVBrandBackdrop: View {
    var glow: UnitPoint = .top
    var intensity: Double = 0.24

    var body: some View {
        ZStack {
            Color.brandBackground
            RadialGradient(
                colors: [Color.accentColor.opacity(intensity), .clear],
                center: glow,
                startRadius: 0,
                endRadius: 960
            )
            RadialGradient(
                colors: [Color.good.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 820
            )
        }
        .ignoresSafeArea()
    }
}

/**
 * Card surface: glass tinted with [color] strongly enough that the backdrop's glow doesn't change it (a card
 * low on the screen stays the color of the ones above it), matte glass over a blur, or a solid card.
 */
private struct TVCardSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var color: Color
    @AppStorage(TVGlassStyle.key, store: Store.defaults) private var chosen = TVGlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            switch TVGlassStyle(rawValue: chosen) ?? .liquid {
            case .liquid:
                content.glassEffect(Glass.regular.tint(color.opacity(0.82)), in: shape)
            case .matte:
                hairline(content
                    .background(color.opacity(0.65), in: shape)
                    .background(.ultraThinMaterial, in: shape))
            case .flat:
                hairline(content.background(color, in: shape))
            }
        } else {
            hairline(content.background(color, in: shape))
        }
        #else
        hairline(content.background(color, in: shape))
        #endif
    }

    /** Without glass's own lit edge a card gets a hairline, so it doesn't melt into the backdrop. */
    private func hairline<V: View>(_ view: V) -> some View {
        view.overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct TVGlassControlSurface<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var fallback: Color
    @AppStorage(TVGlassStyle.key, store: Store.defaults) private var chosen = TVGlassStyle.liquid.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            switch TVGlassStyle(rawValue: chosen) ?? .liquid {
            case .liquid:
                let glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
                content.glassEffect(glass, in: shape)
            case .matte:
                content.background(tint.map { AnyShapeStyle($0.opacity(0.82)) } ?? AnyShapeStyle(.regularMaterial), in: shape)
            case .flat:
                content.background(tint ?? fallback, in: shape)
            }
        } else {
            content.background(tint ?? fallback, in: shape)
        }
        #else
        content.background(tint ?? fallback, in: shape)
        #endif
    }
}

extension View {
    func tvCardSurface<S: InsettableShape>(_ shape: S, color: Color = .card) -> some View {
        modifier(TVCardSurface(shape: shape, color: color))
    }

    func tvGlassSurface<S: Shape>(_ shape: S, tint: Color? = nil, fallback: Color = .cardHigh) -> some View {
        modifier(TVGlassControlSurface(shape: shape, tint: tint, fallback: fallback))
    }

    func tvCard(_ color: Color = .card, padding: CGFloat = TVMetrics.cardPadding, cornerRadius: CGFloat = TVMetrics.cardRadius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvCardSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), color: color)
    }

    /**
     * Softly fades the content out at the edges of a clipping scroll view (instead of a hard cut through a chip
     * or a row); [leading]/[trailing] or [top]/[bottom] are the fade lengths.
     */
    func tvFadeEdges(_ axis: Axis, leading: CGFloat = 0, trailing: CGFloat = 0) -> some View {
        mask {
            let stack = Group {
                LinearGradient(colors: [.clear, .black], startPoint: axis == .horizontal ? .leading : .top, endPoint: axis == .horizontal ? .trailing : .bottom)
                    .frame(width: axis == .horizontal ? leading : nil, height: axis == .vertical ? leading : nil)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: axis == .horizontal ? .leading : .top, endPoint: axis == .horizontal ? .trailing : .bottom)
                    .frame(width: axis == .horizontal ? trailing : nil, height: axis == .vertical ? trailing : nil)
            }
            if axis == .horizontal {
                HStack(spacing: 0) { stack }
            } else {
                VStack(spacing: 0) { stack }
            }
        }
    }
}

/** Glass shapes next to each other blend and morph together on tvOS 26 (GlassGroup on iOS). */
struct TVGlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/** A round icon in the accent color that leads the dashboard's cards and the side panels' rows. */
struct TVIconBadge: View {
    var systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 60

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/**
 * Focus-aware card button for tvOS (server rows, whitelist and announcement cards). With [glass] it has the
 * dashboard's card surface (the focus brightens its tint); without, a solid row for the server pane's glass.
 */
struct TVCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = TVMetrics.cardRadius
    var fill: Color = .card
    var focusedFill: Color = .tvFocusFill
    var highlighted: Bool = false
    var glass: Bool = true
    var focusScale: CGFloat = 1.03
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        surface(configuration.label, shape: shape)
            .overlay(
                shape.strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.95) : (highlighted ? Color.accentColor.opacity(0.55) : Color.primary.opacity(glass ? 0 : 0.05)),
                    lineWidth: isFocused ? 3 : (highlighted ? 2 : 1)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : (isFocused ? focusScale : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.30 : 0), radius: isFocused ? 22 : 0, y: isFocused ? 12 : 0)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    @ViewBuilder
    private func surface(_ label: Configuration.Label, shape: RoundedRectangle) -> some View {
        if glass {
            label.tvCardSurface(shape, color: isFocused ? focusedFill : fill)
        } else {
            label
                .background(shape.fill(isFocused ? focusedFill : fill))
                .clipShape(shape)
        }
    }
}

/** Focus-aware capsule button for top bar controls and filter chips. */
struct TVPillButtonStyle: ButtonStyle {
    var selected: Bool = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let tint: Color? = selected ? .accentColor : (isFocused ? .tvFocusFill : nil)
        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(selected ? Color.onAccent : Color.primary)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .tvGlassSurface(shape, tint: tint, fallback: selected ? .accentColor : (isFocused ? .tvFocusFill : .cardHigh))
            .overlay(
                shape.strokeBorder(
                    isFocused ? Color.primary.opacity(selected ? 0.85 : 0.55) : .clear,
                    lineWidth: 2.5
                )
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.07 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.28 : 0), radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/**
 * Prominent, secondary or destructive action button in the FurkVPN palette (glassProminent / glass on iOS 26):
 * accent-tinted glass for the main action, plain glass for the others, a clear focus lift.
 */
struct TVActionButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var destructive: Bool = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let tint: Color? = destructive ? .errorCard : (prominent ? .accentColor : (isFocused ? .tvFocusFill : nil))
        let fg: Color = destructive ? .onErrorCard : (prominent ? .onAccent : .primary)
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .tvGlassSurface(shape, tint: tint, fallback: tint ?? .cardHigh)
            .overlay(
                shape.strokeBorder(
                    isFocused ? Color.primary.opacity(prominent || destructive ? 0.85 : 0.55) : .clear,
                    lineWidth: 3
                )
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.32 : 0), radius: isFocused ? 20 : 0, y: isFocused ? 10 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/**
 * The frame of the secondary screens (settings, routing, diagnostics, details sheets), as tvOS's own Settings:
 * a branded panel on the left with a big glass icon, the title and a short description, the remote-driven list
 * on the right, all over the brand backdrop.
 */
struct TVSidePanelScreen<Content: View>: View {
    var systemImage: String
    var title: String
    var subtitle: String?
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            TVBrandBackdrop(glow: UnitPoint(x: 0.2, y: 0.42), intensity: 0.20)
            HStack(alignment: .center, spacing: 72) {
                VStack(spacing: 30) {
                    Image(systemName: systemImage)
                        .font(.system(size: 112, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 260, height: 260)
                        .tvGlassSurface(Circle(), fallback: .card)
                        .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
                    VStack(spacing: 14) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .wraps()
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .wraps()
                        }
                    }
                }
                .frame(width: 600)

                content
                    .tint(.primary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, 40)
        }
    }
}

/** Non-focusable toast banner at the bottom of the TV screen. */
struct TVToastOverlay: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TVGlassStyle.current == .flat ? Color.onAccent : Color.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 20)
                    .tvGlassSurface(Capsule(), fallback: .accentColor)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                    .padding(.horizontal, 120)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: text)
    }
}

extension View {
    func tvToast(_ text: Binding<String?>) -> some View {
        modifier(TVToastOverlay(text: text))
    }
}

/** Latency as a small tinted capsule: green, orange or red by speed (PingLabel on iOS). */
struct TVPingLabel: View {
    var ping: Ping?
    var kind: ServerKind?

    var body: some View {
        Group {
            if ping == .testing {
                ProgressView()
                    .scaleEffect(0.62)
                    .frame(width: 44, height: 30)
            } else if let text = Format.ping(ping, kind: kind) {
                Text(text)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(color.opacity(0.14), in: Capsule())
            }
        }
        .fixedSize()
    }

    private var color: Color {
        guard case let .ok(ms) = ping else { return .secondary }
        if ms < 300 { return .good }
        if ms < 800 { return .orange }
        return .red
    }
}

/** Flag, name and protocol of a server (ServerTitle on iOS). */
struct TVServerTitle: View {
    var server: ServerEntry

    var body: some View {
        HStack(spacing: 20) {
            Text(server.flag ?? "🌐")
                .font(.system(size: 46))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let summary = server.summary {
                    Text(summary)
                        .font(.caption)
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
