# Launcher Liquid Glass design QA

> Appearance requirement updated on 2026-08-25: Light is the structural baseline. Light and Dark
> use the same backdrop class/style, material layers, borders, radii, spacing, and interaction states.
> The approved Light baseline is frozen at native clear glass with a 3.5% tint. Dark uses the same
> clear glass layer with a 55% deep semantic tint so bright desktop colors cannot overwhelm the mode;
> neither appearance may add an opaque SwiftUI shell fill or extra optical layer.

## Comparison target

- Historical Dark geometry/local-surface reference: `/Users/linyang/.codex/generated_images/01a03264-0a6d-7fa2-a51c-48a7737b32ba/exec-d79dd23d-f914-411b-ad68-ba6e70cfe8c8.png`
- Normalized source panel: `/tmp/keyestro-dark-final.eNpPrM/design-dark.png`
- Production-host implementation capture: `/tmp/keyestro-dark-final.eNpPrM/live-dark.png`
- Full comparison: `/tmp/keyestro-dark-final.eNpPrM/compare-dark-final.png`
- Search comparison: `/tmp/keyestro-dark-final.eNpPrM/compare-search-final.png`
- Selection comparison: `/tmp/keyestro-dark-final.eNpPrM/compare-selection-final.png`
- Light regression capture: `/tmp/keyestro-dark-final.eNpPrM/live-light.png`
- Viewport: 664 × 414 pt at 2× density.
- Source normalization: exact 1328 × 828 px crop at x=120, y=88; no scaling.
- State: Dark appearance, query `cal`, Calculator selected, five results visible, selected default action shown.

## Capture safety and method

- The historical production comparison used the guarded live-capture path documented by the paths above.
- The 2026-08-25 Light/Dark unification pass used only the off-screen `NSHostingView` renderer. It did not order a QA window front, switch spaces, or use Desktop 2.
- ScreenCaptureKit was not used, so QA did not request screen-recording permission or capture unrelated desktop content.
- Routine launcher QA must remain off-screen. Do not enable the live QA path or use another desktop unless the user explicitly opts in.

## Full-view comparison evidence

- The 664 × 414 pt shell, 28 pt outer radius, 78 pt header, 54 pt search field, 66 pt result rhythm, five-row stack, content insets, action alignment, and 6 pt bottom clearance match the approved composition.
- Light and Dark use one adaptive shell implementation: native clear glass on macOS 26 and the same `underWindowBackground` fallback on earlier systems.
- The approved Light tint remains 3.5%; Dark uses a 55% deep tint on that same glass layer. Both retain the same 0.65 pt rim and 28 pt continuous radius, with no opaque content-layer fill. Rounded corners outside the shell remain transparent.
- Scroll indicators are hidden in the approved five-result state.

## Focused region evidence

- Search: the same clear interactive glass, 22 pt continuous radius, tint opacity, two edge strokes, and content placement in Light and Dark.
- Selection: the same regular interactive glass, 14 pt continuous radius, tint opacity, two edge strokes, leading-indicator width, and content coordinates in Light and Dark.
- Shell: the same clear adaptive backdrop, border width, and content hosting path in both appearances. Only the glass tint RGBA changes; Light's approved values are regression-locked.

## Required fidelity surfaces

- Typography: native San Francisco system type, sizes, weights, baselines, truncation, and hierarchy align at the target viewport.
- Spacing: frame, header, row heights, icon slots, label baselines, separators, action position, radii, and bottom clearance align with the source.
- Color and material: appearance differences are confined to semantic palette RGB values. Material variants, opacity, layer count, edge topology, and geometry remain identical.
- Assets: the implementation intentionally uses the installed macOS Calculator, Calendar, folder, and System Settings icons. Their current OS artwork differs from the generated mock.
- Copy: `cal`, Calculator, Calendar, Calendar / Reminders, Open Applications Folder, Calibration Assistant, Open, and the return indicator match the source state.
- Interaction: Command-A selects the full search query; Return from clipboard history pastes into the captured target; keyboard navigation and default action behavior remain intact.

## Findings

No actionable P0, P1, or P2 structural differences remain between the reviewed Light and Dark launcher states.

Residual P3/environmental differences:

- Native Liquid Glass responds to the actual desktop environment, so its internal reflected field is not a static pixel texture.
- Current macOS application icon artwork differs from the generated reference. Real system assets are the intended implementation.
- One-pixel anti-aliasing phases at glass edges differ from the raster reference while geometry remains aligned.

## Verification checklist

- [x] Approved Dark image used as source truth
- [x] Exact-size full, search, and selection comparisons reviewed together
- [x] Historical live-capture evidence retained without rerunning the Desktop 2 path
- [x] No ScreenCaptureKit or protected-folder access used
- [x] Light appearance captured as a non-regression check
- [x] Approved Light clear-glass values remain unchanged
- [x] Current off-screen Light reference is byte-for-byte identical to the `HEAD` baseline
- [x] Dark uses the same clear Liquid Glass layer with no opaque shell fill
- [x] Light and Dark use identical material topology, opacity, borders, radii, and spacing
- [x] Unification screenshots rendered off-screen without opening or moving a QA window
- [x] Transparent outer corners verified
- [x] Command-A, clipboard Return paste, quick paste, and Dark visual assertions passed
- [x] Release build passed with warnings treated as errors

final result: passed
