# Release verification sheet

Copy this file for each release candidate and record the date, tester, hardware, macOS build, artifact URL, SHA-256, and evidence link for every row.

| Gate | Result / evidence |
|---|---|
| Signed tag, version, and bundle build agree | |
| Debug, Release, unit, contract, migration, fuzz, localization checks | |
| ZIP public-download checksum and app signature/Gatekeeper/staple | |
| DMG public-download checksum, DMG Gatekeeper/staple, mounted app verification | |
| Fresh install and launch outside/inside `/Applications` | |
| Upgrade from previous schema and backup readback | |
| Tampered Sparkle archive, wrong EdDSA, wrong Apple signature, interrupted update | |
| Single/mixed-scale/portrait/negative-coordinate displays and hot-plug | |
| English, Simplified Chinese IME, Japanese IME, emoji, RTL text | |
| VoiceOver, Increase Contrast, Reduce Transparency, Reduce Motion | |
| Accessibility and Screen Recording never-requested/allowed/denied/revoked | |
| Clipboard encryption, exclusion, retention, missing-key recovery | |
| Offline screenshot/OCR and cancellation leaves no output | |
| Window actions across Finder, Safari, Xcode, Terminal, Settings, Electron | |
| Sleep/wake, lock/unlock, full screen, Stage Manager | |
| Performance gates and 8-hour/10,000-cycle soak evidence | |
| Cross-report validator passed for one production-signed executable SHA-256 | |
| SBOM, checksums, release notes, privacy/security docs reviewed | |
| Homebrew Cask generated from read-back artifact and clean install verified | |
