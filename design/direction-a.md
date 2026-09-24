# Nib · Direction A: Clear Water

> Everything that floats in Nib is made of clear water. It lenses the page underneath, stretches with the speed you drag it, settles with surface tension, reaches across to its neighbours, and buds off its parent. The page and your ink carry all the colour. The chrome is only water.

Companion mockup: `design/direction-a.html`. It is interactive, and every number in this document is the number that page runs on. Open it in Chrome or Edge to get the full refraction. Safari and Firefox get the documented fallback.

**Contents**

1. Principles
2. The droplet material
3. Colour
4. Typography
5. Spacing and layout grid
6. Radii
7. Elevation
8. Iconography
9. Motion
10. Droplet physics (the signature)
11. Haptics
12. Screens and layouts
13. Accessibility fallbacks
14. The design system as code (what the build agents must use)
15. What the mockup shows

---

## 1. Principles

1. **The page is the product.** Paper is full-bleed and fixed in place. Chrome floats over it and never frames it. Nib has no opaque navigation bars in the editor, no side gutters painted in UI colour, and no "app skin" around the page.
2. **One material.** Every floating thing (tool palette, bars, popovers, HUDs, AI proposals, selection handles, dragged thumbnails and cards) is the same water. There is no second glass recipe, and glass never sits on glass: when two droplets meet, they merge.
3. **Believable water, not jelly.** The damping ratio for settling droplets is 0.5–0.8, stretch caps are between 3% and 16% on anything with content, and a squash always returns to round before the droplet arrives. When in doubt, choose less.
4. **Colour belongs to ink.** The UI is Apple's neutral greys plus one accent (Pool blue). Hue on screen should come from the user's pens, highlighters, covers and folders. Nib does not use gradients as decoration, decorative accent tints, or tinted AI branding.
5. **The canvas is sacred while the pen is down.** Ink is zero-latency and crisp, so no shader ever passes over a stroke being written. While the Pencil is down, every droplet recedes to 22% opacity and stops sampling the backdrop.
6. **Liquid shows cause and effect.** A droplet deforms because you moved it, merges because you brought it close, and buds because you asked for its contents. Nothing wobbles or breathes on its own. When the user is idle, nothing moves.
7. **Native first.** Nib uses SF Pro, SF Symbols, UIKit semantics, system context menus, system share sheets and system alerts. Liquid is Nib's own chrome only. It never replaces a system component that users already know.
8. **Trust is visible.** The assistant shows what it read, cites where it looked, previews every change on the page before anything changes, and puts Undo next to the result.

---

## 2. The droplet material

A droplet has three layers, bottom to top. It is always composed this way, and no feature is allowed to invent a fourth layer.

| # | Layer | What it does | Device implementation |
|---|---|---|---|
| 1 | **Lens** | Samples what is behind the droplet (page, covers, desk) and refracts, blurs, saturates and tints it | Metal pass over a backdrop texture (§10.9) |
| 2 | **Water** | The union silhouette of all droplets in a container: body tint, edge thickness, caustic, specular and rim. Merges, necks and splits happen here | Same Metal pass, using the SDF smooth-min union |
| 3 | **Content** | Icons, labels and controls. They are never filtered or refracted, and they only follow the droplet's transform with a rigidity factor (§10.2) | Ordinary UIKit/SwiftUI views |

### 2.1 Variants

There are four variants, and nothing else.

| Variant | Used for | Lens | Body tint (light / dark) |
|---|---|---|---|
| **Clear** | Tool palette, top bars, HUDs, proposal chip, selection handles, dragged items | Rim refraction + blur 1.4 pt, saturation 1.7, brightness +4% | `#FFFFFF` 46% / `#161618` 62% |
| **Deep** | Anything holding dense UI or text: popovers, assistant panel, plugin panels, search results, toasts, page navigator | Blur 26 pt, saturation 1.8, no displacement | `#F9F9FB` 72% / `#1E1E20` 74% |
| **Tinted** | The single primary action on a surface (New, Create, Send) | None (opaque accent) | Accent 100% |
| **Bead** | Selection bead, slider thumbs, anchor beads | None: a dense drop with its own highlight | `#FFFFFF` 86% / `#FFFFFF` 22% |

**Why Clear still has a tint.** Nib's palette hovers over dense black handwriting. Crystal-clear water with no body makes black icons over black ink unreadable. The 46% body gives an honest compromise: the core is clear enough that you see the page, and the rim is fully refractive.

### 2.2 Rules

- Glass appears only on the floating layer. It is never used in lists, Settings, sheets, forms, library tiles at rest, or the page.
- Glass never sits on glass. Two droplets that overlap merge (§10.4). A Deep panel can hold controls, but it cannot hold another droplet.
- There is one Tinted droplet per screen at most.
- Text on Clear is ≥ 15 pt semibold, and icons are ≥ 21 pt at medium weight. Body text belongs on Deep.
- Resting droplets are either ≥ 16 pt apart or deliberately merged. The merge distance is 11 pt, and a 12–15 pt gap is banned because it looks like a mistake.
- Contrast is measured over the worst case beneath, which is black ink at 100% under the droplet, not over the design mock.

---

## 3. Colour

All UI neutrals are Apple's semantic colours with their exact values. In code they are `UIColor.label`, `.secondaryLabel` and so on, surfaced through `Nib.Palette`, and never as literals. They are listed here so designers and the mockup match.

### 3.1 UI neutrals

| Token | Light | Dark | Use |
|---|---|---|---|
| `label` | `#000000` | `#FFFFFF` | Primary text, icons on droplets |
| `labelSecondary` | `#3C3C43` @ 60% | `#EBEBF5` @ 60% | Subtitles, section labels, counts |
| `labelTertiary` | `#3C3C43` @ 30% | `#EBEBF5` @ 30% | Placeholders, disabled |
| `labelQuaternary` | `#3C3C43` @ 18% | `#EBEBF5` @ 16% | Hairline glyphs, watermark numbers |
| `separator` | `#3C3C43` @ 29% | `#545458` @ 65% | Hairlines inside droplets (0.5 pt) |
| `separatorSoft` | `#3C3C43` @ 12% | `#545458` @ 34% | Sidebar edge, thread top rule |
| `fill1` | `#787880` @ 20% | `#787880` @ 36% | Slider tracks, switches off |
| `fill2` | `#787880` @ 16% | `#787880` @ 32% | Pressed rows |
| `fill3` | `#767680` @ 12% | `#767680` @ 24% | Selected segment, selected sidebar row, secondary buttons |
| `fill4` | `#747480` @ 8% | `#767680` @ 18% | Proposal block, composer field |
| `background` | `#FFFFFF` | `#000000` | Library content area |
| `backgroundSecondary` | `#F2F2F7` | `#1C1C1E` | Sidebar, folder tiles, grouped lists |
| `backgroundTertiary` | `#FFFFFF` | `#2C2C2E` | Selected segment knob, cells in grouped lists |
| `desk` | `#E7E7EC` | `#121214` | Behind pages in the editor (never pure white or black: the page edge must read) |
| `chromeOpaque` | `#F4F4F6` | `#2C2C2E` | The Reduce Transparency droplet fill |

### 3.2 Accent and semantic

| Token | Light | Dark | Contrast | Use |
|---|---|---|---|---|
| `accent` (Pool) | `#0066E0` | `#3D8BFF` | 5.3:1 on white · 6.3:1 on black | Primary buttons, links, focus rings, the selected sidebar row's glyph, AI additions, citations |
| `accentWash` | `#0066E0` @ 10% | `#3D8BFF` @ 16% | – | Citation chips, drop targets |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | – | Text on accent |
| `destructive` | `#FF3B30` | `#FF453A` | – | Delete, AI strike-throughs, recording dot |
| `success` | `#34C759` | `#30D158` | – | "Applied", sync done, tool-trace checks |
| `warning` | `#FF9500` | `#FF9F0A` | – | Conflicts, storage warnings |

Pool is a half-step deeper than system blue (`#007AFF`), so that 15 pt text passes AA on white. Nib does not use purple or gradient AI branding anywhere. The assistant's colour is the accent, and its mark is a drop.

### 3.3 Water tokens (what the droplet shader reads)

