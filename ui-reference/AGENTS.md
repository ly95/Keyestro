# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## Keyestro UI reference contract

- This folder is a design reference only. Do not modify the production SwiftUI app from this prototype.
- Build the reference with semantic HTML and SVG artwork/icons.
- Light and Dark must use the same component tree, dimensions, spacing, radii, and interaction states. Theme changes are token-only.
- `src/tokens.css` is the only source of truth for typography, control heights, row heights, radii, and spacing. Do not introduce raw component-level values for those properties; follow `design-system.md`.
- The approved type ramp is 26 / 20 / 16 / 14 / 12 / 11 / 10 / 9 px. The approved control heights are 54 / 44 / 32 / 28 px. The approved radii are 6 / 8 / 12 / 16 / 24 / 28 px plus circular/pill shapes.
- Run `npm run test:design-system` after UI edits. The guard must pass before handoff.
- Preserve a translucent Liquid Glass material in both themes. Dark must read as neutral navy/black glass, never as a wallpaper-colored opaque panel; Light must retain its airy glass treatment.
- Include every product-owned UI surface: launcher, clipboard history, settings sections, onboarding, menu bar, capture/OCR, HUDs, confirmations, and loading/empty/error states.

## Locked and selected design decisions

- Launcher Results is locked. Do not change its layout, spacing, content, materials, Light/Dark tokens, or interaction state unless the user explicitly unlocks it.
- Launcher Actions and Clipboard use `design/actions-clipboard-selected-option-3.png` as their selected visual target.
- Actions continues the Results command-palette rhythm: action-specific search, one edge-to-edge action list, selected-row explanation, strict shortcut column, and an isolated destructive action.
- Clipboard keeps a full-width history list. Quick View is a temporary floating inspector anchored over the list, with Paste as the primary action and Copy as the only secondary action.
