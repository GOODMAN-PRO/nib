# Nib design: the binding spec

> Everything that floats in Nib is made of clear water. It lenses the page beneath it, stretches with the speed you drag it, settles with surface tension, reaches across to its neighbours, pinches apart when pulled, and buds off its parent. The page and your ink carry all the colour. The chrome is only water, and while the Pencil is down it steps back.

This document is binding for every feature that draws UI. It locks direction A (Clear Water) with the judge's eight fixes and the grafts from B (Ink Drop) and C (Mercury). The code that implements it is [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) (module `NibDesign`). The approved picture is [design/mockup.html](../design/mockup.html): every number in this file is the number that page runs on. When this file, the code and the mockup disagree, this file wins and the other two are fixed.

**Contents**

1. Principles
2. The droplet material
3. Colour
4. Typography
5. Spacing, grid and fixed metrics
6. Radii
7. Elevation
8. Iconography
9. Motion
10. Droplet physics (the signature)
11. Haptics
12. Accessibility and fallbacks
13. Component catalogue
14. Screens
15. Rules for feature code
16. Slop checklist (the review gate)
17. Where each decision came from

---

## 1. Principles

1. **The page is the product.** Paper is full-bleed and stays put. Chrome floats over it and never frames it: no opaque navigation bars in the editor, no gutters painted in UI colour, no app skin around the page.
2. **One material.** Every floating thing is the same water: tool palette, bars, HUDs, popovers, panels, AI proposals, selection handles, a lifted card or thumbnail. There is no second glass recipe. Glass never sits on glass: when two droplets meet, they merge.
3. **Believable water, not jelly.** Water at UI scale is tight and quick: a stretch settles at ζ 0.68 (one small undershoot, under one visible cycle) and positions settle at ζ ≥ 0.6. Stretch caps sit between 3 % and 16 % on anything with content, and the rendered stretch never passes its cap. Precision tools and frequent actions (handles, the selection bead, grid snaps) do not wobble at all. A squash returns to round before the droplet arrives. When in doubt, choose less.
4. **Colour belongs to ink.** The UI is Apple's neutral greys plus one accent (Pool blue). Hue comes from the user's pens, highlighters, covers and folders. No decorative gradients, no accent tints for decoration, no AI purple.
5. **The canvas is sacred while the Pencil is down.** Ink is zero-latency and crisp. No shader ever passes over a stroke being written. While the Pencil is down, nothing moves, and every droplet over the page or near the stroke recedes to 22 % (§10.8).
6. **Liquid shows cause and effect.** A droplet deforms because you moved it, merges because you brought it close, buds because you asked for what is inside. Nothing wobbles or breathes on its own. When nobody touches anything, nothing moves.
7. **Native first.** SF Pro, SF Symbols, system context menus, share sheet, alerts, keyboard, colour picker and document picker. Liquid is Nib's own chrome only; it never replaces a system component people already know. On iOS 26 and later the droplets *are* Apple's Liquid Glass.
8. **Trust is visible.** The assistant says what it read, cites where, previews every change on the page before anything changes, asks inline before anything destructive, and puts Undo next to the result.
9. **Fast things never animate.** Keyboard shortcuts, Pencil double-tap and squeeze, undo, typing, zoom, pan and scroll are instant. Motion is for the occasional and the spatial.

---

## 2. The droplet material

### 2.1 Layers

A droplet is always three layers, bottom to top. No feature adds a fourth.

| # | Layer | What it does |
|---|---|---|
| 1 | **Lens** | What is behind the droplet, bent at the rim (iOS 26+) or frosted (iOS 17–25 Deep). The core stays clear |
| 2 | **Water** | The union silhouette of every droplet in the container: body tint, edge thickness, caustic, specular, rim, outline. Merges, necks and pinches happen here |
| 3 | **Content** | Icons, labels, controls. Never filtered or refracted; they follow the droplet's transform with a rigidity factor (§10.2) |

### 2.2 The four materials

| Material | Used for | Body tint (light / dark) | iOS 26+ | iOS 17–25 |
|---|---|---|---|---|
| **Clear** | Tool palette, top bars, HUDs, proposal chip and its anchor, lifted cards and thumbnails, selection handles | `#FFFFFF` 46 % / `#161618` 62 % (**80 % over light paper**) | `Glass.regular.interactive()` | Body tint + water optics, no blur |
| **Deep** | Anything with dense UI or text: popovers, assistant, plugin panels, search results, page navigator, toasts | `#F9F9FB` 72 % / **`#1C1C1E` 86 %** | `Glass.regular.tint(deepGlassTint)` | `.ultraThinMaterial` frost + body tint + optics |
| **Tinted** | The one primary action on a surface (New, Create) | Accent 100 % | `Glass.regular.tint(accent)` | Opaque accent with a rim (white 30 %) and the outline only: no edge, caustic or specular |
| **Bead** | Selection bead, slider thumbs, anchor beads, page-number beads | `#FFFFFF` 70 % / `#FFFFFF` 22 %, plus the current ink at 15 % on the selection bead | Plain fill with a rim, no shadow (it lives *inside* a droplet) | Same |

**Why Clear still has a body.** Clear droplets hover over dense black handwriting. Crystal-clear water with no body makes black icons over black ink unreadable. The 46 % body keeps the core readable and leaves the rim fully refractive. The drag test showed that a 14 % veil fails over ink.

**Why the dark Deep body is 86 %.** At 74 % a dark panel over white paper turns muddy mid-grey. At 86 % it reads as a dark surface with the page faintly behind it. Clear has the same problem in dark mode: at 62 % over white paper it is a grey blob (about `#6A6A6C`), so a Clear droplet that is mostly over light paper (luminance > 0.6) thickens to 80 %.

### 2.3 How each OS draws it

| | iOS 26 and later | iOS 17–25 (in practice 17 and 18) |
|---|---|---|
| Body and lens | System Liquid Glass, which refracts any backdrop including PencilKit | Body tint (Clear) or frost + tint (Deep). The page is not refracted |
| Union and merge | `GlassEffectContainer(spacing: 11)` | One metaball field per cluster of nearby droplets (each cluster its own canvas, framed to its bounds, so resting clusters never redraw): silhouettes blurred at σ 8 pt, thresholded at 0.479 with analytic anti-aliasing in Metal |
| Necks with memory | Glass capsules between droplets inside the container | Capsules drawn into the field |
| Rim, edge, caustic, specular | System | `nibWaterField` shader (§10.9) |
| Stretch | Axis-aligned, through the glass frame | Full affine (any axis) |
| Reduce Transparency | System frosting | Opaque `chromeOpaque` union with the 0.8 pt line |

The feel (every spring, stretch cap, neck, bud and haptic) is identical on both. Only the optics differ.

### 2.4 Rules

- Glass appears only on the floating layer. It is never used in lists, Settings, sheets, forms, the template grid, library tiles at rest, or the page.
- Glass never sits on glass. A Deep panel can hold controls, never another droplet. A search field inside a Clear droplet has no fill of its own.
- One Tinted droplet per screen at most.
- **Contrast is measured over the worst case beneath: black ink at 100 % under the droplet.** Over black ink the light Clear body (46 % white) is `#757575`; in dark mode over white paper the 80 % body is about `#454546` (white text 9.6:1).
- **Text of 14 pt or less on any droplet needs ≥ 4.5:1 against that worst case; text of 15 pt semibold or more needs ≥ 3:1.** On light Clear only `label` at full strength passes (4.6:1 on `#757575`); `labelSecondary` there is about 1.7:1 and is **banned on Clear**. Body text belongs on Deep.
- The listed exceptions to "≥ 15 pt on Clear", each in `label` and semibold: the bar subtitle (caption1, 12 pt), HUD numbers (`hud`, 13 pt, both parts in `label`) and the proposal chip (15 pt). Nothing else puts text under 15 pt on Clear.
- Icons on Clear are ≥ 21 pt.
- Resting droplets are either fused (1 pt overlap) or ≥ 16 pt apart. A 12–15 pt gap reads as a mistake and is banned (the docking code pushes it to 16).

---

## 3. Colour

UI neutrals are Apple's semantic colours. In code they are `NibColor` / `NibUIColor`, never literals. Hex values are listed so the mockup and reviews match.

### 3.1 UI neutrals

| Token | Light | Dark | Use |
|---|---|---|---|
| `label` | `#000000` | `#FFFFFF` | Primary text, icons on droplets |
| `labelSecondary` | `#3C3C43` 60 % | `#EBEBF5` 60 % | Subtitles, section labels, counts |
| `labelTertiary` | `#3C3C43` 30 % | `#EBEBF5` 30 % | Placeholders, disabled, empty-state glyphs |
| `labelQuaternary` | `#3C3C43` 18 % | `#EBEBF5` 16 % | Watermark numbers |
| `separator` | `#3C3C43` 29 % | `#545458` 65 % | 0.5 pt hairlines inside droplets |
| `separatorSoft` | `#3C3C43` 12 % | `#545458` 34 % | Sidebar edge, thread top rule |
| `fill1` | `#787880` 20 % | `#787880` 36 % | Slider tracks, switch off |
| `fill2` | `#787880` 16 % | `#787880` 32 % | Pressed rows, selected filter chip |
| `fill3` | `#767680` 12 % | `#767680` 24 % | Selected segment track, sidebar selection, secondary buttons, chips |
| `fill4` | `#747480` 8 % | `#767680` 18 % | Proposal block, composer, search field |
| `background` | `#FFFFFF` | `#000000` | Library content |
| `backgroundSecondary` | `#F2F2F7` | `#1C1C1E` | Sidebar, folder tiles, sheets, Reduce Transparency Deep |
| `backgroundTertiary` | `#FFFFFF` | `#2C2C2E` | Segment knob, grouped cells |
| `desk` | `#E7E7EC` | `#121214` | Behind pages (never pure white or black: the page edge must read) |
| `chromeOpaque` | `#F4F4F6` | `#2C2C2E` | Reduce Transparency droplet fill |
| `scrim` | `#000000` 18 % | `#000000` 45 % | Behind sheets |

### 3.2 Accent and semantic

| Token | Light | Dark | Contrast | Use |
|---|---|---|---|---|
| `accent` (Pool) | `#0066E0` | `#3D8BFF` | 5.3:1 on white, 6.3:1 on black | Primary buttons, links, focus rings, selected sidebar glyph, AI marks and citations |
| `accentWash` | `#0066E0` 10 % | `#3D8BFF` 16 % | – | Citation chips, drop targets, fused folder film, search hits on the page |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | – | Text on accent |
| `destructive` | `#FF3B30` | `#FF453A` | – | Delete, AI strike-throughs, recording dot, laser |
| `success` | `#34C759` | `#30D158` | – | Applied, sync done, tool-trace checks, switch on |
| `warning` | `#FF9500` | `#FF9F0A` | – | Conflicts, storage, permission confirmations, offline |

Pool is a half-step deeper than system blue so 15 pt text passes AA on white. There is one accent. The assistant's colour is the accent and its mark is a drop.

### 3.3 Water tokens (what the droplet is made of)

| Token | Light | Dark | Meaning |
|---|---|---|---|
| `clearBody` | `#FFFFFF` 46 % | `#161618` 62 % | Clear body (Increase Contrast 72 %) |
| `clearBodyOnPaper` | `#FFFFFF` 46 % | **`#161618` 80 %** | Clear body over light paper; mixed in by how much of the droplet is over it |
| `deepBody` | `#F9F9FB` 72 % | **`#1C1C1E` 86 %** | Deep body (Increase Contrast 90 % / 92 %) |
| `deepGlassTint` | `#FFFFFF` 35 % | `#1C1C1E` 45 % | Deep on iOS 26 system glass |
| `waterBody` | `#FFFFFF` 8 % | `#FFFFFF` 3 % | Tint of the union on top of the body |
| `waterEdge` | `#141C28` **7 %** | `#FFFFFF` 8 % | Edge thickness, the dark ring of a real drop. Over light paper only |
| `waterCaustic` | `#FFFFFF` **12 %** | **`#FFFFFF` 10 %** | Bright crescent opposite the light. Over light paper only |
| `waterRim` | `#FFFFFF` 85 % | `#FFFFFF` 42 % | Hairline highlight facing the light |
| `tintRim` | `#FFFFFF` 30 % | `#FFFFFF` 30 % | The rim of a Tinted droplet (its only optic) |
| `waterLine` | `#000000` 7.5 % | `#FFFFFF` 12 % | 0.8 pt outline so a droplet reads over white paper (Increase Contrast 25 % / 40 %) |
| `waterLineBud` | **`#000000` 12 %** | `#FFFFFF` 16 % | Outline of a budding or retracting droplet, from its first frame |
| `beadBody` | `#FFFFFF` **70 %** | `#FFFFFF` 22 % | Bead material (with the Carbon tint it lands near `#E6E6E6`, not mid-grey) |
| `beadShadow` | `#000000` 16 % | `#000000` 45 % | Slider thumbs only; the selection bead has no shadow |
| `swatchRing` | `#000000` 22 % | `#FFFFFF` 35 % | 1 pt ring on inks that vanish against the chrome: Chalk in light mode, Carbon and Midnight in dark mode |

**Optics follow the backdrop.** Edge and caustic exist to show a lens bending something. Over a flat backdrop (the desk, the white library, sheets) there is nothing to bend, and the two bands read as a neumorphic pillow, so they are drawn only where the droplet is over light paper. On iOS 17–25 the container measures this as the share of each droplet's area over the page frames the editor registers (`nibBackdrop`), and the same share mixes `clearBody` toward `clearBodyOnPaper`. The rim and the 0.8 pt line are always drawn: they are enough to separate a droplet from a flat surface.

### 3.4 Ink: the 12 default pens

Ink is never themed. On dark paper the renderer lifts luminance (never inverts) so every ink stays ≥ 3:1 against the paper.

