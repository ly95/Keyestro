# Launcher Dark Liquid Glass design QA

## Comparison target

- Dark source visual truth: `/Users/linyang/.codex/generated_images/01a03264-0a6d-7fa2-a51c-48a7737b32ba/exec-d79dd23d-f914-411b-ad68-ba6e70cfe8c8.png`
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

- The production `LauncherPanelVisualHost` was rendered in a real borderless AppKit window.
- The QA window started fully transparent, was moved to Desktop 2 through the test-only space mover, and was made visible only after its assigned space was verified.
- Capture used the QA process's own window image only. ScreenCaptureKit was not used, so QA does not request screen-recording permission or capture unrelated desktop content.
- The live QA window was hidden and ordered out after every capture.
- The full suite was intentionally stopped when an unrelated legacy window test surfaced on the active desktop. Only headless tests and the Desktop-2-guarded visual test were run afterward.

## Full-view comparison evidence

- The 664 × 414 pt shell, 28 pt outer radius, 78 pt header, 54 pt search field, 66 pt result rhythm, five-row stack, content insets, action alignment, and 6 pt bottom clearance match the approved composition.
- Dark uses native macOS glass with a deep navy transmissive film rather than Light's pale acrylic treatment.
- The outer shell has a restrained layered rim, a top environmental reflection, and transparent rounded corners without an opaque rectangular backing.
- Scroll indicators are hidden in the approved five-result state.

## Focused region evidence

- Search: native clear interactive glass, 22 pt continuous radius, dark navy wash, cool edge refraction, leading environmental pickup, and source-aligned icon/query placement.
- Selection: native regular glass, smoky blue transmission, cyan leading refraction, directional top and bottom highlights, source-aligned content coordinates, and a 14 pt continuous radius.
- Shell: deep navy vertical value falloff, narrow leading-edge illumination, controlled top reflection, and a layered but non-acrylic rim.

## Required fidelity surfaces

- Typography: native San Francisco system type, sizes, weights, baselines, truncation, and hierarchy align at the target viewport.
- Spacing: frame, header, row heights, icon slots, label baselines, separators, action position, radii, and bottom clearance align with the source.
- Color and material: deep navy/black transmission, cool gray-blue edges, white primary text, subdued separators, and cyan interaction tokens reproduce the Dark reference hierarchy.
- Assets: the implementation intentionally uses the installed macOS Calculator, Calendar, folder, and System Settings icons. Their current OS artwork differs from the generated mock.
- Copy: `cal`, Calculator, Calendar, Calendar / Reminders, Open Applications Folder, Calibration Assistant, Open, and the return indicator match the source state.
- Interaction: Command-A selects the full search query; Return from clipboard history pastes into the captured target; keyboard navigation and default action behavior remain intact.

## Findings

No actionable P0, P1, or P2 design differences remain for the reviewed Dark launcher state.

Residual P3/environmental differences:

- Native Liquid Glass responds to the actual desktop environment, so its internal reflected field is not a static pixel texture.
- Current macOS application icon artwork differs from the generated reference. Real system assets are the intended implementation.
- One-pixel anti-aliasing phases at glass edges differ from the raster reference while geometry remains aligned.

## Verification checklist

- [x] Approved Dark image used as source truth
- [x] Exact-size full, search, and selection comparisons reviewed together
- [x] Production AppKit/SwiftUI glass host captured at 2× on Desktop 2
- [x] QA window hidden until Desktop 2 assignment was verified
- [x] No ScreenCaptureKit or protected-folder access used
- [x] Light appearance captured as a non-regression check
- [x] Transparent outer corners verified
- [x] Command-A, clipboard Return paste, quick paste, and Dark visual assertions passed
- [x] Release build passed with warnings treated as errors

final result: passed