| Token | Light | Dark | Meaning |
|---|---|---|---|
| `waterBody` | `#FFFFFF` @ 8% | `#FFFFFF` @ 3% | Tint inside the union silhouette (on top of the lens) |
| `waterEdge` | `#141C28` @ 15% | `#FFFFFF` @ 8% | Edge thickness (the dark ring of a real drop) |
| `waterCaustic` | `#FFFFFF` @ 30% | `#FFFFFF` @ 15% | Bright crescent opposite the light |
| `waterRim` | `#FFFFFF` @ 85% | `#FFFFFF` @ 42% | Hairline highlight facing the light |
| `waterLine` | `#000000` @ 7.5% | `#FFFFFF` @ 12% | 0.8 pt outline, so a droplet reads over white paper |
| `beadBody` | `#FFFFFF` @ 86% | `#FFFFFF` @ 22% | Selection bead and slider thumbs |
| `beadEdge` | `#141C28` @ 15% | `#FFFFFF` @ 12% | – |
| `beadShadow` | `#000000` @ 16% | `#000000` @ 45% | – |

### 3.4 Ink: the default pen palette (12 slots)

Ink is never themed. It is the same in light and dark mode. On dark paper the renderer lifts luminance (it does not invert) so that every ink stays ≥ 3:1 against the paper. Chalk exists for dark paper and blackboards.

