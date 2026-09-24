# Nib · Direction C: Mercury

A precision instrument whose floating chrome moves like quicksilver.

Mockup: `design/direction-c.html` (open in Chrome or Edge for the real refraction path; Safari and Firefox get the frost fallback). Every physics number in this document is the number the mockup runs on, and both use SwiftUI's `(response, dampingFraction)` spring parametrisation, so values port to Swift 1:1.

---

## 1. The idea in five sentences

1. Nib's chrome is **dense liquid metal seen through smoked glass**: heavier and tighter than water, so it stretches less, settles faster (about 3.5 Hz, one overshoot) and snaps with a crisp tick instead of a soft bloop.
2. **Selection is a single bead of mercury.** The selected tool, tab, pen type, slider thumb and primary button are all the same quicksilver material, so "what is active" is always the brightest, most metallic object in its container.
3. **The page is paper and never moves.** Ink is crisp, zero-latency and untouched by any shader; the liquid layer recedes to 14% the instant the pencil lands.
4. **One sharp accent, cinnabar** (the red ore mercury is refined from), reserved for *live* things: recording, focus, canvas selection, and everything the Assistant proposes.
5. **Everything has a keyboard path, and keyboard actions never animate.** Single-key tools, ⌘K for every registered command, hold ⌘ to see shortcuts.

## 2. Principles

| # | Principle | What it rules out |
|---|---|---|
| P1 | **Canvas first.** Chrome floats, recedes and never covers ink the user is working on. | Full-width toolbars that eat page height; chrome that animates while writing. |
| P2 | **Believable physics, not jelly.** Area is preserved, overshoot is single, deformation returns before arrival. | Bouncy cartoon squash, wobble loops, elastic overshoot on data. |
| P3 | **Liquid only where something moves.** Droplet behaviour is for floating, movable, mergeable things. Docked chrome is solid. | Glass on every card; blur as decoration. |
| P4 | **One light, one material vocabulary.** Light from top-left (azimuth 225°, elevation 40°). Three materials only: smoked glass, quicksilver, solid. | Mixed shadow directions, gradients for flavour, a fourth material. |
| P5 | **Trust is visible.** The AI never changes the page silently: proposals are drawn on the page, numbered, reversible as one step. | Chat bubbles that "did something somewhere". |
| P6 | **Instant for experts.** Pointer and keyboard paths are dense and immediate; touch paths keep 44 pt targets. | Animated keyboard shortcuts; hidden power features with no hints. |
| P7 | **Calm by default.** Motion is caused by the user, never ambient. Nothing loops at rest. | Idle shimmer, breathing buttons, animated gradients. |

## 3. Colour

All UI colours are dynamic (light/dark) and live in `NibColor`. Ink, highlighter and paper colours are **content** and never change with the theme.

### 3.1 UI neutrals (cool graphite, hue ≈ 220°, chroma ≈ 0.01)

| Token | Dark | Light | Used for |
|---|---|---|---|
| `desk` | `#0B0C0E` | `#D8DBDF` | Area around pages in the editor, presentation surround |
| `bg` | `#101113` | `#F1F2F4` | App background, Library content area |
| `surface1` | `#15171A` | `#F8F9FA` | Docked chrome: nav bars, sidebar, Assistant panel, status bar |
| `surface2` | `#1B1D21` | `#FFFFFF` | Grouped containers (change sets), fields, segmented tracks |
| `surface3` | `#23262B` | `#E8EAED` | Selected row, active tab, search field, tokens, pressed |
| `surface4` | `#2D3036` | `#DCDFE3` | Toast, tooltip, key-hint plates, selected width dot |
| `line` | `rgba(255,255,255,.07)` | `rgba(12,14,17,.08)` | Hairlines, separators (1 px) |
| `line2` | `rgba(255,255,255,.12)` | `rgba(12,14,17,.14)` | Field borders, vertical dividers in bars |
| `text1` | `#ECEDEF` | `#111317` | Primary text and glyphs |
| `text2` | `#A7ACB4` | `#4E545C` | Secondary text, inactive icons |
| `text3` | `#80858E` | `#666C75` | Metadata, placeholders, section headers (AA ≥ 4.5 on bg and surface2) |
| `text4` | `#50555D` | `#A2A7AE` | Disabled only (never carries information) |

### 3.2 Accent and semantic

| Token | Dark | Light | Rules |
|---|---|---|---|
| `cinnabar` (accent) | `#FF5A36` | `#C93516` | Live state only: recording dot, keyboard focus ring (2 pt), lasso/zoom-box outline on canvas, AI proposal outlines + number beads + anchor, toggle "on" track, unseen-change dot. Never a primary button fill. Budget ≤ 5% of any screen's pixels. |
| `cinnabarWash` | `rgba(255,90,54,.14)` | `rgba(201,53,22,.10)` | Hovered AI proposal region, selection fill on canvas |
| `ok` | `#3DD68C` | `#1A7F4E` | Sync healthy, "applied" receipts, correct flashcard |
| `warn` | `#FFB547` | `#A35F00` | Sync conflict, low storage, unsigned plugin |
| `danger` | `#FF5468` | `#D2263F` | Destructive labels (always text + glyph, never colour alone) |

Contrast (WCAG): text1/bg 16.1 (dark) and 16.6 (light); text3/bg 5.1 and 4.7; cinnabar/surface1 5.8 (dark) and 4.6 on white (light); on-quicksilver 12.2 (dark) and 10.6 (light).

### 3.3 Materials' colours

