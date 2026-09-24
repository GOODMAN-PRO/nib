# Nib · Direction B · Ink Drop

> Clear water floating over calibrated paper. Pen colours are beads of ink. One accent: Blue-Black.
> Everything that floats is a droplet: it stretches when flung, wobbles when it lands, fuses with a
> neighbour and pinches apart when pulled. The page never moves, never blurs, never waits.

Interactive mockup: `design/direction-b.html` (open in Chrome for refraction; every browser gets the physics).
Review helpers in the mockup: `?only=editor|library|ai|phone`, `?theme=light|dark`, the Reduce Motion / Reduce Transparency switches in the header.

---

## 1. Principles

1. **Paper is warm, water is clear, the interface is neither.** The page carries all the warmth (Ivory paper, real inks). UI neutrals are a cool graphite, tinted a whisper toward the accent hue. Chrome is clear water. Three materials, never mixed.
2. **The canvas is sacred.** No liquid shader, blur, refraction or animation ever touches ink while the pencil is down. Chrome near the pen recedes to 32% opacity; the liquid layer freezes. Wet ink is drawn at display rate with prediction, untouched by the design system.
3. **Physically believable water, not jelly.** Surface tension wobble is quick and small (4.2 Hz, ζ 0.32, about 1.5 visible cycles). Long chrome deforms only along its own axes. Position springs are near critically damped. If it reads as a toy, the numbers are wrong.
4. **Motion explains space.** Popovers bud from the control that owns them and are reabsorbed into it. Selection glides. Files flow into folders. Nothing appears from nowhere and nothing animates only to decorate. No idle motion anywhere.
5. **One accent, used for intent.** Blue-Black marks what the user can commit (primary buttons, selection, the assistant's proposals). Ink colours belong to the user's content and never become UI colour.
6. **Editorial type.** New York for titles, covers and anything that is "the user's world"; SF Pro for the interface; SF Rounded for numbers that live on droplets.
7. **The assistant is an editor with a pencil, not a chat.** It shows what it read, what it will change, marks the page like a proofreader, and changes nothing until accepted. One turn is one undo step.
8. **Dignified fallbacks.** Reduce Motion: things are simply where they belong, crossfades only. Reduce Transparency: same silhouettes, opaque surfaces, hairline edges. Increase Contrast: rims and hairlines double, veils go to 92%.

---

## 2. Colour

All values are sRGB hex, derived in OKLCH (listed where it matters). Light / Dark. Contrast ratios are measured against the surface named.

### 2.1 UI neutrals (graphite, hue 255–258)

| Token | Light | Dark | Used for |
|---|---|---|---|
| `desk` | `#EEF0F3` | `#0F1113` | editor surround, library sidebar, anything the paper sits on |
| `base` | `#F5F7F9` | `#0A0B0E` | library content area, settings grouped background |
| `raised` | `#FDFDFE` | `#191C20` | list groups, cards, sheets, the opaque droplet fallback |
| `sunken` | `#E4E6E9` | `#15171A` | search fields, inset wells |
| `fill` | `#DBDEE2` | `#26292D` | switch-off track, segmented control well |
| `text1` | `#181C21` | `#EDEEF1` | primary text and glyphs (16.8:1 on raised) |
| `text2` | `#535860` | `#A7ABB1` | secondary text (7.0:1 light, 7.4:1 dark on raised) |
| `text3` | `#686C73` | `#8A8E94` | tertiary, placeholders (5.2:1 light on raised; never below 4.5:1) |
| `line` | `rgba(24,28,33,.10)` | `rgba(237,238,241,.09)` | hairlines, row separators (0.5 pt) |
| `line2` | `rgba(24,28,33,.16)` | `rgba(237,238,241,.15)` | control outlines, chip borders |

### 2.2 Accent: Blue-Black (the house ink)

| Token | Light | Dark | Notes |
|---|---|---|---|
| `accent` | `#284F88` oklch(.43 .105 258) | `#87B5E9` oklch(.76 .09 252) | primary buttons, selection, links, focus ring, proposal marks |
| `accentPress` | `#1A3F73` | `#75A2D5` | pressed state |
| `accentWash` | `#DCE9FC` | `#1C293D` | selected sidebar row, active toolbar button, inserted-text wash |
| `onAccent` | `#FFFFFF` | `#0A0B0E` | label on accent fills (8.2:1 light, 9.2:1 dark) |

Accent on `raised`: 8.1:1. The accent is never used for decoration, gradients or illustration.

### 2.3 Semantic

| Token | Light | Dark | Use |
|---|---|---|---|
| `success` | `#2B7440` | `#6FC082` | sync OK dot, check marks in the assistant log, "Applied" |
| `warning` (text) | `#975800` | `#EBB25F` | quota, recognition pending |
| `warningFill` | `#C68206` | `#EBB25F` | badges only |
| `danger` | `#C52C26` | `#F2716A` | destructive verbs, deleted text in diffs, errors |
| `laser` | `#E5484D` | `#E5484D` | laser pointer dot/trail only |

AI has no colour of its own (no purple, no sparkle). AI-authored items carry provenance (`createdBy = ai:<chat>`), shown as a small `drop` glyph in the object menu, never as a tint.

### 2.4 Droplet material (fed to the liquid layer)

| Token | Light | Dark | Role |
|---|---|---|---|
| `drop.tint` | white 16% | white 7% | the body of clear water |
| `drop.rim` | `#1E2632` 40% of edge band | white 26% of edge band | refraction edge (dark rim light, lit rim dark) |
| `drop.specular` | white 95% | white 70% | crest along the lit (top-left) edge |
| `drop.caustic` | white 40% | white 18% | soft crescent inside the far (bottom-right) edge |
| `drop.shadow` | `#18202B` 17% | black 55% | contact shadow, clipped outside the silhouette |
| `veil.clear` | white 14% | `#16181C` 56% | legibility veil behind glyphs on clear droplets |
| `veil.dense` | `#FDFDFE` 66% | `#181B1F` 80% | popovers, panels, anything with paragraphs |

### 2.5 The twelve inks

Default palette for pen, pencil, shapes and text. Right column is the automatic mirror used when the paper is dark (paper luminance < 0.2): same hue, lightness mirrored. Contrast is against Ivory paper; every ink clears the 3:1 graphical-object bar.

| # | Name | On light paper | On dark paper | vs Ivory |
|---|---|---|---|---|
| 1 | Carbon | `#181818` | `#E8E8E8` | 16.6 |
| 2 | Graphite | `#565B62` | `#A7ABB1` | 6.4 |
| 3 | **Blue-Black** (default pen) | `#253C67` | `#9CB9E5` | 10.2 |
| 4 | Ultramarine | `#2858CD` | `#7FAEFF` | 5.8 |
| 5 | Cerulean | `#008BC2` | `#8ADCFF` | 3.6 |
| 6 | Teal | `#00847E` | `#81D2CC` | 4.3 |
| 7 | Viridian | `#287C42` | `#8AC997` | 4.9 |
| 8 | Ochre | `#B17514` | `#FFDF90` | 3.6 |
| 9 | Vermilion | `#DB5612` | `#FFB68A` | 3.7 |
| 10 | Carmine | `#BE222A` | `#FF8D85` | 5.7 |
| 11 | Rose | `#BC3E79` | `#FF9EC8` | 4.8 |
| 12 | Violet | `#6C44A4` | `#B699EB` | 6.6 |

Default quick inks on the palette: Blue-Black, Carmine, Ultramarine. Pencil default: Graphite. (This replaces the 3-swatch defaults in `NibContracts` `ToolPresets` via a contract request; contract `RGBA.black #1A1A1A` stays as the legacy black.)

**Highlighters** (drawn beneath ink, multiply blend, 60% opacity): Citron `#F9ED52` (default), Mint `#97F3B8`, Sky `#95DBFF`, Blush `#FFB2C5`, Apricot `#FFC585`, Lilac `#D3BEFD`.

**Other content colours:** sticky note `#FFE87C`, tape `#F4C430` (contract defaults, kept), laser `#E5484D`.

### 2.6 Paper and templates

| Paper | Hex | Notes |
|---|---|---|
| White | `#FEFDFC` | a calibrated white, not screen white |
| **Ivory** (default) | `#FBF7EF` | oklch(.978 .012 85) |
| Cream | `#F9EED9` | Tomoe-like |
| Mist | `#EFF3F6` | cool |
| Sage | `#E9F4E9` | |
| Slate (dark) | `#24272A` | inks switch to their dark mirrors |
| Night (dark) | `#121417` | presentation and dark whiteboards |

Template lines on light paper: ruled `#AAC1D2` at 75%, 0.75 pt; dot grid `#B3B8BE`, 1.2 pt dots; grid `#AAC1D2` at 55%; margin line `#E59B94`. On dark paper: ruled `#444F57`, dots `#51565B`, margin `#8B504C`. Pages keep their paper colour in dark mode; only the desk and chrome change.

### 2.7 Cover cloths

Forest `#1C4732`, Oxblood `#612326`, Navy `#213459`, Graphite `#2B2E33`, Ochre `#B38236`, Clay `#A15D3E`, Teal `#1B575A`, Plum `#512F4F`, Stone `#D5D0C6`, Linen `#F4F0E6`. Cover text: Linen `#F4F0E6` on dark cloth, Graphite `#2B2E33` on light cloth. Three cover templates: **Classic** (title top-left, 22-pt rule, code at the foot), **Label** (a Linen paper label with the title, centred), **Dots** (Classic on a 9-pt dot weave). Covers get one top-lit gradient (white 8% → black 10%) and a spine shade; no other gradients exist in the product.

---

## 3. Typography

System families only: **SF Pro** (Text/Display chosen automatically), **New York** (`.serif`), **SF Rounded** (`.rounded`), **SF Mono** (`.monospaced`). Never set tracking on SF; the system applies optical tracking per size. Weights used: Regular, Medium (covers), Semibold (titles, headlines, buttons), Bold only in numeric badges. No Light/Thin.

| Role | Family, weight | Size / leading (pt) | Dynamic Type style | Where |
|---|---|---|---|---|
| Display | New York Semibold | 34 / 41 | `.largeTitle` | library title, onboarding |
| Title 1 | New York Semibold | 28 / 34 | `.title` | sheet titles, empty states, study card prompt |
| Title 2 | New York Semibold | 22 / 28 | `.title2` | panel empty states, section openers |
| Document title | New York Semibold | 17 / 21 | `.headline` (serif) | editor nav bar title |
| Cover title | New York Medium | 20 / 22, tracking −0.2 | scales with cover size, not DT | notebook covers |
| Headline | SF Pro Semibold | 17 / 22 | `.headline` | popover titles, assistant header |
| Body | SF Pro Regular | 17 / 22 | `.body` | settings rows, lists |
| Callout | SF Pro Regular | 16 / 21 | `.callout` | sidebar rows, the assistant instruction |
| Subheadline | SF Pro Regular/Semibold | 15 / 20 | `.subheadline` | grid item titles, popover rows, buttons |
| Footnote | SF Pro Regular | 13 / 18 | `.footnote` | item meta, nav subtitles, log lines |
| Caption 1 | SF Pro Regular | 12 / 16 | `.caption` | fine print, model name |
| Caption 2 | SF Pro Semibold | 11 / 13 | `.caption2` | badges |
| Droplet numerals | SF Rounded Semibold, monospaced digits | 15 / 18 (chip), 13 / 16 (HUD) | `.subheadline` / `.footnote` | page chip, zoom HUD, thickness, counts |
| Code | SF Mono Regular | 13 / 18 | `.footnote` | plugin console, tool calls, JSON |
| Proposal marks | New York Italic Medium | 17 (margin), 22 (insertions) | page-relative (scales with zoom) | assistant marks on the page |

Dynamic Type: content (lists, settings, assistant, search, study) scales without cap. Floating chrome (palette, chips, HUDs) caps at `.xxxLarge`; at accessibility sizes the palette becomes two rows and glyphs grow to 28 pt. Line length in the assistant panel and documents is capped at 70 characters.

---

## 4. Spacing and layout grid

4-pt base. Scale: **2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64**. No other values.

- Screen margins: iPad regular 20 (library content 32), compact / iPhone 16.
- Library grid gutters: 26 × 22 (iPad landscape), 20 × 20 (portrait), 16 × 20 (iPhone).
- Droplet padding: palette 8 horizontal, chips 16 leading / 5 trailing around a capsule button, popovers 16, panels 18.
- **Resting separation between droplets ≥ 16 pt** (anything closer visibly necks). Droplet to screen edge ≥ 12 pt. Droplet to page edge: none required, droplets may float over the page.
- Touch targets ≥ 44 × 44 even when the glyph box is 40 × 44 (hit area extends into padding).

---

## 5. Radii (concentric)

| Token | pt | Use |
|---|---|---|
| `xs` | 4 | page thumbnails, PDF thumbs, cover spine side (3) |
| `s` | 8 | segmented thumb, small badges |
| `m` | 12 | text fields, search, thickness selection |
| `l` | 16 | folder trays, grouped lists |
| `card` | 18 | proposal card, library drag carrier |
| `popover` | 26 | popovers (pen settings, New menu) |
| `panel` | 30 | floating panels (assistant, plugin panels, page navigator) |
| `capsule` | h/2 | every bar, chip, button, HUD, the palette |

Covers: 3 on the spine side, 9 on the fore-edge. Concentric rule: inner radius = outer radius − inset (panel 30 − 12 → 18 for the proposal card; popover 26 − 16 → 10 for the segmented well). A droplet that is scaled below 20% of its size becomes a circle (§10.9).

---

## 6. Materials and where glass is allowed

Four materials. Nothing else may blur or tint.

| Material | Recipe | Allowed on |
|---|---|---|
| **Droplet · Clear** | refraction lens on the outer 18 pt, 5 pt blur (4 with refraction), saturation 1.7, brightness 1.04, `veil.clear`, water tint, rim, specular, caustic, contact shadow | tool palette, undo droplet, page chip, zoom HUD, AI chip, selection handles, drag carriers, toasts |
| **Droplet · Dense** | 24 pt blur, saturation 1.6, `veil.dense`, same rim/specular/shadow, no refraction | popovers, panels (assistant, plugins, navigator), menus, search overlay |
| **Ink bead** | opaque ink with a caustic brightening low (70% at 50%/82%), a crisp specular (white 78%), a 1.5 pt contact shadow | colour swatches, the selection bead's ink |
| **Opaque** | `raised` fill, 0.5 pt `line2` hairline | lists, settings, sheets, library cards, study cards, Reduce Transparency fallback for all of the above |

Rules
- Glass never sits on glass except during a merge (the union is one droplet).
- No droplet over text that the user is reading for more than a moment unless it is Dense.
- Structural surfaces (sidebar, nav bar, settings, lists) are never droplets. The nav bar sits on the desk with no hairline.
- iOS 26+: system bars and sheets adopt system Liquid Glass automatically; our canvas chrome keeps the Nib droplet engine on every OS so iOS 17–25 look identical.

---

## 7. Elevation and light

One light source: top-left (azimuth 225° in screen space, elevation ~55°). Every specular, shadow and caustic obeys it.

| Level | What | Shadow |
|---|---|---|
| 0 | page on desk | 0.5 pt `line`, 0 1 2 @6%, 0 12 28 −14 @28% |
| 1 | opaque groups | hairline only |
| 2 | resting droplet | water contact shadow: silhouette blur 7, y +5, `drop.shadow`, clipped outside |
| 3 | lifted droplet (dragging) | blur 14, y +12, 22%; body spreads to 102.5% (6% under 80 pt) |
| 4 | system sheets | system |

---

## 8. Iconography

SF Symbols, `.regular` weight, 17-pt body scale in bars (glyph box 24), `.semibold` in chips. Writing tools use a two-layer palette rendering: outline in `text1`, tip filled with the current ink (so the palette shows your inks). `sparkles`, `wand.and.stars` and emoji are banned by lint. Custom symbols (exported as SF Symbol templates) are prefixed `nib.`.

| Tool / action | Symbol |
|---|---|
| Lasso | `lasso` |
| Fountain pen | `nib.fountainpen` (custom; fallback `pencil.tip`) |
| Ball pen | `pencil.tip` |
| Brush pen | `paintbrush.pointed` |
| Pencil | `pencil` |
| Highlighter | `highlighter` |
| Eraser / stroke eraser | `eraser` / `eraser.line.dashed` |
| Shapes | `square.on.circle` |
| Text | `textformat` |
| Image / camera | `photo` / `camera` |
| Tape | `nib.tape` (custom; fallback `rectangle.dashed`) |
| Elements (stickers) | `nib.sticker` (custom peeled-corner square; fallback `note`) |
| Laser pointer | `laser.burst` |
| Ruler | `ruler` |
| Zoom window | `nib.zoomwindow` (custom; fallback `plus.magnifyingglass`) |
| Sticky note / comment | `note.text` / `text.bubble` |
| Math | `function` |
| Audio record / playback | `record.circle` / `waveform` |
| Undo / redo | `arrow.uturn.backward` / `arrow.uturn.forward` |
| Back | `chevron.backward` |
| Page navigator | `sidebar.left` |
| Search | `magnifyingglass` |
| Bookmark | `bookmark` / `bookmark.fill` |
| Share / export | `square.and.arrow.up` |
| More | `ellipsis.circle` |
| New | `plus` |
| Add page | `doc.badge.plus` |
| Pages / outline | `rectangle.portrait.on.rectangle.portrait` / `list.bullet.indent` |
| Present | `play.rectangle` (external display `airplayvideo`) |
| Assistant | `nib.drop` (custom drop with a nib cut; fallback `drop`) |
| Send / stop / dictate | `arrow.up` / `stop.fill` / `mic` |
| Attach selection | `lasso` |
| Preview marks on page | `eye` |
| Accept / discard | `checkmark` / `xmark` |
| History (who changed what) | `clock.arrow.circlepath` |
| Library: all / favourites / shared | `doc` / `star` / `person.2` |
| Study sets / practice / timer | `rectangle.stack` / `rectangle.stack.badge.play` / `timer` |
| Whiteboards / text documents / PDF | `rectangle.and.pencil.and.ellipsis` / `doc.text` / `doc.richtext` |
| Folder / move / duplicate / rename | `folder` / `folder.badge.plus` / `plus.square.on.square` / `pencil.line` |
| Lock / password | `lock` / `lock.doc` |
| Trash | `trash` |
| Sync / WebDAV | `icloud` / `externaldrive.connected.to.line.below` |
| Plugins | `puzzlepiece.extension` |
| External AI bridge | `antenna.radiowaves.left.and.right` |
| Collaboration / live cursor | `person.2` / `cursorarrow.rays` |
| Settings | `gearshape` |
| Grid / list / sort / filter | `square.grid.2x2` / `list.bullet` / `arrow.up.arrow.down` / `line.3.horizontal.decrease` |
| Import | `square.and.arrow.down` |

---

## 9. Motion

All motion is springs (`Spring(response:dampingRatio:)` in SwiftUI, `UISpringTimingParameters(dampingRatio:)` + duration = response in UIKit). Durations are never hand-written outside `NibMotion`.

| Token | Response (s) | ζ | Used for |
|---|---|---|---|
| `tap` | 0.18 | 0.90 | press scale 0.97 on buttons (release faster than press) |
| `snap` | 0.34 | 0.72 | selection changes, segmented thumbs, the selection bead |
| `settle` | 0.42 | 0.78 | a released droplet travelling to rest |
| `surface` | 0.24 | 0.32 | droplet deformation (stretch, wobble) |
| `bud.position` / `bud.size` | 0.44 / 0.40 | 0.74 / 0.62 | popover or panel budding from its control |
| `reabsorb` | 0.30 | 0.92 | popover folding back into its control |
| `film` | 0.36 | 0.62 | folder water films appearing |
| `evaporate` | 0.30 | 1.0 | films, toasts leaving |
| `reflow` | 0.46 s curve (0.32, 0.72, 0, 1) | — | grid items closing a gap (FLIP), page thumbnails parting |
| content fade in / out | 0.18 s ease-out after 0.13 s / 0.09 s linear | — | text inside a budding droplet |

**Never animates:** wet ink (drawn at display rate, no easing); page scroll, zoom and page turns (system deceleration, direct manipulation); anything triggered from the keyboard or Apple Pencil double-tap/squeeze (the bead jumps, haptic only); undo/redo results on the canvas; search results while typing; dark-mode switch; sync/progress beyond a plain determinate bar; any idle, ambient or "breathing" motion.

**Reduce Motion:** positions and sizes jump to their targets, no deformation, no wobble, no budding (popovers crossfade 150 ms), ink bloom becomes a 150 ms crossfade, list reflow is instant, the study-card flip becomes a crossfade.

---

## 10. Droplet physics

The same model drives every droplet. The mockup's JS engine implements these numbers verbatim; the Swift `LiquidLayer` ports them.

### 10.1 State per droplet
Centre `p`, velocity `v`, base size `w×h`, corner radius `r` (capsule = h/2), size scale `(sw, sh)` with its own spring, and a **stretch tensor** `S = s·(cos 2θ, sin 2θ)` stored in doubled-angle form so that travelling left and right stretch the same axis and a ring-out through zero becomes a squash on the perpendicular automatically.

### 10.2 Drag
- Follow the finger with a liquid lag: `p += (finger − p)(1 − e^(−42·dt))` (τ ≈ 24 ms). The grab offset is taken at touch-down, so the droplet catches up the 6-pt slop smoothly instead of jumping.
- Velocity is low-passed at rate 30/s.
- Drag starts after 6 pt of travel (pointer) or a 0.3 s long press (touch on library items). One finger drags; extra touches are ignored.

### 10.3 Stretch with velocity (volume preserving)
- Target amount `s* = cap · (1 − e^(−|v| / vRef))`, direction θ = velocity angle.
- Transform: `rotate(θ) · scale(1 + s, 1/(1 + s)) · rotate(−θ)`: area is preserved exactly.
- **Long chrome** (aspect > 3: palette, chips, toasts) deforms on its own axes only (no shear): `scale(1 + Sx, 1/(1 + Sx))`.
- Content inside a droplet follows 55% of the deformation (70% for dragged cards) so glyphs never smear.

| Droplet | cap | vRef (pt/s) |
|---|---|---|
| Tool palette (iPad / iPhone) | 0.06 / 0.07 | 900 |
| Undo droplet, page chip, AI chip | 0.12 | 900 |
| Library drag carrier | 0.09 | 1100 |
| Selection bead | 0.34 | 700 |
| Popovers | 0.03 | 900 |
| Panels | 0.02 | 900 |

### 10.4 Surface tension (wobble and settle)
- `S` springs to its target with response 0.24 s, ζ 0.32 (4.2 Hz). A sudden stop rings out: ~1.5 visible cycles, 95% settled in ≈ 0.45 s.
- Release: project the landing point with `v × 0.1 s` (UIKit-style deceleration 0.99), then `settle` spring (0.42, ζ 0.78). The slight overshoot plus the surface ring-out is the landing wobble.
- Press: the droplet spreads under the finger to 102.5% (106% below 80 pt) on a 0.30 s / ζ 0.5 spring and recovers with a small wobble on release.
- Docking: the palette snaps to a dock (top or bottom centre) when the projected point is within 120 pt of it; the page chip snaps home within 90 pt; everything else rests where it lands, ≥ 12 pt from edges.

### 10.5 Merge
- **Visual union** is a smooth-min of the droplets' signed distance fields with `k = 12 pt` (Metal). In the HTML mockup the same union is an SVG metaball: Gaussian blur σ 10 then alpha threshold at iso 0.30 (`30 −9`); blobs are inset 5.2 pt (σ·Φ⁻¹(0.7)) so the thresholded edge lands exactly on the true edge. Parallel edges bond at ≤ 10 pt; rounded ends at ≈ 6 pt.
- **Logical merge** when the edge gap drops below **6 pt while either droplet is moving**. Both droplets get a stretch kick toward each other (`16 × cap` in tensor velocity), haptic **merge**.
- Droplets at rest never merge on their own (hence the 16-pt rest separation).

### 10.6 Neck and pinch-off (hysteresis)
While merged, a capsule bridge keeps the neck alive as the droplets separate:
- `T0 = min(0.62 × smaller dimension, 40 pt)`, `thread = 18.4 pt` (renders as a ~8 pt filament).
- `u = (gap − 6) / (SPLIT − 6)`, thickness `= thread + (T0 − thread)(1 − u)^0.8`.
- `SPLIT = min(24 + 0.3 × smaller dimension, 60) pt` (39.6 pt for a 52-pt palette and undo droplet; 33 pt for the chip and its 30-pt anchor).
- The neck pulls both surfaces: each droplet's stretch target gains `0.9 × cap × u` toward the partner (the stationary one leans).
- Past SPLIT the thread snaps in 50 ms, haptic **pinch**, and the tension release rings both droplets out (recoil wobble).
- Release while merged **fuses**: the dragged droplet slides along the contact axis until the edges overlap by 1 pt (and aligns if within 24 pt), leaving one droplet with a waist. Pull it again to pinch it apart.

### 10.7 Bud-off (popovers, menus, panels)
- The popover starts as a 40-pt droplet at the owning control, joined by a 34-pt bridge, with 260 pt/s initial velocity away from the palette.
- Position spring 0.44 / ζ 0.74, size spring 0.40 / ζ 0.62 (a soft swell, ~3% overshoot).
- The neck starts thinning at **150 ms** (response 0.11) and pinches at **≈ 250 ms**, haptic **bud**.
- Content fades in over 180 ms after a 130 ms delay, rising 6 pt, scale 0.98 → 1.
- Anchor: the popover's leading edge sits 56 pt before the owning tool's centre; it opens below a top-docked palette and above a bottom-docked one; 18 pt gap.
- **Reabsorb** (tap the tool again, tap the page, or start dragging the palette): content fades out in 90 ms; the droplet returns to the tool (0.30 / ζ 0.92) shrinking to 40 pt; it touches the palette at **150 ms** (haptic **merge**, bridge 30 pt) and is gone by **470 ms**.
- The assistant panel and page navigator bud the same way from their nav-bar buttons with a 0.46 / ζ 0.80 position spring.

### 10.8 The selection bead
- A 40-pt droplet of clear water under the selected tool, tinted by the current ink: radial ink at 30% low (settled ink), 11% mid, 20% at the rim, plus a white specular and an ink-tinted shadow.
- Glide between tools: `snap` spring (0.34, ζ 0.72); horizontal stretch cap 0.34 at vRef 700: it elongates like a bead running along glass and lands with a wobble.
- **It is a lens:** tools within 32 pt of the bead's centre swell up to 1.14× and rise 1.2 pt (smoothstep falloff), so the icon under the bead is magnified and neighbours swell as it passes.
- Drag the bead (grab the selected tool): follows at rate 50/s, rubber-bands past the ends (`3·√overshoot`), catches on each tool it crosses (haptic **detent** + a small squash kick), and on release snaps to the nearest tool (projected by `v × 0.08 s`).
- **Ink bleed:** choosing an ink swells its bead to 1.2× (420 ms, overshoot curve 0.34, 1.56, 0.64, 1) and the new ink diffuses into the selection bead from the side the swatch is on: a soft disc (10-pt feather) growing 0 → 78 pt over 560 ms (0.2, 0.7, 0.2, 1). Reduce Motion: 150 ms crossfade.

### 10.9 Scale and shape
- A droplet scaled below 20% of its size is a circle; between 20% and 100% its visual corner radius eases from `min(w,h)/2` back to `r`. Radii are applied in local space divided by the scale, so corners stay round under non-uniform scale.

### 10.10 Library drag
- Lift: the cover lifts into a carrier droplet (cover + 10-pt water margin, radius 18); the cover itself stays opaque and crisp.
- Every folder grows a water film (2% → 100%, `film` spring, 35 ms stagger): these are the drop targets.
- Bring the carrier within 6 pt of a folder's film: they fuse (haptic **merge**), the tray tint deepens to 16%.
- Release while fused: the carrier flows into the folder (0.34 / ζ 0.9) shrinking to 12%, the cover fades in 220 ms, the folder **gulps** (size velocity +1.6 / −1.2 → a visible wobble), haptic **drop**, films evaporate after 260 ms, remaining items close the gap (reflow), toast buds up with Undo.
- Release elsewhere: the carrier settles back into its slot (0.42 / ζ 0.74) and films evaporate.

### 10.11 Assistant chip
- The chip (`N edits · Accept · ✕`) is fused to a 30-pt anchor bead pinned at the edited region. Pull it: the neck stretches to a thread and pinches at 33 pt (haptic **pinch**); release anywhere and it springs home (0.50 / ζ 0.72) and re-fuses (haptic **merge**). Brought near the panel it fuses with the panel too.

### 10.12 Refraction and light
- **Lens:** only the outer 18 pt (never more than the corner radius) bends. The displacement profile is `t^2.2` from 0 at 18 pt inside to 1 at the rim, pointing inward (magnification at the meniscus), max offset 0.9 × 18 ≈ 16 pt. The interior is undistorted, so glyphs never ghost.
- **Specular crest:** silhouette minus its blur (σ 3.2) offset (+2.2, +3.2) toward the far side = a crescent on the lit edge; gamma 1.5; white 95% (light) / 70% (dark).
- **Rim:** silhouette minus blur (σ 2.2) = inner edge band; 40% of `drop.rim`.
- **Caustic:** the same crescent on the far (bottom-right) inner edge at 40% / 18%.
- **Contact shadow:** blur 7, +5 y, clipped outside the silhouette so the water stays clear.
- Metal port: refraction samples the canvas renderer's committed tile texture (never wet ink); the normal comes from the SDF gradient with a circular meniscus height profile over the rim width; Blinn-Phong exponent 60.

### 10.13 Haptic events

| Event | UIKit | Intensity |
|---|---|---|
| lift (drag begins) | `UIImpactFeedbackGenerator(.light)` | 0.35 |
| merge (necks form, reabsorb touches) | `.soft` | 0.55 |
| pinch (thread snaps) | `.rigid` | 0.40 |
| bud (popover detaches) | `.soft` | 0.40 |
| snap (tool/dock/selection change) | `.light` | 0.60 |
| detent (bead crosses a tool, segment, thickness) | `UISelectionFeedbackGenerator` | — |
| drop (filed into folder, edits applied) | `UINotificationFeedbackGenerator(.success)` | — |
| warning (destructive confirm) | `.warning` | — |

Rate-limited to one per 60 ms. Suppressed while the pencil is down. Apple Pencil Pro gets `UICanvasFeedbackGenerator` (iOS 17.5+) for alignment and shape snaps only. The mockup shows each event in the "Haptics" pill above its frame.

### 10.14 Where liquid is NOT used
- The canvas: ink, pages, page shadows, selection outlines on the page, lasso path, shape handles on the page (these are crisp 1-pt accent outlines with 8-pt white knobs), rulers, the zoom-window writing area.
- While the pencil is down: the liquid layer freezes (no re-render); droplets within 120 pt of the pen fade to 32% in 160 ms and return 350 ms after lift over 500 ms. Refraction never samples wet ink.
- Structural UI: nav bars, sidebars, settings, lists, sheets, alerts, text fields, keyboards.
- Reading surfaces: study cards, documents, PDF text, the assistant's text (it lives on Dense, never Clear).
- Anything triggered from a keyboard shortcut or Pencil gesture (instant).
- Text documents' blocks, tables and handles (system text editing behaviour).

---

## 11. Layouts

Dimensions are for iPad Pro 11" (1194 × 834 landscape, 834 × 1194 portrait) and iPhone 393 × 852. Size classes drive the switch: regular width = iPad layout; compact width (iPhone, Slide Over, 1/3 split) = iPhone layout.

### 11.1 Library
- **iPad landscape:** sidebar 280 on `desk` (wordmark, All notes / Favourites / Shared / Study sets / Whiteboards, Folders with cloth dots, Plugins / Trash / Settings, sync line). Content on `base`, margins 32: large title New York 34 bottom-aligned in a 96-pt header; trailing search field 252, select, import, **New** (accent capsule; buds a menu: Notebook, Quick note, Whiteboard, Text document, Study set, Import PDF, Scan). Folder trays row (64 tall, 4 visible, scrolls horizontally), then "Recent" with a sort control and a 5-column grid (cover 149 × 199, meta: title Subheadline Semibold, footnote meta with cloth dot).
- **iPad portrait / 2/3 split:** sidebar becomes a Dense droplet that buds from the sidebar button (inset 12, radius 30); grid 4 columns; trays 3 visible.
- **1/2 split:** 3 columns, search collapses to a button.
- **iPhone:** large title with the system search field under it; trays as a horizontal scroller (2.5 visible); 2-column grid (cover 165 × 220, gutter 16); **New** is a 56-pt accent droplet bottom-trailing that buds its menu upward; selection mode puts its actions in a bottom droplet bar.
- Drag: notebook to folder tray or sidebar folder row (both show films), notebook onto notebook asks to merge (D-016), multi-select drags a stacked carrier (up to 3 covers fanned 4°).

### 11.2 Document editor
- **iPad landscape:** nav bar 50 on the desk (no hairline): leading page-navigator toggle and back; centre title (New York 17) with "Physics 9702 · page 3 of 12"; trailing Assistant, Search, Bookmark, Share, More. **Tool palette** droplet 576 × 52 docked top-centre 12 pt under the nav bar: Lasso, Pen, Pencil, Highlighter, Eraser, Shapes, Text, Image, Tape, Elements, Laser | three ink beads; plugin tools follow after a hairline; overflow collapses into `ellipsis` which buds a grid. **Undo droplet** 92 × 52 at the palette's leading side (they fuse if pushed together). **Page chip** 128 × 40 bottom-trailing (SF Rounded 15). **Zoom HUD** "125%" buds at top-centre during pinch and evaporates 0.6 s after. Page fit-width with at least 24 pt of desk each side.
- **Pen settings** (Dense popover 304 × 378): title + current width; Fountain / Ball / Brush segmented; five thickness beads (0.3–1.0 mm); twelve ink beads (6 × 2) with the ink name; Pressure sensitivity switch; Stabilisation slider; "Edit presets" link. Highlighter popover: six highlighter beads, widths, Straight line switch. Eraser: sizes, Whole stroke / Highlighter only, Clear page (destructive, confirmed).
- **Page navigator:** Dense droplet panel 240 wide, inset 12, buds from the leading button; tabs Pages / Outline / Bookmarks; single column of 168-wide thumbnails with SF Rounded numbers; reorder: the dragged thumbnail becomes a droplet, neighbours part (reflow), release plips; multi-select raises an action droplet at the bottom of the panel.
- **Zoom window:** bottom Dense droplet sheet one third of the height; on the page, the zoom box is a 1.5-pt accent rounded rectangle (radius 12) with droplet handles; controls ‹ › advance, return, margin, zoom.
- **iPad portrait:** palette unchanged (fits 834); the assistant becomes a bottom sheet (45% / 90% detents).
- **iPhone / compact:** nav bar with back, title (New York 17 + page subtitle), undo, more. Palette docks at the bottom 344 × 56: Pen, Pencil, Highlighter, Eraser, Lasso, More | two inks; More buds a tool grid upward; settings bud upward. Fling the palette up and it docks at the top.

### 11.3 New notebook and templates
- **iPad:** form sheet 540 × 620 on `raised`. Live cover preview 150 × 200 at the top with the title field overlaid (New York 22). Segmented Cover / Paper. Cover: cloths as 44-pt swatch beads + template chips (Classic, Label, Dots) + Import cover. Paper: template tiles 88 × 116 (Blank, Ruled 7 mm, Ruled 8.7 mm, Dotted 5 mm, Grid 5 mm, Cornell, Music, Planner, then "From plugins"), paper colour beads (White, Ivory, Cream, Mist, Sage, Slate, Night), size menu (A4, Letter, A5, Nib Standard), orientation. Selected tile: 2-pt accent ring with a 3-pt gap (concentric). **Create** in the sheet's trailing nav position.
- **iPhone:** full-height sheet, the same sections stacked, tiles 3 per row.

### 11.4 Search
- **Global (iPad):** a Dense droplet 640 wide buds from the search field; filter chips All / Handwriting / PDF / Typed / Audio / Cards; results grouped Notebooks, Pages (ink snippet 120 × 60 with the match outlined in accent), PDF text, Typed text, Study cards, Transcripts; recent searches when empty; "Handwriting in 12 pages is still being indexed" as a quiet footnote. No stagger, results update in place.
- **In document:** a Clear droplet bar under the nav bar with field, ‹ ›, "3 of 14"; matches on the page get an accent wash (22%) rounded rectangle.
- **iPhone:** full-screen search on `base` with the same groups.

### 11.5 Settings
- iPad: system split view: sidebar sections (General, Writing & Pencil, Documents, Library & Sync, Assistant, Plugins, Bridge, Accessibility, About & parity notes) and inset grouped lists on `base` with `raised` rows (44 pt, Body 17, footnotes Footnote). No droplets except the switch thumb, which squashes like a bead when toggled (width 27 → 35 → 27, height 27 → 23 → 27 over 0.32 s). Keys and tokens are entered only in secure fields in Settings, never by the assistant.
- iPhone: standard navigation stack.

### 11.6 Assistant (bring your own model)
- **iPad landscape:** Dense droplet panel 352 wide, inset 12, from under the nav bar to 12 from the bottom; buds from the Assistant button.
  - Header: drop mark on accent wash, "Assistant", model and provider in Caption 1 ("claude-sonnet-4-5 · Anthropic"), more, close.
  - Context scope chips: This page · Selection · Notebook (Library in More).
  - The turn, not a bubble: "You · 9:41" caption and the instruction in Callout 16. Then a **work log** in Footnote with success checks ("Read page 3 · 214 words recognised", "Checked spelling, symbols and units", "Prepared 3 edits · nothing applied yet"); "Show tool calls" expands the registry commands in SF Mono.
  - **Proposal card** (`raised`, radius 18): "3 edits on page 3" + an "On page" eye toggle; one row per edit: number badge, title, a mini diff in New York (deleted text struck in `danger`, inserted text italic in accent on accent wash), include checkbox.
  - Actions: Discard (quiet capsule), **Accept 3 edits** (accent capsule). Fine print: "Accepting is one undo step. Everything the assistant adds is marked as AI-made and can be selected later."
  - Footer: quick actions (built-in, plugin and user-defined) and the composer (attach selection, field, dictate, send; send becomes stop while running). While the model works: one indeterminate accent line under the header; the log fills as tool calls complete; text is never typed out character by character.
  - **On the page:** proofreader's marks in accent: numbered badges in the left margin matching the rows, strikes through replaced words with the correction in the right margin, dashed insertion boxes with the typeset insertion, carets for small additions. The chip droplet sits at the main edit, fused to its anchor.
  - Confirmations for destructive or sensitive commands appear inline in the proposal card (command name, dry-run summary, Allow once / Allow for this turn / Deny), not as modals. Irreversible verbs are `danger`.
  - After accepting: marks become real content with AI provenance; chip and row read "Applied · Undo" for 8 s; Undo calls `history.revertGroup`.
  - Errors: an inline row with `exclamationmark.triangle` in `danger` and Retry. No provider: New York 22 "Connect a model to use the assistant." with Add provider.
- **iPad portrait:** bottom Dense sheet (45% / 90%), the page and its marks stay visible above.
- **iPhone:** sheet at the medium detent; the chip docks just above the palette.
- **External AI bridge:** when an external agent is connected a small Clear pill sits in the nav bar trailing group ("Bridge · Claude Code", success dot); its edits arrive as proposals exactly like the in-app assistant when the policy asks for confirmation.

### 11.7 Plugins
- **Manager** (Settings › Plugins): list rows with the plugin glyph in a 29-pt squircle, name, version, author, enable switch; Gallery and Install from Files / URL in the nav bar.
- **Detail:** description, permissions grouped in plain language, each with a symbol; on update a permission diff (added in accent, removed struck); Update / Disable / Remove (danger).
- **Install consent** (sheet): source, hash, permission list, "Install" as the only accent button; never auto-installs.
- **Plugin panels:** hosted in the same Dense droplet frame as the assistant (352 wide) with a header showing the plugin name and a "Plugin" provenance tag. HTML panels (WKWebView) receive the tokens as CSS variables (`--nib-accent`, `--nib-text1`, `--nib-space-16`…) and a stylesheet so they match; they cannot draw their own glass (the host draws the droplet).
- **Plugin tools** join the palette after a hairline and use the same bead; plugin menu items appear under "Plugins" in object menus; the developer console is a Dense panel in SF Mono 13.

### 11.8 Study sets
- **iPad:** set editor as a two-pane layout: card list (term / definition rows, Body) and a large card preview (`raised`, radius 20, New York 28 prompt).
- **Practice:** full screen on the desk, one card 560 × 360 centred; tap to flip (the only 3D motion in the app: 0.42 s spring about the Y axis; Reduce Motion crossfades); grading row of four droplet buttons Again / Hard / Good / Easy with next-interval labels in SF Rounded; a thin accent progress line and "14 / 48" at the top; session summary as a quiet bar list.
- **iPhone:** full-width card; swipe right / left to grade: the card turns into a droplet while swiped (stretch, then settle), tinting 12% success or danger at the edge it moves toward.

### 11.9 Presentation mode
- External display: the page only, on the Night desk, no chrome.
- iPad: a presenter droplet at bottom centre: Laser dot / Laser trail / Hide page / Blank, "Presenting on Living Room TV" with `airplayvideo`; page chip shows the slide number.
- Laser: 14-pt `#E5484D` dot with a soft glow; trail fades over 1.1 s. Page changes are direct scrolls, no transitions.

### 11.10 Empty states
Typography only: New York 28 title, one sentence in Callout, one primary action (accent) and at most one quiet action. The only image allowed is a single ink bead.
- Library: "No notes yet." / "Start a notebook, or bring in a PDF to write on." / New notebook · Import a PDF
- Folder: "Nothing in Physics yet." / "Drag notebooks here from All notes."
- Search: "No matches for ‘entropy’." / "Handwriting in 12 pages is still being indexed."
- Assistant (no model): "Connect a model to use the assistant." / Add provider
- Plugins: "No plugins installed." / Browse gallery · Install from Files
- Trash: "Trash is empty." (no action)

### 11.11 Onboarding (4 steps, full screen on Ivory)
1. "Welcome to Nib" (New York 40) and a single Blue-Black ink bead you can drag: it wobbles, stretches, lands. This teaches the feel in two seconds.
2. "Your library is a folder you choose": pick a folder in any Files provider; one sentence on privacy (no Nib servers).
3. Apple Pencil: double-tap and squeeze choices, then write your name on a ruled line (calibrates palm rejection).
4. "Bring your own model" (optional): choose Anthropic, OpenAI, OpenAI-compatible or a custom endpoint, or Skip.
Progress: four small beads at the bottom; the active one glides with the bead physics. Continue is an accent capsule (full width on iPhone, 320 on iPad).

---

## 12. The code design system (what agents must use)

Lives in `NibKit/Sources/NibContracts/UI/Design/` (added through a contract request, owned by the shell/UI seat). Feature modules import it through `NibContracts`; lint makes it the only path.

```
Design/
  NibColor.swift        semantic dynamic colours (§2.1–2.4), Increase Contrast variants
  NibInk.swift          12 inks + 6 highlighters, dark-paper mirrors, papers, template lines, cloths
  NibFont.swift         roles from §3, Dynamic Type mapping, chrome cap
  NibSpace.swift        4-pt scale, NibRadius (concentric helper)
  NibMotion.swift       NibSpring tokens (§9) → Animation / UISpringTimingParameters
  NibHaptic.swift       events from §10.13, rate limit, pencil-down suppression
  NibSymbol.swift       typed SF Symbol + custom `nib.` symbols; Image(nib:)/UIImage(nib:)
  Droplet/
    DropletPhysics.swift   the model in §10 (pure Swift, unit-tested, no UIKit)
    LiquidLayer.swift      CAMetalLayer per window scene: SDF union, bridges, material pass
    Liquid.metal           smin union, meniscus normal, refraction, specular, rim, caustic, shadow
    DropletView.swift      UIKit host view; content + gestures wired to DropletPhysics
    Droplet+SwiftUI.swift  .droplet(_:style:), DropletContainer, .budsFrom(_:)
```

Token shape (excerpt):

```swift
public enum NibColor {
    public static let desk    = UIColor.nib(light: 0xEEF0F3, dark: 0x0F1113)
    public static let raised  = UIColor.nib(light: 0xFDFDFE, dark: 0x191C20)
    public static let text1   = UIColor.nib(light: 0x181C21, dark: 0xEDEEF1)
    public static let accent  = UIColor.nib(light: 0x284F88, dark: 0x87B5E9)
    // …every row of §2.1–2.4
}
public enum NibInk: String, CaseIterable, Sendable {
    case carbon, graphite, blueBlack, ultramarine, cerulean, teal, viridian, ochre, vermilion, carmine, rose, violet
    public var onLightPaper: RGBA { … }   // §2.5 column 3
    public var onDarkPaper: RGBA { … }    // §2.5 column 4
}
public enum NibSpace { public static let s2: CGFloat = 2, s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12,
                       s16: CGFloat = 16, s20: CGFloat = 20, s24: CGFloat = 24, s32: CGFloat = 32,
                       s40: CGFloat = 40, s48: CGFloat = 48, s64: CGFloat = 64 }
public enum NibRadius { public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16,
                        card: CGFloat = 18, popover: CGFloat = 26, panel: CGFloat = 30
                        public static func inner(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 0) } }
public struct NibSpring: Sendable {
    public let response: Double, dampingRatio: Double
    public static let tap = NibSpring(response: 0.18, dampingRatio: 0.90)
    public static let snap = NibSpring(response: 0.34, dampingRatio: 0.72)
    public static let settle = NibSpring(response: 0.42, dampingRatio: 0.78)
    public static let surface = NibSpring(response: 0.24, dampingRatio: 0.32)
    public static let budPosition = NibSpring(response: 0.44, dampingRatio: 0.74)
    public static let budSize = NibSpring(response: 0.40, dampingRatio: 0.62)
    public static let reabsorb = NibSpring(response: 0.30, dampingRatio: 0.92)
    public var animation: Animation { .spring(Spring(response: response, dampingRatio: dampingRatio)) }  // Reduce Motion → nil at call sites via NibMotion.animate
}
public struct DropletStyle: Sendable {
    public enum Material: Sendable { case clear, dense, ink(RGBA), opaque }
    public var material: Material = .clear
    public var corner: Corner = .capsule            // .capsule or .fixed(NibRadius.popover)
    public var stretchCap: CGFloat = 0.12, velocityRef: CGFloat = 900, contentFollow: CGFloat = 0.55
    public var mergeable = true, docks: [DropletDock] = []
    public static let palette = DropletStyle(stretchCap: 0.06)
    public static let chip = DropletStyle()
    public static let popover = DropletStyle(material: .dense, corner: .fixed(NibRadius.popover), stretchCap: 0.03, mergeable: false)
    public static let panel = DropletStyle(material: .dense, corner: .fixed(NibRadius.panel), stretchCap: 0.02)
}
// SwiftUI
ToolPaletteView().droplet("palette", style: .palette)
PenSettings().droplet("penSettings", style: .popover).budsFrom("palette.pen", isPresented: $showPen)
```

**Native pipeline (iOS 17 target).** One `LiquidLayer` (CAMetalLayer) per scene sits between the canvas and a transparent chrome host. Each frame it receives ≤ 32 droplets (centre, half-size, radius, 2×2 deformation) and ≤ 16 bridges, evaluates the smooth-min union (k = 12 pt), and shades refraction (sampling the canvas renderer's committed tile texture; Library and Settings sample a snapshot taken at gesture start), rim, specular, caustic and shadow. SwiftUI/UIKit content renders above, transformed by the same `DropletPhysics` state (the Metal pass never touches text, so labels never ghost). A `CADisplayLink` runs at up to 120 Hz only while something is moving and parks otherwise. Budget: ≤ 1.5 ms GPU on A12Z for 16 droplets; zero cost when idle; the pass is frozen while the pencil is down. On iOS 26 the same API may map `.dense` panels to `glassEffect` inside a `GlassEffectContainer(spacing: 12)` where the system provides equivalent merging; physics tokens stay ours.

**Lint rules** (`Scripts/lint.py`, failing CI outside `UI/Design/`):
1. No colour literals: `Color(red:`, `UIColor(red:`, `#colorLiteral`, `Color(hex`, raw `RGBA(0x…)` in UI code → `NibColor` / `NibInk`.
2. No numeric radii: `.cornerRadius(<n>)`, `RoundedRectangle(cornerRadius: <n>)` → `NibRadius`.
3. Spacing literals must be on the scale (2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64) or `NibSpace`.
4. No hand-rolled motion: `withAnimation(.easeInOut|.linear|.default`, `.animation(.easeIn…`, `UIView.animate(withDuration:` → `NibMotion`.
5. No system materials in features: `.ultraThinMaterial`… `.regularMaterial`, `UIBlurEffect`, `UIVisualEffectView`, `.glassEffect` → `DropletStyle`.
6. No direct haptics: `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator` → `NibHaptic`.
7. No string symbols: `Image(systemName:` / `UIImage(systemName:` → `NibSymbol`; `sparkles` and emoji in UI strings are errors.
8. No ad-hoc fonts: `.font(.system(size:` / `UIFont.systemFont(ofSize:` → `NibFont`.
9. `a11y_lint.py`: every icon-only control has an accessibility label; every droplet exposes its content, not the droplet, to VoiceOver.

**Checks agents run:** snapshot tests of each screen in Light, Dark, Reduce Transparency and Increase Contrast; `DropletPhysicsTests` (stretch preserves area within 1e-6; surface spring settles below 0.5% in 0.5 s; bridge splits exactly at SPLIT; fuse leaves a 1-pt overlap; Reduce Motion jumps to targets).

---

## 13. Accessibility
- VoiceOver reads droplet contents as normal controls in logical order (palette tools as a tab group, the bead is not an element); merges and splits are announced only when they change meaning ("Moved to Chemistry. Undo available.").
- Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Colour are all honoured (selected inks also get a ring; proposal edits also get numbers and strikes, never colour alone).
- Minimum text contrast 4.5:1 everywhere, including over droplets (the veils guarantee it on any backdrop; dark mode uses the 56% clear veil because pages stay light under dark chrome).
- Full keyboard: every tool has a single-key shortcut; ⌘⇧A opens the assistant; Return accepts a proposal, ⌘Z undoes the turn.

## 14. What this direction refuses
Gradients except cover lighting · emoji or sparkle glyphs · AI purple · chat bubbles · cards inside cards · glass on structural UI · radii off the scale · motion without a reason · idle animation · anything liquid on the canvas while writing.
