# Keyestro UI Standard

`src/tokens.css` is the only source of truth for geometry and typography. Light and Dark may change color/material tokens only; they must never change component size, spacing, radius, typography, or state.

## Typography

| Token | Size | Use |
| --- | ---: | --- |
| `--type-display` | 26 px | Product screen titles and onboarding headlines |
| `--type-title` | 20 px | Dialog and empty-state titles |
| `--type-heading` | 16 px | Command titles and section headings |
| `--type-body` | 14 px | Primary content and toolbar fields |
| `--type-label` | 12 px | Control labels and standard copy |
| `--type-meta` | 11 px | Supporting details |
| `--type-caption` | 10 px | Section metadata |
| `--type-micro` | 9 px | Badges and hashes only |

Launcher Results keeps two approved locked values: 23 px search text and 19.5 px result labels.

## Controls and rows

| Context | Height | Radius |
| --- | ---: | ---: |
| Launcher search | 54 px | 16 px |
| Clipboard toolbar field, filter, Quick View action | 44 px | 12 px |
| Standard button and form field | 32 px | 8 px |
| Compact Settings control | 28 px | 8 px |
| Launcher result row | 66 px | 28 px |
| Command row | 54 px | 16 px |
| Content list row | 60 px | 12 px |
| Settings navigation row | 32 px | 8 px |

## Radius and spacing scales

- Approved radii: 6, 8, 12, 16, 24, and 28 px; fully circular or pill shapes use `--radius-pill`.
- Approved spacing: 4, 8, 12, 16, 20, 24, and 32 px.
- Panel-specific fixed dimensions may exist for layout math, but interactive controls must use the documented control and row tokens.

## Enforcement

- Do not add a raw `font-size`, interactive-control height, or interactive radius to `styles.css`.
- Reuse an existing semantic token first. Add a new token only after documenting a genuinely new UI context here.
- Similar controls must share the same token: Launcher Results and Actions search are one class of control; Clipboard search and filters are another.
- Launcher Results is locked and requires a Light/Dark screenshot regression check before every handoff.