| Token | Dark | Light | Notes |
|---|---|---|---|
| `glassTint` | `rgba(17,19,22,.46)` | `rgba(248,249,251,.52)` | Under the droplet body; contrast floor for glyphs |
| `dropletBody` | `#121417` at 66% | `#F4F5F7` at 62% | Metaball fill (100% under Reduce Transparency) |
| `dropletRim` | `rgba(255,255,255,.20)` | `rgba(16,19,24,.22)` | 1.1 pt meniscus band. Bright rim on dark, dark rim on light, like a real droplet on each |
| `quicksilver` | ramp `#F7F8FA → #C9CED6 → #8B929C` | ramp `#646B75 → #3A3F46 → #23272C` | Selection bead, primary buttons, slider thumbs. **Inverts with theme** so it is always the highest-contrast object |
| `onQuicksilver` | `#0B0C0E` | `#FFFFFF` | Glyph/label on the bead |

### 3.4 Default ink: 12 pens

Tuned as fountain-pen inks: dense, slightly desaturated. On White paper every pen except Chalk (made for dark paper) clears 3.5:1, and most clear 4.5:1 (Sky 4.1, Ochre 3.6). Slot order is the order in the pen-settings grid and the `1`–`9`, `0`, `-`, `=` shortcuts.

| # | Name | Hex | Note |
|---|---|---|---|
| 1 | Carbon | `#1A1A1A` | Default pen (matches `RGBA.black` in CONTRACTS) |
| 2 | Graphite | `#4A4E55` | Secondary notes, hatching |
| 3 | Blue-black | `#1F3350` | |
| 4 | Cobalt | `#2350B8` | Headings |
| 5 | Sky | `#1C84C6` | |
| 6 | Teal | `#0F7F7A` | |
| 7 | Green | `#23813F` | |
| 8 | Ochre | `#B77A0B` | |
| 9 | Cinnabar | `#C8401F` | The brand accent as ink: annotations |
| 10 | Crimson | `#B3173D` | Corrections |
| 11 | Plum | `#6E2E86` | |
| 12 | Chalk | `#F2F2EE` | For Slate/Night paper |

Pencil default stays `#3A3A3C` (CONTRACTS `defaultPencil`). "Adapt dark inks on dark paper" (default on) *displays* Carbon/Graphite/Blue-black as Chalk on Slate and Night paper; stored colours never change.

### 3.5 Highlighters (render beneath ink, 50% alpha, multiply)

Yellow `#FFE03D` (default, = `RGBA.highlighterYellow`), Lime `#B8F04A`, Mint `#62E0B4`, Sky `#70C8FF`, Rose `#FF93B8`, Apricot `#FFB25C`.

### 3.6 Paper and template colours

| Paper | Hex | Lines | Dots | Margin line |
|---|---|---|---|---|
| White (default) | `#FFFFFF` | `#C9D1DB` 0.5 pt | `#C3CAD3` r 0.72 pt | `#F0B3A6` |
| Soft | `#F6F6F4` | `#C7CED7` | `#C1C8D0` | `#EFB1A3` |
| Legal | `#FDF6DC` (= `RGBA.paperYellow`) | `#E1D4A0` | `#D9CC96` | `#E7A99A` |
| Mist | `#EEF1F4` | `#C3CCD6` | `#BCC5CF` | `#E9AFA2` |
| Slate | `#2A2D31` | `#3B4048` | `#454A52` | `#7A3A2E` |
| Night | `#242426` (= `RGBA.paperDark`) | `#38393D` | `#434448` | `#74362B` |

Default template: **Dot grid 5 mm** on White. Grid pitch 14.173 pt (5 mm); ruled narrow 7.1 mm; the mockup page uses exactly these values.

## 4. Typography

**System voice is SF Pro; the user's words are New York; numbers and keys are SF Mono.** SF Rounded is deliberately not used: Mercury is a precision tool and rounded terminals read as consumer-soft. All sizes are at the default Dynamic Type size (Large) and scale through `UIFontMetrics(forTextStyle:)`.

| Token | Face | Size / leading | Weight | Tracking | Text style | Used for |
|---|---|---|---|---|---|---|
| `display` | SF Pro Display | 28 / 34 | Semibold | system | `.title` | Library folder title, sheet titles |
| `title` | SF Pro Display | 20 / 25 | Semibold | system | `.title3` | Empty-state and onboarding headlines, settings detail headers |
| `headline` | SF Pro Text | 17 / 22 | Semibold | system | `.headline` | Panel titles ("Assistant"), card face in Practice header |
| `body` | SF Pro Text | 17 / 22 | Regular | system | `.body` | Settings rows, onboarding body |
| `ui` | SF Pro Text | 15 / 20 | Regular / Medium | system | `.subheadline` | **Mercury's default UI size**: sidebar rows, panel text, popover titles (Semibold), buttons 14 Semibold |
| `footnote` | SF Pro Text | 13 / 18 | Regular | system | `.footnote` | Document tabs, command field, breadcrumbs |
| `caption` | SF Pro Text | 12 / 16 | Regular / Semibold | system | `.caption` | Metadata ("Today · 14 pages"), control labels (Semibold, text3) |
| `micro` | SF Pro Text | 11 / 13 | Semibold | +0.03 em | `.caption2` | Cover badges (PDF, SET, BOARD) |
| `mono` | SF Mono | 11.5 / 14 | Medium | 0 | `.caption` + `.monospaced()` | Page numbers, zoom %, key hints, timestamps, model id, counts |
| `notebook` | New York | 15 / 19 | Medium | system | `.subheadline` serif | Notebook/document titles in Library and tabs overflow |
| `reading` | New York | 17 / 24 | Regular | system | `.body` serif | Text Documents default body, study-card back |
| `cardFace` | New York | 34 / 40 | Medium | system | `.largeTitle` serif | Study-card front in Practice |

