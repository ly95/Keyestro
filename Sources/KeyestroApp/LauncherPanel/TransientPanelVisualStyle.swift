import AppKit
import SwiftUI

extension LauncherAppearancePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var panelAppearance: NSAppearance? {
        switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct LauncherThemePalette {
    let surfaceBase: Color
    let surfaceElevated: Color
    let surfaceSubtle: Color
    let surfaceInset: Color
    let textPrimary: Color
    let textSecondary: Color
    let border: Color
    let accent: Color
    let accentSoft: Color
    let selection: Color
    let localStatus: Color
    let localStatusSoft: Color
    let privateStatus: Color
    let privateStatusForeground: Color
    let privateStatusSoft: Color

    static func resolved(for colorScheme: ColorScheme, increasedContrast: Bool) -> Self {
        let palette = colorScheme == .dark ? dark : light
        guard increasedContrast else { return palette }
        return Self(
            surfaceBase: palette.surfaceBase,
            surfaceElevated: palette.surfaceElevated,
            surfaceSubtle: palette.surfaceSubtle,
            surfaceInset: palette.surfaceInset,
            textPrimary: palette.textPrimary,
            textSecondary: palette.textPrimary.opacity(0.82),
            border: palette.textPrimary.opacity(0.42),
            accent: palette.accent,
            accentSoft: palette.accent.opacity(0.22),
            selection: palette.accent.opacity(0.28),
            localStatus: palette.localStatus,
            localStatusSoft: palette.localStatus.opacity(0.2),
            privateStatus: palette.privateStatus,
            privateStatusForeground: palette.privateStatusForeground,
            privateStatusSoft: palette.privateStatus.opacity(0.22)
        )
    }

    private static let light = Self(
        surfaceBase: color(0xEEF3F9),
        surfaceElevated: color(0xFBFCFE),
        surfaceSubtle: color(0xE8EEF6),
        surfaceInset: color(0xF3F7FB),
        textPrimary: color(0x151A22),
        textSecondary: color(0x5C6674),
        border: color(0xB9C4D1),
        accent: color(0x168ED5),
        accentSoft: color(0xDCEEF9),
        selection: color(0xE2F0F8),
        localStatus: color(0x247B58),
        localStatusSoft: color(0xDFF1E8),
        privateStatus: color(0xD7A94E),
        privateStatusForeground: color(0x75520F),
        privateStatusSoft: color(0xF8EED8)
    )

    private static let dark = Self(
        surfaceBase: color(0x080D16),
        surfaceElevated: color(0x111721),
        surfaceSubtle: color(0x151D29),
        surfaceInset: color(0x111621),
        textPrimary: color(0xF3F7FB),
        textSecondary: color(0xA8B4C3),
        border: color(0x354253),
        accent: color(0x6FE5FF),
        accentSoft: color(0x153442),
        selection: color(0x182633),
        localStatus: color(0x70D3A4),
        localStatusSoft: color(0x15372A),
        privateStatus: color(0xE0B45F),
        privateStatusForeground: color(0xE0B45F),
        privateStatusSoft: color(0x392D18)
    )

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

enum TransientPanelVisualStyle {
    static var accentColor: Color {
        Color(nsColor: accentNSColor)
    }

    static var accentNSColor: NSColor {
        NSColor(name: nil) { appearance in
            resolvedAccent(for: appearance)
        }
    }

    static var selectedTextBackgroundNSColor: NSColor {
        NSColor(name: nil) { appearance in
            resolvedAccent(for: appearance).withAlphaComponent(0.32)
        }
    }

    private static func resolvedAccent(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(
            from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ]
        )
        switch match {
        case .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 0.60, green: 0.80, blue: 0.86, alpha: 1)
        case .accessibilityHighContrastAqua:
            return NSColor(srgbRed: 0.19, green: 0.36, blue: 0.42, alpha: 1)
        case .darkAqua:
            return NSColor(srgbRed: 0x82 / 255, green: 0xB6 / 255, blue: 0xC5 / 255, alpha: 1)
        default:
            return NSColor(srgbRed: 0x3F / 255, green: 0x69 / 255, blue: 0x75 / 255, alpha: 1)
        }
    }
}