| # | Name | Hex | Note |
|---|---|---|---|
| 1 | Carbon | `#121212` | Default pen |
| 2 | Graphite | `#5B6068` | Secondary notes, dates |
| 3 | Midnight | `#1B2A6B` | Blue-black fountain ink |
| 4 | Cobalt | `#2156D9` | Blue ballpoint |
| 5 | Lagoon | `#0B8793` | Teal |
| 6 | Moss | `#2F7A3C` | Green |
| 7 | Ochre | `#B7791F` | A yellow that survives on white |
| 8 | Sienna | `#9A4E2A` | Brown |
| 9 | Vermilion | `#D9432B` | Correction red |
| 10 | Crimson | `#B0173A` | Deep red |
| 11 | Plum | `#7B3FA0` | Purple |
| 12 | Chalk | `#F4F4F1` | For dark paper; a 1 pt `swatchRing` in light mode |

Quick slots default to Carbon, Cobalt, Vermilion. Swatches are flat colour with a 0.5 pt hairline: no marbles, no gloss. In dark mode Carbon and Midnight carry a permanent 1 pt `swatchRing` (white 35 %), as Chalk does in light mode, so the swatch is visible before it is selected.

### 3.5 Highlighters

Rendered **beneath** ink: multiply at 60 % on light paper, screen at 35 % on dark paper. Lemon `#FFE45C` (default), Apricot `#FFBE6B`, Mint `#86E3AE`, Sky `#82CCFF`, Lilac `#C8A8FF`, Blush `#FFA3C7`.

### 3.6 Paper, templates, covers, folders, presence

| Paper | Hex | Rule / grid | Margin line |
|---|---|---|---|
| White (default) | `#FFFFFF` | `#CFDBE8` | `#EDB9B3` |
| Ivory | `#FBF8F1` | `#D9D3C5` | `#E9B8A8` |
| Legal | `#FCF3C8` | `#B9C9DA` | `#E3A49B` |
| Grey | `#F1F1EF` | `#D2D4D8` | – |
| Slate (dark) | `#1E1F22` | `#34373D` | `#5A3A38` |
| Night (dark) | `#121212` | `#2A2C30` | – |
| Board | `#1F2A24` | `#33443A` | – |

- **Template geometry** on an A4-width page (595 pt): ruled narrow 7.1 mm (20 pt), college 8.7 mm (24.7 pt), wide 10 mm; grid 5 mm; dots 5 mm at 0.9 pt radius; margin 25 mm from the left. Rules are 0.5 pt at zoom 1 and never thicker than 1 px on screen.
- **Covers**: eight cloths, flat, with a spine (−16 % luminance, 13 pt) and an elastic band (−30 %, 5 pt): Moss `#2F4A3E`, Carbon `#2A2D33`, Terracotta `#A4553A`, Sand `#D5C6A8`, Navy `#23324F`, Oxblood `#5E1F24`, Stone `#8C8A84`, Paper `#F3F1EC`. No gradients, no printed titles, at most 7 % fractal grain.
- **Folder colours** are inks: Cobalt, Moss, Graphite, Ochre, Plum, Vermilion, Lagoon, Sienna.
- **Presence** (never collide with ink): `#FF6B5E`, `#FFB547`, `#3DBB7A`, `#3C8DFF`, `#9C6BFF`, `#FF6FAE`.

---

## 4. Typography

Three families, nothing else. Text styles carry Apple's tracking tables, so nothing sets tracking or kerning by hand (lint rejects `.kerning`/`.tracking`).

| Family | Role |
|---|---|
| **SF Pro** (Text ≤ 19 pt, Display ≥ 20 pt, automatic) | All UI |
| **SF Pro Rounded**, monospaced digits | Numbers that live on water: page counter, zoom %, thickness, timer, recording clock, pairing code, token count |
| **New York** | Editorial moments only: study-card faces, onboarding and empty-state headlines, maths in the assistant, the default body of text documents |

SF Mono appears only in the plugin developer console and the "Show tool calls" disclosure. It is never a decorative metadata style.

### 4.1 Scale (Dynamic Type Large)

| Role (`NibFont.`) | Text style | Size / leading | Weight | Where |
|---|---|---|---|---|
| `display` | `.largeTitle` | 34 / 41 | Bold | Library, Settings titles |
| `displayEditorial` | `.largeTitle` serif | 34 / 41 | Semibold | Onboarding headlines |
| `title1` / `cardFace` | `.title` | 28 / 34 | Bold / serif Regular | Study card face |
| `title2` | `.title2` | 22 / 28 | Bold | Rare sheet titles |
| `title3` | `.title3` | 20 / 25 | Semibold | Sheet titles, library sections |
| `emptyTitle` | `.title3` serif | 20 / 25 | Semibold | Empty-state titles |
| `headline` | `.headline` | 17 / 22 | Semibold | Popover and panel titles |
| `body` | `.body` | 17 / 22 | Regular | Sidebar rows, lists, Settings |
| `callout` | `.callout` | 16 / 21 | Regular | Toasts, empty-state sentences, onboarding body |
| `chat` | `.subheadline` + 1 pt leading | 15 / 21 | Regular | Assistant thread, proposal rows |
| `button` / `barTitle` | `.subheadline` | 15 / 20 | Semibold | Buttons, document title in the bar |
| `footnote` | `.footnote` | 13 / 18 | Regular, Semibold | Section labels (semibold, secondary), notebook titles in the grid |
| `caption1` | `.caption` | 12 / 16 | Regular | Subtitles, dates, tool traces |
| `caption2` | `.caption2` | 11 / 13 | Medium | Pen-type labels, usage line, badges |
| `hud` | `.footnote` rounded, monospaced digits | 13 / 16 | Semibold | "3 / 12", "0.50 mm", "125 %", "04:12" |
| `math` | `.callout` serif italic | 16 / 21 | Regular | Formulas in the assistant |

### 4.2 Dynamic Type

- Lists, Settings, the assistant, search results and sheets scale fully to AX5. At AX1 and larger the assistant panel widens from 344 to 420 pt on iPad, and becomes a full sheet on iPhone.
- **Chrome is capped at xxxLarge.** Bars grow from 44 to 52 pt, palette glyphs from 23 to 28 pt, palette thickness from 56 to 64 pt and pitch from 44 to 52 pt. Past the cap, the Large Content Viewer shows the control's name and glyph on long-press (Apple's own pattern for bars).
- The page never responds to Dynamic Type. Zoom is how you read ink.

---

## 5. Spacing, grid and fixed metrics

Base unit 4 pt; 2 pt only inside controls.

| Token | pt | Typical use |
|---|---|---|
| `xxs` | 2 | Icon-to-badge, segmented inset |
| `xs` | 4 | Bar inner padding |
| `s` | 8 | Button gap in a row, bar top gap |
| `m` | 12 | Popover row gaps, proposal rows |
| `l` | 16 | **Chrome inset from the screen edge**, droplet gap at rest, popover padding, iPhone margin |
| `xl` | 20 | Popover gap from the palette, sheet padding |
| `xxl` | 24 | iPad library margin, **library grid gutter (covers and folder tiles)**, empty-state button gap |
| `x3` | 32 | Library section spacing |
| `x4` | 40 | – |
| `x5` | 48 | Empty-state block spacing |
| `x6` | 64 | Onboarding rhythm |

**Fixed metrics**

- **Hit targets ≥ 44 × 44 pt, always.** The visual can be smaller (a 40 pt HUD, a 12 pt handle bead, a 38 pt proposal button, a 20 pt citation chip); the hit area can't. Palette colour swatches have a 44 pt pitch for this reason.
- Top bars: 44 pt tall at safe-area top + 8 pt, 16 pt from the sides. **Every HUD is 40 pt tall** (page counter, zoom, ruler angle, recording, follow, presenter).
- Palette: 56 pt thick, 44 pt tool pitch (46 on iPhone), 6 pt end padding, a 17 pt divider slot with a 0.5 × 28 pt hairline, 44 pt swatch pitch. Six tools, More and three inks make it 469 pt long (6 + 7 × 44 + 17 + 3 × 44 + 6), which leaves an 834 pt landscape iPad most of its left edge.
- Popover 312 pt wide on iPad (345 pt on iPhone: the screen minus 48), 20 pt from the palette (16 on iPhone), scrolls past 520 pt.
- Panels (assistant, plugins, search results) 344 pt, **420 pt at AX1 and larger**; page navigator 240 pt with 176 pt thumbnails.
- Library grid: covers 140 × 182 pt with a 24 pt gutter (164 pt pitch; five columns in 11″ landscape, four in portrait, six on 13″); what is left of the content width goes to the trailing margin. Rows 250 pt apart. iPhone: three columns of 110 × 143 with a 16 pt gutter.
- Folder tiles 78 pt tall on the same 24 pt gutter; their width is computed, `(content width − 3 × 24) / 4` on iPad (188.5 pt in 11″ landscape), never hard-coded. Names are one line with tail truncation. Sidebar 320.
- Size classes: below 600 pt wide (iPhone, Slide Over, half Split View on 11″) Nib uses the compact layout; otherwise the regular one. Library columns re-flow at 600, 900 and 1180 pt.

---

## 6. Radii

Continuous corners everywhere (`.continuous`, `CALayerCornerCurve.continuous`).

| Element | Radius |
|---|---|
| Bars, HUDs, chips, buttons, fields, palette, toasts | Capsule (h / 2) |
| Popover | 26 |
| Panel, sheet | 28 |
| Composer field (`NibField`) | 22 |
| Study card | 20 |
| Zoom-window frame | 18 |
| Folder tile | 14 |
| Proposal block (panel 28 − inset 16) | 12 |
| Field in a form, sidebar selection | 10 |
| Lifted-card water envelope (cover spine 5 + envelope 3) | 8 |
| Lifted-thumbnail envelope (thumbnail 4 + envelope 3) | 7 |
| Segmented track / knob | 9 / 7 |
| Plugin and settings icon squircle | 7 |
| Badge | 6 |
| Notebook cover | 5 at the spine, 8 at the fore-edge |
| Page thumbnail | 4 (the current-page ring 7) |
| Page | 0 |

**Concentric rule.** A shape inside a shape shares its centre of curvature: `inner = outer − inset`, minimum 8 (`NibRadius.concentric`). Capsules stay capsules. Radii off this table are a lint error.

---

## 7. Elevation

| Level | What | Light | Dark |
|---|---|---|---|
| E0 `paper` | Page on the desk | 0 1 2 5 % · 0 14 34 −10 14 % (+0.5 pt 6 % ring) | 0 18 40 −12 80 % (+0.5 pt white 6 % ring) |
| E1 `rest` | Resting droplet | 0 0.5 1 7 % · 0 6 16 −3 11 % | 0 0.5 1 50 % · 0 8 20 −3 55 % |
| E2 `lifted` | Dragged droplet | 0 1 2 6 % · 0 18 36 −8 22 %, plus lift scale 1.035–1.05 | 0 1 2 50 % · 0 20 40 −8 70 % |
| E3 `sheet` | Sheet, modal | scrim + 0 24 60 −12 28 % | – |
| `cover` / `coverLifted` | Notebook covers | 0 0.5 1 10 % · 0 3 8 −2 10 % / 0 2 4 12 % · 0 22 40 −12 35 % | darker equivalents |

Shadows are the only depth cue besides lift: no inner glows on content, no coloured shadows, no border-plus-wide-shadow "ghost cards". UIKit shadows always set `shadowPath`.

---

## 8. Iconography

SF Symbols only. Palette tools are Medium at 23 pt; bars Regular at 21 pt; sidebar rows Regular at 22 pt; controls in Deep panels Regular at 17 pt. Monochrome by default, hierarchical for multi-layer glyphs. No emoji as icons, anywhere. `sparkles` and magic wands are banned for AI (lint).

### 8.1 Tools

| Tool | Symbol |
|---|---|
| Pen | `pencil.tip` |
| Pencil (type) | `pencil` |
| Highlighter | `highlighter` |
| Eraser / erase filter | `eraser` / `eraser.line.dashed` |
| Lasso / rectangular | `lasso` / `rectangle.dashed` |
| Shapes / connectors | `square.on.circle` / `point.3.connected.trianglepath.dotted` |
| Tape | `rectangle.dashed` |
| Text / full-page typing | `textformat` / `character.cursor.ibeam` |
| Image / camera / scan | `photo` / `camera` / `doc.viewfinder` |
| Elements | `star.square.on.square` |
| Sticky note / comment | `note.text` / `text.bubble` |
| Laser | `laser.burst` |
| Zoom window | `plus.magnifyingglass` |
| Ruler | `ruler` |
| Finger drawing | `hand.draw` |
| More tools | `ellipsis` |
| Plugin tool | The plugin's declared SF Symbol (banned names become `puzzlepiece.extension`) + the 5 pt plugin dot |

### 8.2 Actions and places