Rules: every changing number uses `.monospacedDigit()`; no all-caps except `micro` badges; truncate titles at 2 lines in grids, 1 line in rows; at accessibility sizes (AX1+) popovers become sheets, key hints hide, palette slots stay 44 pt and the palette scrolls.

## 5. Spacing, grid, targets

- Scale (pt): **2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64**. Nothing else.
- Margins: iPad content 32 (landscape) / 24 (portrait); iPhone 16; floating chrome inset **16** from screen edges; sidebar rows inset 12.
- Minimum hit target 44 × 44 always. Visual rows may be 40 pt in pointer-dense lists (sidebar) only if the row is ≥ 200 pt wide.
- Library grid: 5 columns at 850 pt content width, gutters 24 horizontal / 26 vertical, covers 3:4. 4 columns portrait, 3 columns under 700 pt, 2 on iPhone.

## 6. Radii (concentric)

| Element | Radius |
|---|---|
| Anything ≤ 56 pt tall (palette, chips, buttons, segmented, toasts) | capsule (h/2) |
| Popovers and floating panels | 22 |
| Grouped containers (change sets, settings groups) | 14 |
| Fields, sidebar selection, icon buttons | 10 |
| Page thumbnails | 6 |
| Notebook covers | 3 spine / 8 fore-edge |
| Paper page | 2 |

Inner radius = outer radius − inset (a 14 pt group with 4 pt inset holds 10 pt rows). Never exceed 22 on a rectangle.

## 7. Materials

| Material | What it is | Where | Never |
|---|---|---|---|
| **Smoked glass (droplet)** | Backdrop frost 3 pt + saturate 1.5 + rim lens refraction, then a metaball body at 66% (`dropletBody`), meniscus rim, specular from the one light | Floating tool palette, popovers (pen settings, colour, object menu), HUD chips (page, zoom, presentation), AI proposal chip, command bar, floating Assistant, drag skins | Docked bars, sheets, lists, anything scrolling, anything under the pencil |
| **Quicksilver** | Opaque liquid metal: diffuse + hot specular, theme-inverting | Selection bead in palettes and segmented controls, primary buttons, slider thumbs, toggle knobs, selection handles on canvas | Large areas; text longer than 3 words |
| **Solid** | Flat `surface1–4`, hairlines | Nav bars, sidebars, the docked Assistant panel, sheets, settings, library background | Blur. Solid chrome is honest about being fixed |
| **Paper** | Content colour, page shadow E0 | Pages, thumbnails, covers | UI tokens (paper never follows theme) |

iOS 26+: system bars and sheets adopt system Liquid Glass automatically when built with the iOS 26 SDK; Mercury's docked `surface1` becomes their tint. Nib's own droplets keep the `DropletField` renderer on every OS version (iOS 17.0+) so stretch, merge and bud-off behave identically everywhere.

**Reduce Transparency:** glass becomes opaque `surface2` with a 1 px `line2` border; droplet bodies go to 100%; refraction and frost are removed; merge/split geometry still works (it is shape, not transparency).

## 8. Elevation and light

One light: azimuth 225° (top-left), elevation 40°. Every specular sits top-left; shadows fall straight down.

| Level | Dark | Light | Used by |
|---|---|---|---|
| E0 paper | `0 1 2 α.50` + `0 12 36 α.45` | `0 1 2 α.14` + `0 10 30 α.14` | Pages on the desk |
| E1 docked | none, 1 px `line` | same | Bars, sidebars, panels |
| E2 floating | `0 1 1 α.45` + `0 10 28 α.42` | `0 1 1 α.14` + `0 10 26 α.16` | Droplets at rest |
| E3 lifted | `0 2 3 α.40` + `0 22 48 α.55`, scale 1.045 | `0 2 3 α.14` + `0 22 44 α.24` | Anything being dragged |
| E4 modal | system sheet | system | Sheets, alerts |

Mercury droplets cast **tight** shadows and no caustics: metal does not focus light.

## 9. Droplet physics

### 9.1 Integrator
Semi-implicit Euler, 240 Hz fixed sub-steps, frame dt clamped to [1/240, 1/30] s, one `CADisplayLink` (preferred 120 Hz on ProMotion) that parks itself when every spring is at rest. Spring from SwiftUI parameters: `k = (2π/response)²`, `c = 4π·damping/response`, m = 1. Rest when |x − target| < ε and |v| < 12ε.

### 9.2 Spring presets (`NibMotion`)

| Name | response / damping | Used for |
|---|---|---|
| `settle` | 0.34 / 0.80 | Drop, dock, snap to slot or edge, FLIP reflow |
| `wobble` | 0.26 / 0.42 | Shape strain (surface tension): ≈ 3.5 Hz, one visible overshoot, amplitude halves every ≈ 70 ms |
| `beadLead` | 0.22 / 0.80 | Selection bead head |
| `beadTrail` | 0.30 / 0.95 | Bead tail, follows the head (not the target) |
| `bud` | 0.38 / 0.80 | Popover budding off its button |
| `absorb` | 0.22 / 1.00 | Close, merge-in, satellite droplet returning |
| `tether` | 0.28 / 0.70 | AI chip re-docking to its anchor |
| `cardHome` | 0.38 / 0.82 | Library card returning to its slot |