struct TransientPanelVisualAccessibilityPolicy: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let increaseContrast: Bool

    var usesStrongSelectionOutline: Bool {
        differentiateWithoutColor || increaseContrast
    }

    var selectionOpacity: Double {
        increaseContrast ? 0.26 : 0.14
    }

    var selectionOutlineWidth: CGFloat {
        usesStrongSelectionOutline ? 1.5 : 1
    }

    var selectionIndicatorWidth: CGFloat {
        usesStrongSelectionOutline ? 3 : 2
    }
}

typealias LauncherVisualAccessibilityPolicy = TransientPanelVisualAccessibilityPolicy

private struct LauncherNativeGlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var launcherNativeGlassEnabled: Bool {
        get { self[LauncherNativeGlassEnabledKey.self] }
        set { self[LauncherNativeGlassEnabledKey.self] = newValue }
    }
}

private struct TransientPanelSelectionModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.launcherNativeGlassEnabled) private var nativeGlassEnabled

    private var visualAccessibility: TransientPanelVisualAccessibilityPolicy {
        TransientPanelVisualAccessibilityPolicy(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    private var outlineColor: Color {
        visualAccessibility.usesStrongSelectionOutline
            ? .primary
            : TransientPanelVisualStyle.accentColor.opacity(0.22)
    }

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if isSelected {
                ZStack(alignment: .leading) {
                    content
                    if colorScheme == .dark, nativeGlassEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.68),
                                        Color.white.opacity(0.42),
                                        Color.white.opacity(0.12),
                                        Color(red: 0.60, green: 0.74, blue: 0.84).opacity(0.36),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LinearGradient(
                                colors: [
                                    Color(red: 0.66, green: 0.80, blue: 0.94).opacity(0.30),
                                    Color.white.opacity(0.18),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(width: 0.8)
                        }
                        .padding(.vertical, cornerRadius * 0.72)
                        .clipShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .allowsHitTesting(false)
                    }
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color(red: 0.28, green: 0.92, blue: 1)
                                : palette.accent
                        )
                        .frame(
                            width: colorScheme == .dark
                                ? max(3, visualAccessibility.selectionIndicatorWidth)
                                : visualAccessibility.selectionIndicatorWidth
                        )
                        .frame(maxHeight: .infinity)
                        .shadow(
                            color: colorScheme == .dark ? palette.accent.opacity(0.58) : .clear,
                            radius: colorScheme == .dark ? 1.5 : 0,
                            x: colorScheme == .dark ? 0.5 : 0
                        )
                }
                .transientPanelGlassSurface(
                    cornerRadius: cornerRadius,
                    variant: .regular,
                    tint: colorScheme == .dark
                        ? Color(red: 0.02, green: 0.20, blue: 0.31).opacity(0.58)
                        : palette.accent.opacity(0.055),
                    wash: colorScheme == .dark
                        ? Color(red: 0.03, green: 0.10, blue: 0.165).opacity(0.62)
                        : nil,
                    fallback: visualAccessibility.increaseContrast
                        ? TransientPanelVisualStyle.accentColor.opacity(visualAccessibility.selectionOpacity)
                        : palette.selection,
                    edge: colorScheme == .dark
                        ? Color(red: 0.52, green: 0.68, blue: 0.78).opacity(0.32)
                        : palette.accent.opacity(0.30),
                    interactive: true
                )
            } else {
                content
            }
        }
        .overlay {
            if isSelected, visualAccessibility.usesStrongSelectionOutline {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(outlineColor, lineWidth: visualAccessibility.selectionOutlineWidth)
            }
        }
    }
}

enum TransientPanelGlassVariant {
    case regular
    case clear
}

