# Launcher Dark Liquid Glass design QA

## Comparison target

- Dark source visual truth: `/Users/linyang/.codex/generated_images/01a03264-0a6d-7fa2-a51c-48a7737b32ba/exec-d79dd23d-f914-411b-ad68-ba6e70cfe8c8.png`
- Normalized source panel: `/tmp/keyestro-dark-design-qa-final/reference-dark-normalized.png`
- Production-host implementation capture: `/tmp/keyestro-dark-design-qa-final/implementation-dark-live@2x.png`
- Normalized implementation: `/tmp/keyestro-dark-design-qa-final/implementation-dark-normalized.png`
- Full comparison: `/tmp/keyestro-dark-design-qa-final/compare-dark-final.png`
- Search comparison: `/tmp/keyestro-dark-design-qa-final/compare-search.png`
- Selection comparison: `/tmp/keyestro-dark-design-qa-final/compare-selection.png`
- Light regression capture: `/tmp/keyestro-dark-design-qa-final/implementation-light-regression@2x.png`
- Viewport: 664 × 414 pt
- Source normalization: the approved panel was cropped and normalized to 664 × 414 px.
- Implementation capture: 1328 × 828 px at 2× density, downsampled to 664 × 414 px for comparison.
- State: Dark appearance, query `cal`, Calculator selected, five results visible, selected default action shown.

The source uses a dark abstract backdrop. The live implementation was captured over the actual light Desktop 2 wallpaper. Because Liquid Glass is environment-responsive, wallpaper color pickup is expected to differ; geometry, foreground treatment, glass hierarchy, darkness retention, edge response, and background transmission were compared rather than treating backdrop pixels as static paint.

## Full-view comparison evidence

- The production `LauncherPanelVisualHost` was rendered in a real borderless AppKit window, not an opaque SwiftUI screenshot substitute.
- The 664 × 414 pt shell, 28 pt continuous outer radius, 78 pt header, 54 pt search field, 64 pt result rhythm, content insets, five-row stack, and action alignment match the source.
- Dark now has its own material treatment: native macOS regular glass, a deep navy transmissive wash, and a multi-pass specular shell edge. It remains dark over the light Desktop 2 wallpaper while still retaining faint refracted wallpaper color.
- The implementation no longer shares Light's pale acrylic reading. Light remains on the existing clear-glass path and was captured separately as a regression check.
- All four outer corners expose the real desktop rather than a rectangular backing color.

## Focused region evidence

- Search: `/tmp/keyestro-dark-design-qa-final/compare-search.png` shows the same 12 pt shell inset, 54 pt height, 22 pt continuous radius, icon/query placement, and source-aligned cool specular edge. The search surface uses native clear interactive glass with a Dark-only navy tint.
- Selection: `/tmp/keyestro-dark-design-qa-final/compare-selection.png` shows the same edge-to-edge 64 pt row, content coordinates, selected action position, and full-height cyan indicator. The selected surface has a separate regular-glass pass, cyan tint, blue wash, and directional inner highlight rather than a flat fill.
- Shell: the full comparison shows the source's layered rim reproduced as an outer directional highlight plus two inset edge passes. The underlying native glass remains responsible for blur and refraction.

## Required fidelity surfaces

- Fonts and typography: native San Francisco system typography, sizes, weights, baselines, truncation, and hierarchy align at the normalized viewport. Search text, result labels, and action text remain real native text.
- Spacing and layout rhythm: frame, search/header measurements, row heights, icon slots, label baselines, separators, action alignment, radii, and bottom clearance align with the source.
- Colors and visual tokens: Dark uses deep navy/black transmission, cool gray-blue edges, white primary text, subdued separators, and cyan selection/action tokens. The live material adapts to the desktop without becoming a light gray acrylic panel.
- Image quality and asset fidelity: the implementation uses the current macOS Calculator, Calendar, folder, and System Settings application assets at native resolution. Their artwork differs slightly from the generated mock because the app intentionally uses real installed OS assets rather than approximations.
- Copy and content: `cal`, Calculator, Calendar, Calendar / Reminders, Open Applications Folder, Calibration Assistant, Open, and the return indicator match the source state.
- Accessibility and behavior: the focused search field and Results list remain accessible; Command-A selects the entire query; keyboard navigation and the default action remain unchanged.

## Findings

No actionable P0, P1, or P2 differences remain for the reviewed Dark launcher state.

Residual P3/environmental differences:

- The source and live capture sample different wallpapers, so their internal reflected color fields cannot be pixel-identical. Dark value retention and background transmission are now stable on the brighter live backdrop.
- Current macOS application icon artwork differs slightly from the generated source mock. Real system assets are the intended implementation.

## Comparison history

- Earlier P1: the previous QA incorrectly marked a nearly opaque black slab as matching the source. Fix: replaced isolated screenshot judgment with a live production-host capture through ScreenCaptureKit on Desktop 2.
- Iteration P1: clear outer glass with a weak tint became light gray on the bright live wallpaper, so it failed to remain a Dark UI. Fix: restored native regular glass for Dark and separated it from Light's clear-glass path.
- Iteration P1: native regular glass alone still read as gray acrylic and lacked the source's deep value range. Fix: added a Dark-only deep navy transmissive layer that leaves wallpaper color faintly visible.
- Iteration P2: search, shell, and selection were too flat and shared one edge treatment. Fix: added separate Dark search tint, selected-row glass/wash, directional inner highlights, and the layered shell rim.
- Iteration P2: the selected row was too neutral compared with the source's blue glass. Fix: increased the cyan glass tint and added a restrained blue transmissive wash. The final focused comparison shows a distinct blue selected layer without changing geometry.

## Verification checklist

- [x] Approved Dark image used as source truth
- [x] Same-size full and focused comparisons reviewed together
- [x] Production AppKit/SwiftUI glass host captured at 2× through ScreenCaptureKit
- [x] Real Desktop 2 backdrop used to verify transmission and Dark value retention
- [x] Light appearance captured as a non-regression check
- [x] Transparent outer corners verified
- [x] Command-A, accessible search/results, and Dark host assertions passed
- [x] Focused design tests and warnings-as-errors build passed

final result: passed
