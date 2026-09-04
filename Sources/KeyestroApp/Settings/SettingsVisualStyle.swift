import SwiftUI

enum SettingsLayout {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 20
        static let xxLarge: CGFloat = 24
        static let xxxLarge: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let prominent: CGFloat = 16
    }

    enum Typography {
        static let pageTitle = Font.system(.title, design: .default, weight: .bold)
        static let sectionTitle = Font.system(.headline, design: .default, weight: .semibold)
        static let body = Font.system(.body, design: .default)
        static let label = Font.system(.callout, design: .default)
        static let metadata = Font.system(.caption, design: .default)
    }

    static let contentMaxWidth: CGFloat = 680
    static let pagePadding = Spacing.xxxLarge
    static let pageSpacing = Spacing.xxLarge
    static let cardPadding = Spacing.large
    static let cardSpacing = Spacing.medium
    static let rowSpacing = Spacing.medium
    static let rowMinimumHeight: CGFloat = 44
    static let headerIconSize: CGFloat = 32
    static let borderWidth: CGFloat = 1
}

enum SettingsTone: Sendable {
    case standard
    case `private`
    case local
    case danger
}

struct SettingsPageHeader: View {
    let section: SettingsSection

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.Spacing.medium) {
            Image(systemName: section.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(
                    width: SettingsLayout.headerIconSize,
                    height: SettingsLayout.headerIconSize
                )
                .background(
                    palette.accentSoft,
                    in: RoundedRectangle(
                        cornerRadius: SettingsLayout.Radius.control,
                        style: .continuous
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SettingsLayout.Spacing.xSmall) {
                Text(verbatim: section.title)
                    .font(SettingsLayout.Typography.pageTitle)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                Text(verbatim: section.subtitle)
                    .font(SettingsLayout.Typography.label)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: section.title))
        .accessibilityValue(Text(verbatim: section.subtitle))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("settings.detail.header")
    }
}

struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    let tone: SettingsTone
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tone: SettingsTone = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.content = content()
    }

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsLayout.Radius.card, style: .continuous)
    }

    private var surfaceColor: Color {
        switch tone {
        case .standard:
            palette.surfaceElevated
        case .private:
            palette.privateStatusSoft
        case .local:
            palette.localStatusSoft
        case .danger:
            palette.surfaceElevated
        }
    }

    private var borderColor: Color {
        switch tone {
        case .standard:
            palette.border
        case .private:
            palette.privateStatus
        case .local:
            palette.localStatus
        case .danger:
            .red
        }
    }

    private var accentColor: Color {
        switch tone {
        case .standard:
            palette.accent
        case .private:
            palette.privateStatusForeground
        case .local:
            palette.localStatus
        case .danger:
            .red
        }
    }

    private var iconBackground: Color {
        switch tone {
        case .standard:
            palette.accentSoft
        case .private:
            palette.surfaceElevated.opacity(0.58)
        case .local:
            palette.surfaceElevated.opacity(0.58)
        case .danger:
            Color.red.opacity(colorSchemeContrast == .increased ? 0.20 : 0.11)
        }
    }

    private var hasHeader: Bool {
        title != nil || subtitle != nil || systemImage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
            if hasHeader {
                header
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SettingsLayout.cardPadding)
        .background(
            surfaceColor.opacity(reduceTransparency ? 1 : 0.96),
            in: shape
        )
        .overlay {
            shape.stroke(
                borderColor.opacity(colorSchemeContrast == .increased ? 0.92 : 0.48),
                lineWidth: SettingsLayout.borderWidth
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: SettingsLayout.Spacing.medium) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        iconBackground,
                        in: RoundedRectangle(
                            cornerRadius: SettingsLayout.Radius.control,
                            style: .continuous
                        )
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: SettingsLayout.Spacing.xSmall) {
                if let title {
                    Text(verbatim: title)
                        .font(SettingsLayout.Typography.sectionTitle)
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SettingsLayout.Typography.label)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String?
    private let accessory: Accessory

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: SettingsLayout.rowSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.Spacing.xSmall) {
                Text(verbatim: title)
                    .font(SettingsLayout.Typography.body)
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(verbatim: detail)
                        .font(SettingsLayout.Typography.label)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: SettingsLayout.rowMinimumHeight)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) {
            EmptyView()
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    let isEnabled: Bool

    init(
        title: String,
        detail: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
        self.isEnabled = isEnabled
    }

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(isOn: $isOn) {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: title))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

struct SettingsStatusBadge: View {
    let text: String
    let systemImage: String?
    let tone: SettingsTone

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        _ text: String,
        systemImage: String? = nil,
        tone: SettingsTone = .standard
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var foregroundColor: Color {
        switch tone {
        case .standard: palette.accent
        case .private: palette.privateStatusForeground
        case .local: palette.localStatus
        case .danger: .red
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .standard: palette.accentSoft
        case .private: palette.privateStatusSoft
        case .local: palette.localStatusSoft
        case .danger: Color.red.opacity(colorSchemeContrast == .increased ? 0.20 : 0.11)
        }
    }

    var body: some View {
        HStack(spacing: SettingsLayout.Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(SettingsLayout.Typography.metadata.weight(.semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, SettingsLayout.Spacing.small)
        .padding(.vertical, SettingsLayout.Spacing.xSmall)
        .background(
            backgroundColor,
            in: RoundedRectangle(
                cornerRadius: SettingsLayout.Radius.control,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.Radius.control, style: .continuous)
                .stroke(
                    foregroundColor.opacity(colorSchemeContrast == .increased ? 0.72 : 0.24),
                    lineWidth: SettingsLayout.borderWidth
                )
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsNotice: View {
    let title: String?
    let message: String
    let systemImage: String
    let tone: SettingsTone

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        title: String? = nil,
        message: String,
        systemImage: String = "info.circle.fill",
        tone: SettingsTone = .standard
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
    }

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var foregroundColor: Color {
        switch tone {
        case .standard: palette.accent
        case .private: palette.privateStatusForeground
        case .local: palette.localStatus
        case .danger: .red
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .standard: palette.surfaceSubtle
        case .private: palette.privateStatusSoft
        case .local: palette.localStatusSoft
        case .danger: palette.surfaceElevated
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SettingsLayout.Spacing.xSmall) {
                if let title {
                    Text(verbatim: title)
                        .font(SettingsLayout.Typography.label.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                }
                Text(verbatim: message)
                    .font(SettingsLayout.Typography.label)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SettingsLayout.Spacing.medium)
        .background(
            backgroundColor.opacity(reduceTransparency ? 1 : 0.94),
            in: RoundedRectangle(
                cornerRadius: SettingsLayout.Radius.control,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.Radius.control, style: .continuous)
                .stroke(
                    foregroundColor.opacity(colorSchemeContrast == .increased ? 0.72 : 0.28),
                    lineWidth: SettingsLayout.borderWidth
                )
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsDangerZone<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        SettingsCard(
            title: title,
            subtitle: subtitle,
            systemImage: "exclamationmark.triangle.fill",
            tone: .danger
        ) {
            content
        }
    }
}