private struct TransientPanelGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let variant: TransientPanelGlassVariant
    let tint: Color?
    let wash: Color?
    let fallback: Color
    let edge: Color
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.launcherNativeGlassEnabled) private var nativeGlassEnabled

    private var darkSurfaceWash: LinearGradient {
        let colors: [Color] =
            switch variant {
            case .regular:
                [
                    Color.white.opacity(0.055),
                    Color(red: 0.16, green: 0.39, blue: 0.52).opacity(0.065),
                    Color.clear,
                    Color.black.opacity(0.07),
                ]
            case .clear:
                [
                    Color.white.opacity(0.025),
                    Color(red: 0.08, green: 0.16, blue: 0.28).opacity(0.025),
                    Color.clear,
                    Color.black.opacity(0.035),
                ]
            }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var darkEdgeRefraction: RadialGradient {
        let refractionColor: Color
        let opacity: Double
        let endRadius: CGFloat
        switch variant {
        case .regular:
            refractionColor = Color(red: 0.25, green: 0.50, blue: 0.65)
            opacity = 0.11
            endRadius = 220
        case .clear:
            refractionColor = Color(red: 0.20, green: 0.25, blue: 0.35)
            opacity = 0.26
            endRadius = 110
        }
        return RadialGradient(
            colors: [
                refractionColor.opacity(opacity),
                Color.clear,
            ],
            center: UnitPoint(x: 0.04, y: variant == .regular ? 0 : 0.42),
            startRadius: 0,
            endRadius: endRadius
        )
    }

    @ViewBuilder
    private func darkForegroundOptics(in shape: RoundedRectangle) -> some View {
        if variant == .regular {
            ZStack {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(
                                color: Color(red: 0.20, green: 0.37, blue: 0.37).opacity(0.18),
                                location: 0
                            ),
                            .init(color: Color.clear, location: 0.72),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                LinearGradient(
                    stops: [
                        .init(
                            color: Color(red: 0.70, green: 0.86, blue: 0.98).opacity(0.85),
                            location: 0
                        ),
                        .init(
                            color: Color(red: 0.50, green: 0.64, blue: 0.76).opacity(0.62),
                            location: 0.15
                        ),
                        .init(
                            color: Color(red: 0.42, green: 0.48, blue: 0.54).opacity(0.20),
                            location: 0.30
                        ),
                        .init(color: Color.clear, location: 0.48),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white, location: 0),
                            .init(color: Color.white.opacity(0.85), location: 0.04),
                            .init(color: Color.white.opacity(0.22), location: 0.16),
                            .init(color: Color.clear, location: 0.24),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LinearGradient(
                    stops: [
                        .init(
                            color: Color(red: 0.45, green: 0.58, blue: 0.68).opacity(0.25),
                            location: 0
                        ),
                        .init(
                            color: Color(red: 0.42, green: 0.50, blue: 0.58).opacity(0.34),
                            location: 0.45
                        ),
                        .init(
                            color: Color(red: 0.38, green: 0.44, blue: 0.50).opacity(0.22),
                            location: 0.78
                        ),
                        .init(color: Color.clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear, location: 0.88),
                            .init(color: Color.white.opacity(0.15), location: 0.94),
                            .init(color: Color.white, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .clipShape(shape)
        } else {
            ZStack {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(
                                color: Color(red: 0.22, green: 0.28, blue: 0.42).opacity(0.18),
                                location: 0
                            ),
                            .init(color: Color.clear, location: 0.08),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.10), location: 0),
                        .init(color: Color.white.opacity(0.025), location: 0.34),
                        .init(color: Color.clear, location: 0.76),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white, location: 0),
                            .init(color: Color.clear, location: 0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .clipShape(shape)
        }
    }

    @ViewBuilder
    private func darkDirectionalEdges(in shape: RoundedRectangle) -> some View {
        let isRegular = variant == .regular
        ZStack {
            VStack(spacing: 0) {
                if isRegular {
                    LinearGradient(
                        stops: [
                            .init(
                                color: Color(red: 0.62, green: 0.78, blue: 0.90).opacity(0.82),
                                location: 0
                            ),
                            .init(
                                color: Color(red: 0.50, green: 0.66, blue: 0.78).opacity(0.62),
                                location: 0.13
                            ),
                            .init(
                                color: Color(red: 0.48, green: 0.55, blue: 0.62).opacity(0.32),
                                location: 0.26
                            ),
                            .init(
                                color: Color(red: 0.40, green: 0.45, blue: 0.50).opacity(0.10),
                                location: 0.42
                            ),
                            .init(color: Color.clear, location: 0.52),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 4)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white, location: 0),
                                .init(color: Color.white, location: 0.55),
                                .init(color: Color.clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.22), location: 0),
                            .init(
                                color: Color(red: 0.58, green: 0.72, blue: 0.84).opacity(0.13),
                                location: 0.22
                            ),
                            .init(color: Color.white.opacity(0.08), location: 0.52),
                            .init(color: Color.clear, location: 0.82),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 0.7)
                }
                Spacer(minLength: 0)
                if isRegular {
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.22), location: 0),
                            .init(
                                color: Color(red: 0.52, green: 0.62, blue: 0.70).opacity(0.22),
                                location: 0.42
                            ),
                            .init(color: Color.clear, location: 0.84),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 3)
                    .mask(
                        LinearGradient(
                            colors: [Color.clear, Color.white],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .padding(.horizontal, cornerRadius * 0.72)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.80, blue: 0.96)
                            .opacity(isRegular ? 0.18 : 0.13),
                        Color.white.opacity(isRegular ? 0.10 : 0.07),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 0.7)
            }
            .padding(.vertical, cornerRadius * 0.72)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glassEdges(in shape: RoundedRectangle, native: Bool) -> some View {
        shape.stroke(edge, lineWidth: colorScheme == .dark ? 0.9 : 0.75)
        if colorScheme == .dark {
            shape
                .inset(by: 1)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(variant == .regular ? 0.32 : 0.16),
                            Color(red: 0.42, green: 0.78, blue: 0.94)
                                .opacity(variant == .regular ? 0.12 : 0.05),
                            Color.clear,
                            Color.black.opacity(0.32),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
            darkDirectionalEdges(in: shape)
            if native, variant == .regular {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.11),
                            Color(red: 0.52, green: 0.76, blue: 0.90).opacity(0.16),
                            Color.white.opacity(0.08),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 0.7)
                }
                .padding(.horizontal, cornerRadius * 0.72)
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        } else {
            shape
                .inset(by: 1)
                .stroke(Color.white.opacity(0.34), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(fallback, in: shape)
                .clipShape(shape)
                .overlay { shape.stroke(edge, lineWidth: 1) }
        } else if #available(macOS 26.0, *), nativeGlassEnabled {
            let glass: Glass =
                switch variant {
                case .regular: .regular
                case .clear: .clear
                }
            let baseGlass = glass.tint(tint)
            content
                .background {
                    if colorScheme == .dark {
                        darkForegroundOptics(in: shape)
                    }
                }
                .background(wash ?? .clear, in: shape)
                .background {
                    if colorScheme == .dark {
                        ZStack {
                            shape.fill(darkSurfaceWash)
                            shape.fill(darkEdgeRefraction)
                        }
                    }
                }
                .glassEffect(interactive ? baseGlass.interactive() : baseGlass, in: shape)
                .overlay {
                    glassEdges(in: shape, native: true)
                }
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(fallback)
                        if colorScheme == .dark {
                            shape.fill(darkSurfaceWash)
                            shape.fill(darkEdgeRefraction)
                        }
                    }
                }
                .clipShape(shape)
                .overlay {
                    glassEdges(in: shape, native: false)
                }
        }
    }
}

