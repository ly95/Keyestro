# Launcher Liquid Glass design QA

## Comparison target

- Dark source visual truth: `/Users/linyang/.codex/generated_images/01a03264-0a6d-7fa2-a51c-48a7737b32ba/exec-d79dd23d-f914-411b-ad68-ba6e70cfe8c8.png`
- Light source visual truth: `/Users/linyang/.codex/generated_images/01a03264-0a6d-7fa2-a51c-48a7737b32ba/exec-f8fbffde-da2d-4fcf-9c35-7b3fd5ca431a.png`
- Native material behavior: [Apple — Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- Dark live-material implementation: `/tmp/keyestro-design-qa-final/implementation-dark-live.png`
- Light live-material implementation: `/tmp/keyestro-design-qa-final/implementation-light-live.png`
- Dark combined comparison: `/tmp/keyestro-design-qa-final/compare-dark-live.png`
- Light combined comparison: `/tmp/keyestro-design-qa-final/compare-light-live.png`
- Viewport: 664 × 414 pt
- State: query `cal`, Calculator selected, five results visible, search field focused

The Dark source establishes the shared geometry because it is the approved structural direction and has the exact 1.60 launcher aspect ratio. The Light source establishes Light material, color, and depth; its generated shell was normalized from 1292 × 826 px to the same 664 × 414 comparison viewport. This follows the explicit requirement that Light and Dark use one layout rather than two different designs.

## Full-view comparison evidence

The live implementation was rendered through the production `LauncherPanelVisualHost` over the user's real desktop image, not through an opaque screenshot substitute. The reference and implementation were then placed side by side at the same 664 × 414 size.

- The 28 pt shell radius, 78 pt header, 54 pt search field, 64 pt row rhythm, five-result stack, icon scale, text baseline, and bottom clearance align with the Dark reference.
- Light and Dark now share identical structure. Only material style, tint, foreground colors, and the Light action pill vary.
- Light visibly samples and refracts the image behind the shell. Recognizable background features are blurred and optically displaced at the shell, search, selection, and lower edge; there is no milk-white AppKit backing.
- Dark uses the same native macOS 26 glass host with a deep navy tint. It preserves faint background sampling while matching the source's darker value range instead of reverting to a flat gray HUD material.

## Focused region evidence

- Outer corners: the actual wallpaper remains visible outside all four continuous corners. No rectangular backing color leaks through.
- Search: 12 pt shell inset, 54 pt height, 22 pt continuous radius, native clear interactive glass, and the source-aligned query/icon positions.
- Selected result: the glass spans edge to edge, content remains at a 26 pt inset, the 14 pt continuous radius is clipped by the shell where appropriate, and the cyan/blue indicator runs the full row height.
- Light action: a compact 30 pt clear-glass pill matches the Light source. Dark keeps the plain `Open ↩` treatment from the approved Dark source.
- Separators: 14 pt inset and stronger Dark contrast preserve the source rhythm without introducing extra chrome.
- Assets: Calculator, Calendar, folder, and Calibration Assistant use native macOS source icons rather than approximations.

## Interaction and accessibility evidence

- A real `KeyestroTransientPanel`, `CommandTextField`, and `CommandFieldEditor` received a synthetic Command-A key event before the Desktop 2 preview was revealed.
- The selected range was verified as the entire UTF-16 query, then returned to a normal caret state for visual comparison.
- Accessibility exposes one focused search field, one Results list, five buttons, and the Calculator row as selected.
- The live preview window was verified exclusively on Space 83 (Desktop 2), never Space 3 (Desktop 1).

## Findings and fixes

- Earlier P1: previous QA incorrectly used an implementation screenshot as source truth. Fixed by locking the two generated design images above and rebuilding the comparison from them.
- Earlier P1: Light read as white acrylic. Fixed by using `NSGlassEffectView.Style.clear` for the shell and native SwiftUI clear/regular glass for nested surfaces, with the content installed inside the glass host.
- Earlier P1: Dark read as a flat gray slab over a bright background. Fixed by replacing the HUD fallback on macOS 26 with native regular glass and calibrating the deep navy tint while retaining background sampling.
- Earlier P1: selected glass had a 12 pt outer inset. Fixed by making the selection surface edge to edge while keeping its content at the reference-aligned 26 pt inset.
- Earlier P1: corner colors leaked from a rectangular backing. Fixed with one continuous 28 pt clipped native host and a transparent borderless panel.
- Earlier P2: the Light action pill was wider than the source. Fixed by reducing its horizontal glass padding while keeping its content and right alignment intact.
- Earlier P1: Command-A did not reliably select the full search query. The custom field-editor path remains intact and passes both the focused test and the live-window check.

No actionable P0, P1, or P2 differences remain in the reviewed launcher state.

## Verification checklist

- [x] Actual Dark and Light design images used as source truth
- [x] Same-size combined visual comparisons reviewed
- [x] Native material checked over a real image backdrop
- [x] Shared Light/Dark geometry verified
- [x] Full-width selection and transparent corners verified
- [x] Command-A verified in the real panel field editor
- [x] Preview verified exclusively on Desktop 2
- [x] Focused tests, release build, signing, and packaged smoke checks completed

final result: passed