| # | Name | Hex | Notes |
|---|---|---|---|
| 1 | Carbon | `#121212` | Default pen. Near-black, so it never looks harsh against true black UI |
| 2 | Graphite | `#5B6068` | Secondary notes, dates, labels |
| 3 | Midnight | `#1B2A6B` | Blue-black fountain ink |
| 4 | Cobalt | `#2156D9` | Classic blue ballpoint |
| 5 | Lagoon | `#0B8793` | Teal |
| 6 | Moss | `#2F7A3C` | Green |
| 7 | Ochre | `#B7791F` | Warm yellow that survives on white (pure yellow doesn't) |
| 8 | Sienna | `#9A4E2A` | Brown |
| 9 | Vermilion | `#D9432B` | Correction red |
| 10 | Crimson | `#B0173A` | Deep red |
| 11 | Plum | `#7B3FA0` | Purple |
| 12 | Chalk | `#F4F4F1` | For dark paper. Shown with a hairline ring in pickers |

The palette's quick slots default to Carbon, Cobalt and Vermilion.

### 3.5 Highlighters (6)

Highlighters render **beneath** ink (T-092). On light paper they use multiply at 60% opacity, and on dark paper they use screen at 35%.

| Name | Hex |
|---|---|
| Lemon (default) | `#FFE45C` |
| Apricot | `#FFBE6B` |
| Mint | `#86E3AE` |
| Sky | `#82CCFF` |
| Lilac | `#C8A8FF` |
| Blush | `#FFA3C7` |

### 3.6 Paper and templates

| Paper | Hex | Rule / grid colour | Margin line |
|---|---|---|---|
| White (default) | `#FFFFFF` | `#CFDBE8` | `#EDB9B3` |
| Ivory | `#FBF8F1` | `#D9D3C5` | `#E9B8A8` |
| Legal | `#FCF3C8` | `#B9C9DA` | `#E3A49B` |
| Grey | `#F1F1EF` | `#D2D4D8` | – |
| Slate (dark) | `#1E1F22` | `#34373D` | `#5A3A38` |
| Night (dark) | `#121212` | `#2A2C30` | – |
| Board (chalkboard) | `#1F2A24` | `#33443A` | – |

Template geometry at 100% (points on an A4-width page of 595 pt): ruled narrow 7.1 mm (20 pt), college 8.7 mm (24.7 pt), wide 10 mm; grid 5 mm; dots 5 mm at a 0.9 pt radius; the margin sits 25 mm from the left. Rules are 0.5 pt at zoom 1 and never thicker than 1 px on screen.

**Covers** use eight cloth colours, flat with a spine (−16% luminance, 13 pt) and an elastic band (−30%, 5 pt): Moss `#2F4A3E`, Carbon `#2A2D33`, Terracotta `#A4553A`, Sand `#D5C6A8`, Navy `#23324F`, Oxblood `#5E1F24`, Stone `#8C8A84`, Paper `#F3F1EC`. Covers have no gradients, no printed titles, and a 7% fractal grain at most.

**Folder colours** are drawn from the ink palette (Cobalt, Moss, Graphite, Ochre, Plum, Vermilion, Lagoon, Sienna), so the library and the page share one hue vocabulary.

**Presence colours** (collaborators, which never collide with ink): `#FF6B5E`, `#FFB547`, `#3DBB7A`, `#3C8DFF`, `#9C6BFF`, `#FF6FAE`.

---

## 4. Typography

Nib uses three families and nothing else. The system applies optical sizing and size-specific tracking automatically when you use text styles. **Never set kerning or tracking by hand** (the lint rule rejects `.kerning`/`.tracking` outside `Nib.Font`).

| Family | Role |
|---|---|
| **SF Pro** (Text ≤ 19 pt, Display ≥ 20 pt, automatic) | All UI |
| **SF Pro Rounded** | Numbers that live on water: page counter, zoom %, thickness, timer, recording clock, token count. Always monospaced digits |
| **New York** | Editorial moments only: study-card faces, onboarding headlines, empty-state headlines, math in the assistant, and the default body of Text Documents |

### 4.1 Scale (Dynamic Type "Large", the default)

| Nib role | Text style | Size / leading | Weight | Tracking (applied by the system) | Where |
|---|---|---|---|---|---|
| `display` | `.largeTitle` | 34 / 41 | Bold | +0.37 | Library and Settings titles, onboarding (New York Semibold) |
| `title1` | `.title` | 28 / 34 | Bold | +0.36 | Study card face (New York Regular) |
| `title2` | `.title2` | 22 / 28 | Bold | +0.35 | Sheet titles |
| `title3` | `.title3` | 20 / 25 | Semibold | +0.38 | Library sections, empty-state titles |
| `headline` | `.headline` | 17 / 22 | Semibold | −0.43 | Popover and panel titles |
| `body` | `.body` | 17 / 22 | Regular | −0.43 | Sidebar rows, lists, Settings |
| `callout` | `.callout` | 16 / 21 | Regular | −0.31 | Toasts, onboarding body |
| `chat` | `.subheadline` + 1 pt leading | 15 / 21 | Regular | −0.23 | Assistant thread, proposal rows, buttons (Semibold) |
| `barTitle` | `.subheadline` | 15 / 19 | Semibold | −0.23 | Document title in the top-left droplet |
| `footnote` | `.footnote` | 13 / 18 | Regular or Semibold | −0.08 | Section labels in popovers (Semibold, secondary), notebook titles in the grid (Semibold) |
| `caption1` | `.caption` | 12 / 16 | Regular | 0 | Subtitles, dates, tool traces |
| `caption2` | `.caption2` | 11 / 13 | Medium | +0.06 | Pen-type labels, usage line |
| `hud` | `.footnote` rounded, monospaced digits | 13 / 16 | Semibold | – | "3 / 12", "0.50 mm", "100%", "04:12" |
| `math` | `.callout` New York italic | 16 / 21 | Regular | – | Formulas in the assistant |

### 4.2 Dynamic Type

- Lists, Settings, the assistant, search results and sheets scale fully up to AX5. At AX1 and larger, the assistant's floating panel widens from 360 to 420 pt (iPad), or becomes a full sheet (iPhone).
- **Chrome droplets are capped.** Top bars scale up to `.xxxLarge`, which takes them from 44 to 52 pt tall. The palette's icons go from 23 to 28 pt, its thickness from 56 to 64 pt, and its pitch from 44 to 52 pt. Beyond that cap, the Large Content Viewer (`UILargeContentViewerInteraction`) shows the tool name and glyph on long-press, which is Apple's own pattern for bars.
- The page never responds to Dynamic Type. Zoom is how you read ink.

---

## 5. Spacing and layout grid

The base unit is 4 pt, and 2 pt is allowed only inside controls.

| Token | pt | Typical use |
|---|---|---|
| `xxs` | 2 | Icon-to-badge |
| `xs` | 4 | Pill inner padding, segmented inset |
| `s` | 8 | Gap between buttons in a row, divider margins |
| `m` | 12 | Popover row gaps, proposal-row gap |
| `l` | 16 | **Chrome inset from the screen edge**, droplet-to-droplet gap, iPhone margin |
| `xl` | 20 | Popover gap from the palette (rest), sheet padding |
| `xxl` | 24 | iPad content margin (library), grid gutters |
| `x3` | 32 | Section spacing in the library |
| `x4` | 40 | – |
| `x5` | 48 | Empty-state stack spacing |
| `x6` | 64 | Onboarding vertical rhythm |

**Fixed metrics**

- Hit targets are ≥ 44×44 pt, always. Visual size can be smaller (a 36 pt HUD or a 12 pt handle bead), but the hit area can't.
- Top bar droplets are 44 pt tall (36 pt for HUDs), placed at safe area top + 8 pt.
- The palette is 56 pt thick (iPad and iPhone), with a 44 pt tool pitch (46 on iPhone), 6 pt end padding, a 36 pt colour pitch, and a 0.5 × 28 pt divider.
- The library grid on iPad uses 140 × 182 pt covers with a 171.5 pt pitch in 11″ landscape (five columns), four columns in portrait, and six on 13″. Covers start 24 pt from the sidebar. Rows are 250 pt apart (cover + 10 + two title lines + date + 24).
- The iPhone library grid uses three columns of 110 × 143 pt with a 16 pt gutter.

---

## 6. Radii

Nib uses continuous (squircle) corners everywhere (`.continuous`, `CALayerCornerCurve.continuous`).

| Element | Radius |
|---|---|
| Bars, HUDs, chips, buttons, fields, palette | Capsule (h / 2) |
| Popover | 26 |
| Panel (assistant, plugin, search, navigator) | 28 |
| Sheet (`preferredCornerRadius`) | 28 |
| Nested group inside a panel (proposal block, segmented control) | `outer − inset` with a minimum of 8 (panel 28, inset 16 → 12). Segmented control 9 with a 7 pt knob |
| Folder tile | 14 |
| Sidebar selection | 10 |
| Notebook cover | 5 at the spine, 8 at the fore-edge (a physical book) |
| Page thumbnail | 4 |
| Page | 0 (paper has square corners) |
| Selection bead | Circle, r 20 |

**The concentric rule.** A shape inside a shape shares its centre of curvature: `inner = outer − inset`. Capsules stay capsules.

---

## 7. Elevation

There are four levels. UIKit shadows always set `shadowPath` (the droplet renderer supplies it), and the level's blur maps to `shadowRadius = blur / 2`.

| Level | What | Shadow (light) | Shadow (dark) |
|---|---|---|---|
| E0 | Paper on the desk | 0 0 0 0.5 `#000` 6% · 0 1 2 5% · 0 14 34 −10 14% | 0 0 0 0.5 `#FFF` 6% · 0 18 40 −12 80% |
| E1 | Resting droplet | 0 0.5 1 7% · 0 6 16 −3 11% | 0 0.5 1 50% · 0 8 20 −3 55% |
| E2 | Lifted droplet (dragging) | 0 1 2 6% · 0 18 36 −8 22%, plus lift scale 1.035–1.05 | 0 1 2 50% · 0 20 40 −8 70% |
| E3 | Sheet / modal | Dim black 18% (light) / 45% (dark) + 0 24 60 −12 28% | – |

Covers rest at 0 0.5 1 10% · 0 3 8 −2 10%, and when lifted at 0 2 4 12% · 0 22 40 −12 35%. Shadows are the only depth cue besides lift. There are no inner glows on content and no coloured shadows.

---

## 8. Iconography

Nib uses SF Symbols 5 (iOS 17). Palette tools are Medium weight at 23 pt. Bars use Regular at 21 pt, sidebar rows Regular at 22 pt, and the controls inside Deep panels Regular at 17 pt. Rendering is monochrome by default and hierarchical for multi-layer glyphs. The only colour inside a glyph is the **ink layer** of pen and highlighter glyphs, which shows the current ink.

Emoji are never used as icons, and `sparkles` is banned for AI (lint).

### 8.1 Tools (the palette)

| Tool | Symbol | Notes |
|---|---|---|
| Pen | `nib.pen` (custom) · fallback `pencil.tip` | The tip layer takes the current ink colour |
| Pen types (popover) | `nib.nib.fountain`, `nib.nib.ball`, `nib.nib.brush`, `pencil` | Custom templates built on the SF grid |
| Highlighter | `highlighter` | The ink bar under the glyph takes the current highlighter colour |
| Eraser | `eraser` · filter `eraser.line.dashed` | |
| Lasso | `lasso` · rectangular `rectangle.dashed` | |
| Shapes | `square.on.circle` · connectors `point.3.connected.trianglepath.dotted` | |
| Tape | `nib.tape` (custom) · fallback `rectangle.dashed` | |
| Text | `textformat` · full-page typing `character.cursor.ibeam` | |
| Image | `photo` · camera `camera` · scan `doc.viewfinder` | |
| Elements | `nib.sticker` (custom) · fallback `star.square.on.square` | |
| Sticky note | `note.text` · comment `text.bubble` | |
| Laser | `laser.burst` | |
| Zoom window | `plus.magnifyingglass` | |
| Ruler | `ruler` | |
| Finger drawing | `hand.draw` | |
| More tools / plugins | `ellipsis` · plugin tools use the plugin's declared SF Symbol or a monochrome template SVG | |

### 8.2 Actions

| Action | Symbol |
|---|---|
| Back to library | `chevron.backward` |
| Undo / redo | `arrow.uturn.backward` / `arrow.uturn.forward` |
| Search | `magnifyingglass` |
| Bookmark | `bookmark` / `bookmark.fill` |
| Share / export | `square.and.arrow.up` |
| More | `ellipsis` |
| Page navigator | `square.grid.2x2` |
| Outline | `list.bullet.indent` |
| Add page | `doc.badge.plus` |
| Assistant | `drop` (idle) / `drop.fill` (open) |
| Record | `waveform` · `mic` · stop `stop.fill` |
| Present | `play.rectangle` · external display `rectangle.on.rectangle` |
| Accept / discard | `checkmark` / `xmark` |
| Citation | `doc.text.magnifyingglass` |
| Send / stop generating | `arrow.up.circle.fill` / `stop.circle.fill` |
| API key | `key` |
| Bridge (external AI) | `point.3.filled.connected.trianglepath.dotted` |
| Library | `books.vertical` · Favorites `star` · Shared `person.2` · Recents `clock` · Study Sets `rectangle.stack` · Gallery `puzzlepiece.extension` · Trash `trash` |
| Folders and document types | Folder `folder.fill` · New `plus` · Notebook `book.closed` · QuickNote `square.and.pencil` · Whiteboard `scribble.variable` · Text doc `doc.text` · PDF `doc` · Import `square.and.arrow.down` |
| Sort, select, view | `arrow.up.arrow.down` · `checkmark.circle` · `square.grid.2x2` / `list.bullet` |
| Settings | `gearshape` |
| Sync | `checkmark.icloud` / `arrow.triangle.2.circlepath` / `exclamationmark.icloud` |
| Lock | `lock` |
| Collaboration | `person.crop.circle.badge.plus` · live `dot.radiowaves.left.and.right` |
| Plugin permissions | `hand.raised` · network `network` · AI `drop` · document write `pencil.and.outline` |

---

## 9. Motion

### 9.1 Springs

Every animated value in Nib is a spring from `Nib.Motion`. The parameters match SwiftUI `Spring(response:dampingRatio:)`, which gives stiffness k = (2π / response)² and damping c = 4π·ζ / response at mass 1.

| Token | Response (s) | ζ | Used for |
|---|---|---|---|
| `follow` | 0.085 | 1.00 | Droplet following the finger (≈ one frame of viscosity) |
| `tap` | 0.22 | 0.90 | Button press scale (0.96), pokes |
| `lift` | 0.30 | 0.72 | Pick-up scale 1 → 1.035–1.05 |
| `glide` | 0.30 | 0.80 | Selection bead head |
| `trail` | 0.44 | 0.92 | Selection bead tail (the lag makes the teardrop) |
| `snap` | 0.50 | 0.80 | Dock / slot after a fling, carrying the release velocity |
| `reflow` | 0.44 | 0.86 | Neighbours making room (grid, thumbnails) |
| `tether` | 0.40 | 0.62 | Proposal chip flowing back to its line (one visible overshoot) |
| `bud` | 0.42 | 0.76 | Popover position while budding |
| `budSize` | 0.46 | 0.80 | Popover width and height while budding, and palette re-forming |
| `retract` | 0.30 | 0.90 | Popover folding back into its button |
| `neck` | 0.14 | 1.00 | Neck thickness |
| `wobble` | 0.20–0.40 (by size, §10.3) | 0.50 | Surface-tension deformation |
| `sheet` | 0.48 | 0.90 | Sheets, panels docking |
| `reduced` | 0.26 | 1.00 | Replaces **every** spring under Reduce Motion |

### 9.2 Non-spring timing

- Opacity and blur reveals use ease-out `cubic-bezier(.23, 1, .32, 1)`. Enter takes 200–220 ms and exit 100–120 ms, because exits are always faster.
- Content reveal on a budded droplet fades opacity 0 → 1 with blur 3 → 0 pt over 220 ms.
- Colour changes (selected states, accept → ink colour) take 150–350 ms with ease-out. The colour leads the motion.

### 9.3 What never animates

- **Ink.** Wet strokes, the dry-tile swap, erasing and lasso marquee growth all happen with no transitions.
- Page zoom, pan and scroll. These are 1:1 direct manipulation plus the system scroll physics, and nothing else.
- Tool switches from the keyboard, Pencil double-tap or squeeze. The bead teleports in 0 ms.
- Text caret, selection and typing, list rows in Settings, and search results (opacity 120 ms only).
- Assistant streaming text. It appears as it arrives, with no typewriter effect and no shimmer.
- Anything at all while the Pencil is down (§10.8).
- The recording timer and page counter (digits just change).
- Idle states. Nothing breathes, pulses or floats on its own.

---

## 10. Droplet physics (the signature)

This is the complete behaviour. The mockup implements exactly these numbers.

### 10.1 Drag: following the finger

- **Pickup** happens after 6 pt of movement (below that, it's a tap). On pickup the droplet lifts to 1.035 (palette), 1.045 (card) or 1.05 (chip) with `lift`, its shadow goes to E2, and a card grows a 7 pt water envelope around its cover.
- **Follow.** The target is the finger position minus the grab offset, and the droplet position springs to it with `follow` (0.085 s, ζ 1). This is a hair of viscosity, not lag.
- **Bounds.** Past the safe edges, the droplet rubber-bands: `edge + D·(1 − 1/(0.55·e/D + 1))`, where e is the overshoot and D = 120 pt.
- **Multi-touch.** The first pointer owns the drag, and extra touches are ignored until it lifts.

### 10.2 Stretch with velocity

The speed v comes from the droplet's own position spring (smooth, no sample noise).

| Quantity | Formula / value |
|---|---|
| Target stretch | `s* = min(cap, |v| / 2600 pt/s)` (cards 2800) |
| Caps | Bead 0.45 · chip 0.16 · card 0.10 · palette 0.09 · popover 0.06 · panel 0.03 |
| Axis | θ follows `atan2(vy, vx)` when \|v\| > 40 pt/s: `θ += Δ·(1 − e^(−18·dt))`, with Δ wrapped to (−π/2, π/2] |
| Shape | `sx = (1 + s)·L` along θ, `sy = L / √(1 + s)` across it. This is **volume-preserving in 3D** (`sx·sy·sz = 1`, with the droplet thinning as it stretches), not area-preserving. Area preservation looks like rubber |
| Content rigidity | Content gets `s × k`: icons 0.55, card covers 0.70, chip 0.35, popover content 0.15, panel 0.10, bead 1.0. **Text never deforms more than 2.4%** |
| Poke (tap feedback) | Pressing a control on a droplet adds `−0.8` to the stretch velocity (pills), −0.6 (palette tools), −0.25 (controls in popovers). The result is a 2–3% squash that settles in about 0.35 s |

### 10.3 Settle (surface tension)

The stretch value s is itself a spring toward s*. When you stop, s* goes to 0, s overshoots below zero (the droplet flattens across its direction of travel, like a drop landing), then rings out.

- `wobble` response = `clamp(0.20 · √(minor / 44 pt), 0.20, 0.40)` s, with ζ = 0.50. Bigger droplets wobble slower and less, as real drops do. A 40 pt bead gets 0.20 s, the 56 pt palette 0.23 s, a 140 pt card 0.36 s, and panels 0.40 s.
- The ring-out is visible for about 1.5 cycles (≈ 0.35–0.6 s), and amplitude is ≤ 40% of the peak stretch.
- **Release** projects a landing point `p + v·0.12 s` (the fast-deceleration projection). If the finger was still for ≥ 70 ms before lifting, v = 0, so a careful placement never flings. Release speed is capped at 5000 pt/s.
- The droplet then springs to the chosen dock or slot with `snap`, **starting at the release velocity** (no momentum is lost), and a `snap` haptic fires at arrival (≈ 260 ms).

### 10.4 Merge (union)

- All droplets in one container are rendered as a single field. Their union uses a polynomial smooth-min:

  `h = clamp(0.5 + 0.5·(d₂ − d₁)/k, 0, 1)`, then `d = mix(d₂, d₁, h) − k·h·(1 − h)`

  with **k = 11 pt** on iPad and 9 pt on iPhone.
- Two edges start to bridge at an **11 pt gap** (iPhone 9 pt), and the fillet becomes a full union by 4 pt. Fillets are concave, never a straight join.
- The mockup does the same thing with an SVG "goo" threshold: a σ = 8 pt blur (6.5 on iPhone) re-hardened at alpha 0.479 (slope 24, intercept −11.5). Bridging then begins at ≈ 1.35σ.

### 10.5 Necks and pinch-off (hysteresis)

Real water holds on longer than it takes to join. A metaball alone has no memory, so Nib adds a **neck**: a capsule of thickness t between the nearest points of two bonded droplets, which is included in the union.

| Pair | Join at gap | t₀ | Off distance | Pinches at gap ≈ |
|---|---|---|---|---|
| Palette ↔ bars / HUD / assistant panel | 11 pt | 26 pt | 44 pt | 31 pt |
| Popover ↔ palette (bud) | overlap | 30 pt | 21 pt (iPhone 17) | 16 pt (iPhone 13), just before the 20 pt (16) rest gap |
| Proposal chip ↔ its anchor bead | 14 pt | 24 pt | 96 pt | 65 pt |
| Card ↔ card (library, only while one is lifted) | 13 pt | 30 pt | 46 pt | 35 pt |

- Thickness is `t = t₀ · (1 − gap/off)^0.7`, springing with `neck`.
- The neck breaks when t drops below **t_min = 1.27·k_blur + 0.6 ≈ 10.8 pt**. That is the thinnest bridge the threshold can hold, so the logical break and the visual pinch happen on the same frame. After the break the neck retracts into both droplets (t → 0 with `neck`), and a split plip fires.
- Neck endpoints sit 6–10 pt inside each droplet, clamped to a third of its short side, so the bridge always grows out of the body.
- Because the middle of the bridge is furthest from both bodies, the union thins **in the middle first**. It waists, then snaps, the way a drop does.

### 10.6 Bud-off (popovers and menus split from their button)

1. **Tap the selected tool again.** A 30 pt droplet appears at the tool's centre, inside the palette and already merged with it.
2. Its centre springs to the popover's rest position with `bud`, and its size springs to W × H (radius 15 → 26) with `budSize`.
3. The neck (t₀ 30) thins as it leaves, and **pinches at a 16 pt gap**, which is ≈ 80% of the travel and about 180 ms in. That fires a bud plip.
4. **Content reveal** triggers on the pinch or at 300 ms, whichever comes first (opacity plus a 3 → 0 pt blur over 220 ms).
5. The lens opacity follows growth: `clamp((progress − 0.55) / 0.4)`, so frost only appears once there is a body to hold it.
6. **Close** (tap the tool again, tap outside, or drag the palette). Content fades out in 120 ms. After 70 ms the droplet retracts to the tool centre with `retract` (size 28, radius 14), re-joins the palette at 11 pt (merge plip), and is removed once it is < 34 pt and within 5 pt of the tool.

The same mechanics apply to: the lasso object menu (buds from the selection's top edge), the search field (buds from the magnifier), the recording HUD (buds from the mic), and the page-number HUD's thumbnail peek.

**A tap outside an open popover only dismisses it. It never inks.**

### 10.7 Selection bead glide

- The bead has two circles. The head (r 20) springs with `glide` and the tail (r 15.6) chases the head with `trail`. A neck of width `1.2·r·(1 − |head − tail| / 150)` joins them, so a moving bead is a teardrop that rounds up on arrival.
- The bead rides on the tool icons' own layout springs, so it stays glued to its tool while the palette re-forms (vertical ↔ horizontal).
- **Passing lens.** Icons within 30 pt of the head magnify up to **1.13×**: `1 + 0.13·max(0, 1 − d/30)`. The bead magnifies what it passes over, as a drop of water would.
- **Scrub.** Pressing the selected tool and moving along the palette's axis drags the head directly. On release the bead snaps to the nearest tool, which becomes selected. Moving across the axis drags the palette instead.
- Arrival (within 1.2 pt of the target) fires the selection haptic once.
- Keyboard, Pencil double-tap and Pencil squeeze switches teleport the bead in 0 ms.

### 10.8 Recede while writing

- **Pencil down anywhere on the canvas.** All chrome fades to **22% opacity** in 100 ms, backdrop sampling freezes (the lens shows its last texture with no displacement), and no droplet runs physics.
- Dragging a droplet is impossible with the Pencil. The Pencil writes, and fingers move chrome.
- **Return.** 450 ms after the Pencil lifts, the chrome fades back over 220 ms with ease-out. There is no bounce and no stagger.
- Droplets never move out of the way on their own. Their position is the user's.

### 10.9 Refraction and optics

The light comes from the top-left: azimuth 225°, elevation 40°.

| Element | Value |
|---|---|
| Lens (Clear) | Inward displacement `offset = −n̂ · A · (1 − d/ramp)^1.8` for depth d < ramp, where n̂ is the outward SDF normal, `ramp = 0.95·r + 2 pt`, and `A = 0.15·minor + 2 pt` (palette A ≈ 10 pt). The core, deeper than the ramp, is undisplaced, so it magnifies at the rim and stays clear in the middle |
| Lens filter chain | Displacement, then blur 1.4 pt, saturation 1.7, brightness +4%, then tint (§2.1) |
| Deep | Blur 26 pt, saturation 1.8, no displacement |
| Edge (thickness) | Union minus (union ⊗ Gaussian 2.6 pt), drawn as `waterEdge` |
| Caustic | Union minus (union offset by (−4, −6) pt), blurred 2.4 pt, clipped to the union, drawn as `waterCaustic` |
| Specular | Blinn-Phong on the height field (union ⊗ Gaussian 4.2 pt) × 6.5; exponent 40, kₛ 0.55 (bead: exponent 26, kₛ 1.0) |
| Rim | Union minus (union offset by (1.1, 1.5) pt), drawn as `waterRim` (0.8–1.2 pt highlight on the top-left) |
| Outline | Union minus (union eroded 0.8 pt), drawn as `waterLine` |

**Device pipeline (Metal, one pass per window scene).** `DropletField` renders every droplet and neck of a container as rounded-rect and capsule SDFs in their deformed local frames. It unions them with the smooth-min (k 11) and derives height from `smoothstep(0, 8 pt, −d)`, which gives a flat puddle with a rounded rim. It then computes the normal from the gradient, samples the backdrop at `uv + offset`, and composites tint, edge, caustic, specular and rim in one fragment shader over the union's bounding box.

The backdrop is a texture the canvas renderer already owns: the page tiles (F004) at 0.5× scale. It updates at ≤ 30 fps only while chrome moves over changing content, and freezes while the Pencil is down.

**Budget:** ≤ 1.2 ms GPU per frame on A13 at full union size, 0 ms when nothing moves (the display link parks itself). In the headless-Chrome run of the mockup, frame intervals during a full palette drag were median 3.7 ms and p99 13 ms.

### 10.10 Where liquid is **not** used

- The page, ink, dry tiles, thumbnails' contents, exports, print and PDF.
- Text-editing surfaces (text boxes, Text Documents, the composer's text itself).
- Lists, Settings, grouped forms, the template grid, the plugin list, the study-card list.
- Sheets and modals. They are opaque grouped surfaces. Only their single primary button may be a Tinted droplet.
- The library grid at rest. Covers are cloth and paper objects, and water appears only while one is lifted.
- System components: context menus (`UIMenu`), the share sheet, alerts, the keyboard, the document picker and the colour picker.
- Presentation output on an external display: page only, with no chrome at all.
- Anything under the Pencil while it is down.
- Loading or thinking states. There are no liquid loaders, and a plain activity indicator or tool trace is used instead.

### 10.11 Dock zones (palette)

| Device | Zones (chosen by the finger's projected point, not the droplet's centre) |
|---|---|
| iPad | Left or right edge (vertical, slides along the edge within the safe area below the top bars), bottom (horizontal), top below the bars (horizontal). With the assistant docked, the right edge moves to the panel's leading edge |
| iPhone | Bottom (default) or top below the bars, horizontal only |

Changing orientation **re-forms** the palette. Width and height spring with `budSize`, each icon springs to its new slot with a 12 ms stagger per item, and the bead rides along. The lens map is swapped at rest.

---

## 11. Haptics

Nib uses CoreHaptics where there is a pattern, and UIKit generators otherwise. The generators are prepared on touch-down.

| Event | Pattern | Fallback |
|---|---|---|
| **Merge** (two droplets join, or a popover folds back) | "Plip": a transient (intensity 0.45, sharpness 0.70) at 0 ms, then a transient (0.20, 0.35) at +18 ms | `UIImpactFeedbackGenerator(.soft)` at 0.5 |
| **Split** (a neck pinches) | A transient (0.35, 0.90) | `.rigid` at 0.35 |
| **Bud** (popover pinches free) | A transient (0.30, 0.60) | `.soft` at 0.4 |
| **Snap** (dock or slot arrival) | A transient (0.55, 0.40) | `.soft` at 0.7 |
| **Select** (bead arrives) | – | `UISelectionFeedbackGenerator` |
| **Combine armed** (card held over card for 380 ms) | Plip | `.soft` at 0.6 |
| **Accept AI edit** | – | `UINotificationFeedbackGenerator(.success)` |
| **Slider detents** (presets, 0%, 100%) | – | Selection |
| **Pencil Pro** snaps and alignment (iOS 17.5+) | `UICanvasFeedbackGenerator` | none |

Nib never plays a haptic per frame, during writing, for keyboard actions, during scrolling, or more than once per 60 ms (events coalesce).

---

## 12. Screens and layouts

Frames are given in points. iPad Pro 11″ landscape is 1194 × 834 and portrait is 834 × 1194. 13″ scales the margins, not the controls. iPhone is 393 × 852 (safe area top 59, bottom 34). **Split View / Slide Over** use the iPhone layout below a 600 pt width, and the iPad layout otherwise.

### 12.1 Library

**iPad landscape (mockup 01)**

- **Sidebar**, 320 pt. It uses `backgroundSecondary` and is opaque: no glass in navigation.
  - Title "Library", display 34, at y 80.
  - Rows are 44 pt with 12 pt insets: Documents, Favorites, Shared, Recents, Study Sets, Gallery, Trash. Counts are right-aligned in secondary text.
  - The selected row uses `fill3` and a semibold label, with its glyph in accent.
  - The "Folders" disclosure lists the user's folders with folder glyphs in their folder colour.
  - The bottom row shows sync status ("OneDrive · Up to date") and Settings.
- **Content**
  - "Documents", display 34, at x 344, y 80, with a count/sort subtitle in caption1.
  - Folders: 4 tiles, 194 × 78, radius 14, on `backgroundSecondary`.
  - Notebooks: a grid of 140 × 182 covers. The title is footnote semibold (two lines at most), and the subtitle is caption1 with a star for favourites.
  - Type badges (20 pt rounded squares) sit at the bottom-right of non-notebook covers: PDF, whiteboard, study set, text document.
- **Floating chrome**, at y 32: a Clear droplet with Search, Sort and Select (128 × 44), 16 pt gap, then a Tinted "+ New" droplet (96 × 44).
- **Liquid moments**
  - **Lift.** The card grows a water envelope and stretches with speed. Neighbours reflow with `reflow`.
  - **Reach across.** Within 13 pt of another card, a neck forms. It is a visual promise that the two can combine.
  - **Combine.** Hold over a card for 380 ms. The target swells, then the drop flows into it and the stack becomes "New Folder". A Deep toast rises from the bottom: "Made "New Folder" from 2 notebooks · Undo". It auto-dismisses after 6 s.
- **iPad portrait.** The sidebar collapses to an overlay (system `UISplitViewController` behaviour), and the grid uses four columns.
- **iPhone.** Tabs are replaced by the sidebar pushed as the root list. The grid uses three columns of 110 pt covers. Search and New become a single bottom-trailing droplet pair (Search capsule 44, New Tinted 44 × 44). Swipe-down search appears at the top of the list.
- **Empty.** The page shows a centred stack with no illustration:
  - `book.closed` at 44 pt in `labelTertiary`
  - "No notebooks yet" in title3 New York
  - "Write something, or bring in a PDF." in callout secondary
  - a Tinted "New Notebook" button and a Clear "Import" button, 12 pt apart

### 12.2 Document editor

**iPad landscape (mockup 02)**

- **Page and desk.** The page is centred on the `desk`, 760 pt wide at fit, with E0 elevation. It scrolls vertically under the chrome, and the next page follows 16 pt below.
- **Top-left droplet** (Clear, 252 × 44 at 16, 32): back, then the title (barTitle) over "Physics 9702 · Page 3 of 12" (caption1 secondary). Tapping the title opens the document menu, which buds.
- **Top-right droplet** (Clear, 261 × 44), ending 16 pt before the assistant droplet: Undo, Redo | Search, Bookmark, Share, More.
- **Assistant droplet**: Clear, 44 × 44, `drop`.
- **Tool palette** (Clear, 56 × 577, docked left at x 16, vertically centred below the bars):
  - 10 tools: pen, highlighter, eraser, lasso, shapes, tape, text, image, elements, laser.
  - A 0.5 pt divider, then 3 quick ink swatches (22 pt, with a 2 pt label-coloured ring at a 2.5 pt offset when selected).
  - The selection bead sits under the active tool.
  - Customisable per T-086. Plugin tools append after a second divider.
- **Pen settings popover** (Deep, 312 × 412, radius 26, budded from the pen tool):
  - "Fountain Pen" headline, with "Pen" in caption secondary.
  - A pen-type segmented grid of 4 (52 pt cells, the selected one on `fill3`).
  - Thickness: 3 presets (5, 8 and 12 pt dots) plus the value in hud type.
  - Colour: a 6 × 2 swatch grid (26 pt swatches in 30 pt cells) with "Custom…" as a link, which opens the system colour picker with HEX and eyedropper.
  - Pressure sensitivity: a liquid slider whose thumb is a bead (§10.2 cap 0.45).
  - Tip sharpness, stabilisation, Dynamic Ink, stroke pattern and Draw & Hold follow in the same pattern, and the popover scrolls past 520 pt.
- **Page HUD** (Clear, 104 × 40, bottom-right at 16): `square.grid.2x2` plus "3 / 12" in hud. Tapping it opens the page navigator. Dragging it scrubs pages (D-118).
- **Page navigator** (D-065): a Deep panel, 240 pt wide, at the leading edge (or trailing, per D-136), with 12 pt insets from the chrome. Thumbnails are 176 pt wide with the page number in caption1 under each, and the current page gets a 2 pt accent ring.
  - **Reorder.** Long-press lifts a thumbnail into a Clear droplet (stretch cap 0.10). Neighbours reflow, and there is no merge.
  - Multi-select shows a check bead on each selected thumbnail.
- **Zoom window** (T-073):
  - The target box on the page is a Clear droplet frame (rim only, no body): a 2 pt rim with an 18 pt radius, draggable, with stretch.
  - The writing pane is a Deep panel docked to the bottom, full width minus 32, 240 pt tall. Its controls are a bead slider for zoom, plus Return, New Line and Margin toggles.
  - The ink inside the pane is the real canvas at 3×, never refracted.
- **Lasso selection.** A dashed accent marquee (1 pt, 4/4 dash). Handles are 12 pt beads with 44 pt hit areas, and they stretch when dragged. The object menu buds from the selection's top-centre as a Clear capsule (Cut, Copy, Duplicate, Recolor, Convert, More).
- **Recording HUD.** Buds from More › Record, top-centre, 44 pt. It shows a `destructive` dot, the timer in hud type, a live waveform (label-2 bars, no colour), and Stop.
- **Collaboration.** Presence beads (22 pt, initials, presence colours) sit inside the top-left droplet after the title. Live cursors are 10 pt presence-colour beads with a name capsule.

**iPad portrait.** The page fits 800 pt wide. The palette defaults to the top dock (horizontal, below the bars), and popovers bud downward.

**iPhone (mockup 04)**

- The page fits the width with 12 pt desk margins.
- The top-left droplet (212 × 44) holds back plus the title, truncated. The top-right droplet (128 × 44) holds Undo, Assistant and More.
- The palette is horizontal at the bottom (345 × 56, 8 pt above the home indicator): pen, highlighter, eraser, lasso, text and more, then 1 ink swatch (28 pt).
- The pen popover buds upward (345 × 196): 12 swatches of 34 pt, then 3 thickness presets. Deeper settings are under "More settings…", which pushes a sheet.
- The page HUD hides and shows on scroll (fade 150 ms).

### 12.3 Assistant panel (mockup 03)

**Modes (S-002):**

- **Sidebar** (default on iPad landscape). A Deep panel, 344 × (H − 48), docked trailing. The canvas insets, so the page shifts left and stays fully visible. The assistant droplet merges into the panel's header.
- **Floating.** The same panel, draggable, with stretch cap 0.03. It merges with the palette if brought close.
- **Window.** A separate scene.

On iPhone the assistant is a sheet with detents at medium and large, and proposals show on the page above it.

**Anatomy, top to bottom:**

1. **Header (60 pt).**
   - The drop mark in a 30 pt `fill3` circle.
   - "Assistant" in headline.
   - The model and whose key it uses, in caption1 secondary ("Claude Sonnet 4.5 · your API key"). Nib never hides which provider sees the data.
   - Close, as a 30 pt round button.
2. **Scope row.**
   - An Ask | Edit segmented control (S-003; Ask is read-only tools).
   - A scope chip: "This page ▾", which can be This page, Selection, Document or Library.
3. **Thread.** It reads as a document, **not chat bubbles**.
   - A speaker label in caption1 semibold secondary ("You", or "◌ Assistant" with the drop glyph), then the paragraph in chat type.
   - A hairline sits only at the top of the thread.
   - There are no bubbles, no avatars and no alternating alignment.
4. **Tool trace.** Caption1 rows with success checks: "Read page 3 · 14 handwritten lines recognised", "Checked 6 formulas". This is what the AI looked at, in plain words. Tapping a row reveals the raw tool call.
5. **Citations.** Inline `accentWash` chips such as "▤ Line 5". Tapping one scrolls the page to that line and washes it in `accentWash` for 600 ms.
6. **Proposed edit block** (`fill4`, radius 12, 16 pt inset):
   - The title, "Proposed edit", with the change count.
   - One row per change: a 22 pt `destructive` "−" or accent "+" disc, a description with math in New York italic, and the location in caption1.
   - Each row has its own checkbox when there are more than 2 changes, so edits can be accepted partially.
   - Accept (primary) and Discard (secondary) buttons, 38 pt capsules.
   - The footnote "Previewing on the page. Nothing changes until you accept."
   - Edits over 10 items, or across pages, go through the Gateway confirmation sheet ("This changes 14 pages") before Accept is enabled.
7. **On-page diff.**
   - Deletions are struck with a 2.6 pt `destructive` hand-drawn line.
   - Additions are drawn in the user's matched handwriting in **accent** with a 5 pt accent glow at 45%.
   - A **proposal chip** (Clear, 190 × 40) hangs above the change on a water tether from an anchor bead on the ink.
   - You can pull the chip away (the tether stretches, thins, and pinches at 65 pt), and on release it flows back with `tether`.
   - The chip shows the change name plus Accept (✓ on accent) and Discard (✕).
   - Multiple proposals get one chip each. Chips never overlap: they stack 8 pt apart.
8. **After Accept.**
   - The additions turn to the user's ink over 350 ms and slide into place (the struck text is erased).
   - The chip evaporates: it shrinks into the anchor, which dries into the page.
   - The block collapses to "✓ Applied 2 changes · Undo".
   - The whole AI turn is one undo group, so ⌘Z works too.
9. **Composer.** A 44 pt capsule field on `fill4` with Add context (+), a placeholder ("Tell Nib what to change…"), dictation, and Send (a 32 pt accent disc; Stop while generating). The footer reads "1,284 tokens this chat · sent only to your provider" in caption2 tertiary.

**States:**

- **No provider.** The panel body shows "Connect a model" with a list of providers (Anthropic, OpenAI-compatible, Ollama, LM Studio, Custom). Each row opens Settings › AI. The panel shows no marketing.
- **Thinking.** The trace row "Reading page 3…" with a small activity indicator. There is no pulsing bead.
- **Error.** An inline row in `warning` text with Retry. The thread is never lost.

**External AI bridge (S-020).** Settings › AI › Bridge shows the pairing code (hud type, 28 pt), the connected clients and their scopes.

While an external agent is connected, the top-left droplet shows a 6 pt `success` dot and the client name in caption1. Its proposals arrive exactly like the assistant's: on-page diff, chip, Accept or Undo, labelled with the agent's name.

### 12.4 Templates / New notebook sheet

- **iPad form sheet** (720 × 640, radius 28, opaque `backgroundSecondary`). The header has Cancel, "New Notebook" in title3, and Create (a Tinted droplet, which is the sheet's only water).
- **Type segmented control**: Notebook · Whiteboard · Text document · Study set.
- **Title field**, 44 pt. The AI suggestion appears as placeholder text with a "Use" button (D-007).
- **Cover strip.** A horizontal scroll of 88 × 116 covers. The selected cover gets a 2 pt label ring at a 3 pt offset. "No cover" is the first item.
- **Paper grid**: 4 columns of 128 × 166 paper thumbnails, grouped by Template Groups (D-047), with a group picker on the left in portrait-only list style.
- **Options row**: Size (A4, Letter, B5, Legal, Square, Custom), Orientation, Paper colour (swatches from §3.6), and Apply to (all pages / every other).
- **iPhone.** A full sheet with the same order stacked, and Create pinned to the bottom as a Tinted capsule.

### 12.5 Search

- **iPad.** The search droplet buds from the magnifier into a 560 × 44 Clear field at top-centre, and the results show in a Deep panel beneath it (560 × up to 600).
  - Result sections: Top hits, Handwriting (ink snippet crops with the match washed in Lemon at 60% multiply), Typed text, PDF text, Audio transcripts, Folders.
  - Recent searches appear as chips when the field is empty.
  - Results fade in over 120 ms. There is no stagger.
- **In-document search** (D-108) uses the same field in the editor's top bar. Hits are highlighted on the page, and a "3 of 11" hud has previous and next controls.
- **iPhone.** A full-screen list under a system search field, with no droplets.

### 12.6 Settings

- A standard grouped list (`UITableView.Style.insetGrouped`), opaque, with system typography. It opens as a 640 × 720 form sheet on iPad and pushes on iPhone. There is no liquid inside.
- **Sections:**
  - Library & Sync
  - Writing (Stylus, Palm rejection, Pen gestures, Draw & Hold)
  - Documents
  - Assistant (Providers, Bridge, Privacy)
  - Plugins
  - Appearance
  - Accessibility
  - Backup
  - About
- The Appearance section includes a **"Liquid"** row with three options: Full (default), Calm (stretch caps halved, no necks), and Off (the Reduce Transparency and Reduce Motion fallbacks, independent of the system setting).

### 12.7 Plugin manager and plugin panels

- **Settings › Plugins** is a list. Each row has the plugin icon (a 29 pt continuous-radius square), the name, the author in caption1, a permissions summary ("Reads documents · Uses your AI"), and an enable switch.
- The detail page shows the permissions as individual toggles (Network, AI, Write to documents, Clipboard), the version, the source, "Update" and "Remove".
- "Install from File / URL / Gallery" is at the top.
- The Gallery tab of the library shows gallery indexes as sections, using the same list cells.
- **Plugin panels** use the Deep panel chassis.
  - The header shows the plugin icon (20 pt), its name, a "Plugin" caption2 capsule on `fill3`, and a More menu (Reload, Permissions, Report).
  - The panel content is a WKWebView with the Nib design tokens injected as CSS custom properties (`--nib-label`, `--nib-accent`, `--nib-font-body`, …). A plugin's UI inherits the look automatically, including dark mode and Dynamic Type (`font: -apple-system-body`).
  - Plugin toolbar buttons appear in the palette after a divider. Plugin tools behave exactly like native tools, including the bead.
  - Plugin menus appear in the More menu under their plugin name.

### 12.8 Study sets

- **Deck view** (iPad):
  - A paper card, 560 × 360, radius 20, on E1 (cards are paper, not water).
  - The front is in title1 New York, centred. Tapping flips the card around the Y axis with `sheet` (no bounce).
  - A progress bar of 3 pt `fill1` with a label fill runs at the top, with "12 of 42" in hud type.
  - The grading droplets at the bottom-centre are Clear capsules ("Again", "Good", "Easy"), 16 pt apart.
  - Swiping the card right or left grades it: the card follows the finger, tilts ±6°, and flies out with the release velocity.
- **Card list** is an opaque grouped table with inline editing.
- **Smart Learn schedule** is a simple calendar strip.
- **iPhone.** The card fills the width minus 32 pt, and the grading droplets sit at the bottom.

### 12.9 Presentation mode

- The external display shows only the page (letterboxed on black), with no chrome, cursor or selection (the laser is the exception).
- **On iPad**, a Clear HUD droplet at top-centre shows a `rectangle.on.rectangle` "Presenting", the page count, a Laser toggle and Stop.
- **Laser.** The dot is `destructive` with a 12 pt glow at 45%. The trail is a 4 pt line that fades over 600 ms (linear, the only linear motion in Nib, because it is time made visible).
- The flipbook (S-073) uses page swipes with system scroll physics.

### 12.10 Onboarding

There are four steps on full-bleed white paper, each holding one Deep droplet card (480 pt wide on iPad, full width minus 32 on iPhone). Progress is four 8 pt beads with the selection bead gliding between them.

1. **Your library.** Headline in New York 34 Semibold, "Your notes live in a folder you choose." A short explanation of why an outside folder survives reinstalls, then the folder picker as a Tinted button.
2. **Pencil.** A writing strip of real canvas for trying the palm rejection and pen settings. The chrome recedes here too.
3. **Bring your own AI** (optional). Provider rows and Skip. The key is entered only in Settings, never in onboarding text.
4. **Done.** A QuickNote opens straight away.

There is no carousel of feature illustrations and no confetti.

### 12.11 Empty and edge states

| Where | Treatment |
|---|---|
| Library empty | §12.1 empty stack |
| Folder empty | "Nothing in Physics 9702 yet" plus the same two buttons |
| Search no results | "No results for "k/m"" in title3, then callout secondary tips ("Handwriting search needs recognition to finish: 3 pages left.") |
| Trash empty | "Trash is empty" with no button |
| Assistant, no provider | §12.3 |
| Plugins, none | "No plugins yet" plus "Browse Gallery" |
| Offline sync | The top-left droplet's subtitle becomes "Offline · changes saved on this iPad" in `warning` |
| Locked document | The page is replaced by a paper-coloured field with `lock` at 44 pt, "Locked", and a Face ID button |

---

## 13. Accessibility fallbacks

| Setting | Behaviour |
|---|---|
| **Reduce Motion** | Every spring becomes `reduced` (0.26 s, ζ 1). Stretch caps go to 0, there are no necks, and poke is off. Bud-off becomes a 200 ms cross-fade with scale 0.96 → 1 at the final position. The bead moves with `reduced` (no teardrop). Merges still happen (they are geometry, not motion) |
| **Reduce Transparency** | The lens is off. Droplets become `chromeOpaque` with the 0.8 pt `waterLine` outline and an E1 shadow. There is no specular, caustic or edge, and the union shape and merges remain. Deep panels become `backgroundSecondary` |
| **Increase Contrast** | `waterLine` goes to 25% (light) or 40% (dark). The body tint becomes 72% for Clear and 90% for Deep, and `separator` is used at 100% alpha |
| **Differentiate Without Color** | AI deletions get "−" markers at line start, and additions are underlined with a 1.5 pt dashed rule |
| **VoiceOver** | Droplets are containers (`accessibilityContainerType = .semanticGroup`) labelled by function ("Tools", "Pen settings", "Proposed edit: fix period"). The bead is exposed as the selected trait of its tool. Drag-to-dock has custom actions ("Move palette to bottom", …). AI proposals have Accept and Discard as custom actions on the changed ink |
| **Dynamic Type** | §4.2 |
| **Pointer (trackpad)** | Droplets use `UIPointerEffect.lift` on buttons. Hover never deforms droplets, because deformation follows touch only |

---

## 14. The design system as code (what the build agents must use)

Every feature module imports `NibContracts` and nothing else, so **the design system belongs in `NibContracts/UI/Design/`**, not in F094's `FeatAppearance`.

Recommendation for the architecture owner: move F094's "shared materials" there and make F094 the settings UI for appearance only.

### 14.1 Surface

```swift
public enum Nib {                                   // namespace, no instances
  public enum Palette  { /* §3.1–3.3 tokens as dynamic UIColor/Color (trait-aware) */ }
  public enum Ink: String, CaseIterable { case carbon, graphite, midnight, cobalt, lagoon, moss,
                                          ochre, sienna, vermilion, crimson, plum, chalk }   // .color, .hex
  public enum Highlight: String, CaseIterable { case lemon, apricot, mint, sky, lilac, blush }
  public enum Paper: String, CaseIterable { case white, ivory, legal, grey, slate, night, board }
  public enum Font     { static let display, title1, title2, title3, headline, body, callout, chat,
                         barTitle, footnote, caption1, caption2, hud, math: NibFont }   // UIFont + Font
  public enum Space: CGFloat { case xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 20, xxl = 24, x3 = 32, x4 = 40, x5 = 48, x6 = 64 }
  public enum Radius   { static let popover: CGFloat = 26, panel = 28, sheet = 28, tile = 14, sidebarRow = 10,
                         thumb = 4; static func capsule(_ h: CGFloat) -> CGFloat; static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat }
  public enum Elevation { case paper, rest, lifted, sheet }            // applies shadow + shadowPath
  public enum Motion   { static let follow, tap, lift, glide, trail, snap, reflow, tether, bud, budSize,
                         retract, neck, sheet: NibSpring; static func wobble(minor: CGFloat) -> NibSpring }
  public enum Haptic   { static func play(_ e: HapticEvent) }         // merge, split, bud, snap, select, armed, success
  public enum Symbol   { static let pen, highlighter, eraser, … : String }   // §8 names, custom symbols included
}

public struct NibSpring { public let response: Double; public let dampingRatio: Double
  public var swiftUI: Spring { .init(response: response, dampingRatio: dampingRatio) }   // iOS 17
  public var reduced: NibSpring { .init(response: 0.26, dampingRatio: 1) } }

// Droplets
public final class DropletContainerView: UIView        // one union field per container (bars+palette+popovers share one)
public final class DropletView: UIView {                // a droplet; content goes in `contentView`
  public enum Kind { case clear, deep, tinted, bead }
  public var kind: Kind; public var shape: DropletShape  // .capsule / .rounded(radius)
  public var stretchCap: CGFloat; public var rigidity: CGFloat
  public func beginDrag(at: CGPoint); public func drag(to: CGPoint)
  public func endDrag(velocity: CGVector, to target: CGPoint, spring: NibSpring = Nib.Motion.snap)
  public func bud(from source: DropletView, sourcePoint: CGPoint, to frame: CGRect)
  public func retract(into source: DropletView, at point: CGPoint)
  public func poke(_ amount: CGFloat = 0.8)
}
public protocol DropletBackdropProvider: AnyObject { func backdropTexture() -> MTLTexture? ; var isInking: Bool { get } }
public struct Droplet<Content: View>: UIViewRepresentable   // SwiftUI host: Droplet(.clear) { … }
public struct NibSelectionBead                               // head/tail springs + passing-lens magnification
public final class NibSpringDriver                           // CADisplayLink, 240 Hz semi-implicit Euler substeps, parks when settled
```

### 14.2 Enforcement

`Scripts/lint.py` fails CI for feature modules on any of the following:

- **Raw colour.** `Color(red:`, `UIColor(red:`, `Color(hex`, `#colorLiteral`, or six-digit hex literals in `Sources/Feat*`. Use `Nib.Palette` or `Nib.Ink`.
- **Raw type.** `.font(.system(size:`, `UIFont.systemFont(ofSize:`, `.kerning(` or `.tracking(`. Use `Nib.Font`.
- **Raw radii.** Numeric literals in `.cornerRadius(`, `RoundedRectangle(cornerRadius:` or `layer.cornerRadius =`. Use `Nib.Radius`.
- **Raw shadows.** `.shadow(` or `layer.shadowOpacity`. Use `Nib.Elevation`.
- **Raw motion.** `withAnimation(` without `Nib.Motion`, `.easeInOut`, `.linear` (outside `Nib.Motion.laserFade`), `.spring()` without token, or `UIView.animate(withDuration:`.
- **System materials.** `.ultraThinMaterial` (or any `Material`) and `UIVisualEffectView` outside `NibContracts/UI/Design`. Use `DropletView`, or an opaque surface.
- **Raw haptics.** `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator` or `CHHapticEngine` outside `Nib.Haptic`.
- **Banned glyphs.** `Image(systemName: "sparkles")`, `"wand.and.stars"`, or emoji in UI string literals (`\p{Extended_Pictographic}`).

Two further checks:

- `Scripts/a11y_lint.py` requires `accessibilityLabel` on every `DropletView` and every icon-only button.
- A `DesignGallery` snapshot test in `NibTesting` renders every droplet variant, token and state in light, dark, Reduce Transparency and AX3. Reviewers diff it.

### 14.3 iOS 17 / CI constraints

- The Liquid Glass APIs (iOS 26) are **not** available: the build uses the iOS 18 SDK with iOS 17.0 as the deployment target. Everything here is custom Metal plus UIKit, which is why it can match on every supported device.
- SwiftUI `.layerEffect` and `.distortionEffect` (iOS 17) can only sample a view's own layer. They are used for the bead's passing-lens icon magnification. Backdrop refraction needs the UIKit `DropletContainerView` with its Metal field, fed by `DropletBackdropProvider` (the canvas renderer, F004).
- The canvas is UIKit and PencilKit. The droplet field lives in a separate layer above the canvas view, never inside it. PencilKit's wet-ink layer is never sampled while inking.

---

## 15. What the mockup shows

`design/direction-a.html` is a single file. The only external request is Google Fonts Inter, used as a stand-in for SF on Windows. The handwriting uses the system's handwriting fonts (Segoe Print / Bradley Hand / Noteworthy) and SVG paths for the underline, box, graph, strike and arrows.

1. **Library, iPad landscape.**
   - Drag any notebook to see lift, stretch, reflow and necks to neighbours.
   - Hold over a notebook to combine the two into a folder, then use Undo in the toast.
2. **Editor, iPad landscape.**
   - Drag the palette and fling it to any edge. It re-forms vertical or horizontal, and merges with and pinches off the bars.
   - Tap tools to watch the bead glide, or drag the bead itself.
   - Tap the selected pen to fold the popover in, and tap again to bud it out.
   - The pressure slider has a bead thumb.
   - Writing on the page makes the chrome recede.
3. **Editor with the Assistant.**
   - The proposal is shown on the page. Pull the chip to stretch and pinch its tether, and release it to flow back.
   - Accept slides the correction into place in your ink. Undo restores it.
4. **iPhone editor.** A horizontal palette, and a popover that buds upward.

The preview controls at the top switch Light/Dark, Reduced Motion, Reduced Transparency, and "Hear haptics" (optional synthesized plips standing in for the Taptic Engine).

**Engines.** Refraction uses `backdrop-filter: url()` with baked per-droplet lens maps, which only Chromium supports. Other engines get the blur and tint fallback, and merging, necks, stretch and settle work everywhere.