| Action | Symbol |
|---|---|
| Back to library | `chevron.backward` |
| Undo / redo | `arrow.uturn.backward` / `arrow.uturn.forward` |
| Search | `magnifyingglass` |
| Bookmark | `bookmark` / `bookmark.fill` |
| Share / export / import | `square.and.arrow.up` / `square.and.arrow.down` |
| More | `ellipsis` |
| Page navigator / outline / add page | `square.grid.2x2` / `list.bullet.indent` / `doc.badge.plus` |
| Assistant | `drop` (idle), `drop.fill` (open) |
| Record / mic / stop / play / pause | `waveform` / `mic` / `stop.fill` / `play.fill` / `pause.fill` |
| Present / external display | `play.rectangle` / `rectangle.on.rectangle` |
| Accept / discard / include | `checkmark` / `xmark` / `checkmark.circle.fill` |
| Citation | `doc.text.magnifyingglass` |
| Send / stop generating | `arrow.up` on a 32 pt `fill3` disc / `stop.fill` on the same disc |
| On-page preview | `eye` / `eye.slash` |
| Retry / warning | `arrow.clockwise` / `exclamationmark.triangle` |
| API key / bridge | `key` / `point.3.filled.connected.trianglepath.dotted` |
| Library places | `books.vertical`, Favourites `star`, Shared `person.2`, Recents `clock`, Study Sets `rectangle.stack`, Gallery `puzzlepiece.extension`, Trash `trash` |
| Documents | Folder `folder.fill`, New `plus`, Notebook `book.closed`, QuickNote `square.and.pencil`, Whiteboard `scribble.variable`, Text document `doc.text`, PDF `doc` |
| Sort / select / grid / list / sidebar | `arrow.up.arrow.down` / `checkmark.circle` / `square.grid.2x2` / `list.bullet` / `sidebar.left` |
| Settings | `gearshape` |
| Sync | `checkmark.icloud` / `arrow.triangle.2.circlepath` / `exclamationmark.icloud` |
| Lock / Face ID | `lock` / `faceid` |
| Collaboration | Invite `person.crop.circle.badge.plus`, live `dot.radiowaves.left.and.right` |
| Plugin permissions | `hand.raised`, network `network`, AI `drop`, document write `pencil.and.outline` |
| Keyboard | `command`, `keyboard` |

---

## 9. Motion

### 9.1 Springs

