// DevVisuals.swift - the devDesign visual layer, version 1.1, 20 November 2026.
//
// One file, copied UNCHANGED into an app (principle 6, as for web/style.css). Do not edit the copy:
// change it here, bump the version, and copy it again. The rules for using these pieces are in
// ~/devDesign/VISUAL_DESIGN.md. First used in devTrain and devThink (November 2026).
//
// Needs iOS 18 or macOS 15 (Color.mix). No dependencies beyond SwiftUI. The app supplies its own
// area colours (streams, categories, tabs) and sets \.areaAccent where an area begins.
//
// 1.1: an app may tune sizes and strengths through the environment (devPrimaryMetrics,
// devSoftMetrics, devWorldCardMetrics, devCardColours) and through parameters on StartCircle,
// ImmersiveBackdrop and AccentWash. Every default is exactly 1.0's look, so an app that sets
// nothing looks the same. Tuning lives in one place in the app, never in a copy of this file.

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Colour

extension Color {
    /// A colour from "#rrggbb". Named devHex so it never clashes with an app's own hex initialiser.
    init(devHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0x808080
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

extension EnvironmentValues {
    /// The colour of the area the user is in: a stream, a category, a tab. Set it where the area
    /// begins; every piece below reads it. An area colour must reach 3:1 against white and black.
    @Entry var areaAccent: Color = .accentColor
    /// Sizes and strengths of PrimaryCapsule for this app. Default: the standard look.
    @Entry var devPrimaryMetrics: PrimaryCapsuleMetrics = .standard
    /// Sizes and strengths of SoftCapsule for this app.
    @Entry var devSoftMetrics: SoftCapsuleMetrics = .standard
    /// Sizes of WorldCard for this app.
    @Entry var devWorldCardMetrics: WorldCardMetrics = .standard
    /// The quiet (not emphasised) AccentCard's colours, so an app's own theme panels can be used.
    @Entry var devCardColours: CardColours = .standard
}

struct PrimaryCapsuleMetrics: Equatable {
    var fontSize: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var minHeight: CGFloat
    /// How much black is mixed in at the top and bottom of the gradient.
    var topDarken: Double
    var bottomDarken: Double
    /// nil lets a long label wrap; a number keeps it to that many lines, shrinking it a little.
    var lineLimit: Int?

    static let standard = PrimaryCapsuleMetrics(fontSize: 16, horizontalPadding: 20, verticalPadding: 0, minHeight: 44,
                                                topDarken: 0.08, bottomDarken: 0.32, lineLimit: 1)
}

struct SoftCapsuleMetrics: Equatable {
    var fontSize: CGFloat
    var horizontalPadding: CGFloat
    var quietHorizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var minHeight: CGFloat
    var fill: Double
    var pressedFill: Double
    /// Opacity of an outline in the label colour; 0 for none.
    var stroke: Double

    static let standard = SoftCapsuleMetrics(fontSize: 15, horizontalPadding: 16, quietHorizontalPadding: 10, verticalPadding: 0,
                                             minHeight: 40, fill: 0.13, pressedFill: 0.24, stroke: 0)
}

struct WorldCardMetrics: Equatable {
    var smallFontSize: CGFloat
    var actionFontSize: CGFloat
    var actionHorizontalPadding: CGFloat
    var actionVerticalPadding: CGFloat
    /// Smallest gap between the small label and the action; nil for the system's own spacing.
    var actionGap: CGFloat?
    // Compact cards (several to a row).
    var compactSpacer: CGFloat
    var compactBigSize: CGFloat
    var compactPadding: CGFloat
    var compactMinHeight: CGFloat
    var compactObjectSize: CGFloat
    var compactObjectOffset: CGFloat

    static let standard = WorldCardMetrics(smallFontSize: 14, actionFontSize: 14, actionHorizontalPadding: 12, actionVerticalPadding: 6,
                                           actionGap: 6, compactSpacer: 26, compactBigSize: 26, compactPadding: 16,
                                           compactMinHeight: 160, compactObjectSize: 88, compactObjectOffset: 16)
}

struct CardColours: Equatable {
    var panel: Color
    var border: Color
    /// The coloured edge on the leading side of a quiet card.
    var edge: Color

    static let standard = CardColours(panel: Color.secondary.opacity(0.08), border: Color.secondary.opacity(0.25),
                                      edge: Color.secondary.opacity(0.3))
}

/// Type for display moments. Body text stays the system font.
enum DevType {
    /// Big titles and hero lines: the serif face (New York).
    static func display(_ scale: Double = 1) -> Font { .system(size: 30 * scale, weight: .bold, design: .serif) }
    static func displaySection(_ scale: Double = 1) -> Font { .system(size: 24 * scale, weight: .semibold, design: .serif) }
    /// Spoken or quoted words, set larger so they read as speech.
    static func quote(_ scale: Double = 1) -> Font { .system(size: 18 * scale, design: .serif) }
}

// MARK: - Buttons

/// The one main action on a screen: a filled capsule in the area colour, darkened so white text
/// stays readable, with a soft glow. `fullWidth` for equal-width pairs on a phone.
struct PrimaryCapsule: ButtonStyle {
    @Environment(\.areaAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.devPrimaryMetrics) private var m
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: m.fontSize, weight: .semibold))
            .lineLimit(m.lineLimit)
            .minimumScaleFactor(m.lineLimit == nil ? 1 : 0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, m.horizontalPadding)
            .padding(.vertical, m.verticalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: m.minHeight)
            .background {
                Capsule().fill(LinearGradient(colors: [accent.mix(with: .black, by: m.topDarken), accent.mix(with: .black, by: m.bottomDarken)],
                                              startPoint: .top, endPoint: .bottom))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: accent.opacity(enabled ? 0.45 : 0), radius: configuration.isPressed ? 4 : 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Secondary actions: a tinted capsule with the label in the area colour. `quiet` drops the fill
/// (Back, Undo). `onDark` uses white, for immersive screens.
struct SoftCapsule: ButtonStyle {
    @Environment(\.areaAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.devSoftMetrics) private var m
    var quiet = false
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        let ink = onDark ? Color.white : accent
        configuration.label
            .font(.system(size: m.fontSize, weight: .semibold))
            .foregroundStyle(quiet && !onDark ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink))
            .padding(.horizontal, quiet ? m.quietHorizontalPadding : m.horizontalPadding)
            .padding(.vertical, m.verticalPadding)
            .frame(minHeight: m.minHeight)
            .background(Capsule().fill(ink.opacity(quiet ? (configuration.isPressed ? 0.12 : 0) : (configuration.isPressed ? m.pressedFill : m.fill))))
            .overlay(Capsule().strokeBorder(ink.opacity(m.stroke)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.35)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A gentle press for cards and round buttons.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The one big action on an overview, as CleanMyMac's Run: a glowing circle in the area colour.
struct StartCircle: View {
    let title: String
    var accent: Color? = nil
    var hint: String? = nil
    var diameter: CGFloat = 124
    var fontSize: CGFloat = 24
    /// How much white is mixed in at the top of the gradient.
    var lighten: Double = 0.12
    let action: () -> Void
    @Environment(\.areaAccent) private var areaAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        let tint = accent ?? areaAccent
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(LinearGradient(colors: [tint.mix(with: .white, by: lighten), tint.mix(with: .black, by: 0.3)],
                                                         startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
                .shadow(color: tint.opacity(glow ? 0.9 : 0.45), radius: glow ? 36 : 18)
        }
        .buttonStyle(CardPress())
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(hint ?? "")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

// MARK: - Sidebar and lists

/// A coloured rounded square with a white symbol, as in System Settings. For sidebar rows.
struct IconTile: View {
    let colour: Color
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [colour.mix(with: .white, by: 0.15), colour.mix(with: .black, by: 0.15)],
                                     startPoint: .top, endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

/// A small progress ring, for a sidebar row or a card.
struct ProgressRing: View {
    let colour: Color
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(colour.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(colour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - Heroes and cards

/// The hero at the top of a screen or step: a band in the area colour carrying the one thing to
/// focus on. White text on the colour darkened by a quarter stays above 4.5:1 for any area colour
/// that meets the 3:1 rule; the title is always large bold text.
struct HeroBand: View {
    @Environment(\.areaAccent) private var accent
    let eyebrow: String
    let symbol: String
    let title: String
    var detail: String? = nil
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow, systemImage: symbol)
                .font(.system(size: 15 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(title)
                .font(.system(size: titleSize * scale, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            ZStack {
                accent
                Color.black.opacity(0.25)
                LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }

    private var titleSize: CGFloat {
        switch title.count {
        case ..<90: 28
        case ..<200: 22
        default: 19
        }
    }
}

/// A card with a coloured edge: the stronger example, an insight, a prompt.
struct AccentCard<Content: View>: View {
    @Environment(\.areaAccent) private var accent
    @Environment(\.devCardColours) private var colours
    var emphasised = true
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(emphasised ? accent : colours.edge).frame(width: 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(emphasised ? accent.opacity(0.10) : colours.panel))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(emphasised ? accent.opacity(0.35) : colours.border))
    }
}

/// A glassy tilted object in a colour with a symbol: the "object" on a world card, drawn in code.
struct GlassObject: View {
    let accent: Color
    let symbol: String
    var size: CGFloat = 140

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [accent.mix(with: .white, by: 0.35), accent, accent.mix(with: .black, by: 0.4)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    Ellipse().fill(.white.opacity(0.28)).frame(width: size * 0.5, height: size * 0.18)
                        .blur(radius: 6).offset(x: size * 0.12, y: size * 0.1)
                }
                .shadow(color: accent.opacity(0.55), radius: size * 0.16, y: size * 0.08)
                .rotationEffect(.degrees(-14))
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                .rotationEffect(.degrees(-6))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A finding card on an overview: its own world. Glass tinted in its colour, an object breaking out
/// of the corner, a big statement, a small label and one action. Lead with the result; the number
/// is always an action to take, never a score.
struct WorldCard: View {
    let accent: Color
    let symbol: String
    let eyebrow: String
    let big: String
    let small: String
    let action: String
    var compact = false
    let perform: () -> Void
    @Environment(\.devWorldCardMetrics) private var m

    var body: some View {
        Button(action: perform) { label }
            .buttonStyle(CardPress())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(eyebrow): \(big), \(small)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(action)
    }

    /// The card without its button, for use inside a NavigationLink.
    var label: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.trailing, compact ? 70 : 110)
                Spacer(minLength: compact ? m.compactSpacer : 60)
                Text(big)
                    .font(.system(size: compact ? m.compactBigSize : 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .bottom) {
                    Text(small)
                        .font(.system(size: m.smallFontSize))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer(minLength: m.actionGap)
                    Text(action)
                        .font(.system(size: m.actionFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, m.actionHorizontalPadding)
                        .padding(.vertical, m.actionVerticalPadding)
                        .background(.white.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                }
            }
            .padding(compact ? m.compactPadding : 20)
            .frame(maxWidth: .infinity, minHeight: compact ? m.compactMinHeight : 220, alignment: .leading)
            GlassObject(accent: accent, symbol: symbol, size: compact ? m.compactObjectSize : 140)
                .offset(x: compact ? m.compactObjectOffset : 26, y: compact ? -m.compactObjectOffset : -26)
                .allowsHitTesting(false)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.12)], startPoint: .topTrailing, endPoint: .bottomLeading)
                Color.black.opacity(0.18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Backgrounds

/// The immersive overview background: deep teal to indigo, a glow in the area colour, a touch of
/// gold. Use with .environment(\.colorScheme, .dark) and white text on that screen only.
/// `thinning` (0 to 1) lets a translucent window show through.
struct ImmersiveBackdrop: View {
    let accent: Color
    var thinning: Double = 0
    var glowRadius: CGFloat = 560
    var goldOpacity: Double = 0.13
    var goldRadius: CGFloat = 440

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(devHex: "#0d3b4c"), Color(devHex: "#1f1d5c"), Color(devHex: "#2a0f4f")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [accent.opacity(0.55), .clear], center: .bottom, startRadius: 20, endRadius: glowRadius)
            RadialGradient(colors: [Color(devHex: "#f8c829").opacity(goldOpacity), .clear], center: .topTrailing, startRadius: 10, endRadius: goldRadius)
        }
        .opacity(1 - thinning * 0.85)
        .ignoresSafeArea()
    }
}

/// A wash of the area colour behind a reading screen: strong at the top, behind the hero, near
/// nothing by mid-page so long text stays easy to read. Optional base colour underneath.
struct AccentWash: View {
    let accent: Color
    var base: Color? = nil
    /// Strength at the top, at a fifth of the way down, at halfway, and of the corner glow.
    var top: Double = 0.42
    var upper: Double = 0.16
    var middle: Double = 0.04
    var glow: Double = 0.32

    var body: some View {
        ZStack {
            if let base { base }
            LinearGradient(stops: [.init(color: accent.opacity(top), location: 0),
                                   .init(color: accent.opacity(upper), location: 0.22),
                                   .init(color: accent.opacity(middle), location: 0.5),
                                   .init(color: .clear, location: 0.75)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(glow), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Mac translucency

/// The translucency slider's curve, 0 (solid) to 1 (almost clear). First half: the background colour
/// thins over a frosted blur, to 15%. Second half: the blur fades out and the colour thins to a 5%
/// floor. Reduce Transparency must force 0.
enum TranslucencyCurve {
    static func colour(_ see: Double) -> Double { see <= 0.5 ? 1 - see * 1.7 : 0.15 - (see - 0.5) * 0.2 }
    static func blur(_ see: Double) -> Double {
        if see == 0 { return 0 }
        return see <= 0.5 ? 1 : 1 - (see - 0.5) * 2
    }
}

#if os(macOS)
extension View {
    /// Paints the window's own background (SwiftUI paints this container above the NSWindow, so it
    /// must be done here): a behind-window blur under the base colour, both following the curve.
    /// Put it on the window's root view. `see` is the slider value after Reduce Transparency.
    func devWindowBackground(base: Color, see: Double) -> some View {
        self
            .containerBackground(for: .window) {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).opacity(TranslucencyCurve.blur(see))
                    base.opacity(TranslucencyCurve.colour(see))
                }
            }
            .background(TranslucentWindow(enabled: see > 0))
    }
}

/// Makes the window itself see-through while translucency is on. Draws nothing.
struct TranslucentWindow: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !enabled
            window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        }
    }
}
#endif
