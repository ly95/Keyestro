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
        surfaceBase: color(0x07101C),
        surfaceElevated: color(0x101925),
        surfaceSubtle: color(0x182331),
        surfaceInset: color(0x111B28),
        textPrimary: color(0xF3F7FB),
        textSecondary: color(0xA8B4C3),
        border: color(0x455469),
        accent: color(0x6FE5FF),
        accentSoft: color(0x153442),
        selection: color(0x1A2B3B),
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

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if isSelected {
                content.transientPanelGlassSurface(
                    cornerRadius: cornerRadius,
                    variant: .regular,
                    tint: palette.accent.opacity(colorScheme == .dark ? 0.075 : 0.055),
                    wash: nil,
                    fallback: visualAccessibility.increaseContrast
                        ? TransientPanelVisualStyle.accentColor.opacity(visualAccessibility.selectionOpacity)
                        : palette.selection,
                    edge: palette.accent.opacity(colorScheme == .dark ? 0.34 : 0.30),
                    interactive: true
                )
            } else {
                content
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: visualAccessibility.selectionIndicatorWidth)
                    .frame(maxHeight: .infinity)
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

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(fallback, in: shape)
                .clipShape(shape)
                .overlay { shape.stroke(edge, lineWidth: 1) }
        } else if #available(macOS 26.0, *) {
            let glass: Glass =
                switch variant {
                case .regular: .regular
                case .clear: .clear
                }
            let baseGlass = glass.tint(tint)
            content
                .background(wash ?? .clear, in: shape)
                .glassEffect(interactive ? baseGlass.interactive() : baseGlass, in: shape)
                .overlay {
                    shape.stroke(edge, lineWidth: 0.75)
                    shape
                        .inset(by: 1)
                        .stroke(
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.34),
                            lineWidth: 0.5
                        )
                }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(fallback.opacity(0.24), in: shape)
                .clipShape(shape)
                .overlay { shape.stroke(edge, lineWidth: 0.75) }
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
            glassView.style = usesDarkMaterial ? .regular : .clear
            glassView.tintColor =
                usesDarkMaterial
                ? NSColor(srgbRed: 0.01, green: 0.025, blue: 0.055, alpha: 0.80)
                : NSColor(srgbRed: 0.82, green: 0.91, blue: 1, alpha: 0.035)
            layer?.borderWidth = usesDarkMaterial ? 0.80 : 0.65
            layer?.borderColor =
                (usesDarkMaterial
                ? NSColor.white.withAlphaComponent(0.28)
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