Every animated value is a spring from `NibMotion`: k = (2π / response)², c = 4π·ζ / response, mass 1 (SwiftUI's own parameterisation).

| Token | Response (s) | ζ | Used for |
|---|---|---|---|
| `follow` | 0.085 | 1.00 | A droplet following the finger (one frame of viscosity) |
| `tap` | 0.22 | 0.90 | Button press scale 0.96 |
| `lift` | 0.30 | 0.72 | Pick-up scale 1 → 1.035–1.05 |
| `glide` | 0.20 | 1.00 | Selection bead head. A selection indicator never overshoots; tool switching happens tens of times a minute |
| `trail` | 0.26 | 1.00 | Selection bead tail (the short lag makes the teardrop on long jumps) |
| `snap` | 0.50 | 0.80 | **The palette's dock only**, starting from the full release velocity (measured overshoot 4 pt) |
| `slot` | 0.40 | 1.00 | Grid and slot snaps (library cards, page thumbnails, floating panels): only the part of the release velocity that points at the slot, capped at 1200 pt/s and at ω·distance, so it never overshoots |
| `reflow` | 0.44 | 0.86 | Neighbours making room (grid, thumbnails), folder films |
| `tether` | 0.40 | 0.62 | Proposal chip flowing back to its dock (one visible overshoot) |
| `bud` | 0.42 | 0.76 | Popover position while budding |
| `budSize` | 0.46 | 0.80 | Popover size while budding |
| `reform` | 0.28 | 0.90 | Palette gather and spread on an orientation change (§10.10), ≤ 380 ms in total |
| `retract` | 0.30 | 0.90 | Popover folding back into its button |
| `neck` | 0.14 | 1.00 | Neck thickness |
| `absorb` | 0.22 | 1.00 | Satellite drop and cards flowing into a folder |
| `wobble` | clamp(0.14·√(minor / 44), 0.14, 0.26) | 0.68 | Surface tension (§10.3): about 5 % overshoot, under one visible cycle |
| `thumb` | 0.16 | 0.72 | Slider-thumb stretch |
| `sheet` | 0.48 | 0.90 | Sheets and panels docking |
| `reduced` | 0.26 | 1.00 | Replaces every spring under Reduce Motion and Liquid Off (`NibSpring.animation` does this itself) |

Floors, enforced by review and by the springs' unit tests: stretch springs (`wobble`, `thumb`) ζ ≥ 0.65; position and size springs ζ ≥ 0.6; selection indicators and slot snaps ζ = 1.

### 9.2 Non-spring timing

- Opacity and blur reveals: ease-out `cubic-bezier(.23, 1, .32, 1)`. Enter 220 ms, exit 120 ms (exits are always faster).
- A budded droplet's content fades in over 220 ms with blur 3 → 0 pt; it is revealed *through* the droplet, clipped to its shape, and never scales up from 0.
- Colour changes lead motion: a newly selected tool's glyph reaches full strength within 120 ms, before the bead arrives. Accepting an AI change turns ghost ink into ink over 350 ms.
- The laser trail fades linearly over 600 ms: the only linear motion in Nib, because it is time made visible.

### 9.3 What never animates

- Ink: wet strokes, the dry-tile swap, erasing, the lasso marquee as it grows.
- Page zoom, pan and scroll (direct manipulation plus system scroll physics).
- Anything triggered from the keyboard, Pencil double-tap or squeeze: tool switches (the bead teleports), ⌘K (appears in place), panels opened by shortcut.
- Undo and redo (the content changes instantly; only the receipt fades).
- Text caret, selection and typing; Settings rows; search results (120 ms opacity only).
- Streaming assistant text: it appears as it arrives, no typewriter effect, no shimmer.
- Idle states. Nothing breathes, pulses, floats or shimmers on its own. There are no liquid loaders.
- Anything while the Pencil is down (§10.8).

---

## 10. Droplet physics (the signature)

This is the complete behaviour, implemented by `DropletPhysics`, `DropletField` and the components in `NibDesign`, and by the mockup's engine with the same numbers.

### 10.1 Drag

- **Pickup** after 6 pt of movement (less is a tap). The droplet lifts to 1.035 (palette, bars), 1.045 (cards, thumbnails) or 1.05 (chip) with `lift`, goes to E2, and a card or thumbnail grows a 3 pt water envelope, concentric with it. The lift and its shadow carry the pickup, as iOS drag previews do; a wide envelope over a flat backdrop only reads as a die-cut sticker outline.
- **Follow.** Target = finger − grab offset; position springs to it with `follow`. Weight is expressed in shape, never in positional lag.
- **Bounds.** Past the container edges (8 pt inset) the droplet rubber-bands: `edge + D·(1 − 1/(0.55·e/D + 1))`, D = 120 pt.
- **One finger.** The first pointer owns the drag; extra touches are ignored until it lifts.
- **Fingers move chrome; the Pencil writes.** A stroke that starts on the page never reaches a droplet.

### 10.2 Stretch with velocity

| Quantity | Value |
|---|---|
| Speed | From the droplet's own position spring (smooth, no sample noise) |
| Target | `s* = min(cap, \|v\| / vRef)`, vRef 2600 pt/s (cards 2800) |
| Caps | Slider thumb 0.10 · chip 0.16 · anchor 0.20 · bars/HUD 0.10 · card and thumbnail 0.10 · palette 0.09 · toast 0.08 · popover 0.06 · panel 0.03 · handles and the selection bead 0 (§10.15). **Calm** halves every cap |
| **Caps are caps** | The spring aims at s\*, but the rendered stretch is clamped to [−0.4·cap, cap] (Calm-halved), so a spring's overshoot never shows past the cap. Unit-tested: max \|s\| ≤ cap for a 5000 pt/s fling |
| Axis | θ follows `atan2(vy, vx)` above 40 pt/s: `θ += Δ·(1 − e^(−18·dt))`, Δ wrapped to (−π/2, π/2] |
| **Long droplets (fix 5)** | Long droplets (palette, bars, chips, toasts) stretch **only along their own axes, with no shear**: signed stretch `s·cos 2(φ − axis)`, so moving along the droplet lengthens it and moving across shortens and thickens it. The regime is blended, never switched: `w = smoothstep(2.5, 3.5, aspect)`, θ's target is `mix(θ_free, axis, w)` and s is multiplied by `mix(1, cos 2(φ − axis), w)`, with the exponential θ follow on top, so θ never steps (a palette re-forming through aspect 3 does not twist) |
| Shape | Along `(1 + s)·L`, across `L / √(1 + s)`: **volume-preserving in 3D** (the drop thins as it stretches). Area preservation reads as rubber |
| **Origin (fix 6)** | The stretch is applied about the **grab point**, clamped inside the body, so the part under the finger stays under the finger. After release the origin springs back to the centre with `snap`. A slider thumb stretches about its grab side (the lag between finger and thumb) |
| Content rigidity | Content gets `s × k`: covers 0.70, palette icons 0.55, bars 0.50, chip 0.35, toast 0.20, popover content 0.15, panel 0.10. Text never deforms more than 2.4 % |
| Poke | Pressing a control kicks the stretch velocity by an impulse sized to the droplet's `wobble` spring: −2.4 (bars, HUD, chip) and −2.2 (palette) give a **2.5 % squash**, −1.3 (swatch) 1.5 %, −0.5 (popover and panel controls) 1 %. It settles within 0.2 s. The poke runs on iOS 26 too: the glass body never receives touches, so the system's own press response does not fire |

### 10.3 Settle (surface tension)

- The stretch is itself a spring toward s\*. When you stop, s\* → 0 and s dips just below zero once: the droplet flattens slightly across its old direction of travel, like a drop landing, and is round again.
- `wobble` response `clamp(0.14·√(minor / 44 pt), 0.14, 0.26)` s at ζ 0.68: a 44 pt bar 0.14 s, the 56 pt palette 0.16 s, a 140 pt card 0.25 s, panels 0.26 s. **About half a visible cycle, the undershoot ≤ 10 % of the peak.** Water at UI scale is quick and tight; 1.5 cycles at ζ 0.5 is jelly.
- **Release** projects a landing point `p + v·0.12 s`. If the finger was still for ≥ 70 ms before lifting, v = 0: a careful placement never flings. Release speed is capped at 5000 pt/s.
- The palette then springs to its dock with `snap`, **starting at the full release velocity**. Everything that lands in a slot (library cards, thumbnails, floating panels) uses `slot` with only the part of the velocity that points at the slot, capped at 1200 pt/s and at ω·distance (ω = 2π / 0.40 s), so it can never overshoot and never leaves its container. A snap haptic plays about 260 ms in. **Nothing rests where it lands**: every droplet has a home (a dock, a slot, its anchor, its layout position) and flows to it.
- Any change of a droplet's layout position (a dock change, a reflow, a popover re-placed) animates from where it is on screen to the new place with the droplet's current velocity (FLIP).

### 10.4 Merge (union)

- All droplets of a container form one surface. The union is a polynomial smooth-min, `h = clamp(0.5 + 0.5·(d₂ − d₁)/k, 0, 1)`, `d = mix(d₂, d₁, h) − k·h·(1 − h)`, with **k = 11 pt on iPad and 9 pt on iPhone**.
- Edges start to bridge at an 11 pt gap (9 on iPhone) and are a full union by 4 pt. Fillets are concave, never a straight join.
- iOS 17–25 renders this as a metaball field: σ 8 pt (6.5 iPhone), iso 0.479. Bridging begins at ≈ 1.35σ. iOS 26 uses `GlassEffectContainer(spacing: 11)` (9 iPhone).
- **Fuse on release (from B, with fix 7).** A droplet released within the merge distance of a neighbour slides along the contact axis until the edges overlap by exactly 1 pt, and aligns centres if they are within 24 pt. Every droplet keeps ≥ 4.5 pt between its content and its ends, so after a fuse the glyph boxes are **≥ 8 pt apart**. While a drag pushes one droplet into another, the stationary droplet's glyphs yield (fading to 25 % over 12 pt of overlap), so two sets of icons never draw over each other. A resting gap of 12–15 pt is pushed out to 16 pt.

### 10.5 Necks and pinch-off (hysteresis)

Real water holds on longer than it takes to join. A **neck** is a capsule of thickness t between the nearest points of two bonded droplets, included in the union.

| Pair | Joins at gap | t₀ | Off | Pinches at gap ≈ |
|---|---|---|---|---|
| Palette ↔ bars, HUD, assistant panel | 11 pt | 26 | 44 | 31 pt |
| Popover ↔ palette (bud) | overlap | 30 | 21 (iPhone 17) | 16 pt (iPhone 13), just before the 20 pt (16) rest gap |
| Proposal chip ↔ its anchor bead (only while the chip is dragged) | 14 pt | 24 | 96 | 65 pt |
| Card ↔ card (only once a combine has armed, §10.12) | 13 pt | 30 | 46 | 35 pt |

- `t = t₀ · (1 − gap/off)^0.7`, springing with `neck`.
- The neck breaks when t < **t_min = 1.27·σ + 0.6 ≈ 10.8 pt**, the thinnest bridge the field can hold, so the logical break and the visual pinch land on the same frame. The neck retracts into both droplets and a split haptic plays.
- Neck endpoints sit 8 pt inside each droplet, clamped to a third of its short side, so the bridge grows out of the body. The middle is furthest from both bodies, so the union waists in the middle first, then snaps.
- **Satellite (from C).** When the chip's tether pinches, a 5 pt satellite drop is left at the pinch point and flows back into the anchor with `absorb`, then disappears.
- On iOS 26 the necks are glass capsules inside the `GlassEffectContainer`, so the system union draws them with the same memory.

### 10.6 Bud-off (popovers and menus split from their button)

1. **Tap the selected tool again.** A 30 pt droplet appears at the tool's centre, inside the palette and already joined to it.
2. Its centre springs to the popover's rest with `bud`; its size springs to W × H (radius 15 → 26) with `budSize`.
3. The neck (t₀ 30) thins as it leaves and **pinches at a 16 pt gap**, about 80 % of the travel and 180 ms in. A bud haptic plays.
4. **Content** is revealed on the pinch or at 300 ms, whichever comes first: opacity 0 → 1 and blur 3 → 0 over 220 ms, **clipped to the droplet's shape (from C)**. The clip is the body itself: its size, radius and full transform (stretch, axis, grab origin, lift). The content keeps its own gentler rigidity transform *inside* that clip, so nothing ever draws outside the body, not even mid-bud. Content never scales up from 0.
5. **Visibility (fix 4).** From its first frame until the reveal, the bud carries the `waterLineBud` outline (12 % black in light mode) and its body tint, so it is visible over the grey desk. Frost fades in with growth: `clamp((progress − 0.25) / 0.5)`.
6. **Close** (tap the tool again, tap outside, start dragging the palette, press Escape). Content fades out in 120 ms. After 70 ms the droplet retracts to the tool with `retract` (size 28, radius 14), rejoins the palette at 11 pt (merge haptic) and disappears once it is < 34 pt and within 5 pt of the tool.
7. **A touch outside an open popover only dismisses it. It never inks.**
8. **From the keyboard** (a shortcut, ⌘K) the popover or panel appears in place with no bud (`instant`).

The same mechanics apply to the lasso object menu (buds from the selection's top edge), in-document search (from the magnifier), the export popover (from Share), the New menu (from "+ New"), the recording HUD (from the mic) and the page-number peek. A feature places such a popover with `NibBudPopover(placement:)` (`.below`, `.above`, `.leading`, `.trailing`): it is positioned from the source's frame, `popoverGap` away (16 on iPhone) and clamped inside the container inset by 16 pt. The palette's own popovers use the same rule, so there is one placement code path.

While a bud is open it is modal for VoiceOver (focus moves into it when its content is revealed, and the canvas behind it is not reachable), a hardware Escape closes it, and the dismiss area covers the whole window including the status-bar and home-indicator strips.

### 10.7 Selection bead

- Two circles: a head (r 20) on `glide` and a tail (r 15.6) chasing the head on `trail`, joined by a neck. A moving bead is one drop that rounds up on arrival. Tool switching is a tens-of-times-a-minute action, so it is quick: the head never overshoots the tool (`glide` ζ 1) and a 220 pt jump is within 1.2 pt of the tool in about 0.25 s.
- **It never splits (fix 1, from C).** The tail is never more than **1.0·r = 20 pt** behind the head, so the teardrop shows only on jumps longer than three tools, and the neck's half-width never drops below **0.72 × the tail radius** (so the neck is ≥ 22.5 pt wide).
- **Ink tint (from B).** The bead takes the current ink at ≤ 15 %. It stays clear water, body plus rim: no shadow, no edge ring, no specular (inside the palette it must not read as a raised button). No marbling, no gloss.
- **Passing lens.** Icons within 30 pt of the head magnify up to 1.13×: `1 + 0.13·max(0, 1 − d/30)`.
- **Colour leads (from C).** The new tool's glyph reaches full strength within 120 ms, before the bead arrives.
- **Scrub.** Press the selected tool and move along the palette's axis: the head follows directly; on release the bead snaps to the nearest tool, which becomes selected. Moving across the axis drags the palette instead.
- Arrival (within 1.2 pt) plays the selection haptic once.
- **Keyboard, Pencil double-tap and squeeze** teleport the bead in 0 ms, with no haptic.

### 10.8 Recede while writing

- **Pencil down anywhere on the canvas:** every droplet whose frame intersects the page or lies within **24 pt of the stroke's bounds** (which grow as you write) fades to **22 %** in 100 ms. Droplets clear of both stay at 100 %: a docked assistant sidebar never overlaps the canvas, so you can read its answer while you copy it by hand.
- For **all** droplets, backdrop sampling freezes (iOS 26 glass becomes `Glass.identity` over the plain body tint; iOS 17–25 frost is not drawn) and no droplet runs physics (the display link parks). At 22 % the swap is not visible, and nothing re-samples the canvas 120 times a second.
- **Return:** 450 ms after the Pencil lifts, chrome fades back over 220 ms with ease-out. No bounce, no stagger.
- Droplets never move out of the way on their own. Their position is the user's.
- The same rule applies whenever a finger draws (finger-drawing mode) and during a lasso drag.

### 10.9 Optics

Light from the top-left: azimuth 225°, elevation 40°.

| Element | Value |
|---|---|
| Lens (Clear, iOS 26 system) | Refraction at the rim only, frosted core. The mockup uses an inward displacement `−n̂·A·(1 − d/ramp)^1.8` for depth d < ramp, ramp 0.95·r + 2 pt, A = 0.15·minor + 2 pt (**0.08·minor + 1 on droplets under 60 pt thick**, so ink under a palette never doubles), then **blur 5 pt** (handwriting under a label must not read as competing structure), saturation 1.7, brightness +4 %, then the body. Page-resident droplets (the proposal chip, the lasso object menu) never refract: they sit on ink |
| Deep lens | Blur 26 pt, saturation 1.8, no displacement (iOS 17–25: `.ultraThinMaterial`) |
| Edge | Inner band `1 − smoothstep(0, 2.6 pt, d)` in `waterEdge`, over light paper only (§3.3) |
| Caustic | Union minus the union offset by (−4, −6) pt, softened, in `waterCaustic`, over light paper only |
| Specular | Blinn-Phong on the height `smoothstep(0, 8 pt, d)` × 6.5; exponent 40, kₛ 0.55. Not on beads, not on Tinted |
| Rim | Union minus the union offset by (1.1, 1.5) pt, in `waterRim` (a 0.8–1.2 pt highlight on the top-left); `tintRim` on Tinted |
| Outline | `1 − smoothstep(0.3, 1.1 pt, d)` in `waterLine` |
| **Tinted** | Rim and outline only. The water stack over an accent fill is a glossy candy button: no edge band, no caustic, no specular |

In Metal (`nibWaterField`, iOS 17–25) d is the field's distance estimate `(f − iso) / |∇f|`, which gives analytic anti-aliasing and the normal for the specular in one pass.

### 10.10 Re-forming the palette (fix 2)

When a fling docks the palette on an edge of the other orientation (vertical ↔ horizontal), it **gathers into a bead and spreads**, the way a drop re-forms. Docking is a correction gesture, so the whole re-form takes **≤ 380 ms** and the toolbar is dark for under 100 ms:

1. The body travels toward the new dock while its long side contracts to its thickness (56 × 56) with `reform` (0.28 s, ζ 0.9).
2. **The short side never springs below the thickness**: it is snapped to it (the palette never thins to 50 pt on a spring undershoot).
3. Content is clipped to the body throughout. It stays fully visible to progress 0.42, fades to 0 at 0.5, and is back to full at 0.58. **Nothing ever draws outside the body.**
4. At the midpoint (long side ≤ 1.5 × thickness) the layout switches axis while the content is invisible.
5. The body spreads to the new length with `reform`; the icons appear in their new slots; the bead rides along.

Under Reduce Motion the palette cross-fades to its new dock with `reduced`.

### 10.11 Docks

| Device | Docks (chosen from the projected finger point, not the droplet's centre) |
|---|---|
| iPad | Left or right edge (vertical, anywhere along the edge below the bars), bottom (horizontal), top below the bars (horizontal, +40 pt bias so the top is picked only on purpose). With the assistant docked, the right edge moves to the panel's leading edge |
| iPhone | Bottom (default) or top below the bars, horizontal only |

VoiceOver and Full Keyboard Access get "Move palette to the left edge / right edge / top / bottom" actions.

### 10.12 Library drag

- **Lift.** The cover lifts to 1.045 with `coverLifted` and becomes a Clear droplet: a **3 pt** water envelope (radius 8, concentric with the cover's 5 pt spine) grows around it, the cover stays opaque and crisp, stretch cap 0.10 with rigidity 0.70, the title fades out. Neighbours reflow with `reflow`.
- **Combine** (notebook → notebook). Arms only when the finger is inside the **inner 70 %** of the target cover (from C) **and** has been held there **380 ms**. Then, and only then, the target swells to 1.03, grows its own envelope, a neck forms between the two (the visual promise that they will combine) and an armed haptic plays. Proximity alone draws nothing. On drop the dragged drop flows in and the stack becomes "New Folder"; a toast buds up: "Made "New Folder" from 2 notebooks · Undo", 6 s.
- **Folder film** (from B). When a drag starts, every folder tile grows a water film over 260 ms (`reflow`, 35 ms stagger). Brought within 13 pt of a folder, the card fuses with its film (accent wash tint, merge haptic). On drop the card flows into the folder with `absorb`, shrinking to 12 % and fading in 220 ms; the folder takes a small gulp (scale 1.03 → 1); the grid closes the gap; a toast: "Moved to Physics 9702 · Undo". Films evaporate 260 ms after the drop.
- **Sidebar drop** (from C). Over the sidebar the lifted card condenses to 50 % around the finger. The hovered folder row grows a droplet pill from its glyph with "+1"; dropping absorbs the card into the row.
- **Release elsewhere** returns the card to its (possibly new) slot with `slot`: only the part of the release velocity that points at the slot, capped at 1200 pt/s and at ω·distance. A 2500 pt/s fling lands on its slot without passing it. Multi-select drags a stacked carrier (up to 3 covers fanned 4°).

### 10.13 Settings switch (from B)

The only liquid in Settings. On iOS 17–25 the switch thumb squashes 27 → 35 pt wide (27 → 23 tall) over the first 120 ms of a toggle and recovers with `tap`, 0.32 s in total. On iOS 26 the system switch (already Liquid Glass) is used as is.

### 10.14 Press feedback

Every press is scale 0.96 on `tap` (the Tinted primary, covers, buttons, icon buttons and tools alike), plus the poke on droplets (§10.2). On iOS 26 the system glass press does the same for the Tinted droplet. **There is no tap ripple anywhere**: a circle growing from the touch point is Android's ink splash, it scales from 0, and it is the most templated press effect there is.

### 10.15 Where liquid is never used

- The page, ink, dry tiles, thumbnail contents, exports, print and PDFs.
- Text-editing surfaces: text boxes, text documents, the composer text itself.
- Lists, Settings (except the switch thumb), grouped forms, the template grid, the plugin list, study-card lists.
- Sheets and modals: opaque grouped surfaces; only their single primary button may be Tinted.
- Docked and scrolling content: the library grid at rest (water appears only while a cover is lifted), the page navigator's scroll view, search result lists.
- System components: context menus, share sheet, alerts, keyboard, document and colour pickers.
- Presentation output on an external display.
- Anything under the Pencil while it is down.
- Anything triggered from the keyboard.
- Loading and thinking states: a plain activity indicator or a tool-trace row, never a liquid loader.
- **Precision affordances never deform.** Lasso and resize handles, the rotation bead and the ruler are rigid (stretch cap 0, no wobble, no poke), and the selection bead has no stretch of its own (it rides its palette): stretching a 12 pt handle moves its visual centre off its hotspot and makes targeting feel sloppy. Water stays on the object menu capsule, not on the handles.

### 10.16 Performance budget

- iOS 17–25 field (blur + one Metal pass over the union): **≤ 1.2 ms GPU per frame on A12**, the oldest chip iOS 17 supports (iPad mini 5, iPad 8, iPhone XS). 0 ms when nothing moves: the display link parks. The field is drawn per cluster of nearby droplets, each canvas framed to its cluster's bounds, so a resting cluster never redraws and nothing full-screen sits above the canvas.
- Main-thread work for chrome ≤ 3 ms per frame at 120 Hz. Per frame only the droplets that moved re-render: each droplet publishes its own presentation and assigns it only when it changes; nothing reads the whole field.
- While the Pencil is down nothing samples the backdrop (§10.8).
- At `ProcessInfo.thermalState ≥ .serious` the field drops to the opaque union: one path union filled once, no blur and no shader, cheaper than the path it replaces. Low Power Mode caps at 60 Hz automatically.
- iOS 26: `GlassEffectContainer` for all floating chrome in a window; never more than one container per window.

---

## 11. Haptics

`NibHaptics.play(_:)`, coalesced to one per 60 ms. Nothing plays per frame, while the Pencil is down, for keyboard actions, during scrolling, or when Liquid is Off. iPad has no Taptic Engine, so these are no-ops there by hardware (the visuals carry the feedback); Apple Pencil Pro gets `UICanvasFeedbackGenerator` for snaps and alignment (iOS 17.5+).

| Event | Core Haptics (intensity, sharpness) | Fallback |
|---|---|---|
| **Merge "plip"**: two droplets join, a popover folds back, a card fuses with a folder | (0.45, 0.70) at 0 ms, then (0.20, 0.35) at +18 ms | `.soft` 0.5 |
| **Split**: a neck pinches, a tether snaps | (0.35, 0.90) | `.rigid` 0.35 |
| **Bud**: a popover pinches free | (0.30, 0.60) | `.soft` 0.4 |
| **Snap**: dock or slot arrival | (0.55, 0.40) | `.soft` 0.7 |
| **Select**: the bead arrives | – | selection |
| **Armed**: card held over card 380 ms | plip | `.soft` 0.6 |
| **Detent**: slider presets, 0 %, 100 % | – | selection |
| **Success**: AI changes applied, notebook filed | – | notification success |
| **Warning**: destructive confirmation | – | notification warning |

---

## 12. Accessibility and fallbacks

| Setting | Behaviour |
|---|---|
| **Reduce Motion** | Every spring becomes `reduced` (0.26 s, ζ 1), including every `NibMotion.x.animation` a component or feature uses. Stretch caps 0, no necks, no poke. A bud becomes a 200 ms cross-fade with scale 0.96 → 1 at the final position. The bead moves with `reduced` (no teardrop). The palette cross-fades to its new dock. Merges still happen (they are geometry). Haptics stay |
| **Reduce Transparency** | No lens. Droplets become one `chromeOpaque` path union per cluster with the 0.8 pt `waterLine` (no blur, no shader, no shadow: the cheap path, also used when hot); Deep panels become `backgroundSecondary`; Tinted stays accent. The union shape and merges remain; specular, caustic and edge go |
| **Increase Contrast** | `waterLine` 25 % (light) / 40 % (dark); Clear body 72 %, Deep 90 %; `separator` at 100 % alpha |
| **Liquid: Full / Calm / Off** (Settings › General › Appearance) | Calm halves every stretch cap and removes necks. Off applies the Reduce Motion and Reduce Transparency fallbacks and silences droplet haptics, whatever the system settings are |
| **Differentiate Without Colour** | AI deletions get "−" markers at line start and numbers; additions are underlined with a 1.5 pt dashed rule; the selected ink also gets its ring |
| **VoiceOver** | Droplets are containers labelled by function ("Tools", "Pen settings", "Proposed edit: fix period"). The bead is not an element: the selected tool carries the Selected trait and a value ("Pen, selected, Carbon, 0.5 millimetres"). Dragging always has an action equivalent (dock moves, "Move to folder…", "Reorder page"). AI proposals expose Accept and Discard as custom actions on the changed ink, announced as "Proposed change 1 of 3: replace formula". Merges and splits are announced only when they change meaning ("Moved to Chemistry. Undo available.") |
| **Dynamic Type** | §4.2 |
| **Full Keyboard Access and pointer** | Every Nib control is focusable. The focus ring is 2 pt accent, 2 pt outside the control, concentric with it (circle for icon, tool and swatch buttons, capsule for buttons), never inside the union; the system focus effect is turned off so there is one ring. Pointer hover is the system highlight shaped like the control (`hoverEffect(.highlight)`); hover never deforms a droplet (deformation follows touch only). A control with a shortcut shows its `KeyHint` after 500 ms of hover and while ⌘ is held |
| **Keyboard** | Tools `P H E L S U T I M K` (+ plugin keys), `⇧P` next pen type, `[` `]` width, `1–9 0` colours, hold Space to pan, **hold ⌘ to show every shortcut** as `KeyHint`s beside their controls, **⌘K** command bar, ⌘J Assistant, ⌘⏎ accept proposal, ⎋ discard or close, ⌘F search, ⌘⇧S sidebar, ⌘1–9 tabs, ⌘N new, ⌘⇧N QuickNote, ⌘Z / ⇧⌘Z undo and redo |

---

## 13. Component catalogue

Feature UI is composed only of these (`NibDesign`). Each row gives anatomy, sizes, states and the one rule people get wrong. Every state is in `NibDesignGallery`, which NibTesting snapshots in Light, Dark, Reduce Transparency, Increase Contrast and AX3.

**Common states** (unless a row says otherwise). *Default* as specified. *Pressed*: scale 0.96 on `tap` (plus a poke on droplets); the same 0.96 for every button, icon button and tool. *Selected*: glyph at 100 % (unselected tools 74 %), `.isSelected` trait, never colour alone. *Disabled*: 40 % opacity, no hit testing. *Focus*: 2 pt accent ring 2 pt outside, concentric. *Hover*: system highlight in the control's shape. *Shortcut*: `KeyHint` beside the control after 500 ms of hover and while ⌘ is held; every `NibButton`, `NibIconButton` and `NibTool` takes an optional `KeyboardShortcut`.

### 13.1 Surfaces and liquid

| Component | Anatomy and sizes | Do | Don't |
|---|---|---|---|
| **`NibDropletContainer`** | One per window, a sibling layer above the canvas. Holds every floating droplet; defines `NibLiquid.space`; runs the physics; draws the water (iOS 17–25) or hosts the `GlassEffectContainer` (26+) | Put bars, palette, HUDs, popovers, chips, toasts and floating panels inside it | Put it inside a ScrollView or List; nest containers; put content (pages, lists) inside it |
| **`.droplet(_:style:)`** | Presets: `bar`, `hud`, `palette`, `popover`, `panel`, `floatingPanel`, `chip`, `anchor`, `card`, `thumbnail`, `toast`, `primary`, `handle` (rigid: cap 0, no poke), `frame` (rim and outline only, no body: the zoom-window target). `bondsWith:` names the one droplet a `card` may neck with (once a combine arms) | Give every droplet a stable, unique id | Hand-roll a glass or material background; animate a droplet's frame yourself; give a toast a droplet yourself (use `.nibToast`) |
| **`.nibBackdrop(_:)`** | The frames of light paper under the container (the editor passes its visible pages) | Update it as pages scroll | Pass dark papers (they get no edge or caustic) |
| **`.budsFrom(_:isPresented:)`** | Popover presentation that grows out of a droplet or `nibBudAnchor` | Keep the popover in the view tree and toggle `isPresented` | Use `.popover` or `.sheet` for tool settings; pass `instant: false` for keyboard invocations |
| **`nibGlass`** | The material on one surface with no physics | Use it only outside a container (rare) | Stack it on another glass |
| **`nibCard`** | Opaque surface (folder tiles, study cards, cells) with a radius and optional elevation | Use it for anything that is content, not chrome | Put a border and a wide soft shadow on the same card |

### 13.2 Chrome

| Component | Anatomy | Sizes | States and notes |
|---|---|---|---|
| **`NibBarGroup`** | Clear capsule of `NibToolbarItem`s, `NibBarSeparator`s and at most one `NibBarTitle` | 44 pt tall (52 at the cap), 4 pt inner padding, items 44 pt | Groups related actions; never mixes text buttons and icons in one group. Hover: highlight. Capped at xxxLarge |
| **`NibToolbarItem`** | `NibIconButton(.bar)`: 21 pt Regular glyph in a 40 pt visual, 44 pt hit | – | *On* (e.g. bookmarked): glyph in accent. Requires a label |
| **`NibBarTitle`** | Title (barTitle) over subtitle (caption1 **semibold, `label`**: §2.4) | Truncates the title first | The subtitle turns `warning` for "Offline · changes saved on this iPad" |
| **`NibHUD`** | Optional icon button + primary number + secondary part, both in `hud` type and `label` | 40 pt tall, always | Digits change with no animation. Capped at xxxLarge |
| **`NibToast`** | Deep capsule: one line of callout + one action (accent) | ≥ 48 pt tall, ≤ 480 wide, bottom-centre 24 pt above the safe area | Presented only through `.nibToast($item)`, which places it, buds it up from below, dismisses it after 6 s (paused while VoiceOver runs), replaces any toast already showing and posts it as a VoiceOver announcement |

### 13.3 Tools

| Component | Anatomy | Sizes | States and notes |
|---|---|---|---|
| **`NibToolPalette`** | Tools, More, a 17 pt divider slot, quick swatches, then plugin tools after a second divider, the bead, the selected tool's popover | 56 pt thick; 44 pt pitch (46 iPhone); 6 pt ends; 469 pt for 6 tools + More + 3 inks. At the type cap thickness grows to 64 and pitch to 52 (54 iPhone) | Tap selects; tapping the selected tool buds its settings; tapping More buds a grid of the other tools (the bead stays put); drag the body to dock; scrub the bead (never onto More). Plugin tools carry a 5 pt dot. Too many tools for the dock's length: the least recently used collapse into More, never the selected tool. A tool chosen from More takes the last native slot. Capped at xxxLarge |
| **`NibToolButton`** | 23 pt Medium glyph (28 at cap), passing-lens scale | 44 × 44 | Unselected 74 %, selected 100 % within 120 ms; Large Content Viewer. A pen or pencil glyph's colour stripe shows the current ink; the highlighter's shows the current highlight colour; no other glyph is tinted. VoiceOver value: "Carbon, 0.5 millimetres" |
| **`NibToolOptionsBar`** | The active tool's contextual options (a tool's `activeToolMenu`): a Clear `bar` droplet | 44 pt tall | Fused (1 pt overlap) to the palette's far side, level with the selected tool; rendered by the palette, so tools never place it themselves |
| **`NibPenSwatch`** | Flat circle + 0.5 pt hairline; selected: 2 pt label ring 2.5 pt outside | 22 (palette), 26 (popover), 28 (iPhone) in a 44 pt cell | Chalk (light mode) and Carbon and Midnight (dark mode) keep a 1 pt `swatchRing` always. Never glossy |
| **Selection bead** | Head r 20, tail r 15.6, neck ≥ 22.5 pt, `beadBody` + ink 15 % + rim. No shadow, no specular | – | Not an accessibility element |
| **`NibPopoverPanel` / `NibBudPopover`** | Title (headline) + optional subtitle; content in `NibInspectorSection`s | 312 wide (iPhone 345: screen − 48), padding 16, scrolls past 520 | Deep; buds; one popover open at a time. `NibBudPopover(placement:)` positions itself from its source (§10.6) |
| **`NibInspectorSection`** | Label (footnote semibold secondary) + value (hud) or link (accent, 44 pt hit) + content | 8 pt label-to-content | – |
| **`NibInspectorRow`** | Optional 24 pt glyph, title, subtitle, accessory | ≥ 44 pt | – |
| **`NibSlider`** | 4 pt `fill1` track, `label` fill, 28 pt white bead thumb | 44 pt tall | Thumb stretches up to **0.10** with speed (`thumb` spring, about its grab side) and settles in one small undershoot; detent haptics |
| **`NibStrokeWidthSlider`** | Three preset dots (5, 8, 12 pt) + value in mm + bead slider | Presets 44 × 40 | Selected preset on `fill3` |
| **`NibSegmentedControl`** | `fill3` track (radius 9, 2 pt inset), `backgroundTertiary` knob (radius 7, E1) | 32 pt visual; each segment's hit area is 44 pt tall | Knob glides on `tap`; selected label semibold |

### 13.4 Controls and text

| Component | Anatomy | Sizes | States and notes |
|---|---|---|---|
| **`NibButton`** | Capsule; optional glyph; `button` type. Kinds: primary (accent fill), secondary (`fill3`), destructive (`destructive` text on `fill3`: never a red fill), plain (accent text) | ≥ 44 pt regular, 38 pt compact visual (44 hit); two lines at AX sizes | Label is verb + object ("Create Notebook", "Delete 4 items"). One filled primary per surface |
| **`NibIconButton`** | Glyph in a 40 pt visual; `round` = 30 pt `fill3` disc; `send` = 32 pt `fill3` disc with a `label` arrow | 44 hit | Always has an accessibility label |
| **`NibToggle`** | System switch on iOS 26; squash thumb (§10.13) below | 51 × 31 | Green when on |
| **`NibSearchField`** | Magnifier, field, clear button | ≥ 44 pt capsule | `filled` on opaque surfaces (`fill4`), `onDroplet` inside a Clear droplet (no fill) |
| **`NibField`** | Field on `fill4`, radius 22 (`NibRadius.composer`), grows to 5 lines | ≥ 44 pt | Placeholder in `labelTertiary`, focus ring accent |
| **`NibChip`** | Context (removable, `fill3`, ≥ 28 pt, remove button with a 28 × 44 hit area), citation (accent wash, radius 6, 20 pt visual inline, 44 pt hit), filter (selected on `fill2`) | Never wraps | Context chips say exactly what the model reads |
| **`NibBadge`** | Type (20 pt white square on covers), number (22 pt accent disc, SF Rounded bold), destructive number, count, "Plugin" capsule, presence (22 pt initials) | – | – |
| **`KeyHint`** | Keys in caption2 on `fill3`, radius 6 | ≥ 22 × 20 | Shown while ⌘ is held, after 500 ms of hover, in menus and in ⌘K |
| **`NibProgressBar`** | A 3 pt `fill1` track with a `label` fill, capsule ends | 3 pt tall | The only determinate progress (export, import, study sessions); never a liquid loader |
| **`NibPageBeads`** | Onboarding progress: 8 pt beads 8 pt apart, the selection bead gliding between them | – | Not a page control people swipe; VoiceOver reads "Step 2 of 4" |
| **`NibEmptyState`** | 44 pt glyph in tertiary, New York title, one sentence, ≤ 1 primary + 1 secondary | ≤ 420 wide | No illustration, no mascot, no confetti |

### 13.5 Library

| Component | Anatomy | Sizes | States and notes |
|---|---|---|---|
| **`NibDocumentCard`** | Cover (5/8 radii, `cover` elevation), title (footnote semibold, 2 lines), subtitle (caption1, star for favourites), type badge | 140 × 182 (iPhone 110 × 143) | Lifted: 3 pt envelope, `coverLifted`, title hidden. Absorbed: 12 % and faded toward the folder. Select mode: a check bead on the cover (`isSelected`). Tap: press scale then open |
| **`NibClothCover`** | Flat cloth, spine, band | – | No printed title, no gradient |
| **`NibFolderTile`** | Folder glyph in folder colour, full name (one line, tail truncation), count, on `backgroundSecondary` | 78 tall, width from the grid (§5), radius 14 | Targeted: water film; fused: accent wash + 1.03 |
| **`NibSidebarRow`** | 22 pt Regular glyph, title (body, one line, tail truncation), count (secondary, right) | 44 pt, radius 10 selection on `fill3` | Selected: semibold title, accent glyph. The same full folder name as the tiles ("Computer Science 9618") |
| **`NibPageThumbnail`** | Page render (radius 4, paper elevation), number (caption1) | 176 wide in the navigator | Current: 2 pt accent ring 3 pt outside (radius 7), accent number. Select mode: check bead. Reorder: `.droplet(style: .thumbnail)` |

### 13.6 Assistant and plugins

| Component | Anatomy | States and notes |
|---|---|---|
| **`NibProposalCard`** | "Proposed edit" + count + On page toggle; rows (number badge matching the page, title, location, include toggle: a 22 pt ring with a `label` check, accent only in its focus ring); destructive rows with their own secondary button (`destructive` text on `fill3`); optional inline confirmation; Accept N (the card's only filled button) / Discard (equal widths); preview footnote | Accept is disabled while a confirmation or a review (> 10 changes) is pending. Accept never covers a destructive row |
| **`NibProposalReceipt`** | ✓ "Applied N changes" · Undo `⌘Z` · Show | Replaces the card after Accept; Undo reverts the whole turn |
| **`NibProposalChip` + `NibTether`** | Chip (drop mark, change name in 15 pt semibold, Accept disc, Discard) docked in the page's trailing margin, clear of ink; while it is dragged it hangs from a 26 pt anchor bead on the change by a water stem | 204 × 44. Pull: the anchor grows on the change, the stem thins and pinches at 65 pt, leaving a 5 pt satellite; release: flows back to its dock with `tether`, then the anchor dries away. Never refracts |
| **`NibPanelHeader`** | Glyph in a 30 pt `fill3` disc, title (headline), subtitle (caption1 secondary), optional badge, optional More menu, round Close | 60 pt minimum, grows with Dynamic Type. The header of the assistant, plugin panels, the transcript and comments |
| **`NibPluginPanelChrome`** | `NibPanelHeader` with the "Plugin" badge and the More menu (Reload, Permissions, Report a Problem); content below a soft hairline | 344 wide (420 at AX sizes). The plugin draws only inside; it cannot draw glass |

### 13.7 Sheets and lists

| Component | Anatomy | Notes |
|---|---|---|
| **`.nibSheet`** | System sheet on `backgroundSecondary` (radius 28) below iOS 26, the system material on 26 | No glass inside; one Tinted primary |
| **`NibSheetHeader`** | Cancel (accent, ⎋) · title (title3, up to 2 lines, never under the buttons) · primary (Tinted compact, ⏎) | ≥ 60 pt |
| **`NibRow`** | Optional 29 pt icon squircle (radius 7), title, subtitle, accessory | In `List(.insetGrouped)`; ≥ 44 pt |

System components used as they are: `Menu`/`UIMenu`, context menus with previews, `UIActivityViewController`, `UIColorPickerViewController`, `UIDocumentPickerViewController`, alerts and confirmation dialogs, `ProgressView`, the keyboard and its shortcuts bar.

---

## 14. Screens

Frames in points. iPad Pro 11″ landscape 1194 × 834, portrait 834 × 1194 (13″ scales the margins, not the controls). iPhone 393 × 852 (safe area top 59, bottom 34). **Split View, Slide Over and Stage Manager** use the compact layout below 600 pt wide and the regular one above; in between, sidebars become overlays. Everything floating in a screen lives in that window's one droplet container.

### 14.1 Library

**iPad landscape (mockup 01)**

- **Sidebar** 320 pt, opaque `backgroundSecondary` (no glass in navigation). "Library" (display) at y 80. `NibSidebarRow`s, 44 pt with 12 pt insets: Documents, Favourites, Shared, Recents, Study Sets, Gallery, Trash, with counts right-aligned in secondary. The selected row is on `fill3` with a semibold label and an accent glyph. "Folders" disclosure lists folders with their coloured glyphs and full names. The bottom row shows sync ("OneDrive · Up to date") and Settings.
- **Content**: "Documents" (display) at x 344, y 80, with "23 items · Date modified" (caption1). "Folders" (title3), then four folder tiles 78 tall on the 24 pt gutter (188.5 pt wide in 11″ landscape). "Notebooks" (title3), then the cover grid (164 pt pitch). Every library measure sits on the 24 pt gutter.
- **Floating chrome** (droplet container), top-right at y 32: a Clear bar (Search, Sort, Select; 3 × 44 + 8) and, 16 pt away, the Tinted "+ New" droplet (96 × 44), which buds the New menu (Notebook, QuickNote, Whiteboard, Text document, Study set, Import files, Scan document).
- **Liquid moments**: §10.12 (lift, reach, combine, folder film, sidebar drop, absorb, toast with Undo).
- **Select mode**: covers show check beads; a Clear action bar buds up at the bottom centre (Move, Share, Duplicate, Favourite, Delete). Delete asks with a system confirmation dialog.
- **Context menu** on a cover: the system context menu with a cover preview.

**iPad portrait**: the sidebar becomes an overlay from the leading edge (system split-view behaviour); four columns; the floating chrome stays top-right.

**Split View / Stage Manager**: ≥ 900 pt: sidebar + grid; 600–900: overlay sidebar, three to four columns; < 600: the iPhone layout.

**iPhone**: the sidebar is the root list (pushed); the library is a large-title screen with three 110 × 143 columns and a 16 pt gutter; a system search field appears on pull-down. Floating chrome is a pair at the bottom trailing edge: a Clear search droplet (44 × 44) and the Tinted New droplet (44 × 44), 16 pt apart. Select mode puts its actions in a bottom Clear bar.

**Empty**: `NibEmptyState(book.closed, "No notebooks yet", "Write something, or bring in a PDF.", New Notebook, Import)`.

### 14.2 Document editor: chrome

**iPad landscape (mockup 02)**

- **Page and desk.** The page is centred on `desk`, 760 pt wide at fit, E0; the next page follows 16 pt below and scrolls under the chrome.
- **Leading bar** (Clear, 16, 32): Back, then the title (barTitle) over "Physics 9702 · Page 3 of 12". Tapping the title buds the document menu (Rename, Move, Recognition language, Collaborators, Close other tabs). Presence beads and the bridge status sit after the title when present.
- **Trailing bar** ending 16 pt before the assistant droplet: Undo, Redo | Search, Bookmark, Share, More.
- **Assistant droplet** (Clear 44 × 44, `drop`) at the top-right corner.
- **Tool palette** (§14.3) docked left by default at x 16, vertically centred below the bars.
- **Page HUD** (Clear 104 × 40, bottom-right, 16 pt in): `square.grid.2x2` + "3 / 12". Tap opens the page navigator; drag scrubs pages.
- **Document tabs** (optional, Settings › Editing): a third Clear droplet between the bars holding up to 5 tab capsules (32 pt); overflow in a menu. Off by default.

**iPad portrait**: the page fits 800 pt wide. The palette docks at the top, horizontal, below the bars; popovers bud downward.

**iPhone (mockup 04)**: the page fits the width with 12 pt desk margins. Leading bar (back + truncated title, 212 × 44), trailing bar (Undo, Assistant, More; 3 × 44 + 8). Palette horizontal at the bottom, 8 pt above the home indicator: Pen, Highlighter, Eraser, Lasso, Text, More, then one ink (349 × 56). **The canvas has a bottom content inset of 80 pt (palette 56 + 8 + 16)**, so the last line can always scroll above the palette; the palette's rim lens is halved there (§10.9) so ink passing under it never doubles. Popovers bud upward, 345 pt wide. The page HUD hides while scrolling (150 ms fade).

**Read-only mode**: the palette retracts into the leading bar (a reverse bud); the bar's subtitle reads "Read only" with `lock`; tapping it offers "Edit".

**Locked document**: the page is replaced by a paper-coloured field with `lock` at 44 pt, "Locked" (emptyTitle) and a Face ID button.

### 14.3 Tool palette and tool settings (mockup 02)

The palette is `NibToolPalette`: six everyday tools by default (pen, highlighter, eraser, lasso, shapes, text) and **More** (`ellipsis`), which buds a grid of the occasional ones (image, tape, elements, laser, ruler); a divider, three quick inks, then plugin tools after a second divider. That is 469 pt, less than Goodnotes exposes by default. The toolbar customisation sheet (from More › Customise Toolbar) is an opaque list with reorder handles, hide (−) and show (+), and saved layouts; people who want all ten tools on the palette put them there. Every tool popover is a Deep `NibPopoverPanel` budded from its tool; sections below are `NibInspectorSection`s, top to bottom. A tool's contextual options (`activeToolMenu`) appear in a `NibToolOptionsBar` fused to the palette's far side.

| Tool | Popover (312 wide, scrolls past 520) |
|---|---|
| **Pen / pencil** | Title "Fountain Pen" (no subtitle: the type is in the title, the thickness in its section). Type grid 4 × 52 pt cells (Fountain, Ball, Brush, Pencil; selected on `fill3`, radius 10). Thickness (`NibStrokeWidthSlider`). Colour: 12 inks in 44 pt cells (6 × 2) + "Custom…" link (system colour picker with eyedropper). Pressure sensitivity (bead slider, %). Tip sharpness. Stabilisation. Stroke pattern (segmented Solid · Dashed · Dotted). Draw & Hold (toggle row). "Pen gestures…" row |
| **Highlighter** | Six highlighters + Custom. Thickness presets 8, 14, 20 pt + slider. Straight line (toggle). Stabilisation. Draw & Hold |
| **Eraser** | Mode segmented (Precision · Standard · Whole stroke). Size presets + slider. Erase filter chips (Pen, Pencil, Highlighter, Tape). Auto-deselect (toggle). "Clear Page" as a destructive plain button with a system confirmation |
| **Lasso** | Type segmented (Freehand · Rectangle). "Included in selection" toggle rows (Handwriting, Highlighter, Tape, Shapes, Images, Text, Sticky notes, Comments, Maths) |
| **Shapes** | Kind grid 4 × 2 (Line, Arrow, Rectangle, Ellipse, Triangle, Star, Polygon, Connector). Stroke colour, fill (None + inks), thickness presets. Footnote: "Hold at the end of a stroke to snap it to a shape" (never auto-snap) |
| **Tape** | Pattern grid 4 × 2, colours, width presets. Tap tape on the page to hide/reveal it |
| **Text** | Style presets (Title, Heading, Body, Caption), font menu (SF Pro, New York, SF Rounded + system fonts via the font picker), size stepper, B / I / U / S toggles, alignment segmented, text colour, fill, border |
| **Image** | A Deep menu (not a grid): Photos, Camera, Scan document, Files, Image Playground (18.1+) |
| **Elements** | A Deep panel (344 × up to 560) budding from the tool: collections as a segmented scroller, a 4-column grid of 64 pt cells, search, "Create element from selection". Dragging an element out lifts it as a Clear droplet; dropping on the page dries it into content |
| **Laser** | Dot · Trail segmented, colour (Vermilion default + 5), trail length |
| **Sticky note / comment** | Seven note colours; comments pin a 22 pt accent number badge on the page and open a Deep comments drawer |
| **Zoom window** | See below |

**Lasso selection and the object menu.** The marquee is a dashed accent line (1 pt, 4/4). Handles are 12 pt beads with 44 pt hit areas (corners scale, edges resize one axis, a rotation bead 24 pt above the top edge on a hairline). **Handles are rigid**: cap 0, no wobble, no poke, so the visual centre always sits on the hotspot (§10.15). The object menu buds from the selection's top centre as a Clear capsule that never refracts (it sits on ink): Cut, Copy, Duplicate, Colour, Convert, More. More opens the system menu with the full list (Arrange, Lock, Screenshot, Style, Add Comment, Create Element, Ask Assistant, plugin items under their plugin's name). Items made by the AI show "Made by Assistant · 09:41" at the top of the menu.

**Zoom window.** The target box on the page is a `frame` droplet (rim and outline only, no body, `NibRadius.zoomFrame` 18), draggable with stretch. The writing pane is a Deep panel docked at the bottom (full width − 32, 240 tall) with a bead slider for zoom and Return, New line and Margin controls. The ink in the pane is the real canvas at 3×, never refracted.

**Ruler.** An opaque on-page object (1 pt ticks, `label` at 60 %) moved and rotated with two fingers; the angle shows in a Clear 40 pt HUD next to it and snaps at 0/45/90° with a Pencil Pro alignment haptic.

**Shape and alignment guides** are 1 pt accent lines on the page, dashed for spacing. They are content-layer drawing, never droplets.

### 14.4 Page navigator, outline and bookmarks

- **iPad**: a Deep panel 240 wide at the leading edge (trailing per Settings), 12 pt from the chrome, full height below the bars. In landscape the canvas insets so the page stays fully visible; in portrait the panel floats over the page with E2. A segmented control at the top: Pages · Outline · Bookmarks.
- **Pages**: a single column of 176 pt thumbnails with the number under each; the current page has the accent ring. Long-press lifts a thumbnail into a Clear droplet (3 pt envelope, radius 7, cap 0.10; it lands with `slot`); neighbours reflow with `reflow`; no merge between thumbnails. "Select" shows check beads, and the panel's opaque bottom row offers Move, Copy, Export, Delete (no droplet inside the panel). An "Add page" row sits at the end.
- **Outline**: rows (title in body, page number in hud) grouped "From the PDF" and "Yours"; swipe to delete; "Add entry for this page" at the top.
- **Bookmarks**: rows with a 40 pt thumbnail, page number and title.
- **iPhone**: a system sheet at the large detent with a 2-column grid of 160 pt thumbnails and the same tabs.
- **Empty**: Outline "No outline yet" + "Add entry for this page"; Bookmarks "No bookmarks" (the Bookmark button is in the bar).

### 14.5 Search

- **Global (library)**: the search droplet buds from the magnifier into a 560 × 44 Clear field at top centre; results fill a Deep panel beneath (560 × up to 600). Filter chips: All · Handwriting · Typed · PDF · Audio · Cards. Sections: Top hits, Notebooks, Handwriting (ink snippets 120 × 60 with the match washed in Lemon at 60 % multiply), Typed text, PDF text, Transcripts, Folders. Recent searches appear as chips when the field is empty. Results fade in over 120 ms, never staggered. "Handwriting in 12 pages is still being indexed." sits as a footnote.
- **In document**: the same field buds from the bar's magnifier; hits are washed on the page in `accentWash` (radius 4); a "3 of 11" HUD with previous and next.
- **iPad portrait / Split View**: the field and results panel span the width minus 32 below the bars. **iPhone**: full-screen list under a system search field, no droplets.
- **No results**: "No results for "k/m"" (emptyTitle) + a callout tip. **Indexing**: the footnote above, never a spinner over results.

### 14.6 New document and templates sheet (mockup 05)

- **iPad form sheet** 720 × 640, opaque `backgroundSecondary`, radius 28. `NibSheetHeader`: Cancel · "New Notebook" · Create (Tinted, the sheet's only water).
- Type segmented: Notebook · Whiteboard · Text document · Study set.
- **Title field** (44 pt). The AI suggestion appears as placeholder text with a "Use" button when a provider is connected.
- **Live cover preview** (104 × 136) left of the title, updating as choices change.
- **Cover strip**: a horizontal row of 88 × 116 covers ("No cover" first); the selected one has a 2 pt accent ring 3 pt outside, the same ring as the paper grid (one selection language per sheet).
- **Paper**: template groups on the left (Basic, Lined, Grid, Planners, Music, From plugins; a 150 pt list of 32 pt rows) and a scrolling 4-column grid of 104 × 135 paper thumbnails with their names; selected: 2 pt accent ring 3 pt outside. The grid's bottom 16 pt fades, so a cut-off row reads as more below, not as a clipping bug.
- **Options row**: Size (A4, Letter, B5, Legal, Square, Custom), Orientation segmented, Paper colour swatches (§3.6), Apply to (All pages · Every other).
- **iPhone**: a full-height sheet with the same order stacked, three paper tiles per row, Create pinned at the bottom as a Tinted capsule.
- **Change template** (for existing pages) is the same paper grid in a Deep popover budded from More › Change Template, plus "Apply to: This page · All pages".

### 14.7 Export and share

- Share buds a Deep **export popover** from the bar's Share button: Format segmented (PDF · Images · Nib file · Text), Pages (This page · Selected · All), toggles (Include page backgrounds, Include annotations, Flatten, Include audio), then "Share…" (primary, opens the system share sheet), "Save to Files", "Print". Collaboration ("Share live…") is the last row.
- Progress for long exports: a `NibProgressBar` in the popover; completion is a toast ("Exported 12 pages · Show in Files").
- **iPhone**: a system sheet at the medium detent with the same content.
- Locked documents: the popover says "Unlock to export" with Face ID.

### 14.8 Settings (mockup 07)

- **iPad**: a 760 × 706 form sheet (or a window in Stage Manager) split in two: a 220 pt section list (glyphs in `labelSecondary`, the selected row on `fill3` with an accent glyph) and an inset grouped list on the right. **iPhone**: a navigation stack.
- **Sections** (the contract's `SettingsSection`): General (Appearance, Liquid, Language), Editing, Stylus (Apple Pencil, palm rejection, double-tap and squeeze choices), Writing (pen gestures, Draw & Hold, Writing Aids), AI (providers, privacy), Sync (library location, backup, WebDAV), Plugins, Bridge, Advanced (diagnostics, safe mode), About.
- **Appearance › Liquid**: a segmented Full · Calm · Off with the footnote "Calm keeps the water but halves the stretch. Off uses solid chrome and no motion."
- Rows are `NibRow`s with 29 pt squircle icons in muted system colours; values are secondary text; toggles are `NibToggle` (the only liquid here, §10.13).
- API keys and tokens are entered only in secure fields here, never in onboarding and never by the assistant.

### 14.9 Assistant (mockup 03)

**Modes**

- **Sidebar** (default in iPad landscape): a Deep panel 344 × (height − 48) docked trailing; the canvas insets so the page stays fully visible; the assistant droplet merges into the panel header.
- **Floating**: the same panel (344 × 560), draggable (`floatingPanel`, cap 0.03); it docks to either side and merges with the palette if brought close.
- **Window**: a separate scene.
- **iPad portrait**: a Deep panel docked at the bottom (width − 32, detents 45 % and 90 %), the page and its marks visible above.
- **iPhone**: a system sheet at the medium and large detents; the proposal chip docks just above the palette.

**Anatomy, top to bottom**

1. **Header** (`NibPanelHeader`, 60 pt minimum): the drop mark in a 30 pt `fill3` circle, "Assistant" (headline), the model and whose key it uses ("Claude Sonnet 4.5 · your API key", caption1 secondary; Nib never hides which provider sees the data), a round Close.
2. **Mode and context row**: Ask | Edit segmented (Ask uses read-only tools). **Context chips (from C)** state exactly what the model reads: "Page 3", "Handwriting", "Page image", each removable, plus "+" to add Selection, Document or Library.
3. **Thread** reads as a document, **not chat**: a speaker label (caption1 semibold secondary: "You · 9:41", or the drop glyph + "Assistant · 9:41 · 4 s"), then the paragraph in `chat` type. A hairline only at the top of the thread. No bubbles, no avatars, no alternating alignment.
4. **Tool trace**: caption1 rows with success checks ("Read page 3 · 14 handwritten lines recognised", "Checked 6 formulas"). "Show tool calls" reveals the raw calls in SF Mono.
5. **Citations**: inline `accentWash` chips ("▤ Line 5"). Tapping one scrolls the page to that line and washes it in `accentWash` for 600 ms.
6. **Proposal** (`NibProposalCard`): numbered rows whose numbers match the badges on the page; an **include toggle on every row** (a 22 pt ring with a `label` check); an **On page** eye toggle; destructive rows with their own secondary Delete button (`destructive` text on `fill3`) that Accept never covers; Accept is the card's only filled button; an **inline confirmation** ("Allow once · Allow for this turn · Deny") when a command needs permission, never a modal; Accept N / Discard; "Previewing on the page. Nothing changes until you accept." Edits over 10 items or across pages show "Review 14 changes", which opens the Gateway sheet before Accept is enabled.
7. **Receipt** after Accept: ✓ "Applied 2 changes · Undo ⌘Z · Show". The whole turn is one undo group.
8. **Composer**: a `NibField` with the placeholder "Tell Nib what to change…", Dictate, and Send: a `label` arrow on a 32 pt `fill3` disc (`NibIconButton` `send`), **shown only once the field has text** (120 ms fade), Stop in the same place while generating. No "+" in the field: adding context belongs to the context chips row. It must not read as a chat app's composer. Quick actions above it (Summarise, Quiz me, Convert to text, Explain, plus plugin and user actions). Footer: "1,284 tokens this chat · sent only to your provider" (caption2, `labelSecondary`: this is the trust line and it passes 4.5:1).

**On the page (proofreader marks, from B and C)**

- A numbered margin badge (22 pt accent disc) level with each changed line, matching the row numbers. **Every badge sits in the left margin** (x = 52 pt on the page); two changes on one line stack 4 pt apart vertically.
- Deletions: a 2.6 pt hand-drawn strike in `destructive`.
- Additions: **ghost ink at 42 % in the user's current pen**, written in their matched handwriting. No outline: 42 % ghost ink already says "proposed". A change carries at most three marks: its badge, its strike or ghost ink, and (for the main change) the chip.
- **The proposal chip docks in the page's trailing margin** (or the gutter beside the page, 16 pt clear of the panel), level with its line's badges. It never sits over ink: it is tested against every stroke's bounds plus 8 pt and, if its line is taken, it takes the nearest free band above or below (`NibTether.restingCentre`); then a 1 pt accent hairline ties it to its change. It never refracts. **The anchor bead and the water stem exist only while the chip is dragged** (§10.5): pull it and the anchor grows on the change, the stem thins and pinches; let go and it flows back to its dock and the anchor dries away. At rest the chip is just the chip. Several proposals get one chip each, stacked 8 pt apart, never overlapping.
- **After Accept**: ghost ink becomes ink (42 → 100 % over 350 ms, sliding into place), strikes erase the old ink, badges fade over 220 ms, the chip flows back into the change and dries into the page. AI-made items carry provenance ("Made by Assistant").

**States**: no provider ("Connect a model to use the assistant." + provider rows: Anthropic, OpenAI-compatible, Ollama, LM Studio, Custom); thinking (a trace row "Reading page 3…" with a small activity indicator, never a pulsing bead); streaming (text appears as it arrives); error (an inline `warning` row with Retry; the thread is never lost); offline ("You're offline. Your notes are fine; the assistant needs a connection."); context trimmed (the chip turns `warning`: "Trimmed to 3 pages").

**External AI bridge**: while an agent is connected, the leading bar shows a 6 pt `success` dot and the client name ("Claude Code") in caption1. Its proposals arrive exactly like the assistant's, labelled with the agent's name. Settings › Bridge shows the pairing code in `hudLarge` (28 pt), connected clients and their scopes.

### 14.10 Plugins (mockup 06)

- **Plugin manager** (Settings › Plugins; on iPad a 780 × 690 sheet with a 320 pt list and a detail pane): "Install from…" (File, URL, Gallery) leading in the header; a list of `NibRow`s (29 pt icon squircle, name with an "Update" capsule when one is waiting, author and version in caption1, a plain-language permission summary such as "Reads documents · Uses your AI", an enable switch).
- **Detail**: description; **permissions as plain sentences with glyphs** ("Read every document" `doc`, "Change pages" `pencil.and.outline`, "Use your AI provider" `drop`, "Reach the network: api.example.com" `network`), each with its own toggle; contributions (tools, panels, menus, commands, AI actions); version, source; Update (primary), Disable, Remove (destructive, confirmed).
- **Install consent sheet** (from B): source (file, URL or gallery entry), SHA-256 hash (first 12 characters, "Show full hash"), author, the permission list, and "Install" as the only primary. Nothing installs automatically.
- **Update consent**: a **permission diff**: added permissions in accent with "+", removed ones struck through; "Update" is disabled until reviewed.
- **Plugin panels**: `NibPluginPanelChrome` in the Deep panel frame (344 wide) docked with the assistant or floating. HTML panels receive Nib's tokens as CSS variables (`--nib-label`, `--nib-accent`, `--nib-font-body`, `--nib-space-16`, …) and `-apple-system-body`, so they inherit dark mode and Dynamic Type. **They cannot draw their own glass**; Nib draws the droplet.
- **Plugin tools** join the palette after a second divider with the 5 pt plugin dot and behave exactly like native tools, bead included. Tool options a plugin declares are rendered by Nib, so they cannot look foreign. Plugin menu items appear under the plugin's name.
- **Developer console**: a Deep panel 480 × 320 in SF Mono 13 (the one place mono is a UI font).
- **Gallery** (library tab): gallery indexes as sections of the same rows, with Install.
- **Empty**: "No plugins yet" + "Browse Gallery". **Crashed panel**: "This plugin stopped." + Reload.
- **iPad portrait / Split View**: the manager sheet becomes a two-level push (list, then detail); plugin panels float (344 × 560) instead of docking. **iPhone**: Settings › Plugins is a navigation stack; install and update consent are full-height sheets; plugin panels open as system sheets at the medium and large detents; plugin tools join the phone palette's More grid.

### 14.11 Study sets

- **Editor (iPad)**: two panes on opaque surfaces: the card list (Term | Definition rows in body, image slots; ⇥ moves between fields; ⌘⏎ adds a card) and a large preview card (560 × 360, radius 20, `cardFace`).
- **Practice / Smart Learn**: a paper card 560 × 360 (E1, paper not water) centred on the desk; the front in `cardFace`; tap or Space flips it around the Y axis with `sheet` (no bounce; Reduce Motion cross-fades); a 3 pt `fill1` progress line with a `label` fill and "12 of 42" in hud at the top; grading as four Clear droplets at the bottom centre, 16 pt apart: Again · Hard · Good · Easy, each with the next interval in caption2 (1–4 keys). Swiping the card grades it: it follows the finger, tilts ±6° and flies out with the release velocity.
- **Session summary**: a quiet list (reviewed, due tomorrow, hardest cards), no confetti.
- **iPhone**: the card fills the width − 32; grading droplets at the bottom; swipe to grade.

### 14.12 Presentation mode

- The external display shows only the page, letterboxed on black: no chrome, cursor or selection (the laser is the exception).
- On the iPad a Clear presenter HUD at top centre: `rectangle.on.rectangle` "Presenting on Living Room TV", the page count, Laser toggle, Blank screen, Stop. Page changes are direct scrolls.
- Laser: a 12 pt `destructive` dot with a 45 % 12 pt glow; the trail is a 4 pt line fading linearly over 600 ms.
- **iPad portrait** keeps the HUD at top centre. **iPhone**: the HUD docks at the bottom centre above the palette (Stop, Laser, page count); presenting from an iPhone mirrors only the page.

### 14.13 Audio: recording, playback, transcript

- **Record**: More › Record (or ⌘⇧R) buds a Clear recording HUD from the trailing bar to top centre (40 tall): a `destructive` dot, the timer in hud type, a live waveform in `labelSecondary` bars (no colour), Pause and Stop. Strokes written while recording are timestamped.
- **Playback**: a Clear audio bar at the bottom centre (320 × 44; above the palette on iPhone): play/pause, a bead scrubber, elapsed/total in hud, speed (1×, 1.5×, 2×), transcript. **Replay** shows not-yet-written strokes at 30 % and draws them in as the audio reaches them.
- **Recordings list**: a panel tab "Audio" with rows (date, duration, page).
- **Transcript**: a Deep panel with timestamped paragraphs (tap to seek), search, and "Summarise" when AI is connected.

### 14.14 Collaboration

- **Share live** (from Share): a Deep popover with the join code (hud large) and QR, participants with presence colours and roles (Can edit · Can view), and join requests (Approve · Decline).
- **Presence**: up to three 22 pt initial beads after the title in the leading bar (then "+2"). Live cursors are 10 pt presence-colour beads with a caption2 name capsule. Tapping a bead follows that person: a Clear HUD "Following Sam · Stop".
- **Unseen changes**: a 6 pt accent dot on changed thumbnails and a toast "3 changes since you left · Show".
- **Conflicts or offline**: the bar subtitle turns `warning` ("Offline · changes saved on this iPad").
- **iPhone**: presence beads collapse to one bead with a count after the title; Share live is a system sheet at the medium detent; the follow HUD sits under the leading bar.

### 14.15 Onboarding

Four steps on full-bleed white paper, each with one Deep card (480 wide on iPad, width − 32 on iPhone). Progress is `NibPageBeads`: four 8 pt beads with the selection bead gliding between them. The headline is `displayEditorial`, the body `callout`.

1. **"Your notes live in a folder you choose."** Why an outside folder survives reinstalls, then the folder picker as the Tinted button.
2. **Pencil.** A strip of real canvas to try palm rejection and the pen, and the double-tap/squeeze choice. The chrome recedes here too, and the hint "Throw the palette to any edge" appears once.
3. **Bring your own AI** (optional): provider rows and Skip. Keys are entered only in Settings.
4. **Done**: a QuickNote opens straight away.

No carousel of feature illustrations, no confetti.

### 14.16 Command bar (⌘K)

Every registered command (built-in, plugin and AI action) in one list: a Deep panel 560 wide at top centre with a search field, recent commands first, fuzzy search, the source in caption1 ("Pen · Built-in", "Anki Export · Plugin", "Summarise · AI") and the shortcut as a `KeyHint`. ⏎ runs, ⇥ fills arguments. It opens instantly from the keyboard and buds only when tapped (from More › Commands).

### 14.17 Whiteboards and text documents

- **Whiteboard**: an infinite board on Board or White paper with dots; the same chrome, palette and page HUD, which shows zoom ("45 %") instead of a page number; the pinch-zoom HUD buds at top centre during a pinch and evaporates 0.6 s after.
- **Text document**: an opaque reading column 680 wide in New York 17 (body), no droplets on the text. Block handles appear on hover or long-press as plain `labelTertiary` glyphs. The slash menu and Turn Into are Deep popovers at the caret that appear in place (keyboard-triggered, no bud). The formatting bar above the keyboard is the system input accessory style, opaque.

### 14.18 Empty, error and loading states

| Where | Treatment |
|---|---|
| Library empty | `book.closed` · "No notebooks yet" · "Write something, or bring in a PDF." · New Notebook · Import |
| Folder empty | "Nothing in Physics 9702 yet" · "Drag notebooks here." · New Notebook |
| Search, no results | "No results for "k/m"" · "Handwriting search needs recognition to finish: 3 pages left." |
| Trash empty | "Trash is empty" (no button) |
| Assistant, no provider | "Connect a model to use the assistant." + provider rows |
| Plugins, none | "No plugins yet" · "Plugins add tools, panels and templates." · Browse Gallery |
| Outline / bookmarks | "No outline yet" · Add entry / "No bookmarks" |
| **Loading, library** | Paper-coloured cover placeholders (no shimmer); sync row shows `arrow.triangle.2.circlepath` |
| **Loading, document** | Page tiles fade in over 120 ms; a small activity indicator in the page HUD only after 400 ms |
| **Loading, AI** | A trace row with a small activity indicator |
| **Loading, export or import** | A determinate 3 pt bar where the action was started |
| **Loading, plugin panel** | A small activity indicator centred in the panel |
| **Offline sync** | Bar subtitle in `warning`: "Offline · changes saved on this iPad" |
| **Sync conflict** | A `warning` row at the top of the library: "2 notebooks changed on two devices" · Resolve (an opaque sheet comparing both versions) |
| **Page failed to render** | A paper field with `exclamationmark.triangle`: "Couldn't show this page." · Try Again · Restore from Backup |
| **Plugin crashed** | Panel body: "This plugin stopped." · Reload · Report |
| **AI error** | Inline `warning` row in the thread with the provider's message in plain words + Retry |
| **Storage low** | A toast: "iPad storage is almost full. Nib may stop saving audio." · Manage |

Every message says what happened and what to do next, with a verb-plus-object action. No "Oops", no exclamation marks.

---

## 15. Rules for feature code

1. **Import `NibDesign`** and compose only: `.droplet`, `.budsFrom`, `.nibBudAnchor`, the `Nib*` components, `NibColor`/`NibUIColor`, `NibFont`/`NibUIFont`, `NibSpacing`, `NibRadius`, `NibMetrics`, `NibMotion`, `NibHaptics`, `NibSymbol` (`Image(nib:)`), `nibGlass`, `nibCard`, `nibElevation`, `nibSheet`, `nibToast`, `nibBackdrop`, `NibInkingState`, `nibLiquidMode`. `Scripts/lint.py` rejects raw colours, fonts, radii, shadows, animations, materials, glass, haptics, SF Symbol strings, shaders, emoji, banned words and US spellings in UI copy (DESIGN_SYSTEM.md §4).
2. **One `NibDropletContainer` per window**, a sibling above the canvas, never inside a scroll view.
3. **Pass the Pencil state** through one `NibInkingState` that the canvas delegate writes (`canvasViewDidBeginUsingTool` / `…EndUsingTool`, plus the stroke's bounds as it grows) and only `NibDropletContainer(inking:)` reads, so a Pencil down never re-evaluates the editor's body. Pass the visible light pages to `.nibBackdrop(_:)`.
4. **Keyboard paths never animate.** Use `budsFrom(…, instant: true)` and teleport tool changes.
5. **Every icon-only control has an accessibility label**; every drag has an action equivalent.
6. **Missing a component or token?** File a contract request (ARCHITECTURE.md §16). Don't hand-roll one "for now".
7. **Every new screen** adds its snapshots (Light, Dark, Reduce Transparency, Increase Contrast, AX3) before review.
8. **UI copy is British English** (colour, favourite, customise, summarise, recognised), matching this spec. The lint rejects US spellings in `String(localized:)`.

---

## 16. Slop checklist (the review gate)

A reviewer rejects a change that fails any line. "Slop" is anything someone could look at and say "a template made that".

**Tokens and structure**

- [ ] Only tokens: no literal colour, font size, radius, shadow, spacing off the 4 pt scale, spring or duration.
- [ ] One accent, used for meaning (primary, link, focus, AI marks), never for decoration. No second accent, no AI purple, no rainbow of tints.
- [ ] No gradients anywhere in chrome. No gradient text. No glossy or marbled swatches.
- [ ] No card inside a card inside a card; no nested backgrounds (the confirmation inside a proposal is a hairline row, not a card).
- [ ] No border plus wide soft shadow on the same element. No coloured shadows, no inner glows.
- [ ] Radii from §6 only; concentric inside shapes; capsules stay capsules.
- [ ] Glass only on the floating layer; never glass on glass; never on docked or scrolling content.
- [ ] One Tinted droplet per screen.

**Type and copy**

- [ ] SF Pro, SF Pro Rounded (numbers on water), New York (editorial). No SF Mono as a style. No hand-set tracking.
- [ ] No all-caps labels, no eyebrow text above sections, no numbered section markers in the UI.
- [ ] Buttons are verb + object. No "Oops", no exclamation marks, no em dashes, no "seamless / elevate / unleash / supercharge / magic".
- [ ] Nothing wraps or truncates badly at AX3 or in German; chips never wrap.

**Icons and imagery**

- [ ] SF Symbols only. No emoji as icons. No `sparkles` or magic wands for AI (the drop is the mark).
- [ ] No illustrations, mascots or confetti in empty states or onboarding.

**Motion and liquid**

- [ ] Every animation answers a touch; nothing idles, breathes, pulses or shimmers.
- [ ] Springs from `NibMotion` only; stretch springs ζ ≥ 0.65, position springs ζ ≥ 0.6, selection indicators and slot snaps ζ 1; the rendered stretch never passes its cap; no jelly (no multi-bounce, nothing still wobbling after it is pinned).
- [ ] Frequent actions are quick: tool switches, grid snaps and docking corrections finish in ≤ 0.4 s and never overshoot their target.
- [ ] Precision affordances (handles, the ruler) never deform.
- [ ] No tap ripple or ink splash; presses are scale 0.96.
- [ ] Nothing animates on keyboard input, undo, zoom, pan, scroll or typing.
- [ ] The ink path is untouched: no shader, blur or glass over a live stroke; chrome over the page or near the stroke recedes to 22 %; nothing samples the backdrop while the Pencil is down.
- [ ] Buds reveal content through the droplet, clipped to it; nothing scales from 0; nothing draws outside a droplet's body (reshapes included).
- [ ] The bead never splits; necks pinch at the table's distances; nothing rests where it lands.
- [ ] No liquid loaders; loading is a plain indicator or a trace row.

**Interaction and accessibility**

- [ ] 44 pt hit targets everywhere.
- [ ] Reduce Motion, Reduce Transparency, Increase Contrast and Liquid Off checked; snapshots at AX3.
- [ ] Every icon-only control is labelled; state is never colour alone; every drag has an action.
- [ ] Focus rings visible for Full Keyboard Access, outside the control and concentric with it; hover is the system highlight; every shortcut shows its `KeyHint`.
- [ ] Text ≤ 14 pt on a droplet passes 4.5:1 over black ink (§2.4); `labelSecondary` never on Clear.
- [ ] Nothing page-resident sits over ink or refracts it; edge and caustic only over light paper.
- [ ] A tap outside a popover dismisses it and never inks.

**Trust (AI and plugins)**

- [ ] The assistant shows its model and whose key, what it reads (context chips), what it did (trace), where (citations), and previews on the page before changing anything.
- [ ] Destructive AI or plugin actions have their own button or inline confirmation; never a modal, never folded into Accept.
- [ ] Plugins show source, hash and permissions before install, and a permission diff on update; plugin UI never draws its own glass.
- [ ] No chat bubbles, avatars or typing indicators in the assistant.

---

## 17. Where each decision came from

| Decision | Source |
|---|---|
| Four materials, water tokens, colour, the 12 inks, spring table, merge geometry (k 11 / 9), neck table, recede (22 % in 100 ms, back after 450 ms), the two-tap plip, document-style assistant, tool traces, citations, Gateway for > 10 edits, "sent only to your provider", Liquid Full/Calm/Off, lint rules | Direction A (kept) |
| Bead limited to 1.0·r separation (was 1.9·r) and neck ≥ 0.72·r_min | Fix 1 (C's rule), tightened in the second critique |
| Palette re-forms by gathering into a bead; content clipped and cross-faded 0.42–0.58 with `reform`, ≤ 380 ms | Fix 2 (C's clipped reveal), tightened in the second critique |
| Dark Deep `#1C1C1E` 86 %; dark caustic 10 % | Fix 3 |
| `waterLineBud` 12 % on the bud from its first frame | Fix 4 |
| Long droplets stretch on their own axes, no shear | Fix 5 (B's rule) |
| Stretch from the grab point | Fix 6 (C's rule) |
| Fuse to 1 pt overlap, glyph gap ≥ 8 pt, neighbours yield during a drag, 12–15 pt gaps pushed to 16 | Fix 7 (with B's fuse) |
| ≤ 1.2 ms per frame on A12 | Fix 8 |
| `.droplet` / `.budsFrom` / `DropletStyle` presets as the only public liquid API; `DropletPhysics` as tested pure Swift | Graft from B |
| Numbered proofreader badges, include checkbox on every row, On page toggle, AI provenance in the object menu, inline Allow once / for this turn / Deny | Graft from B |
| Folder water film, fuse and absorb with an Undo toast | Graft from B |
| Bead tinted by the current ink at ≤ 15 % | Graft from B |
| Settings switch squash 27 → 35 → 27 pt over 0.32 s | Graft from B |
| Install consent with source and hash, permission diff on update, plugins cannot draw glass | Graft from B |
| Glyph colour leads the bead by 120 ms; keyboard and Pencil switches teleport | Graft from C |
| Bud content revealed through the droplet, never scaled from 0 | Graft from C |
| Sidebar folder drop (condense to 50 %, "+1" pill); combine armed only in the inner 70 % (plus A's 380 ms hold) | Graft from C |
| Tether pinch leaves a 5 pt satellite | Graft from C |
| Context chips; ghost ink at 42 % in the current pen; destructive rows with their own button; the "Applied N changes · Undo ⌘Z · Show" receipt | Graft from C |
| Keyboard map, hold ⌘ for hints, ⌘K for every command | Graft from C |
| 5 pt plugin dot; Nib draws the plugin panel header | Graft from C |
| Component inventory (`NibButton`, `NibIconButton`, `NibToggle`, `NibSlider`, `NibRow`, `NibField`, `NibChip`, `NibToast`, `NibEmptyState`, `KeyHint`, `NibSheet`, bud popover, tether) and the review gate | Graft from C |
| Killed: glossy marble swatches and bead; surface damping 0.32; "rest wherever it lands"; proximity-only recede; quicksilver material and theme-inverting buttons; cinnabar accent; SF Mono metadata; the opaque docked editor bar (tabs are an option); 15 pt default UI size | Judge's verdict |
| Liquid Glass on iOS 26+ with `GlassEffectContainer`; a Canvas metaball field + Metal shading below; Xcode 26.6 on `macos-26` | Research brief, [design/XCODE.md](../design/XCODE.md) |
| Water, not jelly: `wobble` ζ 0.68 at 0.14–0.26 s, rendered stretch clamped to its cap, slider thumb cap 0.10, `glide`/`trail` ζ 1, `slot` for grid snaps, `reform` for re-forming, the stretch-axis regime blended; rigid handles; no ripple | Second critique (measured jelly and overshoot in the mockup) |
| Bud content clipped by the body's own geometry; page-resident droplets never over ink and never refracting; the chip docked in the margin with its stem only while dragged; badges all in the margin; no ghost outline | Second critique |
| Text on Clear as a measurable contrast rule; Clear core blur 5 pt; edge and caustic over light paper only; dark Clear 80 % over paper; Tinted without water optics; bead without shadow | Second critique |
| Recede by page overlap or 24 pt from the stroke (broader than the killed proximity-only rule: everything over the page still recedes); docked panels clear of the canvas stay readable | Second critique |
| Six tools + More (469 pt); composer without "+" and with Send only when there is text; one filled button per proposal card; 24 pt library gutter; en-GB copy | Second critique |