### 9.3 Stretch with velocity (squash and stretch, area-preserving)
- Velocity: exponential smoothing of pointer samples, rate 26 s⁻¹; decays at 16 s⁻¹ once no sample arrives for 40 ms (a held finger un-stretches).
- Strain is a trace-free tensor `(a, b)` on the `wobble` spring. Target: `s = Smax · tanh(|v| / 1400 pt/s)`, `a = s·cos 2θ`, `b = s·sin 2θ`, θ = direction of travel. Matrix = `R(φ) · diag(eˢ, e⁻ˢ) · R(−φ)`, φ = ½·atan2(b, a): det = 1, so area is exactly preserved. On release the target goes to 0 and the tensor passes through zero into a short squash along the old axis, which is what makes it read as liquid rather than rubber.
- Transform origin = the grab point (the part under the finger stays under the finger; the rest trails).
- `Smax` (log-strain): palette 0.09, drag skin under a library card 0.12 (the card itself takes 30% of it plus a tilt of ±3° from horizontal speed), AI chip 0.07, slider thumb 0.25. Positions track the finger 1:1; weight is expressed in shape, never in positional lag.
- Press dent: +0.045 strain (≈ 4.6% flatter and wider) while pressed, fading out above 500 pt/s.
- Throw: release target is projected `0.10 s` of velocity ahead (palette, chip), `0.08 s` for the bead, then snapped (dock edge or slot) with `settle`, starting from the release velocity.
- Rubber band past an end stop: `16 · (1 − e^(−x/16))` pt.

### 9.4 Merge and split (metaball union)
- Union rule: smooth union of signed distance fields. Mockup: SVG goo, blur σ 7 pt, alpha cut `24·α − 10` (iso 0.42). Metal: polynomial smooth-min with `k = 11.5 pt`. Two edges fuse on their own when the gap is under **11.5 pt** (1.65σ).
- Quicksilver uses σ 3 pt, cut `22·α − 9`: bonds under 5 pt, so beads stay beads.
- Active reach (ligament): a capsule drawn between nearest points, thickness from distance, smoothed by the union so both ends flare into a meniscus. A thread under 8 pt thickness vanishes in the union, so every ligament lives in 8–26 pt.
- **Library card → folder row:** active when the pointer is within 64 pt of the row; over the sidebar the lifted card condenses to 50% scale around the finger; the row grows a droplet pill from its icon; ligament thickness `26 · reach^0.8`; armed when the pointer is on the row. Drop: card absorbs into the row (scale → 0.10, `absorb`), plip, count +1, grid reflows with `settle`, toast with Undo.
- **Library card → card:** active within 40 pt of a cover; armed only with the pointer inside the inner 70% of the target cover (prevents accidental folders); drop makes a folder in the target's slot.
- **AI chip tether:** docked 26 pt right and 9 pt below its anchor with a 16 pt neck. Pulling thins the neck `8 + 8·(1 − L/120)^0.6`; at **120 pt** it pinches: split tick, and a 5 pt satellite droplet is left at the midpoint and absorbed back into the anchor. Brought back within **56 pt** a new neck reaches out (`16·(1 − L/56)`); release there re-docks with `tether` and plips on contact.
- Popover ↔ palette gap at rest is 14 pt (> 11.5), so a settled popover is always a separate droplet.

### 9.5 Bud-off (popovers, menus, colour picker, object menu, command bar)
Driven by one spring `p: 0 → 1` (`bud`), closed with `absorb`:
- `p 0 → 0.5`: a bud (radius 9 → 22 pt) travels from the button's centre to the popover's near edge; an 18 pt ligament joins it to the parent and thins to nothing at **p = 0.6: pinch-off, split haptic.**
- `p 0.3 → 1`: the bud inflates into the popover rectangle (overshoot capped at 4%).
- Content is revealed *through* the droplet (clipped to its current shape) and fades in over `p 0.55 → 0.9`, scaling 0.97 → 1 from the button side. Content never scales from 0.
- Close runs the same path backwards and plips when re-absorbed (`p < 0.03`).
- Perceived timing: neck visible ≈ 0–110 ms, pinch ≈ 110 ms, 95% open ≈ 210 ms, settled ≈ 300 ms. Invoked from the keyboard (⌘K, shortcut keys): no bud, the panel simply appears.

### 9.6 Selection bead glide
- Bead radius 17 pt in a 44 pt slot. Head on `beadLead`, tail on `beadTrail` chasing the head, joined by a neck 72% of the smaller radius, both under the quicksilver union: the bead stretches into a teardrop and pulls itself back together on arrival.
- Head gains 16% axial stretch at 1400 pt/s; tail shrinks to 66% and head to 90% at 40 pt separation; separation never exceeds 1.9 r (it never splits).
- Colour leads motion: the new glyph turns `onQuicksilver` in 120 ms with no delay while the bead is still travelling.
- The bead is draggable along the palette; it rubber-bands at the ends, ticks as it passes each slot and settles to the projected slot on release.
- Keyboard or Pencil double-tap: the bead jumps (no glide), one selection tick.