extension View {
    func transientPanelSelectionStyle(isSelected: Bool, cornerRadius: CGFloat) -> some View {
        modifier(TransientPanelSelectionModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    func transientPanelGlassSurface(
        cornerRadius: CGFloat,
        variant: TransientPanelGlassVariant = .regular,
        tint: Color? = nil,
        wash: Color? = nil,
        fallback: Color,
        edge: Color = .clear,
        interactive: Bool = false
    ) -> some View {
        modifier(
            TransientPanelGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                variant: variant,
                tint: tint,
                wash: wash,
                fallback: fallback,
                edge: edge,
                interactive: interactive
            )
        )
    }
}

@MainActor
enum LauncherPanelVisualHost {
    static func makeView(model: LauncherViewModel) -> NSView {
        let backdrop = LauncherPanelBackdropView()

        let hosting = NSHostingView(rootView: LauncherView(model: model))
        backdrop.install(contentView: hosting)
        return backdrop
    }

    static func roundedMaterialMask(cornerRadius: CGFloat) -> NSImage {
        let radius = ceil(cornerRadius)
        let side = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: side, height: side),
            flipped: false
        ) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.clear(rect)
            let maskLayer = CALayer()
            maskLayer.frame = rect
            maskLayer.backgroundColor = NSColor.white.cgColor
            maskLayer.cornerRadius = radius
            maskLayer.cornerCurve = .continuous
            maskLayer.render(in: context)
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius,
            left: radius,
            bottom: radius,
            right: radius
        )
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class LauncherPanelBackdropView: NSView {
    let darkMaterialView = NSVisualEffectView()
    let lightGlassView: NSView = {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = LauncherPanelLayout.panelCornerRadius
            glassView.style = .regular
            return glassView
        }

        let materialView = NSVisualEffectView()
        materialView.material = .underWindowBackground
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.maskImage = LauncherPanelVisualHost.roundedMaterialMask(
            cornerRadius: LauncherPanelLayout.panelCornerRadius
        )
        return materialView
    }()
    private var hostedContentView: NSView?
    private var directContentConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterialVisibility()
    }

    static func usesDarkMaterial(for appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(
            from: [
                .accessibilityHighContrastDarkAqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .aqua,
            ]
        )
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }

    func install(contentView: NSView) {
        hostedContentView = contentView
        updateMaterialVisibility()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = LauncherPanelLayout.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        darkMaterialView.translatesAutoresizingMaskIntoConstraints = false
        darkMaterialView.material = .hudWindow
        darkMaterialView.blendingMode = .behindWindow
        darkMaterialView.state = .active
        darkMaterialView.isEmphasized = true
        darkMaterialView.maskImage = LauncherPanelVisualHost.roundedMaterialMask(
            cornerRadius: LauncherPanelLayout.panelCornerRadius
        )
        addSubview(darkMaterialView)

        lightGlassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lightGlassView)
        NSLayoutConstraint.activate([
            darkMaterialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            darkMaterialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            darkMaterialView.topAnchor.constraint(equalTo: topAnchor),
            darkMaterialView.bottomAnchor.constraint(equalTo: bottomAnchor),
            lightGlassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            lightGlassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            lightGlassView.topAnchor.constraint(equalTo: topAnchor),
            lightGlassView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateMaterialVisibility()
    }

    private func updateMaterialVisibility() {
        let usesDarkMaterial = Self.usesDarkMaterial(for: effectiveAppearance)
        if #available(macOS 26.0, *),
            let glassView = lightGlassView as? NSGlassEffectView
        {
            darkMaterialView.isHidden = true
            lightGlassView.isHidden = false
            glassView.style = .clear
            glassView.tintColor =
                usesDarkMaterial
                ? NSColor(srgbRed: 0.01, green: 0.025, blue: 0.055, alpha: 0.84)
                : NSColor(srgbRed: 0.82, green: 0.91, blue: 1, alpha: 0.035)
            layer?.borderWidth = usesDarkMaterial ? 0 : 0.65
            layer?.borderColor =
                (usesDarkMaterial
                ? NSColor.clear
                : NSColor.white.withAlphaComponent(0.66)).cgColor
            updateContentPlacement(usesNativeGlass: true)
            return
        }

        darkMaterialView.isHidden = !usesDarkMaterial
        lightGlassView.isHidden = usesDarkMaterial
        layer?.borderWidth = 0
        updateContentPlacement(usesNativeGlass: false)
    }

    private func updateContentPlacement(usesNativeGlass: Bool) {
        guard let hostedContentView else { return }
        if usesNativeGlass, #available(macOS 26.0, *),
            let glassView = lightGlassView as? NSGlassEffectView
        {
            if glassView.contentView !== hostedContentView {
                NSLayoutConstraint.deactivate(directContentConstraints)
                directContentConstraints.removeAll()
                hostedContentView.removeFromSuperview()
                glassView.contentView = hostedContentView
            }
            return
        }

        guard hostedContentView.superview !== self else { return }
        if #available(macOS 26.0, *),
            let glassView = lightGlassView as? NSGlassEffectView,
            glassView.contentView === hostedContentView
        {
            glassView.contentView = nil
        }
        hostedContentView.removeFromSuperview()
        hostedContentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostedContentView, positioned: .above, relativeTo: lightGlassView)
        directContentConstraints = [
            hostedContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostedContentView.topAnchor.constraint(equalTo: topAnchor),
            hostedContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(directContentConstraints)
    }
}
