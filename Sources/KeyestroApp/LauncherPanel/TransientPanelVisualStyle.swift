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

    private var selectionShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if isSelected {
                ZStack(alignment: .leading) {
                    content
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(palette.accent)
                        .frame(width: visualAccessibility.selectionIndicatorWidth)
                        .frame(maxHeight: .infinity)
                }
                .clipShape(selectionShape)
                .transientPanelGlassSurface(
                    cornerRadius: cornerRadius,
                    variant: .regular,
                    tint: palette.accent.opacity(0.055),
                    fallback: visualAccessibility.increaseContrast
                        ? TransientPanelVisualStyle.accentColor.opacity(visualAccessibility.selectionOpacity)
                        : palette.selection,
                    edge: palette.accent.opacity(0.30),
                    interactive: true
                )
            } else {
                content
            }
        }
        .overlay {
            if isSelected, visualAccessibility.usesStrongSelectionOutline {
                selectionShape
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
    let fallback: Color
    let edge: Color
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.launcherNativeGlassEnabled) private var nativeGlassEnabled

    @ViewBuilder
    private func glassEdges(in shape: RoundedRectangle) -> some View {
        shape.stroke(edge, lineWidth: 0.75)
        shape
            .inset(by: 1)
            .stroke(Color.white.opacity(0.34), lineWidth: 0.5)
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
                .glassEffect(interactive ? baseGlass.interactive() : baseGlass, in: shape)
                .overlay {
                    glassEdges(in: shape)
                }
        } else {
            content
                .background(fallback, in: shape)
                .clipShape(shape)
                .overlay {
                    glassEdges(in: shape)
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
        fallback: Color,
        edge: Color = .clear,
        interactive: Bool = false
    ) -> some View {
        modifier(
            TransientPanelGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                variant: variant,
                tint: tint,
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
    static let approvedLightGlassTintOpacity: CGFloat = 0.035
    static let darkGlassTintOpacity: CGFloat = 0.55

    let adaptiveGlassView: NSView = {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = LauncherPanelLayout.panelCornerRadius
            glassView.style = .clear
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
        updateMaterialAppearance()
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

    static func glassTintColor(for appearance: NSAppearance) -> NSColor {
        if usesDarkMaterial(for: appearance) {
            return NSColor(
                srgbRed: 0x08 / 255,
                green: 0x0D / 255,
                blue: 0x16 / 255,
                alpha: darkGlassTintOpacity
            )
        }
        return NSColor(
            srgbRed: 0.82,
            green: 0.91,
            blue: 1,
            alpha: approvedLightGlassTintOpacity
        )
    }

    static func borderColor(for appearance: NSAppearance) -> NSColor {
        if usesDarkMaterial(for: appearance) {
            return NSColor(srgbRed: 0x35 / 255, green: 0x42 / 255, blue: 0x53 / 255, alpha: 0.66)
        }
        return NSColor.white.withAlphaComponent(0.66)
    }

    func install(contentView: NSView) {
        hostedContentView = contentView
        updateMaterialAppearance()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = LauncherPanelLayout.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        adaptiveGlassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(adaptiveGlassView)
        NSLayoutConstraint.activate([
            adaptiveGlassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            adaptiveGlassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            adaptiveGlassView.topAnchor.constraint(equalTo: topAnchor),
            adaptiveGlassView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateMaterialAppearance()
    }

    private func updateMaterialAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0.65
        layer?.borderColor = Self.borderColor(for: effectiveAppearance).cgColor

        if #available(macOS 26.0, *),
            let glassView = adaptiveGlassView as? NSGlassEffectView
        {
            glassView.style = .clear
            glassView.tintColor = Self.glassTintColor(for: effectiveAppearance)
            updateContentPlacement(usesNativeGlass: true)
            return
        }

        layer?.borderWidth = 0
        layer?.borderColor = nil
        updateContentPlacement(usesNativeGlass: false)
    }

    private func updateContentPlacement(usesNativeGlass: Bool) {
        guard let hostedContentView else { return }
        if usesNativeGlass, #available(macOS 26.0, *),
            let glassView = adaptiveGlassView as? NSGlassEffectView
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
            let glassView = adaptiveGlassView as? NSGlassEffectView,
            glassView.contentView === hostedContentView
        {
            glassView.contentView = nil
        }
        hostedContentView.removeFromSuperview()
        hostedContentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostedContentView, positioned: .above, relativeTo: adaptiveGlassView)
        directContentConstraints = [
            hostedContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostedContentView.topAnchor.constraint(equalTo: topAnchor),
            hostedContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(directContentConstraints)
    }
}