### 9.7 Refraction and rim
- Rim lens baked once per droplet size: rounded-rect SDF, displacement only in the outer **12 pt** (palettes) / **10 pt** (popovers, chips), profile `(1 − depth/rim)^1.6`, sampling inward (magnified edge), peak **9 pt** / **7 pt**. Centre displacement is 0, so glyphs sit on calm glass.
- Frost 3 pt, saturation 1.5. Without refraction (other renderers, Reduce Transparency off but unsupported): frost 10 pt dark / 12 pt light.
- Meniscus rim 1.1 pt; specular: distant light 225°/40°, exponent 36 (chrome) and 225°/56°, exponent 30 (quicksilver). Tight exponents are what make it read as metal, not soap.

### 9.8 Receding while writing
Pencil or finger ink down: every floating droplet fades to **14% in 120 ms** and stops all droplet rendering; the display link parks. Chrome returns **450 ms** after lift over 220 ms. Droplets never animate, refract or re-render over the canvas while a stroke is live; wet ink owns the GPU.

### 9.9 Where liquid is NOT used
Ink and page content; page thumbnails at rest; text fields and carets; scrolling lists (Library grid scroll, settings, search results); docked bars, sidebars and the docked Assistant panel; sheets and alerts; study-card faces; any keyboard-initiated action; undo/redo (content changes instantly, only the HUD fades); zoom and pan; anything while the pencil is down.

### 9.10 Reduce Motion
Positions snap (no springs), strain is always 0, bead jumps, bud-off becomes a 150 ms opacity fade from 0.98 scale, merges become a 120 ms highlight of the target, splits are instant, receding is an instant opacity change. Haptics stay.

### 9.11 Performance budget
Droplet field ≤ 2 ms GPU per frame at 120 Hz on A12Z; parks when idle (static texture); refraction lens baked once per size, never per frame; union computed only inside the bounding box of active droplets plus 3σ; at most 12 live droplets.

## 10. Haptics (`NibHaptic`)

| Event | Core Haptics (transient intensity / sharpness) | Fallback |
|---|---|---|
| **Merge "plip"** (drop into folder, popover re-absorbed, chip re-docks) | 0.45 / 0.72, then 28 ms later 0.18 / 0.95 (the surface-tension tick) | `UIImpactFeedbackGenerator(.soft)` 0.6 |
| **Split** (bud pinches off, tether snaps) | 0.35 / 0.90 | `.rigid` 0.45 |
| **Dock / snap** (palette lands on an edge) | 0.55 / 0.40 | `.soft` 0.8 |
| Bead arrives, bead passes a slot, target arms | selection | `UISelectionFeedbackGenerator` |
| Assistant changes applied | success | `UINotificationFeedbackGenerator(.success)` |
| Pencil Pro snaps (shape, alignment guides) | | `UICanvasFeedbackGenerator` (iOS 17.5+) `alignmentOccurred` |

Never during inking, scrolling, typing or continuous slider drags (only at detents).

## 11. Iconography

SF Symbols, `.regular` weight, 20 pt in palettes and bars (`.imageScale(.medium)` at `ui` size), monochrome. The selected state never swaps to a `.fill` variant: the glyph stays, the bead behind it changes. Custom symbols are drawn on the SF Symbols template (same weight axes): `nib.tape`, `nib.bead` (Assistant), `nib.pen.fountain`, `nib.pen.ball`, `nib.pen.brush`.

| Tool / action | Symbol | Tool / action | Symbol |
|---|---|---|---|
| Pen | `pencil.tip` (types: `nib.pen.*`) | Undo / Redo | `arrow.uturn.backward` / `arrow.uturn.forward` |
| Pencil | `pencil` | Record audio | `mic` (recording: cinnabar dot) |
| Highlighter | `highlighter` | Assistant | `nib.bead` (fallback `smallcircle.filled.circle`) |
| Eraser | `eraser` (stroke eraser `eraser.line.dashed`) | Share / export | `square.and.arrow.up` |
| Lasso | `lasso` | More | `ellipsis` |
| Shapes | `square.on.circle` | Search / command | `magnifyingglass` / `command` |
| Tape | `nib.tape` | Page sidebar | `sidebar.left` |
| Text | `character.textbox` | Page grid | `square.grid.2x2` |
| Image / Camera | `photo` / `camera` | Bookmark / Outline | `bookmark` / `list.bullet.indent` |
| Elements (stickers) | `star.square.on.square` | Add page | `doc.badge.plus` |
| Sticky note | `note.text` | Layers | `square.3.layers.3d` |
| Comment | `text.bubble` | Convert handwriting | `text.viewfinder` |
| Laser pointer | `laser.burst` | Math / graph | `function` / `chart.xyaxis.line` |
| Ruler | `ruler` | Link | `link` |
| Zoom window | `rectangle.and.text.magnifyingglass` | Eyedropper | `eyedropper` |
| Hand (pan) | `hand.raised` | Read-only | `eye` |
| New / New folder | `plus` / `folder.badge.plus` | All notes / Recents | `books.vertical` / `clock` |
| Favourites / Shared / Trash | `star` / `person.2` / `trash` | Folder | `folder` |
| Import / Scan | `square.and.arrow.down` / `doc.viewfinder` | PDF / Text doc | `doc.richtext` / `doc.text` |
| Study set / Whiteboard | `rectangle.on.rectangle.angled` / `scribble.variable` | Presentation | `play.rectangle` (external `tv`) |
| Timer | `timer` | Lock | `lock` |
| Collaborate / Live cursor | `person.crop.circle.badge.plus` / `cursorarrow` | Bridge (MCP) | `antenna.radiowaves.left.and.right` |
| Sync ok / error | `checkmark.icloud` / `exclamationmark.icloud` | Plugins / Settings | `puzzlepiece.extension` / `gearshape` |
| Accept / Discard | `checkmark` / `xmark` | Keyboard shortcuts | `keyboard` |

