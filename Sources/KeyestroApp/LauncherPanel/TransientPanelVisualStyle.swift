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
        surfaceBase: color(0xF4F5F3),
        surfaceElevated: color(0xFFFFFF),
        surfaceSubtle: color(0xECEFEC),
        surfaceInset: color(0xF2F5F3),
        textPrimary: color(0x17211E),
        textSecondary: color(0x5E6A66),
        border: color(0xD9DEDB),
        accent: color(0x3F6975),
        accentSoft: color(0xE5EFF1),
        selection: color(0xE3EFF2),
        localStatus: color(0x3B8D68),
        localStatusSoft: color(0xE3F2EA),
        privateStatus: color(0xEFD9AA),
        privateStatusForeground: color(0x8A641F),
        privateStatusSoft: color(0xFAF0D9)
    )

    private static let dark = Self(
        surfaceBase: color(0x0E1212),
        surfaceElevated: color(0x151B19),
        surfaceSubtle: color(0x19211F),
        surfaceInset: color(0x1C2622),
        textPrimary: color(0xECF1EF),
        textSecondary: color(0xA9B4B0),
        border: color(0x2B3633),
        accent: color(0x82B6C5),
        accentSoft: color(0x24383D),
        selection: color(0x20343B),
        localStatus: color(0x72C69F),
        localStatusSoft: color(0x173B2C),
        privateStatus: color(0xD8AD64),
        privateStatusForeground: color(0xD8AD64),
        privateStatusSoft: color(0x342A19)
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

    func body(content: Content) -> some View {
        content
            .background(
                isSelected
                    ? (visualAccessibility.increaseContrast
                        ? TransientPanelVisualStyle.accentColor.opacity(visualAccessibility.selectionOpacity)
                        : palette.selection)
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(TransientPanelVisualStyle.accentColor)
                        .frame(width: visualAccessibility.selectionIndicatorWidth)
                        .frame(height: 30)
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

extension View {
    func transientPanelSelectionStyle(isSelected: Bool, cornerRadius: CGFloat) -> some View {
        modifier(TransientPanelSelectionModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}
