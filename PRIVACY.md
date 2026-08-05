# Privacy

Keyestro is local-first and has no telemetry by default. Core app, file, calculator, clipboard, window, screenshot, and OCR features run locally.

- Raw search queries are not persisted.
- File search uses the local Spotlight index. Filename search is on by default; indexed file-content search, hidden files, Trash, and system locations are separate opt-ins. Keyestro never requests Full Disk Access automatically.
- Usage learning stores keyed identifiers, action categories, and timestamps for up to 90 days and can be disabled or cleared.
- Clipboard history is opt-in, encrypted per item with a Keychain-protected installation key, and defaults to 30 days or 1,000 entries.
- Clipboard images use separately authenticated, encrypted 128 px thumbnails in result lists. The full image remains encrypted and is decrypted only when the user restores or previews that item.
- Copying a clipboard-history result changes only the pasteboard. “Paste into Previous App” is a separate, confirmed action and requires Accessibility permission to synthesize Command-V.
- Screenshots have no history by default; OCR uses Apple's on-device Vision framework.
- Diagnostics are created only on request, present a content preview, and redact user paths and content.
- Update checks are the only enabled main-app network request. Native extensions may access the network with the current user's authority; their declared capabilities are disclosure, not an OS sandbox.

Quick links can open a URL only after placeholder values have been percent-encoded. Scripts and extensions run only after explicit local installation and can access data with the current user's macOS authority; their trust warning is shown before installation. Global query sharing is off for every extension until separately enabled.

Native-extension password preferences are stored only in Keychain; SQLite records only that a value is set. They are never broadcast in preference-change notifications, but an installed extension receives the secret itself when it explicitly requests the declared preference. Removing the extension or deleting all local data removes those known Keychain values.

Configuration exports exclude Keychain values, clipboard payloads, passwords, secret arguments, private environment values, and managed script bodies. The Privacy settings surface provides per-type clipboard deletion and an exact local-data deletion workflow. Clearing caches affects only Keyestro's bundle-owned cache directory.