Plugin tools use the plugin's declared symbol (validated against SF Symbols or a monochrome template image) plus a 5 pt `text3` dot at top-right. Emoji are never icons.

## 12. Motion outside the droplets

| Interaction | Motion |
|---|---|
| Button press | squash `scaleX 1.04 / scaleY 0.94`, press 90 ms ease-out, release on `wobble` |
| Colour/state changes | 120–150 ms, no delay, `cubic-bezier(.23,1,.32,1)` |
| Toast | 180 ms fade + 16 pt rise; exit 130 ms |
| Sheet | system |
| Tooltip / key hints | 100 ms fade after 500 ms hover; instant for the next one; holding ⌘ shows all at once |
| Study card flip | `rotateY` on 0.36 / 0.86; Reduce Motion: 150 ms crossfade |

**Never animates:** keyboard-initiated actions (tool keys, ⌘K open, ⌘Z), ink, zoom/pan, page turns in continuous scroll, search-as-you-type filtering, undo/redo content changes, anything at rest.

## 13. Screens

Device classes: **iPad landscape** (1194 × 834 on 11″), **iPad portrait and wide split** (834 wide, or split ≥ 700 pt), **compact** (split < 700 pt, Slide Over, iPhone 393 × 852).

### 13.1 Library
- **iPad landscape:** status 24; docked sidebar 272 (`surface1`): wordmark + New folder + Hide sidebar (44 row), search field 36 (`⌘F` hint), sections *Library* (All notes, Recents, Favourites, Shared with cinnabar unseen dot, Trash) and *Folders*, footer Plugins, Settings, sync line (6 pt `ok` dot + "Synced to iCloud Drive › Nib"). Content: 44 pt bar (breadcrumb; grid/list, sort, Select, Scan, **New** quicksilver `⌘N`), `display` title with item count, bead filter (All · Notebooks · PDFs · Study sets · Whiteboards with counts in mono), 5-column cover grid. Covers are flat bookcloth colours with a spine gradient, never gradients for flavour; PDFs and cover-less notebooks show their first page.
- **Drag:** card lifts (E3, 1.045) into a smoked droplet skin, stretches with speed, condenses to 50% over the sidebar, reaches for folders and cards (§9.4), springs home otherwise. Page thumbnails reorder the same way in the page sidebar.
- **iPad portrait / split ≥ 700:** sidebar becomes an overlay (edge swipe, `⌘⇧S`); 4 columns, margins 24.
- **Compact:** large title, filter bead scrolls horizontally, folders as a list section above a 2-column grid, `+` in the nav bar; bottom tab bar (Library · Search · Shared) uses system material.

### 13.2 Document editor
- **Top bar (docked, 44, `surface1`):** back to folder, page sidebar toggle, document tabs (13 pt, active `surface3`), centred command field "Search or run a command `⌘K`" (hidden < 900 pt), then Undo, Redo | Record, Assistant, Share, More.
- **Tool palette (droplet):** vertical capsule 52 wide, grip 22, 44 pt slots: Pen, Highlighter, Eraser, Lasso, Shapes, Tape, Text, Image, Elements, Laser, then plugin tools; separator; 3 quick colours of the current tool (20 pt droplets). Docks left or right 16 pt from the edge (landscape default: left, vertically centred), thrown between edges with §9.3. Portrait default: horizontal at the bottom, 16 pt above the home indicator; throwing it to a side edge collapses it to a 52 pt droplet in flight and re-forms it vertically on landing.
- **Pen settings (bud-off, 284 wide):** title + key, pen type bead segmented (Fountain · Ball · Brush · Pencil), 12 swatches (6 × 2, 28 pt) + eyedropper, 5 width presets (0.4, 0.6, 0.8, 1.2, 1.6 mm), Pressure and Stabilisation sliders (quicksilver thumbs), "Draw and hold to snap shapes", footer hints in mono (`⇧P` next pen, `[ ]` width, `1–9` colour). Tip sharpness, flatness and Dynamic Ink sit behind "More". Buds toward the page side of the palette.
- **Page navigator:** page chip droplet bottom-right (`3 / 14 · 104%`, mono); tap buds a vertical scrubber of thumbnails on the right edge; the full page sidebar (`⌘⌥1`) docks left at 220 with 150 pt thumbnails, bookmarks and outline tabs.
- **Zoom window:** docked bottom panel at 30% height (solid, it is a workspace, not a droplet); the zoom box on the page is a 1.5 pt cinnabar rectangle with a quicksilver resize bead; return-line control at its right edge.
- **Selection (lasso):** cinnabar 1.5 pt marching outline, quicksilver handle beads (12 pt visual, 44 pt target), rotation bead above; the object menu buds as a horizontal droplet from the selection's top edge.
- **Compact:** bar 44 with two-line title (name + `p. 3 of 14` mono), Undo, Assistant, More; palette is a bottom capsule (5 tools + More + colour); pen settings bud upward into a 60%-height droplet sheet.

