import KeyestroCore
import SwiftUI

struct GeneralSettingsSection: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: SettingsLayout.pageSpacing) {
            SettingsCard(
                title: L10n.text("Appearance"),
                subtitle: L10n.text("Keep the launcher comfortable in every workspace."),
                systemImage: "circle.lefthalf.filled"
            ) {
                SettingsRow(
                    title: L10n.text("Launcher appearance"),
                    detail: L10n.text("Auto follows macOS. Light and Dark overrides stay on this Mac.")
                ) {
                    Picker("Launcher appearance", selection: $settings.launcherAppearance) {
                        ForEach(LauncherAppearancePreference.allCases) { appearance in
                            Text(L10n.text(appearance.title)).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
            .id(SettingsAnchor.generalAppearance)

            SettingsCard(
                title: L10n.text("App behavior"),
                subtitle: L10n.text("Choose where Keyestro appears and when it starts."),
                systemImage: "macwindow"
            ) {
                SettingsToggleRow(
                    title: L10n.text("Show Keyestro in the Dock"),
                    detail: L10n.text("The menu bar remains available when the Dock icon is hidden."),
                    isOn: $settings.showDockIcon
                )
                .id(SettingsAnchor.generalDock)

                Divider()

                LoginItemSettingsView()
                    .id(SettingsAnchor.generalLogin)
            }
        }
    }
}

struct ShortcutSettingsSection: View {
    @ObservedObject var settings: SettingsStore
    let beginRecording: () -> Void
    let endRecording: () -> Void

    var body: some View {
        VStack(spacing: SettingsLayout.pageSpacing) {
            SettingsCard(
                title: L10n.text("Global shortcuts"),
                subtitle: L10n.text("Open Keyestro workflows without leaving the current app."),
                systemImage: "keyboard"
            ) {
                ShortcutRecorder(
                    settings: settings,
                    beginRecording: beginRecording,
                    endRecording: endRecording
                )
            }
            .id(SettingsAnchor.shortcutsHotKeys)

            SettingsCard(
                title: L10n.text("Launcher behavior"),
                subtitle: L10n.text("Tune the keyboard gestures available while searching."),
                systemImage: "command"
            ) {
                SettingsToggleRow(
                    title: L10n.text("Command-number opens visible results"),
                    detail: L10n.text("Use the physical number row; Command-0 opens the tenth result."),
                    isOn: $settings.numberShortcutsEnabled
                )
                .id(SettingsAnchor.shortcutsNumbers)

                Divider()

                SettingsToggleRow(
                    title: L10n.text("Enable /, >, =, and @ query prefixes"),
                    detail: L10n.text("Jump directly to files, commands, calculations, or extensions."),
                    isOn: $settings.prefixesEnabled
                )
                .id(SettingsAnchor.shortcutsPrefixes)
            }
        }
    }
}

struct FeatureSettingsSection: View {
    @ObservedObject var settings: SettingsStore
    let quicklinks: any QuicklinkStoring
    let scripts: any ScriptStoring
    let scriptInstaller: ManagedScriptInstaller?
    let openPermissions: () -> Void

    var body: some View {
        VStack(spacing: SettingsLayout.pageSpacing) {
            fileSearchCard
            systemActionsCard
            clipboardCard

            QuickPasteSettingsView(settings: settings, openPermissions: openPermissions)
                .id(SettingsAnchor.featuresQuickPaste)

            SettingsCard(
                title: L10n.text("Capture & OCR"),
                subtitle: L10n.text("Recognize text locally with Apple Vision."),
                systemImage: "viewfinder"
            ) {
                SettingsRow(
                    title: L10n.text("OCR recognition languages"),
                    detail: L10n.text("Accurate mode runs on this Mac and never sends screenshots to a network service.")
                ) {
                    Picker("OCR recognition languages", selection: $settings.ocrLanguagePreset) {
                        Text("Automatic").tag("automatic")
                        Text("English + 简体中文").tag("en-zh")
                        Text("English").tag("en-US")
                        Text("简体中文").tag("zh-Hans")
                        Text("日本語").tag("ja-JP")
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                .id(SettingsAnchor.featuresOCR)
            }

            SettingsCard {
                QuicklinkSettingsView(store: quicklinks)
            }
            .id(SettingsAnchor.featuresQuicklinks)

            SettingsCard {
                ScriptSettingsView(store: scripts, installer: scriptInstaller)
            }
            .id(SettingsAnchor.featuresScripts)
        }
    }

    private var fileSearchCard: some View {
        SettingsCard(
            title: L10n.text("File Search"),
            subtitle: L10n.text("Choose which Spotlight-indexed content can appear in results."),
            systemImage: "doc.text.magnifyingglass"
        ) {
            SettingsToggleRow(
                title: L10n.text("Enable file search"),
                detail: L10n.text("Off by default. macOS may ask for folder access on your first search."),
                isOn: $settings.fileSearchEnabled
            )

            Divider()

            VStack(spacing: SettingsLayout.Spacing.small) {
                SettingsToggleRow(
                    title: L10n.text("Search indexed file contents"),
                    isOn: $settings.fileContentSearchEnabled,
                    isEnabled: settings.fileSearchEnabled
                )
                SettingsToggleRow(
                    title: L10n.text("Include hidden files"),
                    isOn: $settings.fileHiddenFilesEnabled,
                    isEnabled: settings.fileSearchEnabled
                )
                SettingsToggleRow(
                    title: L10n.text("Include system locations"),
                    isOn: $settings.fileSystemLocationsEnabled,
                    isEnabled: settings.fileSearchEnabled
                )
                SettingsToggleRow(
                    title: L10n.text("Include the Trash"),
                    isOn: $settings.fileTrashEnabled,
                    isEnabled: settings.fileSearchEnabled
                )
            }
            .padding(SettingsLayout.Spacing.medium)
            .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: SettingsLayout.Radius.control))
        }
        .id(SettingsAnchor.featuresFiles)
    }

    private var systemActionsCard: some View {
        SettingsCard(
            title: L10n.text("System actions"),
            subtitle: L10n.text("Keep consequential actions deliberate."),
            systemImage: "power"
        ) {
            SettingsToggleRow(
                title: L10n.text("Always confirm before putting this Mac to sleep"),
                detail: L10n.text("The first sleep action always explains its effect."),
                isOn: $settings.confirmSleepEveryTime
            )
            .id(SettingsAnchor.featuresSleep)
        }
    }

    private var clipboardCard: some View {
        SettingsCard(
            title: L10n.text("Clipboard History"),
            subtitle: L10n.text("Keep recent clipboard items encrypted and available locally."),
            systemImage: "doc.on.clipboard",
            tone: .private
        ) {
            SettingsToggleRow(
                title: L10n.text("Clipboard history"),
                detail: L10n.text("History is off by default and encrypted before persistence."),
                isOn: $settings.clipboardEnabled
            )
            .id(SettingsAnchor.featuresClipboard)

            Divider()

            SettingsToggleRow(
                title: L10n.text("Pause clipboard monitoring"),
                detail: L10n.text("Keep existing history without recording new clipboard changes."),
                isOn: $settings.clipboardPaused,
                isEnabled: settings.clipboardEnabled
            )

            Divider()

            SettingsRow(title: L10n.text("Clipboard retention")) {
                Picker("Clipboard retention", selection: $settings.clipboardRetentionPreset) {
                    Text("1 day").tag("1-day")
                    Text("7 days").tag("7-days")
                    Text("30 days or 1,000 items").tag("30-days")
                    Text("90 days").tag("90-days")
                    Text("Unlimited items (500 MiB quota)").tag("unlimited")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            .id(SettingsAnchor.featuresRetention)

            Divider()

            VStack(alignment: .leading, spacing: SettingsLayout.Spacing.small) {
                Text("Excluded application Bundle IDs (one per line)")
                    .font(SettingsLayout.Typography.label.weight(.medium))
                TextEditor(text: $settings.clipboardExcludedApplications)
                    .font(.body.monospaced())
                    .accessibilityLabel(Text("Excluded application Bundle IDs (one per line)"))
                    .frame(minHeight: 72, maxHeight: 104)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: SettingsLayout.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsLayout.Radius.control)
                            .stroke(.separator, lineWidth: 1)
                    }
                Text(
                    "The source app is inferred best-effort. Exclusions are a privacy convenience, not a security boundary."
                )
                .font(SettingsLayout.Typography.metadata)
                .foregroundStyle(.secondary)
            }
            .id(SettingsAnchor.featuresExclusions)
        }
    }
}