### 13.3 New notebook and templates
- **iPad:** form sheet 720 × 620 (solid). Left 280: live preview of cover + first page. Right: title field (New York 17), cover row (90 × 120 covers), paper grid (3 columns, 120 × 160: Blank, Dot 5 mm, Ruled narrow, Ruled wide, Grid 5 mm, Cornell, plugin templates marked with the plugin dot), paper colour chips (6), size (A4, Letter, Nib Standard) and orientation. Selection = 2 pt quicksilver ring with 2 pt gap. **Create** quicksilver bottom-right (`⌘⏎`). `⌘⇧N` QuickNote skips the sheet with last-used settings.
- **Compact:** full-height sheet with three segments (Cover · Paper · Details), Create in the nav bar.

### 13.4 Search
- **iPad:** `⌘F` opens a 640-wide droplet from the sidebar search (Library) or the command field (Editor), top-centred at y 76. Scope bead (This notebook · Library). Results grouped: Titles, Typed text, Handwriting (thumbnail with the matched word underlined in cinnabar on the ink), PDF text, Audio transcripts (timestamp mono). `↑ ↓ ⏎`. In a document, hits are cinnabar rings on the page and a HUD chip "3 of 12 ‹ ›" docks bottom-centre.
- **Compact:** Search tab, full screen, same grouping.

### 13.5 Settings
System split view (sidebar 320, inset-grouped detail), solid only, rows 44. Sections: General, Pencil & touch, Writing aids, Documents & templates, Library location & sync, Backup, Assistant (providers), Bridge (MCP), Plugins, Security, Accessibility, About & parity notes. Keys are secure fields that never echo; "Test connection" is a quicksilver button with a mono status line (`200 OK · 412 ms`). Destructive rows use `danger` text with a glyph and a confirmation sheet.

### 13.6 Assistant (not a chat)
- **iPad landscape (docked, 360):** header (title, Ask | Edit, close), **context bar** (model and whose key, in mono; "Reading" tokens: Page 3, Handwriting, Page image, each removable), **log** anchored to the bottom, **composer** (quick actions Summarise, Quiz me, Convert to text, Explain; field; attach selection; quicksilver send; `⌘⏎`).
- Turns are **blocks, not bubbles:** a mono label (`You 09:41`, `Assistant 09:41 · 4 s`), plain text, tool activity as collapsed mono lines ("Read page 3 · 214 words recognised").
- **Change sets** are the unit of trust: numbered changes (cinnabar number beads) with an include checkbox (quicksilver), title, kind and location; hovering a row highlights its region on the page; "Preview on page" toggle; footer "One undo step · Discard · **Accept N** `⏎`".
- **On the page:** proposals are ghost ink at 42% in the user's current pen, synthesised in their handwriting, inside 1.5 pt dashed cinnabar outlines with the same numbers. The **proposal chip** (droplet) is tethered to its anchor (§9.4): "3 changes · Assistant · p. 3 · Discard · Accept". While streaming, ghost ink writes itself at pen speed.
- **After Accept:** ghosts become ink, outlines dissolve, the chip absorbs into its anchor, the change set becomes a receipt ("Applied 2 changes · Undo ⌘Z · Show"). Undo reverts the whole turn even after later edits (records changed since are skipped and listed). AI-made items carry provenance ("Made by Assistant · 09:41" in the object menu).
- **Confirmations:** destructive or sensitive commands appear inside the change set as a `danger` row that requires its own explicit button ("Delete 4 items"); Accept never covers them.
- **Modes:** Sidebar (docked), Floating (a 380 × 560 droplet that can be thrown to either side), Window (separate scene). Portrait defaults to Floating; compact uses a medium/large-detent sheet and docks the chip above the palette.
- **External bridge:** when Claude Code or another agent drives Nib over MCP, the same change sets appear, labelled with the agent's name, and the nav shows a `bridge` status pill.

### 13.7 Plugin manager and plugin panels
- **Manager (sheet 760 × 640):** left list 300 (plugin symbol tinted `text2`, name, version mono, enable toggle), right detail: description, **permissions as plain sentences with scope chips** ("Read every document", "Change pages"), contributions (tools, panels, menus, commands, AI actions), Update (quicksilver), Disable, Remove (`danger`). Gallery tab lists index entries with Install. Install and update show a **permission diff** consent sheet (added permissions in `warn`).
- **Panels:** HTML panels live in a Nib-owned droplet (floating 320 × 480) or stack in the right sidebar with the Assistant. Nib draws the header (plugin name + `plugin` mono tag + menu); the plugin draws only inside. Nib injects the tokens as CSS variables (`--nib-surface1`, `--nib-text1`, `--nib-accent`, `--nib-font-ui`, …) so panels match. Plugin tool options are declared and rendered by Nib, so they cannot look foreign.

### 13.8 Study sets
- **Editor:** two columns (Term | Definition) in New York 17, image slots, keyboard `⇥` between fields, `⌘⏎` new card.
- **Practice / Smart Learn:** one card centred on `surface1`, `cardFace` type, flip on `Space`; grading row of 4 capsules (Again, Hard, Good, Easy) with `1–4`; progress as `12 / 48` mono plus a 2 pt quicksilver thread. Compact: full-screen card, swipe to grade.

### 13.9 Presentation mode
External display shows only the page (no chrome) on black. On the iPad a presenter HUD droplet docks bottom-centre: previous/next, laser toggle, timer (mono), "Mirroring to …". Laser: 12 pt cinnabar dot (colour choosable) with a 600 ms fading trail. Chrome on the iPad keeps receding while drawing.

### 13.10 Empty states
No illustrations. A single 40 pt quicksilver bead resting on a hairline, `title` headline, one sentence in `text2`, one quicksilver action, one text action.
- Library: "No notebooks yet" / "Create one, or import PDFs and Goodnotes exports." [New notebook `⌘N`] [Import]
- Search: "No matches for “vectr”" / "Handwriting is searched too. Try the whole library." [Search library]
- Assistant without a provider: "Bring your own model" / "Add a provider in Settings. Keys stay on this device." [Add provider]
- Plugins: "No plugins installed" / "Plugins add tools, panels and templates." [Browse gallery]

### 13.11 Onboarding (three steps, skippable, Pencil-first)
1. **Write.** A blank page; the palette buds in; "Write your name." (teaches zero-latency ink and receding chrome).
2. **Move things.** "Throw the palette to the other side." (teaches the droplet physics once, then never explains it again).
3. **Choose where your library lives.** Files folder picker (iCloud Drive, OneDrive, Dropbox, WebDAV), then an optional "Bring your own AI" row.
Each step: `display` title, `body` text in `text2`, one quicksilver Continue. No carousels.

### 13.12 Command bar (`⌘K`)
Every registered command (built-in, plugin, AI action) in one list: 560 wide droplet from the command field, fuzzy search, recent first, shortcut on the right in mono, `⏎` runs, `⇥` fills arguments. Opens instantly from the keyboard; buds only when tapped.

## 14. Keyboard map (power users)

Tools `P H E L S U T I M K` (+ plugin keys), `⇧P` next pen type, `[ ]` width, `1–9 0 - =` colours, hold `Space` to pan, hold `⌘` to show every shortcut on screen, `⌘K` commands, `⌘J` Assistant, `⌘⏎` accept proposal, `⎋` discard, `⌘F` search, `⌘⇧S` sidebar, `⌘⌥1` page sidebar, `⌘1–9` tabs, `⌘N` new, `⌘⇧N` QuickNote.

## 15. The code design system agents must use

Features may only import `NibContracts`, so the design system lives at **`NibKit/Sources/NibContracts/UI/Design/`** (proposal; ARCHITECTURE.md owns the final placement):

```
Design/
  Tokens.swift        NibColor (dynamic), NibInk, NibHighlighter, NibPaper, NibFont, NibSpace, NibRadius, NibElevation
  Motion.swift        NibMotion.settle / wobble / beadLead / beadTrail / bud / absorb / tether / cardHome
                      (SwiftUI Animation + UIKit UISpringTimingParameters + raw (k, c) for the droplet integrator)
  Haptics.swift       NibHaptic.plip / split / snap / select / success / canvasAlign
  Icons.swift         enum NibIcon: every symbol in §11 (the only allowed `Image(systemName:)` call site)
  Droplet/
    DropletField.swift     one CAMetalLayer per scene: SDF union (smooth-min k 11.5), ligaments, rim lens, specular
    Droplet.swift          UIKit/SwiftUI host: position springs, strain tensor, throw + dock, receding
    Bead.swift             quicksilver bead + BeadSegmentedControl
    BudPopover.swift       bud-off presentation for any anchored panel
    Tether.swift           anchored chip with neck / split / re-merge
  Components/
    NibButton(.quicksilver | .ghost | .danger), NibIconButton, NibToggle, NibSlider (bead thumb),
    NibRow, NibSidebarList, NibField, NibChip, NibToast, NibEmptyState, KeyHint, NibSheet
```

Refraction on the canvas samples the canvas renderer's current frame texture (NibRender), so it costs one extra texture read and needs no screen capture; elsewhere the field composites over a `UIVisualEffectView` frost.

**Enforcement** (add to `Scripts/lint.py`, fail CI on any hit in feature modules):
- No colour literals: `Color(red:`, `UIColor(red:`, `Color(hex`, `#colorLiteral`, `.opacity(` on raw colours.
- No font literals: `.font(.system(size:`, `Font.custom(`, `UIFont.systemFont(ofSize:`.
- No layout literals outside `NibSpace` / `NibRadius`: `.padding(<number>)`, `.cornerRadius(<number>)`, `cornerRadius =`.
- No animation literals outside `NibMotion`: `.spring(`, `withAnimation(.easeInOut`, `UIView.animate(withDuration:`.
- No haptic generators outside `NibHaptic`; no `Image(systemName:` outside `NibIcon`; no `.ultraThinMaterial` / `UIBlurEffect` outside `DropletField` and `NibSheet`.
- Every new screen adds a snapshot to the design catalogue test (light, dark, AX3, Reduce Transparency) before review.

**Review checklist (the gate):** uses only tokens; one accent use per purpose; no droplet on docked or scrolling content; nothing animates on keyboard input; ink path untouched; 44 pt targets; Reduce Motion and Reduce Transparency verified; copy has no em dashes, no "seamless/elevate/unleash", buttons say verb + object.

## 16. Accessibility
- Contrast as listed in §3; state is never colour alone (bead + glyph colour + VoiceOver trait `.selected`).
- VoiceOver: palette is a `UIAccessibilityContainer` of buttons with values ("Pen, selected, Carbon, 0.8 millimetres"); proposal chip exposes Accept/Discard as custom actions; ghost ink regions are announced as "Proposed change 1 of 3: add equation".
- Full Keyboard Access reaches every droplet; focus ring is 2 pt cinnabar outside the droplet (never inside the union, which would swallow it).
- Pointer: hover lifts droplets 1 pt (E2 → E2+) and shows key hints after 500 ms.
- Dynamic Type to AX5; Bold Text maps Regular → Semibold; Increase Contrast raises `line` to 0.16 and rims to 0.35.
