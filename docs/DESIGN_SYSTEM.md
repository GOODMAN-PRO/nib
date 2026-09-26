# NibDesign: the design system as code

This file is the exact Swift source of the `NibDesign` module, the only place in Nib where colour, type, spacing, radii, materials, motion, haptics and the droplet ("liquid") behaviour are defined. [DESIGN.md](DESIGN.md) is the spec. This file is the code that implements it. If they disagree, DESIGN.md wins and this file is fixed.

- **Module:** `NibKit/Sources/NibDesign/` (ARCHITECTURE.md §3: architect-owned, feature agents never edit it, missing pieces go through a contract request).
- **Toolchain:** Swift 5 language mode, iOS 17.0 deployment target, built with Xcode 26.6 (iOS 26 SDK) on `macos-26` ([design/XCODE.md](../design/XCODE.md)). Every iOS 26 symbol sits behind `#available(iOS 26.0, *)` and has an iOS 17 fallback.
- **Rule for feature agents:** feature UI may only call `.droplet(_:style:)`, `.budsFrom(_:isPresented:)`, the `Nib*` components (including `NibBudPopover`, `NibToolOptionsBar`, `NibPanelHeader`, `NibProgressBar`), `NibColor`/`NibUIColor`, `NibFont`/`NibUIFont`, `NibSpacing`, `NibRadius`, `NibMetrics`, `NibMotion`, `NibHaptics`, `NibSymbol`, `NibInkingState`, `CALayer.nibElevation` and the `nib*` modifiers (`nibToast`, `nibBackdrop`, `nibShortcut`, …). `Scripts/lint.py` rejects everything else (§4).
- **Performance contract:** per frame, only the droplets that moved re-render (each reads its own `DropletNode`), and the iOS 17–25 water is one small canvas per cluster of nearby droplets. Nothing field-wide is observed by a feature view (DESIGN.md §10.16).

Contents

1. [Integration changes this module needs](#1-integration-changes-this-module-needs)
2. [How a feature uses it](#2-how-a-feature-uses-it)
3. [Source](#3-source), one block per file
4. [Lint rules](#4-lint-rules)
5. [Device checks the simulator cannot make](#5-device-checks-the-simulator-cannot-make)

---

## 1. Integration changes this module needs

These are small changes outside `NibDesign`. The architect applies them together with the files below. The shader bundle does not exist without the first one, and then the module does not compile.

1. **`NibKit/Package.swift`** is generated from `docs/forge-spec.json` ("Edit the spec, not this file"), so the change goes into the generator, which then emits it. It already has `.target(name: "NibDesign")`: **replace** that line (adding a second `NibDesign` target is a manifest error, and a hand edit is lost on the next regeneration) and add the test target and the default localisation:

   ```swift
   .target(name: "NibDesign", dependencies: ["NibContracts"],                                          // NibPalette (item 6)
           resources: [.process("Shaders"), .process("Localizable.xcstrings")]),                       // default.metallib + strings
   .testTarget(name: "NibDesignTests", dependencies: ["NibDesign"]),                                   // §3.28
   // and in Package(…):
   defaultLocalization: "en",
   ```

   `NibKit/Sources/NibDesign/Localizable.xcstrings` holds every string NibDesign shows. Every `String(localized:)` in the module passes `bundle: .module`; without it the lookup goes to `Bundle.main`, whose catalog never sees package sources, and "Plugin", "Cancel", the ink names and "Move palette to…" would never be translated. Delete `NibKit/Sources/NibDesign/Shaders/.gitkeep` once `NibLiquid.metal` is in the folder.

2. **`.github/workflows/ios.yml`**: after "Select Xcode 26.6" in each job, add `xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain`. Xcode 26 installs the Metal toolchain as a separate component, and the step does nothing when the runner image already has it.

3. **`Scripts/lint.py`**: add the rules in §4.

4. **`docs/forge-spec.json`**: `NibKit/Tests/NibDesignTests/**` is architect-owned like `NibKit/Sources/NibDesign/**`.

5. **`project.yml`**, Nib target, `info.properties`: `CADisableMinimumFrameDurationOnPhone: true`. Without it the droplet display link's `CAFrameRateRange(80…120)` does nothing on ProMotion iPhones.

6. **`NibKit/Sources/NibContracts/NibPalette.swift`** (new, UIKit-free). The ink, highlighter, paper, cover and presence tables are data that core modules need too: NibRender draws ink and paper, NibExport writes them, and neither depends on NibDesign. They live in NibContracts as hex plus `CGColor`; NibDesign extends them with `color`, `uiColor` and localised names (§3.2), so there is one table.

   ```swift
   import CoreGraphics

   /// Nib's colour data (DESIGN.md §3.4–3.6). UIKit-free, so core modules (NibRender, NibExport) share the one table.
   /// Feature UI gets `color` / `uiColor` / `name` from the NibDesign extensions.
   public protocol NibHexColour {
       var hex: UInt32 { get }
   }

   public extension NibHexColour {
       var cgColor: CGColor { NibPalette.cgColor(hex) }
   }

   public enum NibPalette {
       public static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
           CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                   blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
       }
   }

   /// The 12 default inks. Ink is never themed: the same hex in light and dark mode.
   public enum NibInk: String, CaseIterable, Sendable, NibHexColour {
       case carbon, graphite, midnight, cobalt, lagoon, moss, ochre, sienna, vermilion, crimson, plum, chalk

       public var hex: UInt32 {
           switch self {
           case .carbon: return 0x121212
           case .graphite: return 0x5B6068
           case .midnight: return 0x1B2A6B
           case .cobalt: return 0x2156D9
           case .lagoon: return 0x0B8793
           case .moss: return 0x2F7A3C
           case .ochre: return 0xB7791F
           case .sienna: return 0x9A4E2A
           case .vermilion: return 0xD9432B
           case .crimson: return 0xB0173A
           case .plum: return 0x7B3FA0
           case .chalk: return 0xF4F4F1
           }
       }

       /// Inks that vanish against the chrome get a permanent 1 pt ring in pickers: Chalk in light mode,
       /// Carbon and Midnight in dark mode.
       public func needsRing(dark: Bool) -> Bool { dark ? (self == .carbon || self == .midnight) : self == .chalk }
       /// The palette's quick slots on a fresh install.
       public static let quickSlots: [NibInk] = [.carbon, .cobalt, .vermilion]
   }

   /// Highlighters render beneath ink: multiply at 60 % on light paper, screen at 35 % on dark paper.
   public enum NibHighlighter: String, CaseIterable, Sendable, NibHexColour {
       case lemon, apricot, mint, sky, lilac, blush

       public var hex: UInt32 {
           switch self {
           case .lemon: return 0xFFE45C
           case .apricot: return 0xFFBE6B
           case .mint: return 0x86E3AE
           case .sky: return 0x82CCFF
           case .lilac: return 0xC8A8FF
           case .blush: return 0xFFA3C7
           }
       }

       public static let lightPaperOpacity: Double = 0.60
       public static let darkPaperOpacity: Double = 0.35
   }

   /// Paper colours with their rule and margin-line colours.
   public enum NibPaper: String, CaseIterable, Sendable, NibHexColour {
       case white, ivory, legal, grey, slate, night, board

       public var hex: UInt32 {
           switch self {
           case .white: return 0xFFFFFF
           case .ivory: return 0xFBF8F1
           case .legal: return 0xFCF3C8
           case .grey: return 0xF1F1EF
           case .slate: return 0x1E1F22
           case .night: return 0x121212
           case .board: return 0x1F2A24
           }
       }

       public var ruleHex: UInt32 {
           switch self {
           case .white: return 0xCFDBE8
           case .ivory: return 0xD9D3C5
           case .legal: return 0xB9C9DA
           case .grey: return 0xD2D4D8
           case .slate: return 0x34373D
           case .night: return 0x2A2C30
           case .board: return 0x33443A
           }
       }

       public var marginHex: UInt32? {
           switch self {
           case .white: return 0xEDB9B3
           case .ivory: return 0xE9B8A8
           case .legal: return 0xE3A49B
           case .slate: return 0x5A3A38
           case .grey, .night, .board: return nil
           }
       }

       /// Dark papers are not "light paper" for the droplets' backdrop (`nibBackdrop`).
       public var isDark: Bool { self == .slate || self == .night || self == .board }
   }

   /// Cover cloths: flat colour, a spine at −16 % luminance and an elastic band at −30 %.
   public enum NibCoverCloth: String, CaseIterable, Sendable, NibHexColour {
       case moss, carbon, terracotta, sand, navy, oxblood, stone, paper

       public var hex: UInt32 {
           switch self {
           case .moss: return 0x2F4A3E
           case .carbon: return 0x2A2D33
           case .terracotta: return 0xA4553A
           case .sand: return 0xD5C6A8
           case .navy: return 0x23324F
           case .oxblood: return 0x5E1F24
           case .stone: return 0x8C8A84
           case .paper: return 0xF3F1EC
           }
       }

       public var isLight: Bool { self == .sand || self == .paper }
   }

   /// Collaborator colours; they never collide with ink.
   public enum NibPresenceColour {
       public static let hexes: [UInt32] = [0xFF6B5E, 0xFFB547, 0x3DBB7A, 0x3C8DFF, 0x9C6BFF, 0xFF6FAE]
       public static func hex(_ index: Int) -> UInt32 { hexes[((index % hexes.count) + hexes.count) % hexes.count] }
   }
   ```

7. **`CONTRACTS.md`**: nothing changes. `ToolbarItemDescriptor.activeToolMenu` and `ToolMenuDescriptor` views are rendered by `NibToolPalette(options:)` inside a `NibToolOptionsBar` fused to the palette (DESIGN.md §13.3), so FeatPen, FeatHighlighter and FeatEraser register them and FeatToolbar passes them through.

**How the shader is loaded.** `Shaders/NibLiquid.metal` is processed as a package resource, so Xcode compiles it into `default.metallib` inside `NibKit_NibDesign.bundle`. Swift reaches it with `ShaderLibrary.bundle(.module)` (`NibShaders.library`, §3.16). If a render logs "unresolved visible function reference", the function name in Swift and Metal differ or the metallib is missing from the bundle. The header is `<SwiftUI/SwiftUI_Metal.h>`, not `<SwiftUI/SwiftUI.h>` as the research brief wrote.

---

## 2. How a feature uses it

Everything that floats in one window lives in **one** `NibDropletContainer`. It must be a sibling layer above the canvas inside a SwiftUI `ZStack`, never inside a `ScrollView`, so that touches on empty areas fall through to the canvas.

```swift
import SwiftUI
import NibContracts
import NibDesign

struct EditorChrome: View {
    @State private var tool = "pen"
    @State private var ink = 0
    @State private var dock = NibPaletteDock(edge: .leading)
    @State private var showSearch = false
    @State private var toast: NibToastItem?
    let inking: NibInkingState              // the canvas delegate writes it; only the container reads it
    let pages: [CGRect]                      // visible light pages, in the container's coordinates

    var body: some View {
        ZStack {
            CanvasRepresentable(inking: inking)   // UIKit / PencilKit, never inside the container
            NibDropletContainer(inking: inking) {
                ZStack(alignment: .top) {
                    HStack {
                        NibBarGroup(id: "bar.leading") {
                            NibToolbarItem(.back, label: String(localized: "Library")) { }
                            NibBarTitle(title: "Simple Harmonic Motion", subtitle: "Physics 9702 · Page 3 of 12")
                        }
                        Spacer()
                        NibBarGroup(id: "bar.trailing") {
                            NibToolbarItem(.undo, label: String(localized: "Undo"), shortcut: KeyboardShortcut("z")) { }
                            NibToolbarItem(.redo, label: String(localized: "Redo"),
                                           shortcut: KeyboardShortcut("z", modifiers: [.command, .shift])) { }
                            NibBarSeparator()
                            NibToolbarItem(.search, label: String(localized: "Search"), shortcut: KeyboardShortcut("f")) {
                                showSearch = true
                            }
                            .nibBudAnchor("bar.search")
                        }
                    }
                    .padding(.horizontal, NibSpacing.l)
                    .padding(.top, NibMetrics.barTopGap)

                    NibToolPalette(tools: EditorTools.shown, moreTools: EditorTools.more, selection: $tool,
                                   swatches: NibInk.quickSlots.map { NibSwatch(ink: $0) }, swatch: $ink, dock: $dock) { toolID in
                        PenSettings(tool: toolID)            // the popover body; the palette buds it from the tool
                    }

                    NibBudPopover(id: "search", source: "bar.search", isPresented: $showSearch,
                                  title: String(localized: "Search"), placement: .below) {
                        SearchInDocument()
                    }
                }
                .nibToast($toast)
            }
            .nibBackdrop(pages)
        }
    }
}
```

- A popover that is not a palette tool's settings is a `NibBudPopover(placement:)`, a full-size child of the container: it buds from its source (a droplet id or a `nibBudAnchor`, even one another module owns) and positions itself beside it. `.droplet(id, style: .popover).budsFrom(sourceID, isPresented:)` is the raw form.
- Toasts go through `.nibToast($item)` only: it places, times, replaces and announces them.
- The palette docks by itself (`NibToolPalette(dock:)`: set the binding through your command, FeatToolbar's `toolbar.dock`). Anything else that docks like it is `.dropletDockable(id, length:, current:, onDock:)`, a full-size child of the container whose content lays itself out for `@Environment(\.nibDockEdge)`; `onDock` gets the dock a release or an accessibility action chose, and not adopting it sends the droplet home.
- A reorderable grid (the library) shares one `NibReflow`:

  ```swift
  @State private var reflow = NibReflow<NodeID>()
  ScrollView {
      LazyVGrid(columns: columns, spacing: NibMetrics.libraryGutter) {
          ForEach(notebooks) { n in
              NotebookCard(n)
                  .nibReflowItem(n.id, in: reflow)
                  .nibReflowDraggable(n.id, in: reflow, order: notebooks.map(\.id)) { drop in
                      switch drop {
                      case .reorder(let move): model.reorder(move)   // now, then library.reorder {refs, after?, before?}
                      case .combine(let a, into: let b): model.combine(a, into: b)   // library.move onto b
                      case .none: break
                      }
                  }
          }
      }
      .nibReflowSpace(reflow)
  }
  // …and in the window's NibDropletContainer: NibReflowCarrier(reflow) { id in NotebookCard(id) }
  ```

  Set `reflow.isPaused` while the card is fused with a folder film and `reflow.isCondensed` over the sidebar.
- The canvas delegate sets `inking.isInking` on begin/end using tool and grows `inking.strokeBounds` as the stroke is drawn; nothing else observes it, so a Pencil down never re-evaluates the editor's body.
- UIKit code uses `NibUIColor`, `NibUIFont`, `NibMotion.animateUIKit`, `NibHaptics`, `CALayer.nibElevation` and `UIImage(nib:)`.
- Sheets, lists and Settings are opaque system surfaces: `List { NibRow(...) }.listStyle(.insetGrouped)`, `.nibSheet(isPresented:)`, `NibToggle`. There is no droplet in them.

---

## 3. Source

Files in the order below. Paths are relative to the repository root.

Four files live beside these and are not reproduced here: `Gallery/DesignGallery.swift` (the Settings › Advanced › Developer screen that shows every token, component and droplet interaction in light and dark, the held rim included; the app shell registers it with `DesignGallery.registerSettingsPage(in:)`), `Gallery/DockAndReflowDemo.swift` (its Dock and reflow page: a `.dropletDockable` palette over a page of ink and a `NibReflow` notebook grid, to try the two drag feels on a device), `NibKit/Tests/NibDesignTests/TokenContrastTests.swift` (WCAG contrast of the text tokens over the worst case beneath, §2.4 of DESIGN.md) and `NibKit/Tests/NibDesignTests/GlassOpticsTests.swift` (Liquid Glass v2, DESIGN.md §10.9: the rim follows the top-left light with a counter-rim at half and is never a uniform stroke, every optic stays in the outer 4.5 pt so contrast holds under content, the held rim and shadow, Regular system glass with the accent as the only tint, `interactive` on touchable chrome, and the fallback selection of §12).

**Liquid Glass v2 in code.** The optics numbers live in one place, `NibOptics` (§3.16), and reach both Metal functions as arguments, so the Swift and Metal argument lists must match one for one. On iOS 26 `DropletStyle.systemGlass` and `nibGlass` go through `NibSystemGlass` (Regular everywhere, the accent the only tint) and `NibGlassRenderer` picks system glass, water or the opaque union. The held rim is `DropletPresentation.rim` (`DropletStyle.rimStrength(lift:)`), drawn by `NibLiftRim` over iOS 26 glass and by the water shader through `WaterCluster.rim` on iOS 17–25. Outside the liquid files, three call sites follow: `Droplet.swift` (`GlassBody` draws `NibLiftRim` and no bud stroke, `FrameRim` draws its outline once, a droplet outside a container passes `isInteractive`), `DropletContainer.swift` (`NibShaders.waterField(cluster, iso:)`) and `Palette.swift` (`drawNibBeadRim`).

### 3.1 `NibKit/Sources/NibDesign/Modifiers/NibInteraction.swift`

Press, focus, hover and keyboard behaviour shared by every Nib control (DESIGN.md §12, §13). There is no `NibDesign.swift`: a public `enum NibDesign` shadows the module name, so client code could never write `NibDesign.X` to disambiguate.

```swift
import SwiftUI
import UIKit

private struct NibShowsKeyHintsKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while ⌘ is held on a hardware keyboard. The app's root hosting controller sets it from
    /// `UIPress.modifierFlags` in `pressesBegan` / `pressesEnded`; every control with a shortcut then shows its `KeyHint`.
    var nibShowsKeyHints: Bool {
        get { self[NibShowsKeyHintsKey.self] }
        set { self[NibShowsKeyHintsKey.self] = newValue }
    }
}

/// Every Nib button: scale 0.96 on `tap`, the system hover highlight in the control's shape, and one focus ring
/// (2 pt accent, 2 pt outside, concentric) in place of the system focus effect.
public struct NibPressStyle: ButtonStyle {
    let shape: AnyShape

    public init<S: Shape>(shape: S) { self.shape = AnyShape(shape) }
    public init() { self.init(shape: Capsule()) }

    public func makeBody(configuration: Configuration) -> some View {
        NibPressBody(configuration: configuration, shape: shape)
    }
}

struct NibPressBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(NibMotion.tap.animation, value: configuration.isPressed)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .overlay {
                if isFocused {
                    shape.stroke(NibColor.accent, lineWidth: 2)
                        .padding(-3)                         // the 2 pt ring starts 2 pt outside the control
                        .allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
    }
}

public extension View {
    /// Registers `shortcut` with the system (it appears in the ⌘-hold overlay) and shows it as a `KeyHint` below the
    /// control after 500 ms of pointer hover and while ⌘ is held. `nil` does nothing.
    func nibShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(NibShortcutModifier(shortcut: shortcut))
    }
}

struct NibShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcut?
    @Environment(\.nibShowsKeyHints) private var commandHeld
    @State private var hovered = false
    @State private var hoverWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(shortcut)
            .onHover { inside in
                hoverWork?.cancel()
                guard shortcut != nil else { return }
                if inside {
                    let work = DispatchWorkItem { hovered = true }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                } else {
                    hovered = false
                }
            }
            .overlay(alignment: .bottom) {
                if let shortcut, commandHeld || hovered {
                    KeyHint(shortcut)
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - NibSpacing.xs }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)             // the shortcut is already announced by the system
                        .transition(.opacity)
                }
            }
            .animation(NibMotion.fade, value: commandHeld || hovered)
    }
}

extension KeyboardShortcut {
    /// "⇧⌘Z", "⌘⏎", "⎋": the glyphs Apple uses in menus.
    var nibDisplay: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .return: s += "⏎"
        case .escape: s += "⎋"
        case .delete: s += "⌫"
        case .tab: s += "⇥"
        case .space: s += String(localized: "Space", bundle: .module)
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        default: s += String(key.character).uppercased()
        }
        return s
    }
}
```

### 3.2 `NibKit/Sources/NibDesign/Tokens/NibColor.swift`

```swift
import SwiftUI
import UIKit
import NibContracts

extension UIColor {
    /// A trait-aware colour from 0xRRGGBB values. `contrastLight` / `contrastDark` replace the alpha under Increase Contrast.
    static func nib(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1,
                    contrastLight: CGFloat? = nil, contrastDark: CGFloat? = nil) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            var alpha = isDark ? darkAlpha : lightAlpha
            if traits.accessibilityContrast == .high, let raised = isDark ? contrastDark : contrastLight {
                alpha = raised
            }
            return UIColor.nibHex(isDark ? dark : light, alpha)
        }
    }

    static func nibHex(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(cgColor: NibPalette.cgColor(hex, alpha: alpha))
    }
}

/// Colour tokens for UIKit (DESIGN.md §3). UI neutrals are Apple's semantic colours; nothing here is a literal in a feature.
public enum NibUIColor {
    // UI neutrals
    public static let label = UIColor.label
    public static let labelSecondary = UIColor.secondaryLabel
    public static let labelTertiary = UIColor.tertiaryLabel
    public static let labelQuaternary = UIColor.quaternaryLabel
    public static let separator = UIColor.separator
    public static let separatorSoft = UIColor.nib(0x3C3C43, 0.12, dark: 0x545458, 0.34)
    public static let fill1 = UIColor.systemFill
    public static let fill2 = UIColor.secondarySystemFill
    public static let fill3 = UIColor.tertiarySystemFill
    public static let fill4 = UIColor.quaternarySystemFill
    public static let background = UIColor.systemBackground
    public static let backgroundSecondary = UIColor.secondarySystemBackground
    public static let backgroundTertiary = UIColor.tertiarySystemBackground
    public static let groupedBackground = UIColor.systemGroupedBackground
    public static let desk = UIColor.nib(0xE7E7EC, dark: 0x121214)
    public static let chromeOpaque = UIColor.nib(0xF4F4F6, dark: 0x2C2C2E)
    public static let scrim = UIColor.nib(0x000000, 0.18, dark: 0x000000, 0.45)

    // Accent (Pool) and semantic
    public static let accent = UIColor.nib(0x0066E0, dark: 0x3D8BFF)
    public static let accentWash = UIColor.nib(0x0066E0, 0.10, dark: 0x3D8BFF, 0.16)
    public static let onAccent = UIColor.white
    public static let destructive = UIColor.systemRed
    public static let success = UIColor.systemGreen
    public static let warning = UIColor.systemOrange

    // Water: what the droplet material is made of (DESIGN.md §3.3). Deep dark body is #1C1C1E @ 86 % (fix 3). On iOS 26
    // the system glass is the material and only the bodies (as the frozen tint while the Pencil is down) are used; the
    // optics tokens below draw Nib's own water on iOS 17–25 (DESIGN.md §10.9).
    public static let clearBody = UIColor.nib(0xFFFFFF, 0.46, dark: 0x161618, 0.62, contrastLight: 0.72, contrastDark: 0.72)
    /// Clear over light paper: dark mode thickens to 80 % so a droplet over white paper is not a grey blob.
    public static let clearBodyOnPaper = UIColor.nib(0xFFFFFF, 0.46, dark: 0x161618, 0.80, contrastLight: 0.72, contrastDark: 0.86)
    public static let deepBody = UIColor.nib(0xF9F9FB, 0.72, dark: 0x1C1C1E, 0.86, contrastLight: 0.90, contrastDark: 0.92)
    public static let waterBody = UIColor.nib(0xFFFFFF, 0.08, dark: 0xFFFFFF, 0.03)
    /// The rim at full strength: a 0.8 pt line lit by the top-left key light, half as bright on the counter side, and
    /// 22 % of it as the sheen inside the lit edge. Never a uniform stroke.
    public static let waterRim = UIColor.nib(0xFFFFFF, 0.85, dark: 0xFFFFFF, 0.50)
    /// A Tinted droplet's only optic (key and counter rim, no sheen).
    public static let tintRim = UIColor.nib(0xFFFFFF, 0.30, dark: 0xFFFFFF, 0.30)
    public static let waterLine = UIColor.nib(0x000000, 0.075, dark: 0xFFFFFF, 0.12, contrastLight: 0.25, contrastDark: 0.40)
    public static let waterLineBud = UIColor.nib(0x000000, 0.12, dark: 0xFFFFFF, 0.16, contrastLight: 0.25, contrastDark: 0.40)
    /// The water's own shadow over a flat backdrop (desk, library, sheets), and over light paper. Light mode: deeper over
    /// paper, where there is ink to separate from (the system glass's shadow grows over text). Dark mode: lighter over
    /// paper, where the dark water already stands off the white page and a deep halo reads as a smudge.
    public static let waterShadow = UIColor.nib(0x000000, 0.08, dark: 0x000000, 0.28)
    public static let waterShadowOnPaper = UIColor.nib(0x000000, 0.13, dark: 0x000000, 0.18)
    public static let beadBody = UIColor.nib(0xFFFFFF, 0.70, dark: 0xFFFFFF, 0.22)
    /// Slider thumbs only; the selection bead has no shadow.
    public static let beadShadow = UIColor.nib(0x000000, 0.16, dark: 0x000000, 0.45)
    public static let swatchHairline = UIColor.nib(0x000000, 0.22, dark: 0xFFFFFF, 0.28)
    /// The permanent 1 pt ring on inks that vanish against the chrome (NibInk.needsRing(dark:)).
    public static let swatchRing = UIColor.nib(0x000000, 0.22, dark: 0xFFFFFF, 0.35)
}

/// The same tokens for SwiftUI.
public enum NibColor {
    public static let label = Color(uiColor: NibUIColor.label)
    public static let labelSecondary = Color(uiColor: NibUIColor.labelSecondary)
    public static let labelTertiary = Color(uiColor: NibUIColor.labelTertiary)
    public static let labelQuaternary = Color(uiColor: NibUIColor.labelQuaternary)
    public static let separator = Color(uiColor: NibUIColor.separator)
    public static let separatorSoft = Color(uiColor: NibUIColor.separatorSoft)
    public static let fill1 = Color(uiColor: NibUIColor.fill1)
    public static let fill2 = Color(uiColor: NibUIColor.fill2)
    public static let fill3 = Color(uiColor: NibUIColor.fill3)
    public static let fill4 = Color(uiColor: NibUIColor.fill4)
    public static let background = Color(uiColor: NibUIColor.background)
    public static let backgroundSecondary = Color(uiColor: NibUIColor.backgroundSecondary)
    public static let backgroundTertiary = Color(uiColor: NibUIColor.backgroundTertiary)
    public static let groupedBackground = Color(uiColor: NibUIColor.groupedBackground)
    public static let desk = Color(uiColor: NibUIColor.desk)
    public static let chromeOpaque = Color(uiColor: NibUIColor.chromeOpaque)
    public static let scrim = Color(uiColor: NibUIColor.scrim)
    public static let accent = Color(uiColor: NibUIColor.accent)
    public static let accentWash = Color(uiColor: NibUIColor.accentWash)
    public static let onAccent = Color(uiColor: NibUIColor.onAccent)
    public static let destructive = Color(uiColor: NibUIColor.destructive)
    public static let success = Color(uiColor: NibUIColor.success)
    public static let warning = Color(uiColor: NibUIColor.warning)
    public static let clearBody = Color(uiColor: NibUIColor.clearBody)
    public static let clearBodyOnPaper = Color(uiColor: NibUIColor.clearBodyOnPaper)
    public static let deepBody = Color(uiColor: NibUIColor.deepBody)
    public static let waterBody = Color(uiColor: NibUIColor.waterBody)
    public static let waterRim = Color(uiColor: NibUIColor.waterRim)
    public static let tintRim = Color(uiColor: NibUIColor.tintRim)
    public static let waterLine = Color(uiColor: NibUIColor.waterLine)
    public static let waterLineBud = Color(uiColor: NibUIColor.waterLineBud)
    public static let waterShadow = Color(uiColor: NibUIColor.waterShadow)
    public static let waterShadowOnPaper = Color(uiColor: NibUIColor.waterShadowOnPaper)
    public static let beadBody = Color(uiColor: NibUIColor.beadBody)
    public static let beadShadow = Color(uiColor: NibUIColor.beadShadow)
    public static let swatchHairline = Color(uiColor: NibUIColor.swatchHairline)
    public static let swatchRing = Color(uiColor: NibUIColor.swatchRing)
}

// The colour tables live in NibContracts (§1, item 6) so core modules share them; UI gets colours and names here.

public extension NibHexColour {
    var uiColor: UIColor { UIColor.nibHex(hex) }
    var color: Color { Color(uiColor: uiColor) }
}

public extension NibInk {
    var name: String {
        switch self {
        case .carbon: return String(localized: "Carbon", bundle: .module)
        case .graphite: return String(localized: "Graphite", bundle: .module)
        case .midnight: return String(localized: "Midnight", bundle: .module)
        case .cobalt: return String(localized: "Cobalt", bundle: .module)
        case .lagoon: return String(localized: "Lagoon", bundle: .module)
        case .moss: return String(localized: "Moss", bundle: .module)
        case .ochre: return String(localized: "Ochre", bundle: .module)
        case .sienna: return String(localized: "Sienna", bundle: .module)
        case .vermilion: return String(localized: "Vermilion", bundle: .module)
        case .crimson: return String(localized: "Crimson", bundle: .module)
        case .plum: return String(localized: "Plum", bundle: .module)
        case .chalk: return String(localized: "Chalk", bundle: .module)
        }
    }
}

public extension NibPaper {
    var ruleColor: Color { Color(uiColor: UIColor.nibHex(ruleHex)) }
    var marginColor: Color? { marginHex.map { Color(uiColor: UIColor.nibHex($0)) } }
}

/// Folder colours come from the ink palette, so the library and the page share one hue vocabulary.
public enum NibFolderColor: String, CaseIterable, Sendable {
    case cobalt, moss, graphite, ochre, plum, vermilion, lagoon, sienna

    public var ink: NibInk { NibInk(rawValue: rawValue) ?? .graphite }
    public var color: Color { ink.color }
}

/// Collaborator colours; they never collide with ink.
public enum NibPresence {
    public static func color(_ index: Int) -> Color { Color(uiColor: UIColor.nibHex(NibPresenceColour.hex(index))) }
}
```

### 3.3 `NibKit/Sources/NibDesign/Tokens/NibFont.swift`

```swift
import SwiftUI
import UIKit

/// Type roles (DESIGN.md §4). SF Pro for UI, SF Pro Rounded for numbers that live on water, New York for editorial moments.
/// Text styles carry Apple's tracking tables, so nothing sets tracking or kerning by hand.
public enum NibFont {
    public static let display = Font.largeTitle.weight(.bold)
    public static let displayEditorial = Font.system(.largeTitle, design: .serif).weight(.semibold)
    public static let title1 = Font.title.weight(.bold)
    public static let cardFace = Font.system(.title, design: .serif)
    public static let title2 = Font.title2.weight(.bold)
    public static let title3 = Font.title3.weight(.semibold)
    public static let emptyTitle = Font.system(.title3, design: .serif).weight(.semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let bodyEmphasis = Font.body.weight(.semibold)
    public static let callout = Font.callout
    public static let chat = Font.subheadline
    public static let chatEmphasis = Font.subheadline.weight(.medium)
    public static let button = Font.subheadline.weight(.semibold)
    public static let barTitle = Font.subheadline.weight(.semibold)
    public static let footnote = Font.footnote
    public static let footnoteEmphasis = Font.footnote.weight(.semibold)
    public static let caption1 = Font.caption
    /// The only caption allowed on Clear (bar subtitles), and only in `label` (DESIGN.md §2.4).
    public static let caption1Emphasis = Font.caption.weight(.semibold)
    public static let caption2 = Font.caption2.weight(.medium)
    public static let hud = Font.system(.footnote, design: .rounded).weight(.semibold).monospacedDigit()
    public static let hudLarge = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
    public static let math = Font.system(.callout, design: .serif).italic()
    /// Developer console and raw tool calls only. Never used as a decorative metadata style.
    public static let code = Font.system(.footnote, design: .monospaced)
    /// The assistant thread reads at 15/21: subheadline plus 1 pt of leading.
    public static let chatLineSpacing: CGFloat = 1

    /// SF Symbol sizes and weights (DESIGN.md §8). Where a glyph must grow with Dynamic Type, the component scales
    /// the size with `@ScaledMetric` and caps it (palette 28, bars 26).
    public static func glyph(_ g: NibGlyph, size: CGFloat? = nil) -> Font {
        .system(size: size ?? g.size, weight: g.weight)
    }
}

/// The symbol roles of DESIGN.md §8.
public enum NibGlyph: Sendable {
    /// Palette tools: Medium 23 pt.
    case palette
    /// Bar buttons: Regular 21 pt.
    case bar
    /// Sidebar rows: Regular 22 pt.
    case sidebar
    /// Controls in Deep panels: Regular 17 pt.
    case panel
    /// The glyph in a 30 pt round button: Semibold 15 pt.
    case round
    /// The arrow on the 32 pt send disc: Semibold 16 pt.
    case send

    public var size: CGFloat {
        switch self {
        case .palette: return 23
        case .bar: return 21
        case .sidebar: return 22
        case .panel: return 17
        case .round: return 15
        case .send: return 16
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .palette: return .medium
        case .bar, .sidebar, .panel: return .regular
        case .round, .send: return .semibold
        }
    }

    var uiWeight: UIImage.SymbolWeight {
        switch self {
        case .palette: return .medium
        case .bar, .sidebar, .panel: return .regular
        case .round, .send: return .semibold
        }
    }
}

/// The same roles for UIKit, scaled with Dynamic Type through UIFontMetrics.
public enum NibUIFont {
    private static let largeSizes: [UIFont.TextStyle: CGFloat] = [
        .largeTitle: 34, .title1: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
        .callout: 16, .subheadline: 15, .footnote: 13, .caption1: 12, .caption2: 11,
    ]

    public static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular,
                            design: UIFontDescriptor.SystemDesign = .default) -> UIFont {
        let size = largeSizes[style] ?? 17
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if design != .default, let designed = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: designed, size: size)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    public static var body: UIFont { font(.body) }
    public static var headline: UIFont { font(.headline, weight: .semibold) }
    public static var chat: UIFont { font(.subheadline) }
    public static var barTitle: UIFont { font(.subheadline, weight: .semibold) }
    public static var footnote: UIFont { font(.footnote) }
    public static var caption1: UIFont { font(.caption1) }
    public static var hud: UIFont { font(.footnote, weight: .semibold, design: .rounded) }

    /// A symbol configuration for `UIImage(nib:)` in UIKit (`UIImageView.preferredSymbolConfiguration`).
    public static func glyph(_ g: NibGlyph) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: g.size, weight: g.uiWeight)
    }
}
```

### 3.4 `NibKit/Sources/NibDesign/Tokens/NibSpacing.swift`

```swift
import SwiftUI

/// The 4 pt spacing scale (2 pt only inside controls).
public enum NibSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let x3: CGFloat = 32
    public static let x4: CGFloat = 40
    public static let x5: CGFloat = 48
    public static let x6: CGFloat = 64
}

/// Continuous-corner radii (DESIGN.md §6). A shape inside a shape uses `concentric(outer, inset:)`.
public enum NibRadius {
    public static let popover: CGFloat = 26
    public static let panel: CGFloat = 28
    public static let sheet: CGFloat = 28
    public static let composer: CGFloat = 22
    public static let studyCard: CGFloat = 20
    public static let zoomFrame: CGFloat = 18
    public static let tile: CGFloat = 14
    public static let proposal: CGFloat = 12
    public static let field: CGFloat = 10
    public static let sidebarRow: CGFloat = 10
    public static let segment: CGFloat = 9
    /// A lifted cover's 3 pt water envelope, concentric with its 5 pt spine.
    public static let cardEnvelope: CGFloat = 8
    public static let segmentKnob: CGFloat = 7
    /// A lifted thumbnail's 3 pt envelope (4 + 3), the same radius as the current-page ring.
    public static let thumbnailEnvelope: CGFloat = 7
    public static let icon: CGFloat = 7
    public static let badge: CGFloat = 6
    public static let coverSpine: CGFloat = 5
    public static let coverEdge: CGFloat = 8
    public static let thumbnail: CGFloat = 4

    public static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
    public static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 8) }
}

/// Fixed metrics (DESIGN.md §5).
public enum NibMetrics {
    public static let hitTarget: CGFloat = 44
    public static let barHeight: CGFloat = 44
    public static let barHeightMax: CGFloat = 52
    /// Every HUD: page counter, zoom, ruler angle, recording, follow, presenter.
    public static let hudHeight: CGFloat = 40
    public static let chromeInset: CGFloat = 16
    public static let barTopGap: CGFloat = 8
    public static let paletteThickness: CGFloat = 56
    public static let paletteThicknessMax: CGFloat = 64
    public static let palettePitch: CGFloat = 44
    public static let palettePitchMax: CGFloat = 52
    public static let palettePitchCompact: CGFloat = 46
    public static let palettePitchCompactMax: CGFloat = 54
    public static let paletteEndPadding: CGFloat = 6
    public static let paletteSwatchPitch: CGFloat = 44
    public static let paletteDividerGap: CGFloat = 17
    public static let popoverWidth: CGFloat = 312
    public static let popoverGap: CGFloat = 20
    public static let popoverGapCompact: CGFloat = 16
    public static let popoverMaxHeight: CGFloat = 520
    public static let panelWidth: CGFloat = 344
    /// Panels (assistant, plugins, search results) widen at AX1 and larger.
    public static let panelWidthAccessibility: CGFloat = 420
    public static let navigatorWidth: CGFloat = 240
    public static let thumbnailWidth: CGFloat = 176
    public static let sidebarWidth: CGFloat = 320
    public static let coverSize = CGSize(width: 140, height: 182)
    public static let coverSizeCompact = CGSize(width: 110, height: 143)
    /// Every library measure sits on this gutter: covers (164 pt pitch) and folder tiles.
    public static let libraryGutter: CGFloat = 24
    /// Folder tiles are this tall; their width comes from the grid: (content width − 3 × gutter) / 4.
    public static let folderTileHeight: CGFloat = 78
    public static let folderTileMinWidth: CGFloat = 160
    public static let compactBreakpoint: CGFloat = 600
    public static let beadRadius: CGFloat = 20
    public static let minimumGlyphGap: CGFloat = 8
    public static let minimumRestingGap: CGFloat = 16
    /// iPhone: the canvas's bottom content inset, so the last line always scrolls above the palette (56 + 8 + 16).
    public static let canvasBottomInsetCompact: CGFloat = 80

    public static func panelWidth(_ size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? panelWidthAccessibility : panelWidth
    }
}
```

### 3.5 `NibKit/Sources/NibDesign/Tokens/NibElevation.swift`

```swift
import SwiftUI
import UIKit

/// Four elevation levels plus the cover pair (DESIGN.md §7). SwiftUI shadows take radius = blur / 2 and have no spread,
/// so the second layer's opacity is lowered to match the spec's negative spread.
public enum NibElevation: Sendable {
    case paper, rest, lifted, sheet, cover, coverLifted

    struct Layer {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    struct Pair {
        let near: Layer
        let far: Layer
    }

    func pair(dark: Bool) -> Pair {
        switch (self, dark) {
        case (.paper, false): return Pair(near: Layer(opacity: 0.05, radius: 1, y: 1), far: Layer(opacity: 0.12, radius: 17, y: 14))
        case (.paper, true): return Pair(near: Layer(opacity: 0.30, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 20, y: 18))
        case (.rest, false): return Pair(near: Layer(opacity: 0.07, radius: 0.5, y: 0.5), far: Layer(opacity: 0.10, radius: 8, y: 6))
        case (.rest, true): return Pair(near: Layer(opacity: 0.50, radius: 0.5, y: 0.5), far: Layer(opacity: 0.50, radius: 10, y: 8))
        case (.lifted, false): return Pair(near: Layer(opacity: 0.06, radius: 1, y: 1), far: Layer(opacity: 0.20, radius: 18, y: 18))
        case (.lifted, true): return Pair(near: Layer(opacity: 0.50, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 20, y: 20))
        case (.sheet, false): return Pair(near: Layer(opacity: 0.06, radius: 1, y: 1), far: Layer(opacity: 0.24, radius: 30, y: 24))
        case (.sheet, true): return Pair(near: Layer(opacity: 0.50, radius: 1, y: 1), far: Layer(opacity: 0.60, radius: 30, y: 24))
        case (.cover, false): return Pair(near: Layer(opacity: 0.10, radius: 0.5, y: 0.5), far: Layer(opacity: 0.09, radius: 4, y: 3))
        case (.cover, true): return Pair(near: Layer(opacity: 0.60, radius: 0.5, y: 0.5), far: Layer(opacity: 0.55, radius: 5, y: 3))
        case (.coverLifted, false): return Pair(near: Layer(opacity: 0.12, radius: 2, y: 2), far: Layer(opacity: 0.30, radius: 20, y: 22))
        case (.coverLifted, true): return Pair(near: Layer(opacity: 0.60, radius: 2, y: 2), far: Layer(opacity: 0.65, radius: 20, y: 22))
        }
    }
}

struct NibElevationModifier: ViewModifier {
    let level: NibElevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = level.pair(dark: scheme == .dark)
        return content
            .shadow(color: Color.black.opacity(p.near.opacity), radius: p.near.radius, x: 0, y: p.near.y)
            .shadow(color: Color.black.opacity(p.far.opacity), radius: p.far.radius, x: 0, y: p.far.y)
    }
}

public extension CALayer {
    /// The same elevation for UIKit layers (selection handles, UIKit overlays), because `layer.shadow*` is banned in
    /// features. `path` is required: UIKit shadows always set `shadowPath`. Call it again when the trait collection's
    /// `userInterfaceStyle` changes.
    /// ponytail: a CALayer has one shadow, so UIKit gets the far layer only (the near one is under 1 pt); add a
    /// shadow sublayer if a large UIKit surface ever needs both.
    func nibElevation(_ level: NibElevation, path: CGPath, dark: Bool) {
        let far = level.pair(dark: dark).far
        shadowColor = UIColor.black.cgColor
        shadowOpacity = Float(far.opacity)
        shadowRadius = far.radius
        shadowOffset = CGSize(width: 0, height: far.y)
        shadowPath = path
    }
}
```

### 3.6 `NibKit/Sources/NibDesign/Tokens/NibMotion.swift`

```swift
import SwiftUI
import UIKit

/// A spring in SwiftUI's parameterisation: stiffness k = (2π / response)², damping c = 4π·ζ / response, mass 1.
public struct NibSpring: Equatable, Sendable {
    public let response: Double
    public let dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    public var stiffness: Double {
        let w = 2 * Double.pi / response
        return w * w
    }

    public var damping: Double { 4 * Double.pi * dampingRatio / response }

    /// The animation for this spring. Under Reduce Motion or Liquid Off it is `NibMotion.reduced` (critically damped,
    /// no overshoot), here in the one shared place, so no component or feature can forget it (DESIGN.md §12).
    public var animation: Animation {
        let s = (NibMotion.forcesReduced || UIAccessibility.isReduceMotionEnabled) ? NibMotion.reduced : self
        return .spring(response: s.response, dampingFraction: s.dampingRatio, blendDuration: 0)
    }

    /// Kept for call sites that already know the setting; `animation` applies it on its own.
    public func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? NibMotion.reduced.animation : animation
    }

    public func timingParameters(initialVelocity: CGVector = .zero) -> UISpringTimingParameters {
        UISpringTimingParameters(mass: 1, stiffness: CGFloat(stiffness), damping: CGFloat(damping),
                                 initialVelocity: initialVelocity)
    }
}

/// Every animated value in Nib uses one of these (DESIGN.md §9).
public enum NibMotion {
    /// Liquid Off: set by `NibDropletContainer` from the Appearance setting, next to `NibHaptics.isEnabled`.
    public static var forcesReduced = false

    /// A held droplet following the finger. Critically damped, so it never overshoots the finger; it trails it by
    /// v·ζ·response/π (27 ms of travel: 27 pt at 1000 pt/s) and catches up within about 0.1 s of the finger stopping.
    /// That slight lag is the water's weight (DESIGN.md §10.1).
    public static let follow = NibSpring(response: 0.085, dampingRatio: 1.0)
    public static let tap = NibSpring(response: 0.22, dampingRatio: 0.90)
    public static let lift = NibSpring(response: 0.30, dampingRatio: 0.72)
    /// Selection bead head: a selection indicator never overshoots.
    public static let glide = NibSpring(response: 0.20, dampingRatio: 1.0)
    public static let trail = NibSpring(response: 0.26, dampingRatio: 1.0)
    /// The palette's dock only (`.dropletDockable`, `NibToolPalette`), from the full release velocity: one small
    /// overshoot, then the plip on arrival (DESIGN.md §10.11).
    public static let snap = NibSpring(response: 0.50, dampingRatio: 0.80)
    /// Grid and slot snaps, from `DropletPhysics.slotVelocity`: lands without passing the slot.
    public static let slot = NibSpring(response: 0.40, dampingRatio: 1.0)
    /// Neighbours making room (the library's live reorder, `NibReflow`; page thumbnails) and folder films.
    public static let reflow = NibSpring(response: 0.44, dampingRatio: 0.86)
    public static let tether = NibSpring(response: 0.40, dampingRatio: 0.62)
    public static let bud = NibSpring(response: 0.42, dampingRatio: 0.76)
    public static let budSize = NibSpring(response: 0.46, dampingRatio: 0.80)
    /// Palette gather and spread on an orientation change: ≤ 380 ms, a correction, not a show.
    public static let reform = NibSpring(response: 0.28, dampingRatio: 0.90)
    public static let retract = NibSpring(response: 0.30, dampingRatio: 0.90)
    public static let neck = NibSpring(response: 0.14, dampingRatio: 1.0)
    public static let absorb = NibSpring(response: 0.22, dampingRatio: 1.0)
    /// Slider-thumb stretch.
    public static let thumb = NibSpring(response: 0.16, dampingRatio: 0.72)
    public static let sheet = NibSpring(response: 0.48, dampingRatio: 0.90)
    public static let reduced = NibSpring(response: 0.26, dampingRatio: 1.0)

    /// Surface tension: water at UI scale is tight and quick. clamp(0.14·√(minor / 44), 0.14, 0.26) s at ζ 0.68
    /// (about 5 % overshoot, under one visible cycle). Stretch springs never go below ζ 0.65 (DESIGN.md §9.1).
    public static func wobble(minor: CGFloat) -> NibSpring {
        let r = min(max(0.14 * (minor / 44).squareRoot(), 0.14), 0.26)
        return NibSpring(response: Double(r), dampingRatio: 0.68)
    }

    /// Opacity and blur reveals: strong ease-out. Exits are always faster than enters.
    public static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    public static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    public static let recede = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    public static let colorChange = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    public static let fade = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    /// The laser trail is the only linear motion in Nib: it is time made visible.
    public static let laserFade = Animation.linear(duration: 0.6)

    public static let recedeDelay: Double = 0.45
    /// A HUD that answers a gesture (the ruler's angle, the pinch-zoom percentage) lingers this long after the fingers
    /// lift, then fades out with `exit` (DESIGN.md §9.2).
    public static let hudLinger: Double = 0.6
    public static let budRevealDelay: Double = 0.30
    public static let toastDuration: Double = 6
    public static let combineHold: Double = 0.38

    public static func animate<Result>(_ spring: NibSpring, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(spring.animation, body)
    }

    /// UIKit: a spring animator that carries a per-axis initial velocity (normalised by distance, as UIKit expects).
    public static func animateUIKit(_ spring: NibSpring, initialVelocity: CGVector = .zero,
                                    animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        let s = (forcesReduced || UIAccessibility.isReduceMotionEnabled) ? NibMotion.reduced : spring
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: s.timingParameters(initialVelocity: initialVelocity))
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { position in completion(position == .end) }
        }
        animator.startAnimation()
    }
}
```

### 3.7 `NibKit/Sources/NibDesign/Tokens/NibHaptics.swift`

```swift
import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore

public enum NibHapticEvent: CaseIterable, Sendable {
    /// `plip`: a dockable droplet (the palette) arrives in its dock: one light, crisp drop, played once per landing.
    case merge, split, bud, snap, plip, select, armed, success, detent, warning
}

/// Droplet haptics (DESIGN.md §11). Coalesced to one per 60 ms, silent while the Pencil is down or Liquid is Off.
/// iPad has no Taptic Engine, so these are no-ops there by hardware; the visuals carry the feedback.
public enum NibHaptics {
    public static var isInking = false
    public static var isEnabled = true
    private static var lastFire: CFTimeInterval = 0
    private static let player = PlipPlayer()

    public static func play(_ event: NibHapticEvent) {
        guard isEnabled, !isInking else { return }
        let now = CACurrentMediaTime()
        guard now - lastFire >= 0.06 else { return }
        lastFire = now
        player.play(event)
    }

    /// Call on touch-down so the first plip has no latency.
    public static func prepare() { player.prepare() }
}

public extension View {
    /// Plays a Nib haptic whenever `trigger` changes.
    func nibHaptic<T: Equatable>(_ event: NibHapticEvent, trigger: T) -> some View {
        onChange(of: trigger) { _, _ in NibHaptics.play(event) }
    }
}

final class PlipPlayer {
    private let engine: CHHapticEngine?
    private var engineRunning = false
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics, let e = try? CHHapticEngine() {
            e.isAutoShutdownEnabled = true
            engine = e
        } else {
            engine = nil
        }
        // CoreHaptics calls these on its own queue.
        engine?.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { self?.engineRunning = false } }
        engine?.resetHandler = { [weak self] in DispatchQueue.main.async { self?.engineRunning = false } }
    }

    /// Starts the engine asynchronously, never on the frame that needs the haptic: the synchronous `start()` blocks
    /// the main thread for milliseconds after an auto-shutdown.
    func prepare() {
        soft.prepare()
        selection.prepare()
        guard let engine, !engineRunning else { return }
        engine.start { [weak self] error in
            DispatchQueue.main.async { self?.engineRunning = error == nil }
        }
    }

    func play(_ event: NibHapticEvent) {
        switch event {
        case .select, .detent:
            selection.selectionChanged()
        case .success:
            notification.notificationOccurred(.success)
        case .warning:
            notification.notificationOccurred(.warning)
        case .merge, .armed:
            // The "plip": a soft transient, then a quieter duller one 18 ms later.
            let fallbackIntensity: CGFloat = event == .armed ? 0.6 : 0.5
            transients([(0.45, 0.70, 0), (0.20, 0.35, 0.018)]) { self.soft.impactOccurred(intensity: fallbackIntensity) }
        case .split:
            transients([(0.35, 0.90, 0)]) { self.rigid.impactOccurred(intensity: 0.35) }
        case .bud:
            transients([(0.30, 0.60, 0)]) { self.soft.impactOccurred(intensity: 0.4) }
        case .snap:
            transients([(0.55, 0.40, 0)]) { self.soft.impactOccurred(intensity: 0.7) }
        case .plip:
            // One light, crisp drop landing: lighter and sharper than a slot snap, a single transient (not the merge's
            // two-tap plip).
            transients([(0.40, 0.85, 0)]) { self.rigid.impactOccurred(intensity: 0.45) }
        }
    }

    private func transients(_ taps: [(Float, Float, TimeInterval)], fallback: () -> Void) {
        guard let engine, engineRunning else {
            fallback()
            prepare()                                   // warm the engine for the next one
            return
        }
        let events = taps.map { tap in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.1),
            ], relativeTime: tap.2)
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            engineRunning = false
            fallback()
        }
    }
}
```

### 3.8 `NibKit/Sources/NibDesign/Tokens/NibSymbol.swift`

```swift
import SwiftUI
import UIKit

/// Every SF Symbol Nib uses (DESIGN.md §8). Features write `Image(nib: .pen)`, never `Image(systemName:)`.
public struct NibSymbol: Hashable, Sendable {
    public let name: String

    init(_ name: String) { self.name = name }

    private static let banned: Set<String> = ["sparkles", "sparkle", "wand.and.stars", "wand.and.stars.inverse",
                                              "wand.and.rays", "wand.and.rays.inverse", "sparkles.rectangle.stack",
                                              "sparkle.magnifyingglass"]

    /// A plugin's declared symbol. Empty, banned (AI sparkles, magic wands), misspelt or newer-than-this-OS names
    /// become the plugin glyph, so a plugin tool is never an empty, unlabelled button.
    public static func plugin(_ name: String) -> NibSymbol {
        (name.isEmpty || banned.contains(name) || UIImage(systemName: name) == nil) ? .puzzle : NibSymbol(name)
    }

    /// A native descriptor's `icon: String` (CONTRACTS.md): nil when the name is banned or not on this OS.
    public init?(systemName name: String) {
        guard !name.isEmpty, !Self.banned.contains(name), UIImage(systemName: name) != nil else { return nil }
        self.name = name
    }

    // Tools
    public static let pen = NibSymbol("pencil.tip")
    public static let pencil = NibSymbol("pencil")
    public static let highlighter = NibSymbol("highlighter")
    public static let eraser = NibSymbol("eraser")
    public static let eraserFilter = NibSymbol("eraser.line.dashed")
    public static let lasso = NibSymbol("lasso")
    public static let lassoRectangle = NibSymbol("rectangle.dashed")
    public static let shapes = NibSymbol("square.on.circle")
    public static let connectors = NibSymbol("point.3.connected.trianglepath.dotted")
    public static let tape = NibSymbol("rectangle.dashed")
    public static let text = NibSymbol("textformat")
    public static let pageTyping = NibSymbol("character.cursor.ibeam")
    public static let image = NibSymbol("photo")
    public static let camera = NibSymbol("camera")
    public static let scan = NibSymbol("doc.viewfinder")
    public static let elements = NibSymbol("star.square.on.square")
    public static let sticky = NibSymbol("note.text")
    public static let comment = NibSymbol("text.bubble")
    public static let laser = NibSymbol("laser.burst")
    public static let zoomWindow = NibSymbol("plus.magnifyingglass")
    public static let ruler = NibSymbol("ruler")
    public static let fingerDrawing = NibSymbol("hand.draw")
    /// The palette's More slot: buds a grid of the tools that are not on the palette.
    public static let more = NibSymbol("ellipsis")
    public static let moreCircle = NibSymbol("ellipsis.circle")

    // Actions and navigation
    public static let back = NibSymbol("chevron.backward")
    public static let forward = NibSymbol("chevron.forward")
    public static let chevronDown = NibSymbol("chevron.down")
    public static let undo = NibSymbol("arrow.uturn.backward")
    public static let redo = NibSymbol("arrow.uturn.forward")
    public static let search = NibSymbol("magnifyingglass")
    public static let clearText = NibSymbol("xmark.circle.fill")
    public static let bookmark = NibSymbol("bookmark")
    public static let bookmarkFill = NibSymbol("bookmark.fill")
    public static let share = NibSymbol("square.and.arrow.up")
    public static let importFile = NibSymbol("square.and.arrow.down")
    public static let pages = NibSymbol("square.grid.2x2")
    public static let outline = NibSymbol("list.bullet.indent")
    public static let addPage = NibSymbol("doc.badge.plus")
    public static let assistant = NibSymbol("drop")
    public static let assistantOpen = NibSymbol("drop.fill")
    public static let record = NibSymbol("waveform")
    public static let microphone = NibSymbol("mic")
    public static let stop = NibSymbol("stop.fill")
    public static let play = NibSymbol("play.fill")
    public static let pause = NibSymbol("pause.fill")
    public static let present = NibSymbol("play.rectangle")
    public static let externalDisplay = NibSymbol("rectangle.on.rectangle")
    public static let checkmark = NibSymbol("checkmark")
    public static let checkCircle = NibSymbol("checkmark.circle")
    public static let checkCircleFill = NibSymbol("checkmark.circle.fill")
    public static let circle = NibSymbol("circle")
    public static let xmark = NibSymbol("xmark")
    public static let plus = NibSymbol("plus")
    public static let minus = NibSymbol("minus")
    public static let citation = NibSymbol("doc.text.magnifyingglass")
    /// Drawn on a 32 pt `fill3` disc (`NibIconButton` size `.send`), never an accent disc.
    public static let send = NibSymbol("arrow.up")
    public static let stopGenerating = NibSymbol("stop.fill")
    public static let key = NibSymbol("key")
    public static let bridge = NibSymbol("point.3.filled.connected.trianglepath.dotted")
    public static let eye = NibSymbol("eye")
    public static let eyeSlash = NibSymbol("eye.slash")
    public static let warningTriangle = NibSymbol("exclamationmark.triangle")
    public static let retry = NibSymbol("arrow.clockwise")
    public static let lock = NibSymbol("lock")
    public static let faceID = NibSymbol("faceid")
    public static let command = NibSymbol("command")
    public static let keyboard = NibSymbol("keyboard")
    public static let dictate = NibSymbol("mic")
    public static let attach = NibSymbol("plus")

    // Library
    public static let library = NibSymbol("books.vertical")
    public static let favorites = NibSymbol("star")
    public static let starFill = NibSymbol("star.fill")
    public static let shared = NibSymbol("person.2")
    public static let recents = NibSymbol("clock")
    public static let studySets = NibSymbol("rectangle.stack")
    public static let gallery = NibSymbol("puzzlepiece.extension")
    public static let puzzle = NibSymbol("puzzlepiece.extension")
    public static let trash = NibSymbol("trash")
    public static let folder = NibSymbol("folder")
    public static let folderFill = NibSymbol("folder.fill")
    public static let notebook = NibSymbol("book.closed")
    public static let quickNote = NibSymbol("square.and.pencil")
    public static let whiteboard = NibSymbol("scribble.variable")
    public static let textDocument = NibSymbol("doc.text")
    public static let pdf = NibSymbol("doc")
    public static let sort = NibSymbol("arrow.up.arrow.down")
    public static let select = NibSymbol("checkmark.circle")
    public static let listView = NibSymbol("list.bullet")
    public static let sidebar = NibSymbol("sidebar.left")
    public static let settings = NibSymbol("gearshape")
    public static let syncDone = NibSymbol("checkmark.icloud")
    public static let syncing = NibSymbol("arrow.triangle.2.circlepath")
    public static let syncError = NibSymbol("exclamationmark.icloud")

    // Collaboration and permissions
    public static let invite = NibSymbol("person.crop.circle.badge.plus")
    public static let live = NibSymbol("dot.radiowaves.left.and.right")
    public static let permission = NibSymbol("hand.raised")
    public static let network = NibSymbol("network")
    public static let documentWrite = NibSymbol("pencil.and.outline")
}

public extension Image {
    init(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}

public extension UIImage {
    convenience init?(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}
```

### 3.9 `NibKit/Sources/NibDesign/Modifiers/NibSurfaces.swift`

```swift
import SwiftUI

/// A capsule when `cornerRadius` is nil, otherwise a continuous rounded rectangle clamped to a capsule.
public struct NibDropletShape: Shape {
    public var cornerRadius: CGFloat?

    public init(cornerRadius: CGFloat? = nil) { self.cornerRadius = cornerRadius }

    public func path(in rect: CGRect) -> Path {
        let capsule = min(rect.width, rect.height) / 2
        let r = min(cornerRadius ?? capsule, capsule)
        return Path(roundedRect: rect, cornerRadius: max(0, r), style: .continuous)
    }
}

/// The four droplet materials (DESIGN.md §2). Nothing else is glass.
public enum NibGlass: Sendable {
    case clear, deep, tinted, bead
}

/// What Nib asks of the system glass on iOS 26+ (DESIGN.md §2.2). Every droplet is the Regular variant: Apple never
/// mixes Regular and Clear in one interface, and Clear is for media-rich backdrops with a dimming layer beneath, which
/// a page of handwriting is not. Regular already thickens itself for large surfaces (popovers, panels) and adapts its
/// shadow and tint to what is beneath, so Deep is not tinted either: a tint means prominence, never thickness, and
/// only the Tinted material (the one primary action) has one. `isInteractive` is set wherever the glass takes the touch.
struct NibSystemGlass: Equatable {
    var tintsAccent: Bool
    var isInteractive: Bool

    static func of(_ kind: NibGlass, interactive: Bool) -> NibSystemGlass {
        NibSystemGlass(tintsAccent: kind == .tinted, isInteractive: interactive)
    }

    @available(iOS 26.0, *)
    var glass: Glass {
        (tintsAccent ? Glass.regular.tint(NibColor.accent) : Glass.regular).interactive(isInteractive)
    }
}

/// Which recipe draws the droplet material (DESIGN.md §2.3, §12). The system glass handles Reduce Transparency (it
/// frosts) and Increase Contrast (it borders) itself, so on iOS 26 only Liquid Off replaces it.
enum NibGlassRenderer: Equatable {
    /// System Liquid Glass (iOS 26+).
    case system
    /// Nib's water: body tint, rim, sheen, outline, shadow (iOS 17–25).
    case water
    /// One opaque fill with the 0.8 pt line: Liquid Off everywhere; Reduce Transparency and thermal throttling on 17–25.
    case opaque

    static func select(systemGlass: Bool, mode: NibLiquidMode, reduceTransparency: Bool,
                       throttled: Bool = false) -> NibGlassRenderer {
        if mode == .off { return .opaque }
        if systemGlass { return .system }
        return reduceTransparency || throttled ? .opaque : .water
    }
}

public extension View {
    /// The droplet material on a single surface that has no physics, such as a floating HUD outside a container.
    /// Inside a `NibDropletContainer` use `.droplet(_:style:)`, which merges, stretches and buds. `interactive`: the
    /// surface holds controls, so on iOS 26 the glass answers touches the way system buttons do.
    func nibGlass(_ kind: NibGlass = .clear, cornerRadius: CGFloat? = nil, interactive: Bool = false) -> some View {
        modifier(NibGlassModifier(kind: kind, shape: NibDropletShape(cornerRadius: cornerRadius), interactive: interactive))
    }

    /// An opaque surface: folder tiles, study cards, cells. Never glass.
    func nibCard(_ fill: Color = NibColor.backgroundSecondary, cornerRadius: CGFloat = NibRadius.tile,
                 elevation: NibElevation? = nil) -> some View {
        modifier(NibCardModifier(fill: fill, cornerRadius: cornerRadius, elevation: elevation))
    }

    func nibElevation(_ level: NibElevation) -> some View {
        modifier(NibElevationModifier(level: level))
    }

    /// Chrome stops growing at xxxLarge; beyond it the Large Content Viewer shows the control (DESIGN.md §4.2).
    /// Applied by the bar groups, HUDs, the palette and the proposal chip only. Panels, the assistant, search results
    /// and plugin panels scale to AX5.
    func nibChromeTypeCap() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct NibGlassModifier: ViewModifier {
    let kind: NibGlass
    let shape: NibDropletShape
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nibLiquidMode) private var mode
    /// While the Pencil is down nothing samples the backdrop (DESIGN.md §10.8).
    @Environment(\.nibIsInking) private var frozen

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The glass is applied to the content itself, as Apple's custom-view guide does: its foreground effects
            // (vibrant labels, the interactive response) reach the controls. One modifier chain in every state, so a
            // Pencil down or a Liquid change never rebuilds the content.
            content
                .background { systemUnderlay }
                .glassEffect(systemGlass, in: shape)
        } else {
            content.background { fallback }
        }
    }

    private var renderer: NibGlassRenderer {
        var hasSystemGlass = false
        if #available(iOS 26.0, *) { hasSystemGlass = true }
        return NibGlassRenderer.select(systemGlass: hasSystemGlass, mode: mode, reduceTransparency: reduceTransparency)
    }

    private var tint: Color {
        kind == .deep ? NibColor.deepBody : (kind == .tinted ? NibColor.accent : NibColor.clearBody)
    }

    /// iOS 26: nothing under system glass, except the plain body tint while frozen (`.identity` above it), the opaque
    /// fill under Liquid Off, and a bead, which is a plain fill because it only ever sits inside glass (never glass on
    /// glass, no rim painted over the system's).
    @available(iOS 26.0, *)
    @ViewBuilder private var systemUnderlay: some View {
        if renderer == .opaque {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)
        } else if frozen {
            shape.fill(tint)
        }
    }

    @available(iOS 26.0, *)
    private var systemGlass: Glass {
        if renderer == .opaque || kind == .bead || frozen { return .identity }
        return NibSystemGlass.of(kind, interactive: interactive).glass
    }

    @ViewBuilder private var fallback: some View {
        if renderer == .opaque {
            opaque
        } else if kind == .bead {
            shape.fill(NibColor.beadBody)              // a bead is body plus its key rim: no shadow (DESIGN.md §2.2)
                .overlay { NibWaterRimLayer(cornerRadius: shape.cornerRadius, bead: true) }
        } else {
            water
        }
    }

    /// iOS 17–25: the water's shadow (outside the body only), frost under Deep (not while inking), the body tint and
    /// the analytic optics. A lone surface has no page behind it, so it gets no edge lens; Tinted gets its rim and the
    /// outline only.
    private var water: some View {
        ZStack {
            NibWaterShadow(shape: shape)
            if kind == .deep && !frozen {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(tint)
            NibWaterRimLayer(cornerRadius: shape.cornerRadius, rimOnly: kind == .tinted, tinted: kind == .tinted)
        }
    }

    private var opaque: some View {
        shape.fill(kind == .deep ? NibColor.backgroundSecondary : (kind == .tinted ? NibColor.accent : NibColor.chromeOpaque))
            .overlay { shape.stroke(NibColor.waterLine, lineWidth: 0.8) }
            .nibElevation(.rest)
    }
}

/// The water optics of one shape, analytic (no field), for iOS 17–25 surfaces with no container field: `nibGlass`,
/// beads, folder films, the zoom-window frame. Always the directional rim (key rim, counter-rim half as bright) and the
/// 0.8 pt outline under it; the sheen unless `rimOnly` (flat library films, frames, Tinted). `tinted` uses the Tinted
/// rim. `bead` is the key rim alone, no counter-rim, sheen or outline, so a bead never reads as a raised button.
/// `strength` is the rim strength (1 at rest, `DropletStyle.liftedRim` held).
struct NibWaterRimLayer: View {
    let cornerRadius: CGFloat?
    var rimOnly = false
    var tinted = false
    var bead = false
    var outline = true
    var strength: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let r = cornerRadius ?? min(proxy.size.width, proxy.size.height) / 2
            Rectangle()
                .fill(Color.white)
                .padding(-1)                    // 1 pt outset so the anti-aliased edge is not cut
                .colorEffect(NibShaders.waterRim(cornerRadius: r, strength: strength, sheen: !(rimOnly || bead),
                                                 counter: !bead, outline: outline && !bead, tinted: tinted))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// iOS 26: a held droplet's brighter rim (DESIGN.md §10.9, Held). Nothing is painted on the system glass at rest. The
/// body of a droplet in a container never takes the touch, so the system cannot light it up; while it is held this
/// adds only the difference, the key and counter rim at (strength − 1) × `waterRim`, plus-lighter onto the system's own
/// rim. No outline, no sheen.
struct NibLiftRim: View {
    let cornerRadius: CGFloat?
    let boost: CGFloat

    var body: some View {
        NibWaterRimLayer(cornerRadius: cornerRadius, rimOnly: true, outline: false, strength: boost)
            .blendMode(.plusLighter)
    }
}

/// The water's shadow on iOS 17–25 for a lone surface (DESIGN.md §10.9): the silhouette blurred at σ 8 pt, 5 pt down,
/// in `waterShadow`, drawn outside the body only so it never shows through the translucent water. Droplets in a
/// container get the same shadow from the field shader.
struct NibWaterShadow: View {
    let shape: NibDropletShape
    /// How far the shadow reaches past the body: 5 pt down plus two blur radii of 8 pt, rounded up.
    static let reach: CGFloat = 24

    var body: some View {
        let reach = Self.reach
        Canvas { context, size in
            let rect = CGRect(x: reach, y: reach, width: max(0, size.width - 2 * reach),
                              height: max(0, size.height - 2 * reach))
            let silhouette = shape.path(in: rect)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(silhouette)
            context.clip(to: outside, style: FillStyle(eoFill: true))
            context.addFilter(.shadow(color: NibColor.waterShadow, radius: 8, x: 0, y: NibOptics.shadowOffset,
                                      options: .shadowOnly))
            context.fill(silhouette, with: .color(.black))
        }
        .padding(-reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension GraphicsContext {
    /// The selection bead's rim (DESIGN.md §10.7, §10.9). iOS 17–25: the key rim alone, `waterRim` in a crescent
    /// 0.8 pt wide where the edge faces the top-left light and tapering to nothing where it turns away (the bead minus
    /// itself moved 0.8 pt away from the light). No counter-rim, sheen or line: it must not read as a raised button.
    /// Inside iOS 26 system glass the bead is a plain fill and this draws nothing (no rim over the system's glass).
    mutating func drawNibBeadRim(_ bead: Path, systemGlass: Bool) {
        guard !systemGlass else { return }
        drawLayer { layer in
            layer.fill(bead, with: .color(NibColor.waterRim))
            layer.blendMode = .destinationOut
            layer.fill(bead.offsetBy(dx: -NibOptics.light.dx * NibOptics.beadRim, dy: -NibOptics.light.dy * NibOptics.beadRim),
                       with: .color(.black))
        }
    }
}

struct NibCardModifier: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let elevation: NibElevation?

    func body(content: Content) -> some View {
        let card = content.background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        if let elevation {
            card.nibElevation(elevation)
        } else {
            card
        }
    }
}
```

### 3.10 `NibKit/Sources/NibDesign/Liquid/NibLiquid.swift`

```swift
import SwiftUI
import Observation

/// Settings › Appearance › Liquid. Calm halves every stretch cap and drops necks; Off uses the Reduce Motion and
/// Reduce Transparency fallbacks whatever the system settings say.
public enum NibLiquidMode: String, CaseIterable, Sendable {
    case full, calm, off
}

public enum NibLiquid {
    /// The coordinate space every droplet, drag and bud uses. `NibDropletContainer` defines it.
    public static let space = NamedCoordinateSpace.named("nib.droplets")
    /// Opacity of a receding droplet while the Pencil is down.
    public static let recedeOpacity: Double = 0.22
    /// A droplet within this distance of the stroke's bounds recedes even when it is off the page (DESIGN.md §10.8).
    public static let recedeReach: CGFloat = 24
}

/// The Pencil state. The canvas delegate writes it (begin/end using tool, and the stroke's bounds in the container's
/// coordinates as the stroke grows); only `NibDropletContainer(inking:)` reads it, so a Pencil down or up never
/// re-evaluates the editor's body at the moment the first ink frame is produced.
@Observable
public final class NibInkingState {
    public var isInking = false
    /// The current stroke's bounds, `.null` between strokes.
    public var strokeBounds: CGRect = .null

    public init() {}
}

/// Merge geometry per size class (DESIGN.md §10.4). `minimumNeck` is the thinnest bridge the field threshold can hold,
/// so a neck's logical break and its visual pinch land on the same frame.
public struct DropletMetrics: Equatable, Sendable {
    public var mergeDistance: CGFloat
    public var fieldBlur: CGFloat
    public var iso: Float
    public var budNeckOff: CGFloat

    public static let regular = DropletMetrics(mergeDistance: 11, fieldBlur: 8, iso: 0.479, budNeckOff: 21)
    public static let compact = DropletMetrics(mergeDistance: 9, fieldBlur: 6.5, iso: 0.479, budNeckOff: 17)

    public var minimumNeck: CGFloat { 1.27 * fieldBlur + 0.6 }
}

private struct NibLiquidModeKey: EnvironmentKey {
    static let defaultValue: NibLiquidMode = .full
}

private struct NibIsInkingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NibBackdropKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}

private struct NibDropletIsLiftedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NibGlassNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

struct NibBudRequest {
    let source: String
    let isPresented: Binding<Bool>
    let instant: Bool
}

private struct NibBudKey: EnvironmentKey {
    static let defaultValue: NibBudRequest? = nil
}

public extension EnvironmentValues {
    var nibLiquidMode: NibLiquidMode {
        get { self[NibLiquidModeKey.self] }
        set { self[NibLiquidModeKey.self] = newValue }
    }

    /// True for content of a droplet that is being dragged (covers hide their titles, shadows deepen).
    var nibDropletIsLifted: Bool {
        get { self[NibDropletIsLiftedKey.self] }
        set { self[NibDropletIsLiftedKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// Set by the container while backdrop sampling is frozen (the Pencil is down): glass becomes `.identity`, frost
    /// is not drawn.
    var nibIsInking: Bool {
        get { self[NibIsInkingKey.self] }
        set { self[NibIsInkingKey.self] = newValue }
    }

    var nibBackdrop: [CGRect] {
        get { self[NibBackdropKey.self] }
        set { self[NibBackdropKey.self] = newValue }
    }

    var nibGlassNamespace: Namespace.ID? {
        get { self[NibGlassNamespaceKey.self] }
        set { self[NibGlassNamespaceKey.self] = newValue }
    }

    var nibBud: NibBudRequest? {
        get { self[NibBudKey.self] }
        set { self[NibBudKey.self] = newValue }
    }
}

public extension View {
    /// The app root passes the Appearance › Liquid setting here.
    func nibLiquidMode(_ mode: NibLiquidMode) -> some View { environment(\.nibLiquidMode, mode) }

    /// The frames of light paper (luminance > 0.6) under the container, in its coordinates: the editor passes its
    /// visible pages, never dark papers. Droplets over them get the edge lens and a deeper shadow on iOS 17–25
    /// (DESIGN.md §3.3), dark-mode Clear thickens to 80 %, and they recede while the Pencil is down.
    func nibBackdrop(_ pages: [CGRect]) -> some View { environment(\.nibBackdrop, pages) }
}
```

### 3.11 `NibKit/Sources/NibDesign/Liquid/DropletPhysics.swift`

The physics is internal: nothing outside NibDesign needs it, and the tests use `@testable import`. Only `.droplet` / `.budsFrom` / `DropletStyle` presets are public liquid API.

```swift
import CoreGraphics
import Foundation

// MARK: - Springs

/// A damped spring on one value in SwiftUI's parameterisation, integrated with semi-implicit Euler in fixed
/// 1/240 s sub-steps (stable for every Nib spring, frame-rate independent at 60, 80 and 120 Hz).
struct SpringValue: Equatable, Sendable {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var epsilon: CGFloat

    init(_ value: CGFloat, epsilon: CGFloat = 0.02) {
        self.value = value
        self.target = value
        self.epsilon = epsilon
    }

    var isResting: Bool { abs(value - target) < epsilon && abs(velocity) < epsilon * 4 }

    mutating func snap(to newValue: CGFloat) {
        value = newValue
        target = newValue
        velocity = 0
    }

    mutating func step(_ dt: CGFloat, spring: NibSpring) {
        guard dt > 0 else { return }
        let k = CGFloat(spring.stiffness)
        let c = CGFloat(spring.damping)
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
        if isResting {
            value = target
            velocity = 0
        }
    }
}

struct SpringPoint: Equatable, Sendable {
    var x: SpringValue
    var y: SpringValue

    init(_ point: CGPoint, epsilon: CGFloat = 0.05) {
        x = SpringValue(point.x, epsilon: epsilon)
        y = SpringValue(point.y, epsilon: epsilon)
    }

    var value: CGPoint { CGPoint(x: x.value, y: y.value) }

    var velocity: CGVector {
        get { CGVector(dx: x.velocity, dy: y.velocity) }
        set {
            x.velocity = newValue.dx
            y.velocity = newValue.dy
        }
    }

    var target: CGPoint {
        get { CGPoint(x: x.target, y: y.target) }
        set {
            x.target = newValue.x
            y.target = newValue.y
        }
    }

    var isResting: Bool { x.isResting && y.isResting }

    mutating func snap(to point: CGPoint) {
        x.snap(to: point.x)
        y.snap(to: point.y)
    }

    mutating func step(_ dt: CGFloat, spring: NibSpring) {
        x.step(dt, spring: spring)
        y.step(dt, spring: spring)
    }
}

// MARK: - Necks

/// A neck: joins at `join` pt, starts `t0` thick, thins as t = t0·(1 − gap/off)^0.7 and breaks below the minimum neck.
struct NeckParams: Equatable, Sendable {
    var join: CGFloat
    var t0: CGFloat
    var off: CGFloat
}

enum BondEvent: Equatable, Sendable {
    case joined, split
}

/// Hysteresis between two droplets: water holds on longer than it takes to join.
struct Bond: Equatable, Sendable {
    private(set) var isJoined = false
    var thickness = SpringValue(0, epsilon: 0.05)

    /// Updates the bond for this frame's gap. With `hysteresis` off (system glass on iOS 26, which has no memory)
    /// joining and splitting both happen at `join`, so haptics stay in step with what the system draws.
    mutating func update(gap: CGFloat, params: NeckParams, minimumNeck: CGFloat, enabled: Bool,
                         hysteresis: Bool) -> BondEvent? {
        let t = DropletPhysics.neckThickness(gap: gap, params: params)
        var event: BondEvent?
        if !enabled {
            isJoined = false
        } else if !isJoined && gap < params.join {
            isJoined = true
            event = .joined
        } else if isJoined && (hysteresis ? t < minimumNeck : gap >= params.join) {
            isJoined = false
            event = .split
        }
        thickness.target = isJoined && hysteresis ? t : 0
        return event
    }
}

// MARK: - Droplet physics

enum DropletPhysics {
    static let pickupSlop: CGFloat = 6
    static let rubberDimension: CGFloat = 120
    static let projection: CGFloat = 0.12
    static let carefulReleaseStill: Double = 0.070
    static let maxReleaseSpeed: CGFloat = 5000
    static let maxSlotSpeed: CGFloat = 1200
    /// Settle lead (DESIGN.md §10.3): when the stretch target falls back towards zero (the droplet slows down), the
    /// surface reacts as if it had fallen 33 ms earlier, so it overshoots zero once by about 6 % of its peak for every
    /// droplet size (water landing: half a visible cycle, never a second bounce). Without it the settle is a dead stop.
    static let settleLead: CGFloat = 0.033

    /// How far a held droplet trails the finger at `speed` with a critically damped follow spring: v·ζ·response/π
    /// (27 pt at 1000 pt/s with `follow`). The slight lag is the water's weight (DESIGN.md §10.1).
    static func followLag(speed: CGFloat, spring: NibSpring = NibMotion.follow) -> CGFloat {
        speed * CGFloat(spring.dampingRatio * spring.response) / .pi
    }

    /// UIScrollView-style resistance past [lo, hi]: edge + D·(1 − 1/(0.55·e/D + 1)).
    static func rubberBand(_ v: CGFloat, lo: CGFloat, hi: CGFloat, dimension d: CGFloat = rubberDimension) -> CGFloat {
        guard hi >= lo else { return (lo + hi) / 2 }
        if v < lo { return lo - (1 - 1 / ((lo - v) * 0.55 / d + 1)) * d }
        if v > hi { return hi + (1 - 1 / ((v - hi) * 0.55 / d + 1)) * d }
        return v
    }

    /// A careful release never flings: if the finger rested ≥ 70 ms the velocity is zero. Capped at 5000 pt/s.
    static func releaseVelocity(_ v: CGVector, stillFor: Double) -> CGVector {
        if stillFor >= carefulReleaseStill { return .zero }
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard speed > maxReleaseSpeed else { return v }
        let k = maxReleaseSpeed / speed
        return CGVector(dx: v.dx * k, dy: v.dy * k)
    }

    /// The landing a fling projects to: p + v·0.12 s.
    static func projectedLanding(_ p: CGPoint, velocity v: CGVector) -> CGPoint {
        CGPoint(x: p.x + v.dx * projection, y: p.y + v.dy * projection)
    }

    /// Grid and slot snaps (DESIGN.md §10.3): only the part of the release velocity that points at the slot, capped
    /// at 1200 pt/s and at ω·distance. With the critically damped `slot` spring no axis can then cross its target, so
    /// the droplet lands without overshooting and never leaves the box between where it was and where it goes.
    /// `displacement` is the droplet's offset from the slot (the slot is at zero).
    static func slotVelocity(_ v: CGVector, displacement d: CGPoint, spring: NibSpring = NibMotion.slot) -> CGVector {
        let distance = (d.x * d.x + d.y * d.y).squareRoot()
        guard distance > 0.001 else { return .zero }
        let ux = -d.x / distance, uy = -d.y / distance
        let along = max(0, v.dx * ux + v.dy * uy)
        let omega = 2 * CGFloat.pi / CGFloat(spring.response)
        let speed = min(along, maxSlotSpeed, omega * distance)
        return CGVector(dx: ux * speed, dy: uy * speed)
    }

    /// s* = min(cap, |v| / vRef).
    static func stretchTarget(speed: CGFloat, cap: CGFloat, vRef: CGFloat) -> CGFloat {
        min(cap, speed / max(vRef, 1))
    }

    /// The rendered stretch: the spring aims at s*, but what is drawn never passes the cap (and dips at most
    /// 0.4·cap below zero), so a spring's overshoot never shows as a stretch past its cap (DESIGN.md §10.2).
    static func clampStretch(_ s: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(s, -0.4 * cap), cap)
    }

    /// (−π/2, π/2]: a stretch looks the same forwards and backwards.
    static func wrapHalfTurn(_ a: CGFloat) -> CGFloat {
        a - .pi * (a / .pi).rounded()
    }

    /// θ follows its target exponentially, θ += Δ·(1 − e^(−18·dt)), so it never steps.
    static func followAxis(_ theta: CGFloat, toward target: CGFloat, dt: CGFloat) -> CGFloat {
        theta + wrapHalfTurn(target - theta) * (1 - exp(-18 * dt))
    }

    /// How much of the long-droplet regime applies: smoothstep(2.5, 3.5, aspect). Blended, never switched, so a
    /// palette re-forming through aspect 3 does not twist in one frame.
    static func longAxisWeight(aspect: CGFloat) -> CGFloat {
        let t = min(max((aspect - 2.5) / 1.0, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Fix 5: a long droplet deforms on its own axes only. The signed stretch is the tensor's component on the long
    /// axis: moving along it lengthens, moving across it shortens and thickens. No shear.
    static func axisLocked(stretch s: CGFloat, velocityAngle phi: CGFloat, longAxis: CGFloat) -> CGFloat {
        s * cos(2 * (phi - longAxis))
    }

    /// Volume-preserving in 3D (sx·sy·sz = 1 with the depth following the cross axis): along 1 + s, across 1/√(1 + s).
    /// Area preservation reads as rubber; this reads as a drop thinning as it stretches.
    static func deformation(stretch s: CGFloat, axis theta: CGFloat, lift: CGFloat = 1) -> CGAffineTransform {
        let along = (1 + s) * lift
        let across = lift / (1 + s).squareRoot()
        let c = cos(theta), n = sin(theta)
        let a = c * c * along + n * n * across
        let b = c * n * (along - across)
        let d = n * n * along + c * c * across
        return CGAffineTransform(a: a, b: b, c: b, d: d, tx: 0, ty: 0)
    }

    /// Fix 6: the droplet transform about the grab point `anchor` (both in coordinates centred on the rest centre),
    /// so the part under the finger stays under the finger: p' = offset + anchor + L·(q − anchor).
    static func transform(offset: CGPoint, anchor: CGPoint, linear: CGAffineTransform) -> CGAffineTransform {
        let la = CGPoint(x: linear.a * anchor.x + linear.c * anchor.y, y: linear.b * anchor.x + linear.d * anchor.y)
        return CGAffineTransform(a: linear.a, b: linear.b, c: linear.c, d: linear.d,
                                 tx: offset.x + anchor.x - la.x, ty: offset.y + anchor.y - la.y)
    }

    /// Converts a centred transform to SwiftUI's `transformEffect` space (origin at the view's top-left).
    static func aboutCentre(_ t: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(t)
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
    }

    static func neckThickness(gap: CGFloat, params: NeckParams) -> CGFloat {
        params.t0 * pow(max(0, 1 - gap / params.off), 0.7)
    }

    /// Polynomial smooth-min: the union the Metal field and system glass approximate (k = merge distance).
    static func smoothMin(_ d1: CGFloat, _ d2: CGFloat, k: CGFloat) -> CGFloat {
        let h = min(max(0.5 + 0.5 * (d2 - d1) / k, 0), 1)
        return d2 + (d1 - d2) * h - k * h * (1 - h)
    }

    /// Nearest points and gap between two droplet boxes. Corner-to-corner gaps grow by 0.59·r (rounded corners).
    static func gap(_ a: CGRect, _ b: CGRect, minCorner: CGFloat) -> (gap: CGFloat, pointA: CGPoint, pointB: CGPoint) {
        let ax: CGFloat, bx: CGFloat, ay: CGFloat, by: CGFloat
        if a.maxX < b.minX {
            ax = a.maxX; bx = b.minX
        } else if b.maxX < a.minX {
            ax = a.minX; bx = b.maxX
        } else {
            ax = (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2; bx = ax
        }
        if a.maxY < b.minY {
            ay = a.maxY; by = b.minY
        } else if b.maxY < a.minY {
            ay = a.minY; by = b.maxY
        } else {
            ay = (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2; by = ay
        }
        var g = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
        if ax != bx && ay != by { g += minCorner * 0.59 }
        return (g, CGPoint(x: ax, y: ay), CGPoint(x: bx, y: by))
    }

    /// The axis a docked droplet may slide along when it fuses (its dock fixes the other one).
    enum ContactAxis: Sendable {
        case horizontal, vertical
    }

    /// B's fuse (with fix 7): after a release within the merge distance, slide `moving` along the contact axis until the
    /// edges overlap by 1 pt, and (when free to) align centres within 24 pt. With ≥ 4.5 pt content inset at each end the
    /// glyph boxes then stay ≥ 8 pt apart.
    static func fuse(_ moving: CGRect, onto fixed: CGRect, along axis: ContactAxis? = nil) -> CGRect {
        var r = moving
        let gapX = max(fixed.minX - moving.maxX, moving.minX - fixed.maxX)
        let gapY = max(fixed.minY - moving.maxY, moving.minY - fixed.maxY)
        let horizontal = axis.map { $0 == .horizontal } ?? (gapX >= gapY)
        if horizontal {
            r.origin.x = moving.midX < fixed.midX ? fixed.minX + 1 - moving.width : fixed.maxX - 1
            if axis == nil && abs(moving.midY - fixed.midY) <= 24 { r.origin.y = fixed.midY - moving.height / 2 }
        } else {
            r.origin.y = moving.midY < fixed.midY ? fixed.minY + 1 - moving.height : fixed.maxY - 1
            if axis == nil && abs(moving.midX - fixed.midX) <= 24 { r.origin.x = fixed.midX - moving.width / 2 }
        }
        return r
    }

    /// Where a docking droplet may come to rest next to a neighbour: fused if within `mergeDistance`, pushed out to
    /// 16 pt if in the banned 12–15 pt band, otherwise unchanged. A docked droplet (`axis` set) only slides along its
    /// dock, and only neighbours beside it on that axis count.
    static func restingRect(_ moving: CGRect, near fixed: CGRect, mergeDistance: CGFloat,
                            along axis: ContactAxis? = nil) -> CGRect {
        if let axis {
            let across = axis == .horizontal
                ? (moving.minY < fixed.maxY && fixed.minY < moving.maxY)
                : (moving.minX < fixed.maxX && fixed.minX < moving.maxX)
            guard across else { return moving }
        }
        let g = gap(moving, fixed, minCorner: 0).gap
        if g < mergeDistance { return fuse(moving, onto: fixed, along: axis) }
        guard g < 16 else { return moving }
        var r = moving
        let push = 16 - g
        let gapX = max(fixed.minX - moving.maxX, moving.minX - fixed.maxX)
        let gapY = max(fixed.minY - moving.maxY, moving.minY - fixed.maxY)
        let horizontal = axis.map { $0 == .horizontal } ?? (gapX >= gapY)
        if horizontal {
            r.origin.x += moving.midX < fixed.midX ? -push : push
        } else {
            r.origin.y += moving.midY < fixed.midY ? -push : push
        }
        return r
    }

    /// Fix 2: while the palette re-forms, content cross-fades over progress 0.42–0.58 and is invisible at the
    /// midpoint, where the layout switches axis. The toolbar is dark for under 100 ms.
    static func reshapeContentOpacity(progress p: CGFloat) -> CGFloat {
        if p <= 0.42 || p >= 0.58 { return 1 }
        return abs(p - 0.5) / 0.08
    }
}

// MARK: - Selection bead

struct BeadGeometry: Equatable, Sendable {
    var head: CGFloat
    var tail: CGFloat
    var headRadius: CGFloat
    var tailRadius: CGFloat
    var neckWidth: CGFloat
}

enum BeadPhysics {
    static let tailRatio: CGFloat = 0.78
    /// Fix 1 (from C), tightened: the tail never falls more than 1.0·r behind the head, so the bead never splits and
    /// the teardrop shows only on jumps longer than three tools.
    static let maxSeparation: CGFloat = 1.0
    /// Fix 1: the neck's half-width never drops below 0.72 of the smaller radius.
    static let minNeckHalfWidth: CGFloat = 0.72

    static func clampTail(head: CGFloat, tail: CGFloat, radius: CGFloat) -> CGFloat {
        let m = maxSeparation * radius
        return min(max(tail, head - m), head + m)
    }

    static func geometry(head: CGFloat, tail: CGFloat, radius r: CGFloat) -> BeadGeometry {
        let t = clampTail(head: head, tail: tail, radius: r)
        let rt = r * tailRatio
        let separation = abs(head - t)
        let neck = max(2 * minNeckHalfWidth * rt, 1.2 * r * (1 - separation / 150))
        return BeadGeometry(head: head, tail: t, headRadius: r, tailRadius: rt, neckWidth: neck)
    }

    /// Passing lens: icons within 30 pt of the head magnify up to 1.13×.
    static func passingLens(distance d: CGFloat) -> CGFloat {
        1 + 0.13 * max(0, 1 - d / 30)
    }
}

// MARK: - One droplet's dynamics

/// Position, size, corner, stretch (surface tension), lift and grab anchor of one droplet.
struct DropletDynamics: Equatable, Sendable {
    var offset = SpringPoint(.zero)
    var size = SpringPoint(.zero)
    var corner = SpringValue(0, epsilon: 0.05)
    var stretch = SpringValue(0, epsilon: 0.0004)
    var axis: CGFloat = 0
    var lift = SpringValue(1, epsilon: 0.0004)
    var anchor = SpringPoint(.zero)
    var positionSpring = NibMotion.snap
    var sizeSpring = NibMotion.budSize

    /// The rendered stretch for this droplet's (Calm-halved) cap.
    func renderStretch(cap: CGFloat) -> CGFloat { DropletPhysics.clampStretch(stretch.value, cap: cap) }

    /// Advances one frame and returns true while anything moves. Under `reduceMotion` the shape jumps to its targets
    /// (no stretch, no lift spring) and positions use the critically damped `reduced` spring.
    mutating func step(_ dt: CGFloat, style: DropletStyle, reduceMotion: Bool, calm: Bool) -> Bool {
        offset.step(dt, spring: reduceMotion ? NibMotion.reduced : positionSpring)
        size.step(dt, spring: reduceMotion ? NibMotion.reduced : sizeSpring)
        corner.step(dt, spring: reduceMotion ? NibMotion.reduced : sizeSpring)
        anchor.step(dt, spring: NibMotion.snap)
        if reduceMotion {
            lift.snap(to: lift.target)
        } else {
            lift.step(dt, spring: NibMotion.lift)
        }

        let v = offset.velocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        let cap = calm ? style.stretchCap / 2 : style.stretchCap
        var target = DropletPhysics.stretchTarget(speed: speed, cap: cap, vRef: style.vRef)
        let w = max(size.x.value, 1), h = max(size.y.value, 1)
        let long: CGFloat = w >= h ? 0 : .pi / 2
        let weight = DropletPhysics.longAxisWeight(aspect: max(w, h) / min(w, h))
        let phi = atan2(v.dy, v.dx)
        if speed > 40 {
            target *= 1 + (cos(2 * (phi - long)) - 1) * weight
        }
        let free = speed > 40 ? phi : axis
        axis = DropletPhysics.followAxis(axis, toward: free + DropletPhysics.wrapHalfTurn(long - free) * weight, dt: dt)

        if reduceMotion || cap == 0 {
            stretch.snap(to: 0)
        } else {
            let wobble = NibMotion.wobble(minor: min(w, h))
            if abs(target) < abs(stretch.target) {
                // Settle lead: a target falling back towards zero kicks the surface by the spring force it would have
                // felt had it fallen `settleLead` earlier. Rising targets (speeding up) get no lead.
                let omega = 2 * CGFloat.pi / CGFloat(wobble.response)
                stretch.velocity += omega * omega * DropletPhysics.settleLead * (target - stretch.target)
            }
            stretch.target = target
            stretch.step(dt, spring: wobble)
        }
        return !(offset.isResting && size.isResting && corner.isResting && stretch.isResting
                 && lift.isResting && anchor.isResting)
    }
}
```

### 3.12 `NibKit/Sources/NibDesign/Liquid/DropletStyle.swift`

```swift
import SwiftUI

/// Edges a floating palette can dock to.
public enum NibDock: String, CaseIterable, Sendable {
    case leading, trailing, top, bottom

    public var isVertical: Bool { self == .leading || self == .trailing }

    var moveTitle: String {
        switch self {
        case .leading: return String(localized: "Move palette to the left edge", bundle: .module)
        case .trailing: return String(localized: "Move palette to the right edge", bundle: .module)
        case .top: return String(localized: "Move palette to the top", bundle: .module)
        case .bottom: return String(localized: "Move palette to the bottom", bundle: .module)
        }
    }
}

/// How a droplet responds to a drag.
public enum DropletDrag: Equatable, Sendable {
    /// Does not move (bars, HUDs, popovers, handles: their feature moves them).
    case fixed
    /// Follows the finger and returns to its rest, or to a new rest the feature lays out, with the `slot` spring from
    /// the part of the release velocity that points there (cards, thumbnails, floating panels).
    case free
    /// Docks to screen edges with `snap` from the full release velocity (the palette manages this itself).
    case docks([NibDock])
    /// Hangs from an anchor and flows back to its dock on release (the AI proposal chip).
    case tethered
}

/// The droplet materials. (Not `Material`: that would shadow `SwiftUI.Material` inside this module and trip the
/// lint rule for materials in features.)
public enum DropletMaterial: Equatable, Sendable {
    case clear, deep, tinted
}

/// A droplet preset. Feature code only uses the static presets.
public struct DropletStyle: Equatable, Sendable {
    public var material: DropletMaterial
    /// nil = capsule.
    public var cornerRadius: CGFloat?
    public var stretchCap: CGFloat
    public var vRef: CGFloat = 2600
    /// Content follows s × rigidity: icons 0.55, covers 0.70, chip 0.35, popover content 0.15, panels 0.10.
    public var rigidity: CGFloat
    public var lift: CGFloat = 1.035
    /// Stretch-velocity impulse on a press, sized to the droplet's wobble spring: 2.4 is a 2.5 % squash on a 44 pt bar.
    public var poke: CGFloat = 2.4
    var neck: NeckParams?
    public var drag: DropletDrag = .fixed
    /// Water margin that grows around the content while lifted (covers and thumbnails: 3 pt).
    public var envelope: CGFloat = 0
    /// No water at rest: the droplet only exists while it is dragged or settling (covers, thumbnails).
    public var restsDry = false
    /// Necks only on request (`.droplet(bondsWith:)`), never from proximity: library cards bond once a combine arms.
    public var bondsOnRequest = false
    /// Rim and outline only, no body (the zoom-window target frame). Drawn by the droplet itself, outside the union.
    public var drawsBody = true
    /// Page-resident droplets sit on ink and never refract it (the chip, the lasso object menu). iOS 17–25: no edge lens.
    /// iOS 26: the system glass always lenses, so these are docked clear of ink instead; they stay the Regular variant
    /// like every other droplet (Clear glass is for media and never mixes with Regular, DESIGN.md §2.2).
    public var refracts = true
    /// Touchable chrome: `Glass.interactive()` on iOS 26 wherever the glass itself takes the touch (`nibGlass`, a
    /// droplet outside a container). Inside a container the body sits behind the content and is never hit-tested, so
    /// the poke (§10.2) and the held rim (`liftedRim`) are the press response there.
    public var isInteractive = true
    /// Rim strength at rest (DESIGN.md §10.9): 1. `lifted` raises it to `liftedRim`.
    public var rim: CGFloat = 1
    /// Rim strength while the droplet is held, reached at full lift and following the lift spring there and back: the
    /// key rim, counter-rim and sheen all scale by it (1.5 = half as bright again). 1 = never brightens (precision
    /// handles). iOS 26 draws the difference over the system glass; iOS 17–25 feeds it to the water shader.
    public var liftedRim: CGFloat = NibOptics.liftedRim

    public static let bar = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.10, rigidity: 0.5,
                                         neck: NeckParams(join: 11, t0: 26, off: 44))
    public static let hud = bar
    public static let palette = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.09, rigidity: 0.55,
                                             poke: 2.2, neck: NeckParams(join: 11, t0: 26, off: 44),
                                             drag: .docks(NibDock.allCases))
    public static let popover = DropletStyle(material: .deep, cornerRadius: NibRadius.popover, stretchCap: 0.06,
                                             rigidity: 0.15, lift: 1.0, poke: 0.5,
                                             neck: NeckParams(join: 11, t0: 30, off: 21), isInteractive: false)
    public static let panel = DropletStyle(material: .deep, cornerRadius: NibRadius.panel, stretchCap: 0.03,
                                           rigidity: 0.10, lift: 1.0, poke: 0.5,
                                           neck: NeckParams(join: 11, t0: 28, off: 44), isInteractive: false)
    public static let floatingPanel = DropletStyle(material: .deep, cornerRadius: NibRadius.panel, stretchCap: 0.03,
                                                   rigidity: 0.10, lift: 1.02, poke: 0.5,
                                                   neck: NeckParams(join: 11, t0: 28, off: 44), drag: .free,
                                                   isInteractive: false)
    public static let chip = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.16, rigidity: 0.35,
                                          lift: 1.05, neck: NeckParams(join: 14, t0: 24, off: 96), drag: .tethered,
                                          refracts: false)
    public static let anchor = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0.20, rigidity: 1,
                                            lift: 1.0, neck: NeckParams(join: 14, t0: 24, off: 96), refracts: false)
    public static let card = DropletStyle(material: .clear, cornerRadius: NibRadius.coverSpine, stretchCap: 0.10,
                                          vRef: 2800, rigidity: 0.70, lift: 1.045, poke: 1.4,
                                          neck: NeckParams(join: 13, t0: 30, off: 46), drag: .free, envelope: 3,
                                          restsDry: true, bondsOnRequest: true)
    public static let thumbnail = DropletStyle(material: .clear, cornerRadius: NibRadius.thumbnail, stretchCap: 0.10,
                                               rigidity: 0.70, lift: 1.045, poke: 1.4, drag: .free, envelope: 3,
                                               restsDry: true)
    public static let toast = DropletStyle(material: .deep, cornerRadius: nil, stretchCap: 0.08, rigidity: 0.2,
                                           lift: 1.0, poke: 1.0, isInteractive: false)
    public static let primary = DropletStyle(material: .tinted, cornerRadius: nil, stretchCap: 0.10, rigidity: 0.5,
                                             neck: NeckParams(join: 11, t0: 26, off: 44))
    /// Precision affordances never deform (DESIGN.md §10.15): lasso and resize handles, the rotation bead.
    public static let handle = DropletStyle(material: .clear, cornerRadius: nil, stretchCap: 0, rigidity: 1, lift: 1.0,
                                            poke: 0, refracts: false, isInteractive: false, liftedRim: 1)
    /// The zoom-window target: rim and outline only, radius 18, draggable with stretch.
    public static let frame = DropletStyle(material: .clear, cornerRadius: NibRadius.zoomFrame, stretchCap: 0.06,
                                           rigidity: 1, lift: 1.0, poke: 0, drag: .free, drawsBody: false,
                                           refracts: false, isInteractive: false)

    var glassKind: NibGlass {
        switch material {
        case .clear: return .clear
        case .deep: return .deep
        case .tinted: return .tinted
        }
    }

    /// The same droplet shown as held: its rim at `liftedRim` without being dragged (a feature's own press-and-hold
    /// state, the gallery). A drag brightens the rim by itself, following the lift spring.
    public var lifted: DropletStyle {
        var style = self
        style.rim = max(rim, liftedRim)
        return style
    }

    /// Rim strength at lift progress `progress` (0 at rest, 1 fully lifted): `rim` → `max(rim, liftedRim)`.
    public func rimStrength(lift progress: CGFloat) -> CGFloat {
        rim + (max(rim, liftedRim) - rim) * min(max(progress, 0), 1)
    }

    /// What this droplet asks of the system glass on iOS 26 (DESIGN.md §2.2).
    var systemGlassSpec: NibSystemGlass { NibSystemGlass.of(glassKind, interactive: isInteractive) }
}

@available(iOS 26.0, *)
extension DropletStyle {
    /// Regular for every material (tinted with the accent only for Tinted), interactive for touchable chrome.
    var systemGlass: Glass { systemGlassSpec.glass }
}

/// Where the palette rests: an edge plus a 0…1 position along it.
public struct NibPaletteDock: Equatable, Sendable {
    public var edge: NibDock
    public var along: CGFloat

    public init(edge: NibDock, along: CGFloat = 0.5) {
        self.edge = edge
        self.along = along
    }

    public var isVertical: Bool { edge.isVertical }
}

/// Drag events a feature can observe (library drop targets, page reorder), in `NibLiquid.space` coordinates.
public enum NibDropletDrag {
    case began(location: CGPoint)
    case changed(location: CGPoint)
    case ended(location: CGPoint, velocity: CGVector)
}
```

### 3.13 `NibKit/Sources/NibDesign/Liquid/DropletField.swift`

**Observation is per droplet.** The per-frame state (`entries`, `beads`, bonds) is `@ObservationIgnored`. Each droplet publishes an Equatable `DropletPresentation` through its own `DropletNode`, assigned only when it changes, and each bead its own `BeadNode`. So while one droplet moves, only that droplet's modifier re-renders; the container body, the palette body and every other droplet do not. The only views that read field-wide state every frame are the leaf water, frost and neck layers (`clusters`, `necks`, `satellites`).

```swift
import SwiftUI
import Observation
import QuartzCore

/// What one droplet's views need this frame. Equatable, so a node is only written when something changed.
struct DropletPresentation: Equatable {
    var hidden = false
    /// The droplet has bud state in the field (then `hidden` is the field's word, not the binding's).
    var hasBud = false
    var revealed = true
    var contentOpacity: Double = 1
    var contentTransform: CGAffineTransform = .identity
    var bodySize: CGSize = .zero
    var bodyOffset: CGPoint = .zero
    var cornerRadius: CGFloat = 0
    var budLine = false
    /// The body's exact outline (size, radius, stretch, axis, grab origin, lift) in the content's untransformed
    /// coordinates, while the body is smaller than the content: budding, retracting, re-forming. Content is clipped
    /// to it before its own transform, so the clip lands on the body and nothing ever draws outside it.
    var bodyMask: Path?
    var isLifted = false
    /// Rim strength (DESIGN.md §10.9): 1 at rest, rising to the style's `liftedRim` with the lift spring while held.
    /// iOS 26 draws the difference over the system glass (`NibLiftRim`); iOS 17–25 passes it to the water shader.
    var rim: CGFloat = 1
    /// Released and still flowing home (the proposal chip shows its anchor until then).
    var isSettling = false
    var isDrawn = false
    /// Recede while the Pencil is down: over the page or within 24 pt of the stroke (DESIGN.md §10.8).
    var recedes = false
    var reshape: DropletField.ReshapePhase = .idle
}

/// One droplet's published state; its modifier is the only reader.
@Observable
final class DropletNode {
    var presentation = DropletPresentation()
}

/// One selection bead's published state; the bead and the palette's tool buttons (passing lens) read it.
@Observable
final class BeadNode {
    var head: CGFloat = 0
    var tail: CGFloat = 0
}

/// One container's droplets: rest frames, springs, bonds (necks), buds, reshapes, beads, satellites and recede.
/// A display link steps it only while something moves and parks when every spring rests (0 ms idle cost).
@Observable
final class DropletField {
    struct Entry {
        let id: String
        var style: DropletStyle
        var rest: CGRect = .zero
        var hasRest = false
        var dyn = DropletDynamics()
        var isDragging = false
        var grabOffset: CGPoint = .zero
        var lastMove: CFTimeInterval = 0
        var dragScale: CGFloat = 1
        /// Released toward a slot: the release velocity is re-projected if the feature lays out a new slot (FLIP).
        var landing: CGVector?
        var bondTarget: String?
        var bud: BudState?
        var reshape: ReshapePhase = .idle
        var reshapeFrom: CGFloat = 0
        var contentAlpha: CGFloat = 1
    }

    struct BudState {
        var source: String
        var owner: String
        var presented: Bool
        var revealed: Bool
        var visible: Bool
        var startedAt: CFTimeInterval
        var closingAt: CFTimeInterval?
    }

    enum ReshapePhase: Equatable {
        case idle, gathering, spreading
    }

    struct BeadState: Equatable {
        var head: SpringValue
        var tail: SpringValue
        var arrived = true
        var scrubbing = false
    }

    struct PairKey: Hashable {
        let a: String
        let b: String

        init(_ x: String, _ y: String) {
            if x < y {
                a = x; b = y
            } else {
                a = y; b = x
            }
        }
    }

    /// A bud source inside a droplet (a palette tool): its rect in the owner's centred coordinates.
    struct LocalAnchor {
        let owner: String
        let rect: CGRect
    }

    /// Kind weights written into the metaball field's colour channels: red = clear, green = deep, blue = tinted. Their
    /// sum (relative to coverage) carries the droplet's share over light paper: 0.5 on a flat desk, 1 fully over paper.
    struct FieldColour: Equatable {
        var clear: Double
        var deep: Double
        var tinted: Double

        var color: Color { Color(red: clear, green: deep, blue: tinted) }

        static func of(_ m: DropletMaterial, paper: Double) -> FieldColour {
            let k = 0.5 + 0.5 * min(max(paper, 0), 1)
            switch m {
            case .clear: return FieldColour(clear: k, deep: 0, tinted: 0)
            case .deep: return FieldColour(clear: 0, deep: k, tinted: 0)
            case .tinted: return FieldColour(clear: 0, deep: 0, tinted: k)
            }
        }

        static func mix(_ x: FieldColour, _ y: FieldColour) -> FieldColour {
            FieldColour(clear: (x.clear + y.clear) / 2, deep: (x.deep + y.deep) / 2, tinted: (x.tinted + y.tinted) / 2)
        }
    }

    struct Neck: Identifiable, Equatable {
        let id: String
        let from: CGPoint
        let to: CGPoint
        let thickness: CGFloat
        let colour: FieldColour

        var length: CGFloat { ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot() }
        var angle: CGFloat { atan2(to.y - from.y, to.x - from.x) }
        var midpoint: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
        var path: Path {
            Path { p in
                p.move(to: from)
                p.addLine(to: to)
            }
        }
    }

    /// C's satellite: the 5 pt drop a pinched tether leaves behind, absorbed back into its anchor.
    struct Satellite: Identifiable, Equatable {
        let id: Int
        let target: String
        var centre: SpringPoint
        var radius: SpringValue

        var path: Path {
            let c = centre.value, r = max(0, radius.value)
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
    }

    struct Render: Identifiable, Equatable {
        let id: String
        let material: DropletMaterial
        let path: Path
        let innerPath: Path
        let frostPath: Path
        let frostOpacity: Double
        let budLine: Bool
        /// Share of the droplet over light paper (edge lens, deeper shadow, dark-mode Clear body).
        let paper: Double
        /// Lift progress (0 at rest, 1 fully lifted) and the rim strength it gives (DESIGN.md §10.9).
        let lift: Double
        let rim: Double
        /// False for covers and thumbnails: their content carries its own lifted shadow.
        let castsShadow: Bool
    }

    // Per-frame state: not observed (views observe their own node, and the water layers the clusters).
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var beads: [String: BeadState] = [:]
    @ObservationIgnored private var nodes: [String: DropletNode] = [:]
    @ObservationIgnored private var beadNodes: [String: BeadNode] = [:]
    @ObservationIgnored private var bonds: [PairKey: Bond] = [:]
    @ObservationIgnored private var links: Set<PairKey> = []
    @ObservationIgnored private var anchors: [String: LocalAnchor] = [:]
    @ObservationIgnored private var dismissers: [String: () -> Void] = [:]
    @ObservationIgnored private var pendingBuds: [String: (source: String, presented: Bool)] = [:]
    @ObservationIgnored private var driver: DisplayLinkDriver?
    @ObservationIgnored private var restoreWork: DispatchWorkItem?
    @ObservationIgnored private var nextSatellite = 0
    @ObservationIgnored private var stroke: CGRect = .null
    @ObservationIgnored private var backdrop: [CGRect] = []
    /// A dockable droplet's meniscus to the dock it reaches for (DESIGN.md §10.11), by droplet id. `DockMeniscus`
    /// (DropletDock.swift) owns its rules; the field steps it and draws it as one of that droplet's necks.
    @ObservationIgnored private var meniscuses: [String: DockMeniscus] = [:]

    // Observed by the leaf layers only (water, frost, necks), and written only when they change.
    private(set) var clusters: [WaterCluster] = []
    private(set) var necks: [Neck] = []
    private(set) var satellites: [Satellite] = []
    // Observed; each changes rarely.
    private(set) var hasOpenBud = false
    /// The Pencil is down: physics is parked.
    private(set) var isInking = false
    /// Backdrop sampling is frozen and droplets near the ink recede: from Pencil down until 450 ms after it lifts.
    private(set) var isFrozen = false
    private(set) var isThermallyThrottled = false
    /// `nibBudAnchor` frames, in `NibLiquid.space`.
    private(set) var worldAnchors: [String: CGRect] = [:]
    var bounds: CGRect = .zero
    var metrics: DropletMetrics = .regular
    var reduceMotion = false
    var mode: NibLiquidMode = .full
    var usesSystemGlass = false

    init() {}

    private var physicsOff: Bool { reduceMotion || mode == .off }
    private var necksOn: Bool { !reduceMotion && mode == .full }

    // MARK: Nodes

    func node(_ id: String) -> DropletNode {
        if let n = nodes[id] { return n }
        let n = DropletNode()
        nodes[id] = n
        return n
    }

    func beadNode(_ id: String) -> BeadNode {
        if let n = beadNodes[id] { return n }
        let n = BeadNode()
        beadNodes[id] = n
        return n
    }

    /// Writes every node and the layers' state, each only if it changed. Called at the end of every tick and after
    /// mutations that happen while physics is parked (inking, stroke growth).
    private func publish() {
        for id in order {
            let p = presentation(id)
            let n = node(id)
            if n.presentation != p { n.presentation = p }
        }
        for (id, b) in beads {
            let n = beadNode(id)
            if n.head != b.head.value { n.head = b.head.value }
            if n.tail != b.tail.value { n.tail = b.tail.value }
        }
        let open = entries.values.contains { $0.bud?.presented == true }
        if open != hasOpenBud { hasOpenBud = open }
        let next = buildClusters()
        if next != clusters { clusters = next }
    }

    // MARK: Registration and layout

    func register(_ id: String, style: DropletStyle) {
        if var entry = entries[id] {
            if entry.style != style {
                entry.style = style
                entries[id] = entry
            }
            return
        }
        entries[id] = Entry(id: id, style: style)
        order.append(id)
    }

    func unregister(_ id: String) {
        entries[id] = nil
        order.removeAll { $0 == id }
        bonds = bonds.filter { $0.key.a != id && $0.key.b != id }
        links = links.filter { $0.a != id && $0.b != id }
        dismissers[id] = nil
        beads[id] = nil
        beadNodes[id] = nil
        nodes[id] = nil
        anchors = anchors.filter { $0.value.owner != id }
        wake()
    }

    /// Called with the droplet's laid-out frame. A changed frame animates from where the droplet is on screen to the
    /// new layout (FLIP), keeping any release velocity: reflow, docking and re-forming all go through here.
    func setRest(_ id: String, _ rect: CGRect, style: DropletStyle) {
        register(id, style: style)
        guard var e = entries[id], rect.width > 0, rect.height > 0 else { return }
        if !e.hasRest {
            e.rest = rect
            e.hasRest = true
            e.dyn.size.snap(to: CGPoint(x: rect.width, y: rect.height))
            e.dyn.corner.snap(to: cornerTarget(e.style, rect.size))
            entries[id] = e
            if let pending = pendingBuds.removeValue(forKey: id) {
                setBud(id, source: pending.source, presented: pending.presented, instant: true, dismiss: dismissers[id] ?? {})
            }
            wake()
            return
        }
        guard rect != e.rest else { return }
        let visual = visualCentre(e)
        e.dyn.offset.x.value = visual.x - rect.midX
        e.dyn.offset.y.value = visual.y - rect.midY
        if !e.isDragging && e.bud?.closingAt == nil { e.dyn.offset.target = .zero }
        if let released = e.landing {         // a new slot: aim the release at it
            e.dyn.offset.velocity = DropletPhysics.slotVelocity(released, displacement: e.dyn.offset.value)
        }
        if e.reshape != .gathering { e.dyn.size.target = CGPoint(x: rect.width, y: rect.height) }
        e.dyn.corner.target = cornerTarget(e.style, rect.size)
        e.rest = rect
        entries[id] = e
        wake()
    }

    /// A bud source inside a droplet; `rect` is in the owner's centred coordinates.
    func setLocalAnchor(_ id: String, owner: String, rect: CGRect) {
        anchors[id] = LocalAnchor(owner: owner, rect: rect)
    }

    func setWorldAnchor(_ id: String, _ rect: CGRect) {
        if worldAnchors[id] != rect { worldAnchors[id] = rect }
    }

    func setBackdrop(_ pages: [CGRect]) {
        guard pages != backdrop else { return }
        backdrop = pages
        publish()
    }

    /// Necks only on request (`DropletStyle.bondsOnRequest`): the library bonds a lifted card to its target once the
    /// combine arms.
    func setBondTarget(_ id: String, _ target: String?) {
        guard var e = entries[id], e.bondTarget != target else { return }
        e.bondTarget = target
        entries[id] = e
        wake()
    }

    // MARK: Geometry

    private func cornerTarget(_ style: DropletStyle, _ size: CGSize) -> CGFloat {
        style.cornerRadius ?? min(size.width, size.height) / 2
    }

    func visualCentre(_ e: Entry) -> CGPoint {
        CGPoint(x: e.rest.midX + e.dyn.offset.x.value, y: e.rest.midY + e.dyn.offset.y.value)
    }

    private func liftProgress(_ e: Entry) -> CGFloat {
        let span = e.style.lift - 1
        guard span > 0.0001 else { return e.isDragging ? 1 : 0 }
        return min(max((e.dyn.lift.value - 1) / span, 0), 1)
    }

    func bodySize(_ e: Entry) -> CGSize {
        let pad = e.style.envelope * 2 * liftProgress(e)
        return CGSize(width: max(0, e.dyn.size.x.value + pad), height: max(0, e.dyn.size.y.value + pad))
    }

    func cornerRadius(_ e: Entry) -> CGFloat {
        let s = bodySize(e)
        let capsule = min(s.width, s.height) / 2
        guard e.style.cornerRadius != nil else { return capsule }
        return min(e.dyn.corner.value + e.style.envelope * liftProgress(e), capsule)
    }

    func visualBox(_ e: Entry) -> CGRect {
        let s = bodySize(e), c = visualCentre(e), l = e.dyn.lift.value
        return CGRect(x: c.x - s.width * l / 2, y: c.y - s.height * l / 2, width: s.width * l, height: s.height * l)
    }

    func visualFrame(_ id: String) -> CGRect? {
        guard let e = entries[id], e.hasRest else { return nil }
        return visualBox(e)
    }

    func isDrawn(_ e: Entry) -> Bool {
        guard e.hasRest, e.bud?.visible ?? true else { return false }
        if !e.style.restsDry { return true }
        return e.isDragging || !e.dyn.offset.isResting || e.dyn.lift.value > 1.001
    }

    private func cap(_ e: Entry) -> CGFloat { mode == .calm ? e.style.stretchCap / 2 : e.style.stretchCap }

    private func linear(_ e: Entry, rigidity: CGFloat) -> CGAffineTransform {
        DropletPhysics.deformation(stretch: e.dyn.renderStretch(cap: cap(e)) * rigidity, axis: e.dyn.axis,
                                   lift: e.dyn.lift.value)
    }

    private func worldTransform(_ e: Entry) -> CGAffineTransform {
        DropletPhysics.transform(offset: e.dyn.offset.value, anchor: e.dyn.anchor.value, linear: linear(e, rigidity: 1))
            .concatenating(CGAffineTransform(translationX: e.rest.midX, y: e.rest.midY))
    }

    /// The body outline in centred coordinates, before any transform.
    private func localBody(_ e: Entry, inset: CGFloat) -> Path {
        let s = bodySize(e)
        let w = max(0, s.width - 2 * inset), h = max(0, s.height - 2 * inset)
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let r = max(0, min(cornerRadius(e) - inset, min(w, h) / 2))
        return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
    }

    private func bodyPath(_ e: Entry, inset: CGFloat) -> Path {
        localBody(e, inset: inset).applying(worldTransform(e))
    }

    private func sourceRect(_ source: String) -> CGRect? {
        if let a = anchors[source], let owner = entries[a.owner], owner.hasRest {
            return a.rect.applying(worldTransform(owner))
        }
        if let rect = worldAnchors[source] { return rect }
        if let e = entries[source], e.hasRest { return visualBox(e) }
        return nil
    }

    private func sourcePoint(_ source: String) -> CGPoint? {
        sourceRect(source).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Where a popover should grow from: a palette tool's slot, a `nibBudAnchor`, or a droplet (NibBudPlacement).
    func anchorRect(_ source: String) -> CGRect? { sourceRect(source) }

    /// Share of a box over light paper (`nibBackdrop`).
    private func paperShare(_ box: CGRect) -> Double {
        let area = max(box.width * box.height, 1)
        let covered = backdrop.reduce(CGFloat(0)) { sum, page in
            let i = box.intersection(page)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        return Double(min(covered / area, 1))
    }

    private func recedes(_ e: Entry) -> Bool {
        guard isFrozen else { return false }
        let box = visualBox(e)
        if paperShare(box) > 0 { return true }
        guard !stroke.isNull else { return false }
        let dx = max(0, stroke.minX - box.maxX, box.minX - stroke.maxX)
        let dy = max(0, stroke.minY - box.maxY, box.minY - stroke.maxY)
        return (dx * dx + dy * dy).squareRoot() < NibLiquid.recedeReach
    }

    /// Where a docking droplet should rest given its neighbours: fused (1 pt overlap) or ≥ 16 pt apart.
    func restingRect(_ rect: CGRect, excluding id: String, along axis: DropletPhysics.ContactAxis?) -> CGRect {
        var r = rect
        for other in order where other != id {
            guard let o = entries[other], isDrawn(o), o.style.neck != nil, o.bud == nil else { continue }
            r = DropletPhysics.restingRect(r, near: visualBox(o), mergeDistance: metrics.mergeDistance, along: axis)
        }
        return r
    }

    // MARK: What the views draw

    private func presentation(_ id: String) -> DropletPresentation {
        guard let e = entries[id], e.hasRest else { return DropletPresentation() }
        let size = bodySize(e)
        let body = linear(e, rigidity: 1)
        let anchor = e.dyn.anchor.value
        let offset = e.dyn.offset.value
        let content: CGAffineTransform
        if usesSystemGlass {
            let r = e.style.rigidity
            content = CGAffineTransform(a: 1 + (body.a - 1) * r, b: 0, c: 0, d: 1 + (body.d - 1) * r, tx: 0, ty: 0)
        } else {
            content = linear(e, rigidity: e.style.rigidity)
        }
        // Fix 7: while a dragged droplet overlaps this one, this one's glyphs yield (down to 25 % over 12 pt of
        // overlap), so two sets of icons never draw on top of each other. At rest, fuse keeps them >= 8 pt apart.
        var alpha = Double(e.contentAlpha)
        if !e.isDragging {
            let box = visualBox(e)
            for other in order where other != id {
                guard let o = entries[other], o.isDragging else { continue }
                let overlap = box.intersection(visualBox(o))
                if !overlap.isNull {
                    let depth = min(overlap.width, overlap.height)
                    alpha *= Double(max(0.25, 1 - max(0, depth - 1) / 12))
                }
            }
        }
        var p = DropletPresentation(hidden: e.bud.map { !$0.visible } ?? false)
        p.hasBud = e.bud != nil
        p.revealed = e.bud?.revealed ?? true
        p.contentOpacity = alpha
        p.contentTransform = DropletPhysics.aboutCentre(
            DropletPhysics.transform(offset: offset, anchor: anchor, linear: content), size: e.rest.size)
        p.bodySize = CGSize(width: size.width * body.a, height: size.height * body.d)
        p.bodyOffset = CGPoint(x: offset.x + anchor.x * (1 - body.a), y: offset.y + anchor.y * (1 - body.d))
        p.cornerRadius = cornerRadius(e) * min(body.a, body.d)
        p.budLine = e.bud.map { !$0.revealed || $0.closingAt != nil } ?? false
        if size.width < e.rest.width - 0.5 || size.height < e.rest.height - 0.5 {
            // The body's own geometry (its full stretch, axis, grab origin and lift), expressed in the content's
            // coordinates: the mask rides the content's gentler rigidity transform and lands exactly on the body.
            p.bodyMask = localBody(e, inset: 0)
                .applying(DropletPhysics.aboutCentre(DropletPhysics.transform(offset: offset, anchor: anchor, linear: body),
                                                     size: e.rest.size))
                .applying(p.contentTransform.inverted())
        }
        p.isLifted = e.isDragging
        p.rim = e.style.rimStrength(lift: liftProgress(e))
        p.isSettling = !e.isDragging && !e.dyn.offset.isResting
        p.isDrawn = isDrawn(e)
        p.recedes = recedes(e)
        p.reshape = e.reshape
        return p
    }

    private var renderList: [Render] {
        order.compactMap { id -> Render? in
            guard let e = entries[id], isDrawn(e), e.style.drawsBody else { return nil }
            var frost = 1.0
            if e.bud != nil {
                let progress = Double(bodySize(e).width / max(e.rest.width, 1))
                frost = min(max((progress - 0.25) / 0.5, 0), 1)
            }
            let lift = liftProgress(e)
            return Render(id: id, material: e.style.material, path: bodyPath(e, inset: 0), innerPath: bodyPath(e, inset: 0.8),
                          frostPath: bodyPath(e, inset: 1.5), frostOpacity: frost,
                          budLine: e.bud.map { !$0.revealed || $0.closingAt != nil } ?? false,
                          paper: e.style.refracts ? paperShare(visualBox(e)) : 0,
                          lift: Double(lift), rim: Double(e.style.rimStrength(lift: lift)), castsShadow: !e.style.restsDry)
        }
    }

    /// Droplets linked in the last `stepBonds` (close enough for their union to touch) share one cluster, drawn by one
    /// small canvas framed to its bounds (§3.17), so resting clusters never redraw.
    private func buildClusters() -> [WaterCluster] {
        let renders = renderList
        let groups = WaterCluster.groups(renders.map(\.id), linked: links)
        let pad = 3 * metrics.fieldBlur
        return groups.map { ids in
            let set = Set(ids)
            let members = renders.filter { set.contains($0.id) }
            let own = necks.filter { n in ids.contains { n.id.hasPrefix($0 + "|") || n.id.hasSuffix("|" + $0) } }
            let sats = satellites.filter { set.contains($0.target) }
            var frame = CGRect.null
            for r in members { frame = frame.union(r.path.boundingRect) }
            for n in own { frame = frame.union(n.path.boundingRect.insetBy(dx: -n.thickness, dy: -n.thickness)) }
            for s in sats { frame = frame.union(s.path.boundingRect) }
            let recede = ids.contains { id in entries[id].map(recedes) ?? false }
            let optics = WaterCluster.optics(members)
            return WaterCluster(id: ids[0], renders: members, necks: own, satellites: sats,
                                frame: frame.insetBy(dx: -pad, dy: -pad).integral,
                                opacity: recede ? NibLiquid.recedeOpacity : 1,
                                rim: optics.rim, shadow: optics.shadow, shadowY: optics.shadowY)
        }
    }

    // MARK: Drag

    func isDragging(_ id: String) -> Bool { entries[id]?.isDragging ?? false }

    func beginDrag(_ id: String, at location: CGPoint) {
        guard var e = entries[id], e.hasRest, !isInking else { return }
        let centre = visualCentre(e)
        let s = bodySize(e)
        e.isDragging = true
        e.landing = nil
        e.grabOffset = CGPoint(x: location.x - centre.x, y: location.y - centre.y)
        e.dyn.anchor.snap(to: CGPoint(x: min(max(e.grabOffset.x, -s.width / 2), s.width / 2),
                                      y: min(max(e.grabOffset.y, -s.height / 2), s.height / 2)))
        e.dyn.positionSpring = NibMotion.follow
        e.dyn.lift.target = e.style.lift * e.dragScale
        e.lastMove = CACurrentMediaTime()
        entries[id] = e
        NibHaptics.prepare()
        wake()
    }

    func drag(_ id: String, to location: CGPoint) {
        guard var e = entries[id], e.isDragging else { return }
        var x = location.x - e.grabOffset.x
        var y = location.y - e.grabOffset.y
        if bounds.width > 0 {
            let box = visualBox(e)
            let area = bounds.insetBy(dx: 8, dy: 8)
            x = DropletPhysics.rubberBand(x, lo: area.minX + box.width / 2, hi: area.maxX - box.width / 2)
            y = DropletPhysics.rubberBand(y, lo: area.minY + box.height / 2, hi: area.maxY - box.height / 2)
        }
        let target = CGPoint(x: x - e.rest.midX, y: y - e.rest.midY)
        if physicsOff {
            e.dyn.offset.snap(to: target)
        } else {
            e.dyn.offset.target = target
        }
        e.lastMove = CACurrentMediaTime()
        entries[id] = e
        wake()
    }

    /// Ends a drag and returns the release velocity after the careful-release rule, so a component can project a dock.
    /// The palette docks with `snap` from the full velocity; slot droplets land with `slot` from the part of it that
    /// points at their slot; the chip flows back to its dock with `tether`.
    @discardableResult
    func endDrag(_ id: String, velocity: CGVector) -> CGVector {
        guard var e = entries[id], e.isDragging else { return .zero }
        let released: CGVector = physicsOff ? .zero
            : DropletPhysics.releaseVelocity(velocity, stillFor: CACurrentMediaTime() - e.lastMove)
        e.isDragging = false
        switch e.style.drag {
        case .tethered:
            e.dyn.positionSpring = NibMotion.tether
            e.dyn.offset.velocity = CGVector(dx: released.dx * 0.6, dy: released.dy * 0.6)
        case .free:
            e.dyn.positionSpring = NibMotion.slot
            e.dyn.offset.velocity = DropletPhysics.slotVelocity(released, displacement: e.dyn.offset.value)
            e.landing = released
        case .docks, .fixed:
            e.dyn.positionSpring = NibMotion.snap
            e.dyn.offset.velocity = released
        }
        e.dyn.lift.target = 1
        e.dyn.offset.target = .zero
        e.dyn.anchor.target = .zero
        entries[id] = e
        wake()
        return released
    }

    func setDragScale(_ id: String, _ scale: CGFloat) {
        guard var e = entries[id], e.dragScale != scale else { return }
        e.dragScale = scale
        if e.isDragging { e.dyn.lift.target = e.style.lift * scale }
        entries[id] = e
        wake()
    }

    /// Tap feedback: the style's impulse on the stretch velocity (a 2.5 % squash on a bar). It runs on iOS 26 too:
    /// the glass body never receives touches, so the system's own press response would not fire.
    func poke(_ id: String, _ amount: CGFloat? = nil) {
        guard var e = entries[id], !physicsOff, !isInking, e.style.stretchCap > 0 else { return }
        e.dyn.stretch.velocity -= amount ?? e.style.poke
        entries[id] = e
        wake()
    }

    // MARK: Bud-off

    func dismissBuds() {
        for (id, dismiss) in dismissers where entries[id]?.bud?.presented == true {
            dismiss()
        }
    }

    func setBud(_ id: String, source: String, presented: Bool, instant: Bool, dismiss: @escaping () -> Void) {
        dismissers[id] = dismiss
        guard var e = entries[id], e.hasRest else {
            pendingBuds[id] = (source, presented)
            return
        }
        let now = CACurrentMediaTime()
        if presented {
            if e.bud?.presented == true { return }
            var bud = BudState(source: source, owner: anchors[source]?.owner ?? source, presented: true, revealed: false,
                               visible: true, startedAt: now, closingAt: nil)
            if instant || physicsOff {
                e.dyn.offset.snap(to: .zero)
                e.dyn.size.snap(to: CGPoint(x: e.rest.width, y: e.rest.height))
                e.dyn.corner.snap(to: cornerTarget(e.style, e.rest.size))
                bud.revealed = true
            } else {
                let src = sourcePoint(source) ?? CGPoint(x: e.rest.midX, y: e.rest.midY)
                e.dyn.offset.snap(to: CGPoint(x: src.x - e.rest.midX, y: src.y - e.rest.midY))
                e.dyn.size.snap(to: CGPoint(x: 30, y: 30))
                e.dyn.corner.snap(to: 15)
                e.dyn.positionSpring = NibMotion.bud
                e.dyn.sizeSpring = NibMotion.budSize
                e.dyn.offset.target = .zero
                e.dyn.size.target = CGPoint(x: e.rest.width, y: e.rest.height)
                e.dyn.corner.target = cornerTarget(e.style, e.rest.size)
            }
            e.bud = bud
        } else if var bud = e.bud, bud.presented {
            bud.presented = false
            bud.revealed = false
            if instant || physicsOff {
                bud.visible = false
            } else {
                bud.closingAt = now
            }
            e.bud = bud
        } else if e.bud == nil {
            e.bud = BudState(source: source, owner: anchors[source]?.owner ?? source, presented: false, revealed: false,
                             visible: false, startedAt: now, closingAt: nil)
        }
        entries[id] = e
        wake()
    }

    private func stepBud(_ e: inout Entry, now: CFTimeInterval) {
        guard var bud = e.bud else { return }
        if bud.presented {
            if !bud.revealed && now - bud.startedAt >= NibMotion.budRevealDelay { bud.revealed = true }
        } else if let closingAt = bud.closingAt, now - closingAt >= 0.07, let src = sourcePoint(bud.source) {
            e.dyn.positionSpring = NibMotion.retract
            e.dyn.sizeSpring = NibMotion.retract
            e.dyn.offset.target = CGPoint(x: src.x - e.rest.midX, y: src.y - e.rest.midY)
            e.dyn.size.target = CGPoint(x: 28, y: 28)
            e.dyn.corner.target = 14
            let c = visualCentre(e)
            let d = ((c.x - src.x) * (c.x - src.x) + (c.y - src.y) * (c.y - src.y)).squareRoot()
            if e.dyn.size.x.value < 34 && d < 5 {
                bud.visible = false
                bud.closingAt = nil
                e.dyn.offset.snap(to: .zero)
                e.dyn.size.snap(to: CGPoint(x: e.rest.width, y: e.rest.height))
                e.dyn.corner.snap(to: cornerTarget(e.style, e.rest.size))
                e.dyn.positionSpring = NibMotion.snap
                e.dyn.sizeSpring = NibMotion.budSize
            }
        }
        e.bud = bud
    }

    // MARK: Palette re-form (fix 2: gather into a bead, switch axis at the midpoint, spread; ≤ 380 ms)

    func beginReshape(_ id: String, towards centre: CGPoint, velocity: CGVector) {
        guard var e = entries[id], e.hasRest else { return }
        let thick = min(e.rest.width, e.rest.height)
        let target = CGPoint(x: centre.x - e.rest.midX, y: centre.y - e.rest.midY)
        e.reshapeFrom = max(e.dyn.size.x.value, e.dyn.size.y.value)
        if physicsOff {
            e.reshape = .spreading
            e.dyn.offset.snap(to: target)
            e.dyn.size.snap(to: CGPoint(x: thick, y: thick))
            e.reshapeFrom = thick
        } else {
            e.reshape = .gathering
            e.dyn.offset.target = target
            e.dyn.offset.velocity = velocity
            e.dyn.sizeSpring = NibMotion.reform
            e.dyn.size.target = CGPoint(x: thick, y: thick)
        }
        entries[id] = e
        wake()
    }

    private func stepReshape(_ e: inout Entry) {
        let thick = min(e.rest.width, e.rest.height)
        // While re-forming, the short side never springs below the thickness: it is snapped to it.
        for keyPath in [\SpringPoint.x, \SpringPoint.y]
        where e.reshape != .idle && e.dyn.size[keyPath: keyPath].value < thick {
            e.dyn.size[keyPath: keyPath].value = thick
            e.dyn.size[keyPath: keyPath].velocity = max(0, e.dyn.size[keyPath: keyPath].velocity)
        }
        let long = max(e.dyn.size.x.value, e.dyn.size.y.value)
        switch e.reshape {
        case .idle:
            e.contentAlpha = 1
        case .gathering:
            let switchAt = thick * 1.5
            let p = 0.5 * (e.reshapeFrom - long) / max(1, e.reshapeFrom - switchAt)
            e.contentAlpha = DropletPhysics.reshapeContentOpacity(progress: min(max(p, 0), 0.5))
            if long <= switchAt {
                e.reshape = .spreading
                e.reshapeFrom = long
            }
        case .spreading:
            let to = max(e.rest.width, e.rest.height)
            let p = 0.5 + 0.5 * (long - e.reshapeFrom) / max(1, to - e.reshapeFrom)
            e.contentAlpha = DropletPhysics.reshapeContentOpacity(progress: min(max(p, 0.5), 1))
            if e.dyn.size.isResting && abs(long - to) < 1 && to > e.reshapeFrom {
                e.reshape = .idle
                e.contentAlpha = 1
                e.dyn.sizeSpring = NibMotion.budSize
            }
        }
    }

    // MARK: Selection bead

    /// Glides the bead to `head` (a tap), or teleports it (keyboard, Pencil double-tap or squeeze, Reduce Motion).
    func setBead(_ id: String, head: CGFloat, glide: Bool) {
        var b = beads[id] ?? BeadState(head: SpringValue(head, epsilon: 0.05), tail: SpringValue(head, epsilon: 0.05))
        if !glide || physicsOff {
            b.head.snap(to: head)
            b.tail.snap(to: head)
            b.arrived = true
        } else if b.head.target != head {
            b.head.target = head
            b.arrived = false
        }
        beads[id] = b
        wake()
    }

    func scrubBead(_ id: String, to along: CGFloat) {
        guard var b = beads[id] else { return }
        b.scrubbing = true
        b.head.target = along
        b.arrived = true
        beads[id] = b
        wake()
    }

    func endScrub(_ id: String) {
        beads[id]?.scrubbing = false
    }

    private func stepBeads(_ dt: CGFloat) -> Bool {
        var busy = false
        for (id, var b) in beads {
            b.head.step(dt, spring: physicsOff ? NibMotion.reduced : NibMotion.glide)
            b.tail.target = b.head.value
            b.tail.step(dt, spring: physicsOff ? NibMotion.reduced : NibMotion.trail)
            b.tail.value = BeadPhysics.clampTail(head: b.head.value, tail: b.tail.value, radius: NibMetrics.beadRadius)
            if !b.arrived && abs(b.head.value - b.head.target) < 1.2 {
                b.arrived = true
                if !b.scrubbing { NibHaptics.play(.select) }
            }
            if !b.head.isResting || !b.tail.isResting { busy = true }
            beads[id] = b
        }
        return busy
    }

    // MARK: Necks and clusters

    /// Where droplet `id`'s meniscus reaches (a dock frame), or nil to let it go.
    func setMeniscus(_ id: String, towards dock: CGRect?) {
        if meniscuses[id] == nil && dock == nil { return }
        var m = meniscuses[id] ?? DockMeniscus()
        guard m.target != dock else { return }
        m.target = dock
        meniscuses[id] = m
        wake()
    }

    private func neckParams(_ a: Entry, _ b: Entry) -> NeckParams? {
        let budNeck = NeckParams(join: metrics.mergeDistance, t0: 30, off: metrics.budNeckOff)
        if let bud = b.bud, bud.owner == a.id { return budNeck }
        if let bud = a.bud, bud.owner == b.id { return budNeck }
        if a.style.bondsOnRequest || b.style.bondsOnRequest {
            guard a.bondTarget == b.id || b.bondTarget == a.id else { return nil }
        }
        guard let x = a.style.neck, let y = b.style.neck else { return nil }
        let scale = metrics.mergeDistance / 11
        return NeckParams(join: min(x.join, y.join) * scale, t0: min(x.t0, y.t0), off: min(x.off, y.off))
    }

    private func inward(_ p: CGPoint, towards c: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = c.x - p.x, dy = c.y - p.y
        let l = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let m = min(d, l)
        return CGPoint(x: p.x + dx / l * m, y: p.y + dy / l * m)
    }

    private func stepBonds(_ dt: CGFloat) -> Bool {
        var busy = false
        var result: [Neck] = []
        var linked: Set<PairKey> = []
        let reach = 3 * metrics.fieldBlur
        let ids = order
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard let a = entries[ids[i]], let b = entries[ids[j]] else { continue }
                let key = PairKey(ids[i], ids[j])
                let boxA = visualBox(a), boxB = visualBox(b)
                let g = DropletPhysics.gap(boxA, boxB, minCorner: min(cornerRadius(a), cornerRadius(b)))
                let params = neckParams(a, b)
                if isDrawn(a) && isDrawn(b) && g.gap < max(params?.off ?? 0, metrics.mergeDistance) + reach {
                    linked.insert(key)
                }
                guard let params else { continue }
                var bond = bonds[key] ?? Bond()
                let enabled = isDrawn(a) && isDrawn(b) && necksOn
                if let event = bond.update(gap: g.gap, params: params, minimumNeck: metrics.minimumNeck,
                                           enabled: enabled, hysteresis: !usesSystemGlass) {
                    handle(event, a, b, at: CGPoint(x: (g.pointA.x + g.pointB.x) / 2, y: (g.pointA.y + g.pointB.y) / 2))
                }
                bond.thickness.step(dt, spring: NibMotion.neck)
                if !bond.thickness.isResting { busy = true }
                bonds[key] = bond
                if bond.thickness.value > 0.8 {
                    let ca = CGPoint(x: boxA.midX, y: boxA.midY), cb = CGPoint(x: boxB.midX, y: boxB.midY)
                    let from = inward(g.pointA, towards: ca, by: min(8, min(boxA.width, boxA.height) / 3))
                    let to = inward(g.pointB, towards: cb, by: min(8, min(boxB.width, boxB.height) / 3))
                    result.append(Neck(id: key.a + "|" + key.b, from: from, to: to, thickness: bond.thickness.value,
                                       colour: .mix(.of(a.style.material, paper: a.style.refracts ? paperShare(boxA) : 0),
                                                    .of(b.style.material, paper: b.style.refracts ? paperShare(boxB) : 0))))
                }
            }
        }
        for (id, var m) in meniscuses {
            guard let e = entries[id], e.hasRest else {
                meniscuses[id] = nil
                continue
            }
            let box = visualBox(e)
            if m.step(dt, body: box, enabled: necksOn && isDrawn(e), minimumNeck: metrics.minimumNeck) { busy = true }
            if let s = m.segment {
                result.append(Neck(id: id + "|" + DockMeniscus.neckID, from: s.from, to: s.to, thickness: s.thickness,
                                   colour: .of(e.style.material, paper: e.style.refracts ? paperShare(box) : 0)))
            }
            meniscuses[id] = m.isIdle ? nil : m
        }
        links = linked
        if result != necks { necks = result }
        return busy
    }

    private func handle(_ event: BondEvent, _ a: Entry, _ b: Entry, at point: CGPoint) {
        let budID: String? = b.bud?.owner == a.id ? b.id : (a.bud?.owner == b.id ? a.id : nil)
        if let budID, var bud = entries[budID]?.bud {
            switch event {
            case .joined:
                if bud.closingAt != nil { NibHaptics.play(.merge) }
            case .split:
                if bud.presented && !bud.revealed {
                    bud.revealed = true
                    entries[budID]?.bud = bud
                    NibHaptics.play(.bud)
                }
            }
            return
        }
        switch event {
        case .joined:
            NibHaptics.play(.merge)
        case .split:
            NibHaptics.play(.split)
            if a.style.drag == .tethered || b.style.drag == .tethered {
                spawnSatellite(at: point, into: a.style.drag == .tethered ? b.id : a.id)
            }
        }
    }

    private func spawnSatellite(at point: CGPoint, into anchor: String) {
        nextSatellite += 1
        satellites.append(Satellite(id: nextSatellite, target: anchor, centre: SpringPoint(point),
                                    radius: SpringValue(5, epsilon: 0.05)))
    }

    private func stepSatellites(_ dt: CGFloat) -> Bool {
        guard !satellites.isEmpty else { return false }
        var next: [Satellite] = []
        for var s in satellites {
            guard let anchor = entries[s.target], anchor.hasRest else { continue }
            s.centre.target = visualCentre(anchor)
            s.centre.step(dt, spring: NibMotion.absorb)
            let c = s.centre.value, t = s.centre.target
            if ((c.x - t.x) * (c.x - t.x) + (c.y - t.y) * (c.y - t.y)).squareRoot() < 3 { s.radius.target = 0 }
            s.radius.step(dt, spring: NibMotion.absorb)
            if s.radius.target > 0 || s.radius.value > 0.3 { next.append(s) }
        }
        satellites = next
        return !next.isEmpty
    }

    // MARK: Recede while writing (DESIGN.md §10.8)

    func setInking(_ inking: Bool) {
        guard inking != isInking else { return }
        restoreWork?.cancel()
        NibHaptics.isInking = inking
        isInking = inking
        if inking {
            if !isFrozen { isFrozen = true }
            publish()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isFrozen = false
                self.stroke = .null
                self.publish()
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.recedeDelay, execute: work)
            wake()
        }
    }

    /// The stroke's bounds as it grows: droplets within 24 pt of it recede too.
    func setStroke(_ rect: CGRect) {
        guard rect != stroke, isFrozen else { return }
        stroke = rect
        publish()
    }

    // MARK: Frame loop

    func wake() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        if hot != isThermallyThrottled { isThermallyThrottled = hot }
        if driver == nil {
            driver = DisplayLinkDriver { [weak self] dt in self?.tick(dt) ?? false }
        }
        driver?.start()
    }

    private func tick(_ dt: CFTimeInterval) -> Bool {
        guard !isInking else { return false }
        let step = CGFloat(dt)
        let now = CACurrentMediaTime()
        var busy = false
        for id in order {
            guard var e = entries[id] else { continue }
            stepBud(&e, now: now)
            let moving = e.dyn.step(step, style: e.style, reduceMotion: physicsOff, calm: mode == .calm)
            stepReshape(&e)
            if !moving && !e.isDragging { e.landing = nil }
            let budBusy = e.bud.map { $0.presented ? !$0.revealed : $0.closingAt != nil } ?? false
            if moving || e.isDragging || e.reshape != .idle || budBusy { busy = true }
            entries[id] = e
        }
        if stepBonds(step) { busy = true }
        if stepBeads(step) { busy = true }
        if stepSatellites(step) { busy = true }
        publish()
        return busy
    }
}

/// A CADisplayLink that runs at up to 120 Hz while its tick reports work, then parks itself. (ProMotion iPhones need
/// `CADisableMinimumFrameDurationOnPhone` in the app's Info.plist, §1.)
final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let onTick: (CFTimeInterval) -> Bool

    init(onTick: @escaping (CFTimeInterval) -> Bool) {
        self.onTick = onTick
        super.init()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        let dt = last == 0 ? 1.0 / 120 : min(max(now - last, 1.0 / 240), 1.0 / 30)
        last = now
        if !onTick(dt) { stop() }
    }
}
```

### 3.14 `NibKit/Sources/NibDesign/Liquid/DropletContainer.swift`

```swift
import SwiftUI

/// The one container per window for everything that floats. iOS 26+: the system's Liquid Glass inside a
/// `GlassEffectContainer` (union and morph are the OS's; Nib adds necks with memory, buds and physics).
/// iOS 17–25: a metaball field per cluster of nearby droplets (Canvas blur, thresholded and shaded in Metal) with
/// frost under Deep droplets.
///
/// The container does not cap Dynamic Type: panels, the assistant, search results and plugin panels scale to AX5.
/// Bars, HUDs, the palette and the proposal chip cap themselves (`nibChromeTypeCap`).
public struct NibDropletContainer<Content: View>: View {
    @State private var field = DropletField()
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nibLiquidMode) private var mode
    @Environment(\.nibBackdrop) private var backdrop
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let inking: NibInkingState?
    private let content: Content

    /// `inking` is the Pencil state the canvas delegate writes; this container is its only reader.
    public init(inking: NibInkingState? = nil, @ViewBuilder content: () -> Content) {
        self.inking = inking
        self.content = content()
    }

    private static var systemGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private var usesSystemGlass: Bool { Self.systemGlassAvailable && mode != .off }

    public var body: some View {
        ZStack {
            if field.hasOpenBud {
                DismissCatcher(field: field)
            }
            layers
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(NibLiquid.space)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { field.bounds = CGRect(origin: .zero, size: proxy.size) }
                    .onChange(of: proxy.size) { _, size in field.bounds = CGRect(origin: .zero, size: size) }
            }
        }
        .environment(field)
        .environment(\.nibGlassNamespace, glassNamespace)
        .environment(\.nibIsInking, field.isFrozen)
        .onChange(of: reduceMotion, initial: true) { _, value in field.reduceMotion = value }
        .onChange(of: mode, initial: true) { _, value in
            field.mode = value
            field.usesSystemGlass = Self.systemGlassAvailable && value != .off
            NibHaptics.isEnabled = value != .off
            NibMotion.forcesReduced = value == .off
        }
        .onChange(of: inking?.isInking ?? false, initial: true) { _, value in field.setInking(value) }
        .onChange(of: inking?.strokeBounds ?? .null) { _, rect in field.setStroke(rect) }
        .onChange(of: backdrop, initial: true) { _, pages in field.setBackdrop(pages) }
        .onChange(of: sizeClass, initial: true) { _, value in
            field.metrics = value == .compact ? .compact : .regular
        }
    }

    @ViewBuilder private var layers: some View {
        if #available(iOS 26.0, *) {
            if usesSystemGlass {
                GlassEffectContainer(spacing: field.metrics.mergeDistance) {
                    ZStack {
                        NeckGlassLayer(field: field)
                        content
                    }
                }
            } else {
                fallback
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        ZStack {
            if reduceTransparency || mode == .off || field.isThermallyThrottled {
                WaterOpaqueLayer(field: field)
            } else {
                FrostLayer(field: field)
                WaterLayer(field: field)
            }
            content
        }
    }
}

/// While a bud is open, a touch anywhere outside the droplets only dismisses it. It never reaches the canvas, not
/// even from the status-bar or home-indicator strips.
struct DismissCatcher: View {
    let field: DropletField

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { _ in field.dismissBuds() })
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Places every cluster's canvas at its own frame; the canvases are Equatable, so a cluster at rest never redraws.
struct ClusterLayer<Cell: View>: View {
    let field: DropletField
    let cell: (WaterCluster) -> Cell

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(field.clusters) { c in
                cell(c)
                    .frame(width: c.frame.width, height: c.frame.height)
                    .offset(x: c.frame.minX, y: c.frame.minY)
                    .opacity(c.opacity)
                    .animation(field.isInking ? NibMotion.recede : NibMotion.enter, value: c.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// iOS 17–25: frost (material blur) under Deep droplets, inset 1.5 pt so it never pokes past the water outline.
/// Not drawn while the Pencil is down: nothing re-samples the canvas 120 times a second (DESIGN.md §10.8).
struct FrostLayer: View {
    let field: DropletField

    var body: some View {
        let frozen = field.isFrozen
        ClusterLayer(field: field) { c in
            Canvas { context, _ in
                let o = CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY)
                for r in c.renders where r.budLine {
                    context.stroke(r.path.applying(o), with: .color(NibColor.waterLineBud), lineWidth: 0.8)
                }
            }
            .background(alignment: .topLeading) {
                if !frozen {
                    ForEach(c.renders.filter { $0.material == .deep }) { r in
                        r.frostPath
                            .applying(CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY))
                            .fill(.ultraThinMaterial)
                            .opacity(r.frostOpacity)
                    }
                }
            }
        }
    }
}

/// iOS 17–25: each cluster's droplets and necks as one metaball field in a canvas framed to the cluster. The Canvas
/// blurs the silhouettes (σ 8 pt iPad / 6.5 pt iPhone); the Metal layer effect thresholds it with analytic
/// anti-aliasing and shades body, edge lens, sheen, outline, directional rim and the water's shadow (DESIGN.md §10.9).
/// Material kinds and the paper share travel in the colour channels.
struct WaterLayer: View {
    let field: DropletField

    var body: some View {
        let blur = field.metrics.fieldBlur
        let iso = field.metrics.iso
        ClusterLayer(field: field) { c in
            WaterClusterCanvas(cluster: c, blur: blur, iso: iso).equatable()
        }
    }
}

struct WaterClusterCanvas: View, Equatable {
    let cluster: WaterCluster
    let blur: CGFloat
    let iso: Float

    var body: some View {
        let o = CGAffineTransform(translationX: -cluster.frame.minX, y: -cluster.frame.minY)
        Canvas { context, _ in
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: blur))
                for r in cluster.renders {
                    layer.fill(r.path.applying(o), with: .color(DropletField.FieldColour.of(r.material, paper: r.paper).color))
                }
                for n in cluster.necks {
                    layer.stroke(n.path.applying(o), with: .color(n.colour.color),
                                 style: StrokeStyle(lineWidth: n.thickness, lineCap: .round))
                }
                for s in cluster.satellites {
                    layer.fill(s.path.applying(o), with: .color(DropletField.FieldColour.of(.clear, paper: 0).color))
                }
            }
        }
        .layerEffect(NibShaders.waterField(cluster, iso: iso), maxSampleOffset: CGSize(width: 6, height: 8))
    }
}

/// Reduce Transparency, Liquid Off and thermal throttling: one union path per cluster (`Path.union`, iOS 17), filled
/// once in `chromeOpaque` and stroked with the 0.8 pt water line. No blur, no threshold, no shader, no shadow: this
/// is the cheap path and it costs less than the one it replaces.
struct WaterOpaqueLayer: View {
    let field: DropletField

    var body: some View {
        ClusterLayer(field: field) { c in
            Canvas { context, _ in
                let o = CGAffineTransform(translationX: -c.frame.minX, y: -c.frame.minY)
                var union = Path()
                for r in c.renders { union = union.union(r.path.applying(o)) }
                for n in c.necks {
                    union = union.union(n.path.applying(o).strokedPath(StrokeStyle(lineWidth: n.thickness, lineCap: .round)))
                }
                for s in c.satellites { union = union.union(s.path.applying(o)) }
                context.fill(union, with: .color(NibColor.chromeOpaque))
                context.stroke(union, with: .color(NibColor.waterLine), lineWidth: 0.8)
                for r in c.renders where r.material != .clear {
                    context.fill(r.innerPath.applying(o),
                                 with: .color(r.material == .deep ? NibColor.backgroundSecondary : NibColor.accent))
                }
            }
        }
    }
}

/// iOS 26+: necks and satellites as glass capsules inside the GlassEffectContainer, so the system union gives the
/// bridge its memory (a neck thins and pinches instead of vanishing at the container spacing). While the Pencil is
/// down they are `.identity` over the plain body tint, like every droplet.
@available(iOS 26.0, *)
struct NeckGlassLayer: View {
    let field: DropletField

    var body: some View {
        let glass: Glass = field.isFrozen ? .identity : .regular
        ZStack(alignment: .topLeading) {
            ForEach(field.necks) { n in
                Capsule()
                    .fill(field.isFrozen ? NibColor.clearBody : Color.clear)
                    .frame(width: max(n.length, 1), height: n.thickness)
                    .glassEffect(glass, in: Capsule())
                    .rotationEffect(.radians(Double(n.angle)))
                    .position(n.midpoint)
            }
            ForEach(field.satellites) { s in
                Circle()
                    .fill(field.isFrozen ? NibColor.clearBody : Color.clear)
                    .frame(width: max(0, s.radius.value * 2), height: max(0, s.radius.value * 2))
                    .glassEffect(glass, in: Circle())
                    .position(s.centre.value)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

### 3.15 `NibKit/Sources/NibDesign/Liquid/Droplet.swift`

```swift
import SwiftUI
import QuartzCore

public extension View {
    /// Makes this view a droplet of the enclosing `NibDropletContainer`: water body, velocity stretch, surface-tension
    /// settle, merge and pinch with neighbours, FLIP when its layout changes. Outside a container it is a static glass.
    /// - Parameters:
    ///   - id: unique within the container.
    ///   - dragScale: 0.5 while a library card is over the sidebar (C's condense), otherwise 1.
    ///   - bondsWith: for `bondsOnRequest` styles (library cards), the droplet a neck should reach: the library passes
    ///     the target cover once a combine has armed (DESIGN.md §10.12), nil otherwise.
    ///   - onDrag: drag events in `NibLiquid.space`, for features that need drop targets.
    func droplet(_ id: String, style: DropletStyle = .bar, dragScale: CGFloat = 1, bondsWith: String? = nil,
                 onDrag: ((NibDropletDrag) -> Void)? = nil) -> some View {
        modifier(DropletModifier(id: id, style: style, managesDrag: true, dragScale: dragScale, bondsWith: bondsWith,
                                 onDrag: onDrag))
    }

    /// Presents this droplet by budding it off `sourceID` (a droplet id or a `nibBudAnchor`): it grows out of the
    /// source, its neck pinches, the content is revealed through the droplet. Closing retracts it into the source.
    /// `instant` is for keyboard invocations: nothing that the keyboard triggers animates.
    func budsFrom(_ sourceID: String, isPresented: Binding<Bool>, instant: Bool = false) -> some View {
        environment(\.nibBud, NibBudRequest(source: sourceID, isPresented: isPresented, instant: instant))
    }

    /// Marks a control inside a droplet (for example a bar button) as a bud source.
    func nibBudAnchor(_ id: String) -> some View {
        background(BudAnchorReader(id: id))
    }
}

extension View {
    func droplet(_ id: String, style: DropletStyle, managesDrag: Bool) -> some View {
        modifier(DropletModifier(id: id, style: style, managesDrag: managesDrag, dragScale: 1, bondsWith: nil, onDrag: nil))
    }
}

struct DropletModifier: ViewModifier {
    let id: String
    let style: DropletStyle
    let managesDrag: Bool
    let dragScale: CGFloat
    let bondsWith: String?
    let onDrag: ((NibDropletDrag) -> Void)?
    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.nibGlassNamespace) private var namespace
    @Environment(\.nibBud) private var bud

    func body(content: Content) -> some View {
        if let field {
            AttachedDroplet(content: content, id: id, style: style, managesDrag: managesDrag, dragScale: dragScale,
                            bondsWith: bondsWith, onDrag: onDrag, field: field, node: field.node(id),
                            namespace: namespace, bud: bud)
        } else {
            content.nibGlass(style.glassKind, cornerRadius: style.cornerRadius, interactive: style.isInteractive)
        }
    }
}

/// One droplet in a container. It reads only its own node, so it re-renders only when its own presentation changes.
struct AttachedDroplet<Content: View>: View {
    let content: Content
    let id: String
    let style: DropletStyle
    let managesDrag: Bool
    let dragScale: CGFloat
    let bondsWith: String?
    let onDrag: ((NibDropletDrag) -> Void)?
    let field: DropletField
    let node: DropletNode
    let namespace: Namespace.ID?
    let bud: NibBudRequest?

    var body: some View {
        let p = node.presentation
        let requestedHidden = bud.map { !$0.isPresented.wrappedValue } ?? false
        let hidden = p.hasBud ? p.hidden : requestedHidden
        let isOpenBud = bud != nil && !hidden
        let draggable = managesDrag && style.drag != .fixed
        let recede = p.recedes ? NibLiquid.recedeOpacity : 1
        return content
            .environment(\.nibDropletIsLifted, p.isLifted)
            .opacity(p.revealed ? 1 : 0)
            .blur(radius: p.revealed ? 0 : 3)
            .scaleEffect(p.revealed || !field.reduceMotion ? 1 : 0.96)
            .animation(p.revealed ? NibMotion.enter : NibMotion.exit, value: p.revealed)
            .mask(alignment: .topLeading) {
                // C's rule, exactly: the clip is the body's own geometry (in the content's coordinates, so it rides
                // the transform below and lands on the body). Nothing draws outside the body, not even mid-bud.
                if let mask = p.bodyMask {
                    mask
                } else {
                    Rectangle().padding(-64)
                }
            }
            .opacity(p.contentOpacity * recede)
            .animation(p.recedes ? NibMotion.recede : NibMotion.enter, value: p.recedes)
            .transformEffect(p.contentTransform)
            .overlay {
                if !style.drawsBody && p.isDrawn {
                    FrameRim(style: style, presentation: p).opacity(recede)
                }
            }
            .background {
                SystemBody(id: id, style: style, presentation: p, namespace: namespace, field: field)
                    .opacity(recede)
            }
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            // An open bud is modal for VoiceOver: focus moves into it when its content is revealed, the canvas behind
            // it is not reachable, and a hardware Escape closes it (DESIGN.md §10.6).
            .accessibilityAddTraits(isOpenBud ? .isModal : [])
            .onChange(of: p.revealed && isOpenBud) { _, revealed in
                if revealed { AccessibilityNotification.ScreenChanged().post() }
            }
            .background {
                if isOpenBud {
                    // Registered only while presented: closed buds stay in the view tree, and their shortcuts
                    // would conflict.
                    Button("") { bud?.isPresented.wrappedValue = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .background(RestReader(id: id, style: style, field: field))
            .gesture(dragGesture, including: draggable ? .all : .subviews)
            .onAppear { field.register(id, style: style) }
            .onDisappear { field.unregister(id) }
            .onChange(of: dragScale, initial: true) { _, scale in field.setDragScale(id, scale) }
            .onChange(of: bondsWith, initial: true) { _, target in field.setBondTarget(id, target) }
            .onChange(of: bud?.isPresented.wrappedValue ?? false, initial: true) { _, presented in
                guard let bud else { return }
                field.setBud(id, source: bud.source, presented: presented, instant: bud.instant) {
                    bud.isPresented.wrappedValue = false
                }
            }
            .accessibilityAction(.escape) {
                if let bud { bud.isPresented.wrappedValue = false }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .onChanged { value in
                if !field.isDragging(id) {
                    field.beginDrag(id, at: value.startLocation)
                    onDrag?(.began(location: value.startLocation))
                }
                field.drag(id, to: value.location)
                onDrag?(.changed(location: value.location))
            }
            .onEnded { value in
                let v = CGVector(dx: value.velocity.width, dy: value.velocity.height)
                let released = field.endDrag(id, velocity: v)
                onDrag?(.ended(location: value.location, velocity: released))
            }
    }
}

/// A `frame` droplet (the zoom-window target) has no body: rim and outline only, on both OS generations.
struct FrameRim: View {
    let style: DropletStyle
    let presentation: DropletPresentation

    var body: some View {
        // The rim layer draws the 0.8 pt outline itself: no second stroke (DESIGN.md §10.9).
        NibWaterRimLayer(cornerRadius: presentation.cornerRadius, rimOnly: true, strength: presentation.rim)
            .frame(width: max(0, presentation.bodySize.width), height: max(0, presentation.bodySize.height))
            .offset(x: presentation.bodyOffset.x, y: presentation.bodyOffset.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The droplet's body on iOS 26+: system glass sized and offset by the physics (axis-aligned stretch through the frame,
/// which the glass union definitely honours). On iOS 17–25 the container's field draws the body, so this is empty.
struct SystemBody: View {
    let id: String
    let style: DropletStyle
    let presentation: DropletPresentation
    let namespace: Namespace.ID?
    let field: DropletField

    var body: some View {
        if #available(iOS 26.0, *) {
            if field.usesSystemGlass && presentation.isDrawn && !presentation.hidden && style.drawsBody {
                GlassBody(id: id, style: style, presentation: presentation, namespace: namespace, frozen: field.isFrozen)
            }
        }
    }
}

@available(iOS 26.0, *)
struct GlassBody: View {
    let id: String
    let style: DropletStyle
    let presentation: DropletPresentation
    let namespace: Namespace.ID?
    /// While the Pencil is down the glass does not sample the backdrop: `.identity` over the plain body tint. At 22 %
    /// the swap is invisible, and nothing re-samples the canvas 120 times a second.
    let frozen: Bool

    var body: some View {
        let shape = NibDropletShape(cornerRadius: style.cornerRadius == nil ? nil : presentation.cornerRadius)
        shape
            .fill(frozen ? tint : Color.clear)
            .frame(width: max(0, presentation.bodySize.width), height: max(0, presentation.bodySize.height))
            .glassEffect(frozen ? .identity : style.systemGlass, in: shape)
            .modifier(GlassIDModifier(id: id, namespace: namespace))
            .overlay {
                // Nothing is painted on system glass at rest: its own rim, shadow and lensing are the droplet (a bud's
                // outline is for the iOS 17–25 water only). Held, the rim brightens (DESIGN.md §10.9).
                if presentation.rim > 1.001 {
                    NibLiftRim(cornerRadius: style.cornerRadius == nil ? nil : presentation.cornerRadius,
                               boost: presentation.rim - 1)
                }
            }
            .offset(x: presentation.bodyOffset.x, y: presentation.bodyOffset.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch style.material {
        case .clear: return NibColor.clearBody
        case .deep: return NibColor.deepBody
        case .tinted: return NibColor.accent
        }
    }
}

@available(iOS 26.0, *)
struct GlassIDModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

/// Reports the droplet's laid-out frame (not its rendered transform) to the field.
struct RestReader: View {
    let id: String
    let style: DropletStyle
    let field: DropletField

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { field.setRest(id, proxy.frame(in: NibLiquid.space), style: style) }
                .onChange(of: proxy.frame(in: NibLiquid.space)) { _, frame in field.setRest(id, frame, style: style) }
        }
    }
}

struct BudAnchorReader: View {
    let id: String
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { field?.setWorldAnchor(id, proxy.frame(in: NibLiquid.space)) }
                .onChange(of: proxy.frame(in: NibLiquid.space)) { _, frame in field?.setWorldAnchor(id, frame) }
        }
    }
}
```

### 3.16 `NibKit/Sources/NibDesign/Liquid/NibShaders.swift`

```swift
import Foundation
import SwiftUI

/// The water's optics (DESIGN.md §10.9, Liquid Glass v2), in one place: the Metal shaders receive these numbers as
/// arguments, the Canvas bead rim uses them, and NibDesignTests checks them. Every optic lives in the outer 4.5 pt of a
/// droplet; the core is the body tint alone. Nothing is a uniform stroke except the 0.8 pt outline under the rim.
enum NibOptics {
    /// Unit vector toward the key light in screen space (y down): the top-left, azimuth 225°.
    static let light = CGVector(dx: -0.7071, dy: -0.7071)
    /// Key lobe `max(λ, 0)^1.5` and counter lobe `counter · max(−λ, 0)^2`, λ = outward normal · light.
    static let keyPower: CGFloat = 1.5
    static let counterPower: CGFloat = 2
    /// The counter-rim (bottom-right) at its peak, relative to the key rim at its peak.
    static let counter: CGFloat = 0.5
    /// The sheen inside the lit edge, as a share of `waterRim`, times the key lobe squared.
    static let sheen: CGFloat = 0.22
    /// The rim and outline band: `1 − smoothstep(0.3, 1.1, d)`, d = depth inside the silhouette in points (≈ 0.8 pt).
    static let edgeBand: (CGFloat, CGFloat) = (0.3, 1.1)
    /// The sheen band: `1 − smoothstep(0.8, 4.5, d)`.
    static let sheenBand: (CGFloat, CGFloat) = (0.8, 4.5)
    /// Edge lens (iOS 17–25, over light paper only): the body thins by up to 35 % at the silhouette, back to full by
    /// 4 pt, as if the glass bent the page in at its rim. Content sits ≥ 4.5 pt inside, so text contrast is untouched.
    static let lens: CGFloat = 0.35
    static let lensDepth: CGFloat = 4
    /// Deeper than this nothing but the body is drawn: the clear core.
    static let opticsDepth: CGFloat = 4.5
    /// Rim strength while a droplet is held, at full lift (`DropletStyle.liftedRim` default).
    static let liftedRim: CGFloat = 1.5
    /// The water's shadow (iOS 17–25): the field (the silhouette blurred at σ) moved down 5 pt at rest, 8 pt held, drawn
    /// outside the body only; its opacity grows by 60 % at full lift.
    static let shadowOffset: CGFloat = 5
    static let liftedShadowOffset: CGFloat = 8
    static let liftedShadow: CGFloat = 1.6
    /// The selection bead's key rim: the bead minus itself moved this far away from the light.
    static let beadRim: CGFloat = 0.8

    static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// λ for an outward unit normal.
    static func lambda(_ outward: CGVector) -> CGFloat { outward.dx * light.dx + outward.dy * light.dy }

    static func key(_ outward: CGVector) -> CGFloat { pow(max(lambda(outward), 0), keyPower) }

    /// How lit the rim is at an edge whose outward normal is `outward`: 1 facing the light, `counter` facing away, 0
    /// where the edge runs parallel to the light.
    static func rimLight(_ outward: CGVector) -> CGFloat {
        key(outward) + counter * pow(max(-lambda(outward), 0), counterPower)
    }

    /// The rim's alpha at depth `d` for an edge facing `outward`, at strength `strength`, over a rim colour of alpha `a`.
    static func rimAlpha(_ outward: CGVector, depth d: CGFloat, strength: CGFloat = 1, colourAlpha a: CGFloat) -> CGFloat {
        min(a * rimLight(outward) * (1 - smoothstep(edgeBand.0, edgeBand.1, d)) * strength, 1)
    }

    /// The body's opacity factor at depth `d` over a droplet whose share over light paper is `paper` (edge lens).
    static func lensFactor(depth d: CGFloat, paper: CGFloat) -> CGFloat {
        1 - lens * min(max(paper, 0), 1) * (1 - smoothstep(0, lensDepth, d))
    }
}

/// The Metal functions in Shaders/NibLiquid.metal, loaded from this module's bundle. The argument lists here and the
/// function signatures there must match one for one.
enum NibShaders {
    static let library = ShaderLibrary.bundle(.module)

    /// Layer effect over one cluster's field Canvas (iOS 17–25): body, edge lens, sheen, outline, directional rim and
    /// the water's shadow. It samples ±1.5 pt around each pixel and 8 pt above it at most.
    static func waterField(_ cluster: WaterCluster, iso: Float) -> Shader {
        waterField(iso: iso, rim: cluster.rim, shadow: cluster.shadow, shadowY: cluster.shadowY)
    }

    static func waterField(iso: Float, rim: Float = 1, shadow: Float = 1,
                           shadowY: Float = Float(NibOptics.shadowOffset)) -> Shader {
        library.nibWaterField(
            .float(iso), .float(rim), .float(shadow), .float(shadowY),
            .float(NibOptics.light.dx), .float(NibOptics.light.dy), .float(NibOptics.counter), .float(NibOptics.sheen),
            .float(NibOptics.lens),
            .color(NibColor.clearBody), .color(NibColor.clearBodyOnPaper), .color(NibColor.deepBody), .color(NibColor.accent),
            .color(NibColor.waterBody), .color(NibColor.waterRim), .color(NibColor.tintRim), .color(NibColor.waterLine),
            .color(NibColor.waterShadow), .color(NibColor.waterShadowOnPaper))
    }

    /// Colour effect for one static shape (`nibGlass` on iOS 17–25, beads, folder films, frames, the held rim on iOS 26):
    /// analytic rounded-rect distance, no sampling. `sheen` false drops the sheen, `counter` false the counter-rim,
    /// `outline` false the 0.8 pt line; `tinted` uses the Tinted rim.
    static func waterRim(cornerRadius: CGFloat, strength: CGFloat, sheen: Bool, counter: Bool, outline: Bool,
                         tinted: Bool) -> Shader {
        library.nibWaterRim(
            .boundingRect, .float(cornerRadius), .float(strength),
            .float(NibOptics.light.dx), .float(NibOptics.light.dy), .float(counter ? NibOptics.counter : CGFloat(0)),
            .float(sheen ? NibOptics.sheen : 0), .float(outline ? Float(1) : Float(0)),
            .color(tinted ? NibColor.tintRim : NibColor.waterRim), .color(NibColor.waterLine))
    }
}
```

### 3.17 `NibKit/Sources/NibDesign/Liquid/WaterCluster.swift`

There is no tap ripple (DESIGN.md §10.14): press feedback is scale 0.96 everywhere. This file is the field's clustering instead: droplets whose unions can touch (closer than their neck's pinch distance or the merge distance, plus 3σ of blur) share one small canvas, so a resting cluster never redraws and nothing full-screen sits above the canvas (DESIGN.md §10.16).

```swift
import SwiftUI

/// One group of droplets whose water can touch, drawn by one canvas framed to `frame` (container coordinates).
struct WaterCluster: Identifiable, Equatable {
    /// The first droplet's id: stable while the group exists, so SwiftUI keeps the canvas.
    let id: String
    var renders: [DropletField.Render]
    var necks: [DropletField.Neck]
    var satellites: [DropletField.Satellite]
    var frame: CGRect
    /// 0.22 while any member recedes (the union cannot fade one member without changing its shape).
    var opacity: Double
    /// The union's rim strength (its most lifted member's), shadow opacity multiplier and shadow offset (DESIGN.md §10.9).
    var rim: Float = 1
    var shadow: Float = 1
    var shadowY: Float = Float(NibOptics.shadowOffset)

    /// One union has one rim and one shadow: the rim follows the most lifted member; the shadow deepens from 1× at 5 pt
    /// to 1.6× at 8 pt with the lift of the members that cast one, and is 0 when none does (lifted covers and
    /// thumbnails bring their own).
    static func optics(_ members: [DropletField.Render]) -> (rim: Float, shadow: Float, shadowY: Float) {
        let rim = members.map(\.rim).max() ?? 1
        let casting = members.filter(\.castsShadow)
        guard !casting.isEmpty else { return (Float(rim), 0, Float(NibOptics.shadowOffset)) }
        let lift = CGFloat(min(max(casting.map(\.lift).max() ?? 0, 0), 1))
        let shadow = 1 + (NibOptics.liftedShadow - 1) * lift
        let y = NibOptics.shadowOffset + (NibOptics.liftedShadowOffset - NibOptics.shadowOffset) * lift
        return (Float(rim), Float(shadow), Float(y))
    }

    /// Union-find over the linked pairs; groups keep the order of `ids`.
    static func groups(_ ids: [String], linked: Set<DropletField.PairKey>) -> [[String]] {
        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func root(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            var y = x
            while let p = parent[y], p != r { parent[y] = r; y = p }     // path compression
            return r
        }
        for pair in linked where parent[pair.a] != nil && parent[pair.b] != nil {
            let ra = root(pair.a), rb = root(pair.b)
            if ra != rb { parent[rb] = ra }
        }
        var order: [String] = []
        var members: [String: [String]] = [:]
        for id in ids {
            let r = root(id)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(id)
        }
        return order.compactMap { members[$0] }
    }
}
```

### 3.17a `NibKit/Sources/NibDesign/Liquid/DropletDock.swift`

The palette's water dock (DESIGN.md §10.1–10.3, §10.10, §10.11), public so any droplet that docks like the palette can use it. `DropletDockModel` is the pure dock logic (region, frames, the projected release, the nearest dock with the top's +40 pt bias, the 200 / 160 pt capture radius, the meniscus law) and is unit-tested (§3.28a). `.dropletDockable(_:length:thickness:docks:current:style:reservedTrailing:onDock:)` makes a full-size child of the container a dockable droplet; its content reads `@Environment(\.nibDockEdge)` for its axis. `NibDock.commandValue` / `init?(commandValue:)` are the `toolbar.dock` names (left, right, top, bottom). Internally `DockMeniscus` is the neck to the dock that `DropletField` draws, `DropletDockDriver` is the hold-and-release path `NibToolPalette` shares, and `DockLanding` arms the one plip.

```swift
import SwiftUI
import QuartzCore

// MARK: - The dock model (pure)

/// Where a dockable droplet (the tool palette) rests and which dock a release chooses (DESIGN.md §10.11). Pure value
/// logic in one coordinate space (the container's, `NibLiquid.space`): every number the dock feel runs on lives here and
/// is unit-tested.
public struct DropletDockModel: Equatable, Sendable {
    /// A release docks to the nearest dock only when the projected finger is within this distance of that dock's centre
    /// line (the top counts `topBias` further). Anywhere else the droplet flows home to the dock it left: nothing rests
    /// where it lands, and a drop in the middle of the page never moves the palette by accident.
    public static let captureRadius: CGFloat = 200
    /// iPhone (compact width): a narrower page and only the top and bottom docks.
    public static let captureRadiusCompact: CGFloat = 160
    /// The top dock sits under the bars, so it is chosen only on purpose: its distance counts 40 pt more.
    public static let topBias: CGFloat = 40
    /// The body is home when its centre is this close to its dock: the one plip plays then.
    public static let arrivalTolerance: CGFloat = 1.5
    /// A release that has not arrived within this time never plips (it was interrupted by another drag).
    public static let arrivalTimeout: Double = 1.5
    /// The meniscus (a neck, DESIGN.md §10.5): it starts to reach for the dock at a 72 pt gap, touches and fuses at 20 pt,
    /// is 26 pt thick at contact, thins as t₀·(1 − gap/off)^0.7 and pinches when t < t_min (≈ 52 pt on iPad).
    public static let meniscusJoin: CGFloat = 20
    public static let meniscusThickness: CGFloat = 26
    public static let meniscusOff: CGFloat = 72

    /// The rect every docked frame stays inside (below the bars, 16 pt in from the edges).
    public var region: CGRect
    /// The droplet's size docked at the top or bottom.
    public var horizontal: CGSize
    /// The droplet's size docked at the left or right edge.
    public var vertical: CGSize
    /// The docks this device offers (compact widths keep the top and bottom only).
    public let docks: [NibDock]
    public var captureRadius: CGFloat

    public init(region: CGRect, horizontal: CGSize, vertical: CGSize, docks: [NibDock] = NibDock.allCases,
                compact: Bool = false) {
        self.region = region
        self.horizontal = horizontal
        self.vertical = vertical
        let allowed = compact ? docks.filter { !$0.isVertical } : docks
        self.docks = allowed.isEmpty ? [.bottom] : allowed
        self.captureRadius = compact ? Self.captureRadiusCompact : Self.captureRadius
    }

    /// A droplet `length` long and `thickness` thick (the palette: its length and 56 pt).
    public init(region: CGRect, length: CGFloat, thickness: CGFloat, docks: [NibDock] = NibDock.allCases,
                compact: Bool = false) {
        self.init(region: region, horizontal: CGSize(width: length, height: thickness),
                  vertical: CGSize(width: thickness, height: length), docks: docks, compact: compact)
    }

    /// The docks' region in a full-window view of `size`: below the bars (safe area + 8 + 44 + 16), 16 pt in from the
    /// sides, 16 pt above the bottom safe area (8 on iPhone, just above the home indicator), less `reservedTrailing` (a
    /// docked assistant panel moves the right dock to its leading edge).
    public static func region(size: CGSize, safeArea s: EdgeInsets, compact: Bool,
                              reservedTrailing: CGFloat = 0) -> CGRect {
        let top = s.top + NibMetrics.barTopGap + NibMetrics.barHeight + NibSpacing.l
        let bottom = s.bottom + (compact ? NibSpacing.s : NibSpacing.l)
        return CGRect(x: s.leading + NibSpacing.l, y: top,
                      width: max(0, size.width - s.leading - s.trailing - 2 * NibSpacing.l - reservedTrailing),
                      height: max(0, size.height - top - bottom))
    }

    public func size(for edge: NibDock) -> CGSize { edge.isVertical ? vertical : horizontal }

    /// The frame docked at `dock`: `along` 0…1 slides it from the start of its edge to the end.
    public func frame(for dock: NibPaletteDock) -> CGRect {
        let s = size(for: dock.edge), r = region
        let t = min(max(dock.along, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let c: CGPoint
        switch dock.edge {
        case .leading: c = CGPoint(x: r.minX + s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .trailing: c = CGPoint(x: r.maxX - s.width / 2, y: lerp(r.minY + s.height / 2, r.maxY - s.height / 2))
        case .top: c = CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.minY + s.height / 2)
        case .bottom: c = CGPoint(x: lerp(r.minX + s.width / 2, r.maxX - s.width / 2), y: r.maxY - s.height / 2)
        }
        return CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    /// The `along` that centres the droplet on `point` (clamped to its edge).
    public func along(for point: CGPoint, on edge: NibDock) -> CGFloat {
        let s = size(for: edge)
        let t = edge.isVertical
            ? (point.y - (region.minY + s.height / 2)) / max(1, region.height - s.height)
            : (point.x - (region.minX + s.width / 2)) / max(1, region.width - s.width)
        return min(max(t, 0), 1)
    }

    public func along(ofFrame frame: CGRect, on edge: NibDock) -> CGFloat {
        along(for: CGPoint(x: frame.midX, y: frame.midY), on: edge)
    }

    /// Distance from `p` to the line the droplet's centre sits on at `edge` (perpendicular to the edge; anywhere along
    /// it counts), plus 40 pt for the top.
    public func distance(from p: CGPoint, to edge: NibDock) -> CGFloat {
        let s = size(for: edge)
        switch edge {
        case .leading: return abs(p.x - (region.minX + s.width / 2))
        case .trailing: return abs(p.x - (region.maxX - s.width / 2))
        case .top: return abs(p.y - (region.minY + s.height / 2)) + Self.topBias
        case .bottom: return abs(p.y - (region.maxY - s.height / 2))
        }
    }

    /// The nearest dock this device offers (top biased by 40 pt).
    public func nearestDock(to p: CGPoint) -> NibDock {
        docks.min { distance(from: p, to: $0) < distance(from: p, to: $1) } ?? .bottom
    }

    /// The nearest dock if `p` is within its capture radius, otherwise nil.
    public func capturedDock(at p: CGPoint) -> NibDock? {
        let edge = nearestDock(to: p)
        return distance(from: p, to: edge) <= captureRadius ? edge : nil
    }

    /// The landing a release projects: p + v·0.12 s, with v zeroed if the finger rested ≥ 70 ms and capped at 5000 pt/s.
    public static func projectedPoint(finger p: CGPoint, velocity v: CGVector, stillFor: Double) -> CGPoint {
        DropletPhysics.projectedLanding(p, velocity: DropletPhysics.releaseVelocity(v, stillFor: stillFor))
    }

    /// The dock a release lands in, from the projected point: the nearest dock within the capture radius, centred on
    /// the projected point along it; otherwise home (`current`).
    public func release(projected p: CGPoint, from current: NibPaletteDock) -> NibPaletteDock {
        guard let edge = capturedDock(at: p) else { return validated(current) }
        return NibPaletteDock(edge: edge, along: along(for: p, on: edge))
    }

    /// `release(projected:from:)` from the raw finger, velocity and stillness.
    public func release(finger: CGPoint, velocity: CGVector, stillFor: Double,
                        from current: NibPaletteDock) -> NibPaletteDock {
        release(projected: Self.projectedPoint(finger: finger, velocity: velocity, stillFor: stillFor), from: current)
    }

    /// A dock this device does not offer (a side edge on iPhone) becomes the bottom, else the first dock offered.
    public func validated(_ dock: NibPaletteDock) -> NibPaletteDock {
        if docks.contains(dock.edge) { return dock }
        return NibPaletteDock(edge: docks.contains(.bottom) ? .bottom : docks[0], along: 0.5)
    }

    /// While held: the frame the meniscus reaches for (the dock the finger is within capture of, slid along its edge to
    /// face the body), or nil.
    public func meniscusTarget(finger: CGPoint, body: CGRect) -> CGRect? {
        guard let edge = capturedDock(at: finger) else { return nil }
        return frame(for: NibPaletteDock(edge: edge, along: along(for: CGPoint(x: body.midX, y: body.midY), on: edge)))
    }

    static var meniscusParams: NeckParams {
        NeckParams(join: meniscusJoin, t0: meniscusThickness, off: meniscusOff)
    }

    /// The meniscus thickness at `gap`: t₀·(1 − gap/off)^0.7 (the §10.5 law), 0 beyond `off`.
    public static func meniscusThickness(gap: CGFloat) -> CGFloat {
        DropletPhysics.neckThickness(gap: gap, params: meniscusParams)
    }

    /// How far across the gap the tongue reaches before it touches: 0 at `off`, 1 at `join` (smoothstep).
    public static func meniscusReach(gap: CGFloat) -> CGFloat {
        let t = min(max((meniscusOff - gap) / (meniscusOff - meniscusJoin), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The gap at which a fused meniscus pinches: where t falls below the thinnest bridge the field can hold.
    public static func meniscusPinchGap(minimumNeck: CGFloat) -> CGFloat {
        meniscusOff * (1 - pow(min(minimumNeck / meniscusThickness, 1), 1 / 0.7))
    }

    public static func hasArrived(centre: CGPoint, at target: CGPoint) -> Bool {
        let dx = centre.x - target.x, dy = centre.y - target.y
        return (dx * dx + dy * dy).squareRoot() <= arrivalTolerance
    }
}

public extension NibDock {
    /// The dock as commands, plugins and the assistant name it (`toolbar.dock {dock}`): "left", "right", "top",
    /// "bottom". Left and right are the leading and trailing edges (mirrored in right-to-left layouts).
    var commandValue: String {
        switch self {
        case .leading: return "left"
        case .trailing: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }

    init?(commandValue: String) {
        switch commandValue.lowercased() {
        case "left", "leading": self = .leading
        case "right", "trailing": self = .trailing
        case "top": self = .top
        case "bottom": self = .bottom
        default: return nil
        }
    }
}

// MARK: - The meniscus

/// The palette's meniscus to the dock it reaches for (DESIGN.md §10.11): a tongue that grows out of the body as it nears
/// the dock, fuses when it touches, then holds on like every neck (§10.5) and pinches when it is thinner than the field
/// can hold. `DropletField` steps it and draws `segment` as a neck of its droplet; the rules are all here. It never plays
/// a haptic: the one plip is the arrival.
struct DockMeniscus: Equatable {
    enum Phase: Equatable {
        case idle, reaching, fused, retracting
    }

    struct Segment: Equatable {
        var from: CGPoint
        var to: CGPoint
        var thickness: CGFloat
    }

    static let neckID = "dock.meniscus"

    /// The dock frame to reach for; nil lets go (whatever is out retracts).
    var target: CGRect?
    private(set) var phase: Phase = .idle
    private(set) var segment: Segment?
    private var last: CGRect?
    private var thickness = SpringValue(0, epsilon: 0.05)
    /// How far the far end sits past the body's edge point, towards the dock (negative: inside the body).
    private var extent = SpringValue(0, epsilon: 0.05)

    var isIdle: Bool { target == nil && last == nil }

    /// One frame. `body` is the droplet's visual box; `enabled` is false under Reduce Motion, Calm and Liquid Off (no
    /// necks) and while the droplet is not drawn. Returns true while anything moves.
    mutating func step(_ dt: CGFloat, body: CGRect, enabled: Bool, minimumNeck: CGFloat) -> Bool {
        if let target { last = target }
        guard let dock = last else {
            segment = nil
            return false
        }
        let short = min(min(body.width, body.height), min(dock.width, dock.height)) / 2
        let g = DropletPhysics.gap(body, dock, minCorner: short)
        let gap = g.gap
        let t = DropletDockModel.meniscusThickness(gap: gap)
        let inA = min(8, min(body.width, body.height) / 3)
        let inB = min(8, min(dock.width, dock.height) / 3)
        let letGo = target == nil || !enabled
        if letGo {
            if phase != .idle { phase = .retracting }
        } else {
            switch phase {
            case .idle, .reaching:
                if gap < DropletDockModel.meniscusJoin {
                    phase = .fused
                } else {
                    phase = gap < DropletDockModel.meniscusOff ? .reaching : .idle
                }
            case .fused:
                if t < minimumNeck { phase = .retracting }
            case .retracting:
                // A pinched meniscus re-arms only once the body is out of reach again (or it touches again).
                if gap < DropletDockModel.meniscusJoin {
                    phase = .fused
                } else if gap >= DropletDockModel.meniscusOff {
                    phase = .idle
                }
            }
        }
        switch phase {
        case .idle, .retracting:
            thickness.target = 0
            extent.target = -inA
        case .reaching:
            thickness.target = t
            extent.target = max(-inA, DropletDockModel.meniscusReach(gap: gap) * gap - t / 2)
        case .fused:
            thickness.target = t
            extent.target = gap + inB
        }
        thickness.step(dt, spring: NibMotion.neck)
        extent.step(dt, spring: NibMotion.neck)
        let moving = !(thickness.isResting && extent.isResting)

        if letGo && thickness.value < 0.3 {
            phase = .idle
            last = nil
            segment = nil
            return false
        }
        let ca = CGPoint(x: body.midX, y: body.midY), cb = CGPoint(x: dock.midX, y: dock.midY)
        var dx = g.pointB.x - g.pointA.x, dy = g.pointB.y - g.pointA.y
        var length = (dx * dx + dy * dy).squareRoot()
        if length < 0.5 {
            dx = cb.x - ca.x
            dy = cb.y - ca.y
            length = (dx * dx + dy * dy).squareRoot()
        }
        guard length > 0.001, thickness.value > 0.8 else {
            segment = nil
            return moving
        }
        let nx = dx / length, ny = dy / length
        let from = CGPoint(x: g.pointA.x - nx * inA, y: g.pointA.y - ny * inA)
        let reach = max(extent.value, -inA + 0.5)
        segment = Segment(from: from, to: CGPoint(x: g.pointA.x + nx * reach, y: g.pointA.y + ny * reach),
                          thickness: thickness.value)
        return moving
    }
}

// MARK: - The driver (shared by `.dropletDockable` and `NibToolPalette`)

/// A release: the dock chosen, the frame it rests in (fused to or 16 pt clear of its neighbours) and the velocity the
/// snap starts from.
struct DockRelease: Equatable {
    var dock: NibPaletteDock
    var frame: CGRect
    var velocity: CGVector
}

/// An armed arrival: the plip plays once, the first time the released body reaches `centre` (within 1.5 pt) or comes
/// to rest. The snap overshoots by about 4 pt and comes back, but the landing is disarmed by then: one plip.
struct DockLanding: Equatable {
    enum Outcome: Equatable {
        case waiting, arrived, expired
    }

    var centre: CGPoint
    var since: CFTimeInterval = CACurrentMediaTime()

    func check(body: CGPoint, settling: Bool, now: CFTimeInterval) -> Outcome {
        if now - since > DropletDockModel.arrivalTimeout { return .expired }
        return DropletDockModel.hasArrived(centre: body, at: centre) || !settling ? .arrived : .waiting
    }
}

/// Drives one dockable droplet of a container: hold, meniscus, release to a dock. The palette and every other
/// dockable use it, so they feel the same.
struct DropletDockDriver {
    let id: String
    let field: DropletField

    func begin(at location: CGPoint) {
        field.beginDrag(id, at: location)
    }

    /// While held: follow the finger (`follow`), and reach for the dock the finger is within capture of.
    func move(to location: CGPoint, model: DropletDockModel) {
        field.drag(id, to: location)
        let body = field.visualFrame(id) ?? CGRect(origin: location, size: .zero)
        field.setMeniscus(id, towards: model.meniscusTarget(finger: location, body: body))
    }

    /// Ends the drag: the release velocity (careful-release rule, capped) projects the landing, the model picks the
    /// dock, the body rests fused to or 16 pt clear of its neighbours, and the meniscus now reaches for that dock (the
    /// body swallows it as it lands). The droplet springs there with `snap` from the full release velocity.
    func release(at location: CGPoint, velocity: CGVector, from current: NibPaletteDock,
                 model: DropletDockModel) -> DockRelease {
        let v = field.endDrag(id, velocity: velocity)
        var next = model.release(projected: DropletPhysics.projectedLanding(location, velocity: v), from: current)
        let rested = field.restingRect(model.frame(for: next), excluding: id,
                                       along: next.isVertical ? .vertical : .horizontal)
        next.along = model.along(ofFrame: rested, on: next.edge)
        field.setMeniscus(id, towards: rested)
        return DockRelease(dock: next, frame: rested, velocity: v)
    }

    /// The body is home: let the meniscus go and play the one plip.
    func arrive() {
        field.setMeniscus(id, towards: nil)
        NibHaptics.play(.plip)
    }
}

/// Plays the arrival plip once the released body reaches its dock (or comes to rest), then disarms. A leaf: it reads
/// the droplet's node, so only it re-renders per frame.
struct DockArrivalWatcher: View {
    let id: String
    let node: DropletNode?
    let field: DropletField?
    @Binding var landing: DockLanding?

    var body: some View {
        Color.clear
            .onChange(of: node?.presentation) { _, p in
                guard let target = landing, let p, !p.isLifted, let field, let box = field.visualFrame(id) else { return }
                switch target.check(body: CGPoint(x: box.midX, y: box.midY), settling: p.isSettling,
                                    now: CACurrentMediaTime()) {
                case .waiting:
                    break
                case .arrived:
                    landing = nil
                    DropletDockDriver(id: id, field: field).arrive()
                case .expired:
                    landing = nil
                    field.setMeniscus(id, towards: nil)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - `.dropletDockable`

private struct NibDockEdgeKey: EnvironmentKey {
    static let defaultValue: NibDock? = nil
}

public extension EnvironmentValues {
    /// The edge a `.dropletDockable` droplet is laid out for: lay the content out vertically for `.leading` and
    /// `.trailing`. It switches at the midpoint of a re-form, while the content is invisible. nil outside a dockable.
    var nibDockEdge: NibDock? {
        get { self[NibDockEdgeKey.self] }
        set { self[NibDockEdgeKey.self] = newValue }
    }
}

public extension View {
    /// Makes this view a dockable droplet of the enclosing `NibDropletContainer` (DESIGN.md §10.1–10.3, §10.10,
    /// §10.11). Place it as a full-size child of the container: it positions itself at `current`, and lays its content
    /// out `length` × `thickness` (read `@Environment(\.nibDockEdge)` for the axis).
    ///
    /// Held, it is a bead of water: it lifts, its rim strengthens, it follows the finger with `follow` (a slight lag),
    /// stretches with its speed about the grab point, settles with one small wobble, keeps lensing the page, and grows a
    /// meniscus towards the dock it would land in. Released, it projects the fling (p + v·0.12 s), picks the nearest
    /// dock within the capture radius (else flows home), springs there with `snap` from the release velocity, re-forms
    /// when the orientation changes, and plays one plip on arrival. Under Reduce Motion it cross-fades.
    ///
    /// - Parameters:
    ///   - id: the droplet's id, unique in the container.
    ///   - length, thickness: its size along and across its dock (the palette: its length and 56 pt).
    ///   - docks: the edges it may use (compact widths keep top and bottom only).
    ///   - current: where it rests. Changing it from outside (a command, an accessibility action) moves it there.
    ///   - style: its droplet style (`.palette`).
    ///   - reservedTrailing: width kept clear at the trailing edge (a docked assistant panel).
    ///   - onDock: the dock a release or an accessibility action chose. Set `current` from it (FeatToolbar runs
    ///     `toolbar.dock`); leaving `current` unchanged sends the droplet home.
    func dropletDockable(_ id: String, length: CGFloat, thickness: CGFloat = NibMetrics.paletteThickness,
                         docks: [NibDock] = NibDock.allCases, current: NibPaletteDock,
                         style: DropletStyle = .palette, reservedTrailing: CGFloat = 0,
                         onDock: @escaping (NibPaletteDock) -> Void) -> some View {
        modifier(DropletDockableModifier(id: id, length: length, thickness: thickness, docks: docks, current: current,
                                         style: style, reservedTrailing: reservedTrailing, onDock: onDock))
    }
}

struct DropletDockableModifier: ViewModifier {
    let id: String
    let length: CGFloat
    let thickness: CGFloat
    let docks: [NibDock]
    let current: NibPaletteDock
    let style: DropletStyle
    let reservedTrailing: CGFloat
    let onDock: (NibPaletteDock) -> Void

    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nibLiquidMode) private var mode
    /// The dock the content is laid out for. It lags `current` through a re-form (the axis switches at the midpoint).
    @State private var laidOut: NibPaletteDock?
    /// The dock a running re-form spreads into.
    @State private var pending: NibPaletteDock?
    @State private var dragging = false
    @State private var releaseVelocity: CGVector = .zero
    @State private var landing: DockLanding?
    @State private var opacity: Double = 1
    @GestureState private var live = false

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let compact = sizeClass == .compact
            let origin = proxy.frame(in: NibLiquid.space).origin
            let model = DropletDockModel(
                region: DropletDockModel.region(size: proxy.size, safeArea: proxy.safeAreaInsets, compact: compact,
                                                reservedTrailing: reservedTrailing)
                    .offsetBy(dx: origin.x, dy: origin.y),
                length: length, thickness: thickness, docks: docks, compact: compact)
            let wanted = model.validated(current)
            let dock = laidOut ?? wanted
            let frame = model.frame(for: dock)
            let driver = field.map { DropletDockDriver(id: id, field: $0) }
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.nibDockEdge, dock.edge)
                    .frame(width: frame.width, height: frame.height)
                    .droplet(id, style: style, managesDrag: false)
                    .opacity(opacity)
                    .gesture(dragGesture(driver: driver, model: model))
                    .accessibilityActions {
                        ForEach(model.docks, id: \.self) { edge in
                            Button(edge.moveTitle) { onDock(NibPaletteDock(edge: edge, along: 0.5)) }
                        }
                    }
                    .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(DockArrivalWatcher(id: id, node: field?.node(id), field: field, landing: $landing))
            .onAppear { if laidOut == nil { laidOut = wanted } }
            .onChange(of: wanted) { _, next in adopt(next, model: model) }
            .onChange(of: live) { _, isLive in
                // A cancelled drag (no onEnded) still lets go: the droplet flows home with no velocity.
                guard !isLive else { return }
                DispatchQueue.main.async {
                    guard dragging, let driver else { return }
                    dragging = false
                    let box = field?.visualFrame(id) ?? frame
                    let r = driver.release(at: CGPoint(x: box.midX, y: box.midY), velocity: .zero,
                                           from: laidOut ?? wanted, model: model)
                    landing = DockLanding(centre: CGPoint(x: r.frame.midX, y: r.frame.midY))
                }
            }
        }
        .background(ReshapeWatcher(node: field?.node(id)) {
            if let pending {
                laidOut = pending
                self.pending = nil
            }
        })
    }

    private func dragGesture(driver: DropletDockDriver?, model: DropletDockModel) -> some Gesture {
        DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .updating($live) { _, state, _ in state = true }
            .onChanged { value in
                guard let driver else { return }
                if !dragging {
                    dragging = true
                    landing = nil
                    driver.begin(at: value.startLocation)
                }
                driver.move(to: value.location, model: model)
            }
            .onEnded { value in
                guard let driver, dragging else { return }
                dragging = false
                let from = laidOut ?? model.validated(current)
                let r = driver.release(at: value.location,
                                       velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height),
                                       from: from, model: model)
                releaseVelocity = r.velocity
                landing = DockLanding(centre: CGPoint(x: r.frame.midX, y: r.frame.midY))
                if r.dock != from { onDock(r.dock) }
            }
    }

    /// `current` changed (a release, an accessibility action, a command): move there. Same axis: the new layout
    /// position animates from where the body is (FLIP, `snap`, from the release velocity). Other axis: re-form (§10.10).
    /// Reduce Motion or Liquid Off: fade out, move, fade in.
    private func adopt(_ next: NibPaletteDock, model: DropletDockModel) {
        let shown = laidOut ?? next
        let velocity = releaseVelocity
        releaseVelocity = .zero
        guard next != shown else { return }
        if reduceMotion || mode == .off {
            withAnimation(NibMotion.exit) { opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                laidOut = next
                pending = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.reduced.response) {
                    withAnimation(NibMotion.enter) { opacity = 1 }
                }
            }
        } else if next.isVertical != shown.isVertical, let field {
            let target = model.frame(for: next)
            pending = next
            field.beginReshape(id, towards: CGPoint(x: target.midX, y: target.midY), velocity: velocity)
        } else {
            laidOut = next
        }
    }
}
```

### 3.17b `NibKit/Sources/NibDesign/Liquid/NibReflow.swift`

The library's live reorder (DESIGN.md §10.12, §14.1). `NibReflowModel` is the pure logic (the gap under the finger with 24 pt hysteresis, the combine zone that holds a cover still, the outside margin, every item's target slot, the move as from / to / after / before) and is unit-tested (§3.28b). `NibReflow` is the observable a grid shares: `.nibReflowSpace` on the grid's content, `.nibReflowItem` (the neighbours spring aside with `reflow`) and `.nibReflowDraggable` (0.3 s press, then 6 pt; "Move earlier" / "Move later" actions) on each cell, and `NibReflowCarrier` in the window's droplet container: the lifted card as a `card` droplet, and the armed cover necking with it. A drop is `.reorder` (apply it to the data in the same update, then run `library.reorder`), `.combine` (`library.move` onto the notebook) or `.none`.

```swift
import SwiftUI
import Observation
import QuartzCore

// MARK: - Numbers

/// The library's live reorder (DESIGN.md §10.12, §14.1): home-screen reflow with water easing.
public enum NibReflowMetrics {
    /// The finger must be this much closer to another slot's centre than to the gap's before the gap moves (it moves
    /// half of this past the midpoint), so the gap never flickers at a boundary.
    public static let hysteresis: CGFloat = 24
    /// The inner share of a cover that is its combine zone: while the finger is in it, that cover holds still, so a
    /// combine can arm after `NibMotion.combineHold` (380 ms).
    public static let combineCore: CGFloat = 0.70
    /// Further than this outside every slot (over the sidebar, a folder tile, the bars) the gap closes back at home.
    public static let outsideMargin: CGFloat = 24
    /// A press this long lifts a card out of a scroll view (then 6 pt of movement picks it up).
    public static let liftDelay: Double = 0.3
    /// The cover a combine is armed on swells to this.
    public static let armedScale: CGFloat = 1.03
    /// A carrier that has not landed within this long after the drop is removed anyway.
    public static let landingTimeout: Double = 1.2
    /// The coordinate space of a reflowing grid (`.nibReflowSpace`): put it on the scrolled content, so frames and the
    /// finger stay put while the grid scrolls.
    public static let space = NamedCoordinateSpace.named("nib.reflow")
}

// MARK: - The model (pure)

/// A slot grid: slot i's frame in the reflow space (the library's cover grid, 164 pt pitch in 11-inch landscape).
public struct NibReflowLayout: Equatable, Sendable {
    public var columns: Int
    public var cell: CGSize
    public var spacing: CGSize
    public var origin: CGPoint

    public init(columns: Int, cell: CGSize,
                spacing: CGSize = CGSize(width: NibMetrics.libraryGutter, height: NibMetrics.libraryGutter),
                origin: CGPoint = .zero) {
        self.columns = columns
        self.cell = cell
        self.spacing = spacing
        self.origin = origin
    }

    public func slot(_ index: Int) -> CGRect {
        let c = max(columns, 1)
        return CGRect(x: origin.x + CGFloat(index % c) * (cell.width + spacing.width),
                      y: origin.y + CGFloat(index / c) * (cell.height + spacing.height),
                      width: cell.width, height: cell.height)
    }

    public func slots(count: Int) -> [CGRect] { (0..<max(count, 0)).map { slot($0) } }
}

/// A finished reorder: the item moves from `from` to `to` (indices in the order the drag began with).
public struct NibReflowMove<ID: Hashable>: Equatable {
    public let id: ID
    public let from: Int
    public let to: Int
    /// The neighbours it lands between (nil at either end): what `library.reorder {after?, before?}` takes.
    public let after: ID?
    public let before: ID?

    public init(id: ID, from: Int, to: Int, in order: [ID]) {
        self.id = id
        self.from = from
        self.to = to
        let result = NibReflowModel<ID>.reordered(order, from: from, to: to)
        after = to > 0 && to - 1 < result.count ? result[to - 1] : nil
        before = to + 1 < result.count ? result[to + 1] : nil
    }
}

/// What a drop means. `.reorder` is recorded as an undoable reorder command; `.combine` as a merge (§10.12).
public enum NibReflowDrop<ID: Hashable>: Equatable {
    /// Back where it was.
    case none
    case reorder(NibReflowMove<ID>)
    /// Dropped while a combine was armed on `into`.
    case combine(ID, into: ID)
}

/// The live insertion point of a drag and every item's target slot. Pure value logic: the finger, the ordered ids and
/// their slot frames in; the gap and the offsets out (DESIGN.md §10.12).
///
/// - The gap sits at the slot nearest the finger. It moves only when the finger is `hysteresis` closer to another
///   slot's centre than to the gap's, so it never flickers at a boundary.
/// - While the finger is in the inner 70 % of another cover (its combine zone), that cover holds still: the reflow
///   waits, so a combine can arm. Paused (a combine armed, a folder fused), nothing moves.
/// - Outside every slot by more than `outsideMargin`, the gap closes back at home.
public struct NibReflowModel<ID: Hashable>: Equatable {
    public let ids: [ID]
    public let slots: [CGRect]
    /// The dragged item's index.
    public let from: Int
    /// Where the gap is: the index the dragged item would land at.
    public private(set) var insertion: Int
    public var hysteresis: CGFloat
    /// Covers can combine (notebooks): their inner 70 % holds the reflow. Page thumbnails do not.
    public var combines: Bool
    public var outsideMargin: CGFloat

    /// nil unless `dragged` is in `ids` and every id has a slot.
    public init?(ids: [ID], slots: [CGRect], dragged: ID, combines: Bool = true,
                 hysteresis: CGFloat = NibReflowMetrics.hysteresis,
                 outsideMargin: CGFloat = NibReflowMetrics.outsideMargin) {
        guard ids.count == slots.count, let i = ids.firstIndex(of: dragged) else { return nil }
        self.ids = ids
        self.slots = slots
        self.from = i
        self.insertion = i
        self.hysteresis = hysteresis
        self.combines = combines
        self.outsideMargin = outsideMargin
    }

    public var dragged: ID { ids[from] }

    /// Where the item at `index` is shown for the current gap: the ones between home and the gap shift one slot.
    public func targetIndex(ofIndex i: Int) -> Int {
        if i == from { return insertion }
        if from < insertion && i > from && i <= insertion { return i - 1 }
        if insertion < from && i >= insertion && i < from { return i + 1 }
        return i
    }

    public func targetIndex(of id: ID) -> Int? { ids.firstIndex(of: id).map { targetIndex(ofIndex: $0) } }

    public func targetSlot(of id: ID) -> CGRect? { targetIndex(of: id).map { slots[$0] } }

    /// How far the item is shown from its own slot (centre to centre).
    public func offset(of id: ID) -> CGSize {
        guard let i = ids.firstIndex(of: id) else { return .zero }
        let a = slots[i], b = slots[targetIndex(ofIndex: i)]
        return CGSize(width: b.midX - a.midX, height: b.midY - a.midY)
    }

    /// The cover whose shown frame's inner 70 % holds `p` (never the dragged one): a combine target.
    public func combineCandidate(at p: CGPoint) -> ID? {
        guard combines else { return nil }
        let inset = (1 - NibReflowMetrics.combineCore) / 2
        for i in ids.indices where i != from {
            let r = slots[targetIndex(ofIndex: i)]
            if r.insetBy(dx: r.width * inset, dy: r.height * inset).contains(p) { return ids[i] }
        }
        return nil
    }

    /// The slot the finger asks for (before hysteresis): the nearest slot centre, or home when `p` is outside every
    /// slot by more than `outsideMargin`.
    public func candidate(at p: CGPoint) -> Int { nearest(p).index }

    /// Moves the gap for the finger at `p`. Returns true when it moved (the neighbours reflow).
    @discardableResult
    public mutating func update(finger p: CGPoint, paused: Bool = false) -> Bool {
        guard !paused, combineCandidate(at: p) == nil else { return false }
        let n = nearest(p)
        guard n.index != insertion else { return false }
        if n.inside {
            guard Self.distance(p, slots[n.index]) + hysteresis < Self.distance(p, slots[insertion]) else { return false }
        }
        insertion = n.index
        return true
    }

    /// The reorder the current gap means, nil if the item would land at home.
    public var move: NibReflowMove<ID>? {
        insertion == from ? nil : NibReflowMove(id: dragged, from: from, to: insertion, in: ids)
    }

    /// `ids` with the item at `from` moved to `to`.
    public static func reordered(_ ids: [ID], from: Int, to: Int) -> [ID] {
        guard ids.indices.contains(from), ids.indices.contains(to) else { return ids }
        var r = ids
        let x = r.remove(at: from)
        r.insert(x, at: to)
        return r
    }

    private func nearest(_ p: CGPoint) -> (index: Int, inside: Bool) {
        var best = from, bestDistance = CGFloat.infinity, inside = false
        for (i, r) in slots.enumerated() {
            if r.insetBy(dx: -outsideMargin, dy: -outsideMargin).contains(p) { inside = true }
            let d = Self.distance(p, r)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return inside ? (best, true) : (from, false)
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = p.x - r.midX, dy = p.y - r.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - The live reorder

/// A live reorder for SwiftUI: the pure `NibReflowModel` plus the item frames, the lifted carrier and combine arming.
/// Items read only their own offset (`.nibReflowItem`), so a moved gap re-renders only the items that move.
///
/// Usage: `.nibReflowSpace(reflow)` on the grid's content; `.nibReflowItem(id, in: reflow)` and
/// `.nibReflowDraggable(id, in: reflow, order:onDrop:)` on each cell; a `NibReflowCarrier` in the window's droplet
/// container (the lifted card as water). In `onDrop`, apply a `.reorder` to your data in that same update (optimistic:
/// the neighbours are already where the new order puts them) and record it as one undoable command
/// (`library.reorder`); a `.combine` is a merge (`library.move` onto the notebook).
@Observable
public final class NibReflow<ID: Hashable> {
    /// The lifted item, in global coordinates (the carrier follows it).
    public struct Lift: Equatable {
        public enum Phase: Equatable {
            case dragging
            case released(CGVector)
        }

        public let id: ID
        public var start: CGPoint
        public var location: CGPoint
        public var phase: Phase
    }

    /// The drag in progress (nil between drags).
    public private(set) var model: NibReflowModel<ID>?
    /// The carrier's state (only the carrier reads it: it changes with every finger move).
    public private(set) var lift: Lift?
    /// The item that is lifted (its cell hides while a carrier draws it).
    public private(set) var carried: ID?
    /// Where the carrier rests, in global coordinates: the item's home slot while dragging, the slot it lands in once
    /// dropped (the field flies it there from wherever the finger let go).
    public private(set) var carrierFrame: CGRect?
    /// The cover a combine is armed on (the finger held in its inner 70 % for 380 ms): the reflow pauses.
    public private(set) var armed: ID?
    /// The armed cover's frame, in global coordinates (it holds still while armed, and until the card has flowed in).
    public private(set) var armedFrame: CGRect?
    /// Hold the reflow from outside: the card fused with a folder film, or it is over the sidebar.
    public var isPaused = false
    /// The card is over the sidebar: the carrier condenses to 50 % around the finger (§10.12).
    public var isCondensed = false
    /// Neighbours spring with `reflow` while a drag is on; a drop that reorders the data resets them at once.
    public private(set) var animatesOffsets = true
    /// A `NibReflowCarrier` draws the lifted card (and the armed cover) as water.
    public internal(set) var hasCarrier = false
    /// A uniform grid computes slots itself; otherwise the cells' measured frames are used.
    public var layout: NibReflowLayout?
    public let combines: Bool

    @ObservationIgnored var frames: [ID: CGRect] = [:]
    @ObservationIgnored var spaceOrigin: CGPoint = .zero
    @ObservationIgnored private var order: [ID] = []
    @ObservationIgnored private var hover: ID?
    @ObservationIgnored private var armWork: DispatchWorkItem?
    @ObservationIgnored private var landingWork: DispatchWorkItem?

    public init(layout: NibReflowLayout? = nil, combines: Bool = true) {
        self.layout = layout
        self.combines = combines
    }

    public var isDragging: Bool { lift?.phase == .dragging }

    public func offset(for id: ID) -> CGSize { model?.offset(of: id) ?? .zero }

    public func isCarried(_ id: ID) -> Bool { carried == id }

    /// The frame an item is shown at now, in global coordinates (nil when no drag is on).
    public func globalFrame(of id: ID) -> CGRect? {
        guard let r = model?.targetSlot(of: id) else { return nil }
        return r.offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
    }

    /// Lifts `id` (in `order`, the items as the grid shows them) under the finger at `point` (reflow space).
    public func begin(_ id: ID, order: [ID], at point: CGPoint) {
        cancelArming()
        landingWork?.cancel()
        var ids: [ID] = [], slots: [CGRect] = []
        for (i, x) in order.enumerated() {
            if let layout {
                ids.append(x)
                slots.append(layout.slot(i))
            } else if let f = frames[x] {
                ids.append(x)
                slots.append(f)
            }
        }
        guard let m = NibReflowModel(ids: ids, slots: slots, dragged: id, combines: combines) else { return }
        self.order = order
        animatesOffsets = true
        armed = nil
        armedFrame = nil
        model = m
        carried = id
        let g = global(point)
        carrierFrame = m.slots[m.from].offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
        lift = Lift(id: id, start: g, location: g, phase: .dragging)
    }

    /// The finger moved (reflow space): the carrier follows, the gap reflows (unless paused or held), a combine arms.
    public func move(to point: CGPoint) {
        guard var m = model, var l = lift, l.phase == .dragging else { return }
        l.location = global(point)
        lift = l
        arm(m.combineCandidate(at: point), at: point, in: m)
        if m.update(finger: point, paused: isPaused || armed != nil) { model = m }
    }

    /// Drops. The carrier flows to where the item now belongs (its new slot, or into the armed cover). Apply a
    /// `.reorder` to the data in this same update.
    @discardableResult
    public func end(velocity: CGVector = .zero) -> NibReflowDrop<ID> {
        cancelArming()
        guard let m = model, var l = lift else { return .none }
        let drop: NibReflowDrop<ID>
        var rest = m.slots[m.from]
        if let armed, combines {
            drop = .combine(m.dragged, into: armed)
            rest = m.targetSlot(of: armed) ?? rest
        } else if let move = m.move {
            drop = .reorder(fullOrderMove(move, in: m))
            rest = m.slots[m.insertion]
        } else {
            drop = .none
        }
        // A reorder lands the data where the neighbours already are: reset them without animation. Otherwise they
        // spring back to their own slots.
        if case .reorder = drop { animatesOffsets = false }
        carrierFrame = rest.offsetBy(dx: spaceOrigin.x, dy: spaceOrigin.y)
        l.phase = .released(velocity)
        lift = l
        model = nil
        isPaused = false
        isCondensed = false
        scheduleLandingTimeout()
        return drop
    }

    /// Abandons the drag: the neighbours spring back and the carrier flows home.
    public func cancel() {
        guard let m = model else { return }
        if m.insertion != m.from {
            model = NibReflowModel(ids: m.ids, slots: m.slots, dragged: m.dragged, combines: m.combines)
        }
        armed = nil
        armedFrame = nil
        _ = end()
    }

    /// The carrier is home: the cell shows again.
    func landed() {
        landingWork?.cancel()
        lift = nil
        carried = nil
        carrierFrame = nil
        armed = nil
        armedFrame = nil
        animatesOffsets = true
    }

    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + spaceOrigin.x, y: p.y + spaceOrigin.y) }

    /// The move in the order the caller passed (the model may hold only the cells that were measured).
    private func fullOrderMove(_ move: NibReflowMove<ID>, in m: NibReflowModel<ID>) -> NibReflowMove<ID> {
        guard m.ids != order, let from = order.firstIndex(of: move.id),
              let to = order.firstIndex(of: m.ids[m.insertion]) else { return move }
        return NibReflowMove(id: move.id, from: from, to: to, in: order)
    }

    /// Combine arming (§10.12): the finger in a cover's inner 70 % for 380 ms arms it (armed haptic); leaving the
    /// cover disarms it and the reflow resumes. Proximity alone draws nothing.
    private func arm(_ candidate: ID?, at p: CGPoint, in m: NibReflowModel<ID>) {
        if let armed {
            if let r = m.targetSlot(of: armed), r.contains(p) { return }
            self.armed = nil
            armedFrame = nil
        }
        guard candidate != hover else { return }
        hover = candidate
        armWork?.cancel()
        armWork = nil
        guard let candidate, combines else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hover == candidate, self.isDragging else { return }
            self.armed = candidate
            self.armedFrame = self.globalFrame(of: candidate)
            NibHaptics.play(.armed)
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.combineHold, execute: work)
    }

    private func cancelArming() {
        armWork?.cancel()
        armWork = nil
        hover = nil
    }

    private func scheduleLandingTimeout() {
        landingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let l = self.lift, l.phase != .dragging else { return }
            self.landed()
        }
        landingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NibReflowMetrics.landingTimeout, execute: work)
    }
}

// MARK: - SwiftUI

public extension View {
    /// The reflow's coordinate space: put it on the grid's content (inside its scroll view).
    func nibReflowSpace<ID: Hashable>(_ reflow: NibReflow<ID>) -> some View {
        coordinateSpace(NibReflowMetrics.space)
            .onGeometryChange(for: CGPoint.self) { proxy in
                proxy.frame(in: .global).origin
            } action: { origin in
                reflow.spaceOrigin = origin
            }
    }

    /// One reorderable cell: it springs aside with `reflow` to open the gap, reports its slot, hides while the carrier
    /// draws it, and swells to 1.03 when a combine arms on it (the carrier draws that too, as water).
    func nibReflowItem<ID: Hashable>(_ id: ID, in reflow: NibReflow<ID>) -> some View {
        modifier(NibReflowItemModifier(id: id, reflow: reflow))
    }

    /// Makes a cell liftable: a 0.3 s press, then 6 pt of movement, lifts it; moving reflows its neighbours; lifting
    /// the finger calls `onDrop`. Also adds "Move earlier" and "Move later" accessibility actions (every drag has an
    /// action equivalent).
    func nibReflowDraggable<ID: Hashable>(_ id: ID, in reflow: NibReflow<ID>, order: [ID],
                                          onDrop: @escaping (NibReflowDrop<ID>) -> Void) -> some View {
        modifier(NibReflowDragModifier(id: id, reflow: reflow, order: order, onDrop: onDrop))
    }
}

struct NibReflowItemModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let reflow: NibReflow<ID>

    func body(content: Content) -> some View {
        let offset = reflow.offset(for: id)
        let armed = reflow.armed == id
        let drawnByCarrier = reflow.hasCarrier && (reflow.isCarried(id) || armed)
        content
            .scaleEffect(armed ? NibReflowMetrics.armedScale : 1)
            .animation(NibMotion.lift.animation, value: armed)
            .opacity(drawnByCarrier ? 0 : 1)
            .offset(offset)
            .animation(reflow.animatesOffsets ? NibMotion.reflow.animation : nil, value: offset)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: NibReflowMetrics.space)
            } action: { frame in
                reflow.frames[id] = frame
            }
    }
}

struct NibReflowDragModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let reflow: NibReflow<ID>
    let order: [ID]
    let onDrop: (NibReflowDrop<ID>) -> Void

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: NibReflowMetrics.liftDelay)
                    .sequenced(before: DragGesture(minimumDistance: DropletPhysics.pickupSlop,
                                                   coordinateSpace: NibReflowMetrics.space))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        if !reflow.isDragging { reflow.begin(id, order: order, at: drag.startLocation) }
                        reflow.move(to: drag.location)
                    }
                    .onEnded { value in
                        guard case .second(true, let drag?) = value, reflow.isDragging else {
                            reflow.cancel()
                            return
                        }
                        onDrop(reflow.end(velocity: CGVector(dx: drag.velocity.width, dy: drag.velocity.height)))
                    }
            )
            .accessibilityAction(named: Text(String(localized: "Move earlier", bundle: .module))) { step(-1) }
            .accessibilityAction(named: Text(String(localized: "Move later", bundle: .module))) { step(1) }
    }

    private func step(_ delta: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
        onDrop(.reorder(NibReflowMove(id: id, from: i, to: i + delta, in: order)))
    }
}

// MARK: - The carrier

extension DropletStyle {
    /// The cover a combine is armed on, as water under its own content: a 3 pt envelope (radius 8) with the held rim
    /// (it rises to meet the card) that necks with the lifted card (§10.12). Rigid: it does not move.
    static var armedCover: DropletStyle {
        var s = DropletStyle.card
        s.cornerRadius = NibRadius.cardEnvelope
        s.stretchCap = 0
        s.poke = 0
        s.lift = 1
        s.envelope = 0
        s.restsDry = false
        s.drag = .fixed
        s.isInteractive = false
        return s.lifted
    }
}

/// The lifted card as water (DESIGN.md §10.12): a `card` droplet in the window's droplet container that follows the
/// finger through a `NibReflow` drag (lift, 3 pt envelope, stretch, settle), condenses over the sidebar, necks with the
/// cover a combine is armed on, and flows with `slot` to where the item now belongs when it is dropped. Place it as a
/// full-size child of the `NibDropletContainer`; `content` draws an item exactly as its grid cell does (the cell hides
/// while the carrier draws it).
public struct NibReflowCarrier<ID: Hashable, Content: View>: View {
    let reflow: NibReflow<ID>
    let id: String
    let content: (ID) -> Content
    @Environment(DropletField.self) private var field: DropletField?

    public init(_ reflow: NibReflow<ID>, id: String = "reflow.carrier", @ViewBuilder content: @escaping (ID) -> Content) {
        self.reflow = reflow
        self.id = id
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global).origin
            let local = proxy.frame(in: NibLiquid.space).origin
            // Global → this view, and global → the container's space (where the field works).
            let toView = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x - global.x, y: p.y - global.y) }
            let toField = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x - global.x + local.x, y: p.y - global.y + local.y) }
            ZStack(alignment: .topLeading) {
                if let armed = reflow.armed, let frame = reflow.armedFrame {
                    ArmedCover(id: id + ".target", frame: frame.offsetBy(dx: -global.x, dy: -global.y)) {
                        content(armed)
                    }
                }
                if let carried = reflow.carried, let rest = reflow.carrierFrame {
                    let centre = toView(CGPoint(x: rest.midX, y: rest.midY))
                    content(carried)
                        .frame(width: rest.width, height: rest.height)
                        .modifier(DropletModifier(id: id, style: .card, managesDrag: false,
                                                  dragScale: reflow.isCondensed ? 0.5 : 1,
                                                  bondsWith: reflow.armed == nil ? nil : id + ".target", onDrag: nil))
                        .position(centre)
                        .background(CarrierDriver(reflow: reflow, id: id, toField: toField))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onAppear { reflow.hasCarrier = true }
        .onDisappear { reflow.hasCarrier = false }
    }
}

/// The armed cover: its content over a 3 pt water envelope that swells to 1.03 with `lift` (the body's growth runs on
/// the field's size spring).
struct ArmedCover<Content: View>: View {
    let id: String
    let frame: CGRect
    @ViewBuilder let content: () -> Content
    @State private var swelled = false

    var body: some View {
        let s = swelled ? NibReflowMetrics.armedScale : 1
        content()
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(s)
            .frame(width: frame.width * s + 6, height: frame.height * s + 6)
            .droplet(id, style: .armedCover, managesDrag: false)
            .position(x: frame.midX, y: frame.midY)
            .onAppear { withAnimation(NibMotion.lift.animation) { swelled = true } }
    }
}

/// Feeds the carrier droplet the finger (begin, follow, release) and tells the reflow when it has landed. A leaf: it
/// reads the carrier's node, so only it re-renders per frame.
struct CarrierDriver<ID: Hashable>: View {
    let reflow: NibReflow<ID>
    let id: String
    let toField: (CGPoint) -> CGPoint
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        Color.clear
            .onChange(of: reflow.lift) { _, lift in drive(lift) }
            .onChange(of: field?.node(id).presentation) { _, p in
                // The droplet registers a frame after it appears: catch up with the finger, then watch for the landing.
                drive(reflow.lift)
                guard let p, let lift = reflow.lift, case .released = lift.phase, !p.isLifted, !p.isSettling else {
                    return
                }
                reflow.landed()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func drive(_ lift: NibReflow<ID>.Lift?) {
        guard let field, let lift, field.visualFrame(id) != nil else { return }
        switch lift.phase {
        case .dragging:
            if !field.isDragging(id) { field.beginDrag(id, at: toField(lift.start)) }
            field.drag(id, to: toField(lift.location))
        case .released(let velocity):
            if field.isDragging(id) { field.endDrag(id, velocity: velocity) }
        }
    }
}
```

### 3.18 `NibKit/Sources/NibDesign/Shaders/NibLiquid.metal`

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Nib's water on iOS 17–25 (docs/DESIGN.md §10.9, Liquid Glass v2). Every optic lives in the outer 4.5 pt: a 0.8 pt rim
// lit by the top-left key light with a counter-rim half as bright opposite it, a sheen inside the lit edge and, over
// light paper, a body that thins toward the silhouette where the glass would bend the page. The core is the body tint
// alone. The numbers arrive from NibOptics (NibShaders.swift); the argument lists there and here match one for one.

static inline half4 over(half4 src, half4 dst) {
    return src + dst * (1.0h - src.a);
}

// `c` (premultiplied) at `k` times its own alpha, the result's alpha capped at 1.
static inline half4 scaled(half4 c, float k) {
    float a = float(c.a);
    if (a <= 0.0 || k <= 0.0) {
        return half4(0.0h);
    }
    return c * half(min(k, 1.0 / a));
}

// body: premultiplied body colour. d: distance inside the silhouette in points. outward: unit normal pointing out of
// the water. light: unit vector toward the key light (screen space, y down). strength: rim strength (1 at rest, 1.5
// held). counter: the counter-rim's peak relative to the key rim's. sheen: the sheen's share of the rim colour.
static inline half4 waterOptics(half4 body, float d, float2 outward, float2 light, half4 rim, half4 line,
                                float strength, float counter, float sheen) {
    float lambda = dot(outward, light);
    float k = max(lambda, 0.0);
    float c = max(-lambda, 0.0);
    float key = k * sqrt(k);                                  // max(λ, 0)^1.5
    float lit = key + counter * c * c;                        // + counter · max(−λ, 0)^2
    float band = 1.0 - smoothstep(0.3, 1.1, d);               // the 0.8 pt edge: outline and rim
    float glow = 1.0 - smoothstep(0.8, 4.5, d);               // the sheen inside the lit edge

    half4 o = body;
    o = over(scaled(rim, sheen * key * key * glow * strength), o);
    o = over(line * half(band), o);                           // under the rim: it shows where the rim is dim
    o = over(scaled(rim, lit * band * strength), o);
    return o;
}

// Layer effect over a cluster's blurred field. Alpha = union coverage; r, g, b = clear, deep, tinted coverage, scaled
// by k = 0.5 + 0.5 × the share over light paper, so (r + g + b) / a recovers that share. strength: rim strength.
// shadowK: shadow opacity multiplier (0 = none, 1 at rest, 1.6 held). shadowY: shadow offset downward in points.
[[ stitchable ]] half4 nibWaterField(float2 position, SwiftUI::Layer layer, float iso, float strength, float shadowK,
                                     float shadowY, float lightX, float lightY, float counter, float sheen, float lens,
                                     half4 clearBody, half4 clearBodyPaper, half4 deepBody, half4 tintBody,
                                     half4 waterBody, half4 rim, half4 tintRim, half4 line,
                                     half4 shadowDesk, half4 shadowPaper) {
    half4 c = layer.sample(position);
    float f = float(c.a);
    float cover = 0.0;
    half4 o = half4(0.0h);
    if (f >= iso * 0.35) {
        const float e = 1.5;
        float fx = (float(layer.sample(position + float2(e, 0.0)).a) - float(layer.sample(position - float2(e, 0.0)).a))
                   / (2.0 * e);
        float fy = (float(layer.sample(position + float2(0.0, e)).a) - float(layer.sample(position - float2(0.0, e)).a))
                   / (2.0 * e);
        float2 g = float2(fx, fy);
        float gl = max(length(g), 0.0001);
        float d = (f - iso) / gl;
        if (d >= -0.5) {
            cover = saturate(d + 0.5);
            float kinds = max(float(c.r) + float(c.g) + float(c.b), 0.0001);
            float paper = saturate((kinds / max(f, 0.0001) - 0.5) * 2.0);
            float tinted = float(c.b) / kinds;
            half4 clear = mix(clearBody, clearBodyPaper, half4(half(paper)));
            half4 body = clear * half(float(c.r) / kinds) + deepBody * half(float(c.g) / kinds) + tintBody * half(tinted);
            body = over(waterBody * half(1.0 - tinted), body);
            // Edge lens: only where there is a page to bend, never on Tinted.
            body = body * half(1.0 - lens * paper * (1.0 - tinted) * (1.0 - smoothstep(0.0, 4.0, d)));
            half4 r = mix(rim, tintRim, half4(half(tinted)));
            // The field grows inward, so −∇f points out of the water.
            o = waterOptics(body, d, -g / gl, float2(lightX, lightY), r, line, strength, counter,
                            sheen * (1.0 - tinted)) * half(cover);
        }
    }
    // The shadow: the field is the silhouette blurred at σ, so the field `shadowY` points higher is the water's soft
    // shadow. It is drawn only where the water is not, so it never shows through the translucent body.
    if (cover < 1.0 && shadowK > 0.0) {
        half4 s = layer.sample(position - float2(0.0, shadowY));
        float fs = float(s.a);
        if (fs > 0.002) {
            float sk = max(float(s.r) + float(s.g) + float(s.b), 0.0001);
            float sp = saturate((sk / fs - 0.5) * 2.0);
            half4 shadow = scaled(mix(shadowDesk, shadowPaper, half4(half(sp))), shadowK * saturate(fs / iso));
            o = o + shadow * half(1.0 - cover);
        }
    }
    return o;
}

static inline float roundedBoxSDF(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// Colour effect for one static shape drawn with a 1 pt outset (nibGlass on iOS 17–25, beads, folder films, frames, the
// held rim over iOS 26 glass). The body underneath is drawn by SwiftUI; this adds the optics. counter 0 drops the
// counter-rim, sheen 0 the sheen, lineOn 0 the outline.
[[ stitchable ]] half4 nibWaterRim(float2 position, half4 color, float4 bounds, float radius, float strength,
                                   float lightX, float lightY, float counter, float sheen, float lineOn,
                                   half4 rim, half4 line) {
    float2 halfSize = bounds.zw * 0.5 - 1.0;
    float2 centre = bounds.xy + bounds.zw * 0.5;
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 p = position - centre;
    float d = -roundedBoxSDF(p, halfSize, r);
    if (d < -0.5 || d > 5.0) {
        return half4(0.0h);
    }
    const float e = 0.5;
    float2 g = float2(roundedBoxSDF(p + float2(e, 0.0), halfSize, r) - roundedBoxSDF(p - float2(e, 0.0), halfSize, r),
                      roundedBoxSDF(p + float2(0.0, e), halfSize, r) - roundedBoxSDF(p - float2(0.0, e), halfSize, r));
    float2 outward = g / max(length(g), 0.0001);
    half4 o = waterOptics(half4(0.0h), d, outward, float2(lightX, lightY), rim, line * half(lineOn), strength, counter,
                          sheen);
    return o * half(saturate(d + 0.5));
}
```

### 3.19 `NibKit/Sources/NibDesign/Components/Buttons.swift`

```swift
import SwiftUI

/// A titled action for components that take one (empty states, toasts, inspector links).
public struct NibAction {
    public let title: String
    public let handler: () -> Void

    public init(_ title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }
}

/// Capsule button. Primary is the one filled action per surface; destructive is `destructive` text on `fill3`,
/// never a red fill, so a card never has two filled buttons competing (DESIGN.md §13.4).
public struct NibButton: View {
    public enum Kind: Sendable {
        case primary, secondary, destructive, plain
    }

    public enum Size: Sendable {
        case regular, compact
    }

    let title: String
    let symbol: NibSymbol?
    let kind: Kind
    let size: Size
    let expands: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `expands` fills the proposed width (equal-width button pairs such as Accept / Discard).
    public init(_ title: String, symbol: NibSymbol? = nil, kind: Kind = .secondary, size: Size = .regular,
                expands: Bool = false, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.size = size
        self.expands = expands
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(nib: symbol)
                }
                Text(title)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .font(NibFont.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .compact ? 14 : 18)
            .padding(.vertical, typeSize.isAccessibilitySize ? NibSpacing.s : 0)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: size == .compact ? 38 : 44)
            .background(background, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .nibShortcut(shortcut)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return NibColor.onAccent
        case .secondary: return NibColor.label
        case .destructive: return NibColor.destructive
        case .plain: return NibColor.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return NibColor.accent
        case .secondary, .destructive: return NibColor.fill3
        case .plain: return Color.clear
        }
    }
}

/// Icon-only button: 44 × 44 hit target whatever the glyph size, and the Large Content Viewer past the type cap.
public struct NibIconButton: View {
    public enum Size: Sendable {
        /// 21 pt Regular in a 40 pt visual.
        case bar
        /// 23 pt Medium.
        case palette
        /// 17 pt Regular.
        case panel
        /// A 30 pt `fill3` disc with a 15 pt Semibold `labelSecondary` glyph (Close).
        case round
        /// A 32 pt `fill3` disc with a 16 pt Semibold `label` arrow (the composer's Send and Stop).
        case send
    }

    let symbol: NibSymbol
    let label: String
    let size: Size
    let isOn: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var barGlyph: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var paletteGlyph: CGFloat = 23
    @ScaledMetric(relativeTo: .body) private var panelGlyph: CGFloat = 17

    public init(_ symbol: NibSymbol, label: String, size: Size = .bar, isOn: Bool = false,
                shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.isOn = isOn
        self.shortcut = shortcut
        self.action = action
    }

    private var glyph: Font {
        switch size {
        case .bar: return NibFont.glyph(.bar, size: min(barGlyph, 26))
        case .palette: return NibFont.glyph(.palette, size: min(paletteGlyph, 28))
        case .panel: return NibFont.glyph(.panel, size: panelGlyph)
        case .round: return NibFont.glyph(.round)
        case .send: return NibFont.glyph(.send)
        }
    }

    private var disc: CGFloat? {
        switch size {
        case .round: return 30
        case .send: return 32
        default: return nil
        }
    }

    private var tint: Color {
        switch size {
        case .round: return NibColor.labelSecondary
        case .send: return NibColor.label
        default: return isOn ? NibColor.accent : NibColor.label
        }
    }

    public var body: some View {
        Button(action: action) {
            Image(nib: symbol)
                .font(glyph)
                .foregroundStyle(tint)
                .frame(width: disc ?? 40, height: disc ?? 40)
                .background {
                    if disc != nil {
                        Circle().fill(NibColor.fill3)
                    }
                }
                .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .nibShortcut(shortcut)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(label) } icon: { Image(nib: symbol) }
        }
    }
}

/// A key-combination hint, shown while ⌘ is held, after 500 ms of hover, in menus and in the command bar.
public struct KeyHint: View {
    let keys: String

    public init(_ keys: String) { self.keys = keys }

    public init(_ shortcut: KeyboardShortcut) { self.keys = shortcut.nibDisplay }

    public var body: some View {
        Text(keys)
            .font(NibFont.caption2)
            .foregroundStyle(NibColor.labelSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(NibColor.fill3, in: RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous))
    }
}

public enum NibBadgeKind: Sendable {
    /// Document type on a cover (PDF, whiteboard, study set, text document).
    case type(NibSymbol)
    /// Proofreader number in the margin and on proposal rows.
    case number(Int)
    case destructiveNumber(Int)
    case count(Int)
    /// "Plugin" provenance capsule.
    case plugin
    case presence(initials: String, colorIndex: Int)
}

public struct NibBadge: View {
    let kind: NibBadgeKind

    public init(_ kind: NibBadgeKind) { self.kind = kind }

    public var body: some View {
        switch kind {
        case .type(let symbol):
            Image(nib: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemGray))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: NibRadius.badge, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        case .number(let n):
            numberDisc(n, fill: NibColor.accent)
        case .destructiveNumber(let n):
            numberDisc(n, fill: NibColor.destructive)
        case .count(let n):
            Text("\(n)")
                .font(NibFont.caption2)
                .monospacedDigit()
                .foregroundStyle(NibColor.labelSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(NibColor.fill3, in: Capsule())
        case .plugin:
            Text(String(localized: "Plugin", bundle: .module))
                .font(NibFont.caption2)
                .foregroundStyle(NibColor.labelSecondary)
                .padding(.horizontal, 7)
                .frame(minHeight: 18)
                .background(NibColor.fill3, in: Capsule())
        case .presence(let initials, let colorIndex):
            Text(initials)
                .font(NibFont.caption2)
                .foregroundStyle(Color.white)
                .frame(minWidth: 22, minHeight: 22)
                .background(NibPresence.color(colorIndex), in: Circle())
        }
    }

    private func numberDisc(_ n: Int, fill: Color) -> some View {
        Text("\(n)")
            .font(Font.system(.footnote, design: .rounded).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(NibColor.onAccent)
            .frame(width: 22, height: 22)
            .background(fill, in: Circle())
    }
}
```

### 3.20 `NibKit/Sources/NibDesign/Components/Controls.swift`

```swift
import SwiftUI

/// Switch. iOS 26: the system switch (its thumb is already Liquid Glass). iOS 17–25: the thumb squashes
/// 27 → 35 → 27 pt over 0.32 s, the only liquid in Settings.
public struct NibToggle: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            Toggle(title, isOn: $isOn)
                .font(NibFont.body)
        } else {
            Toggle(title, isOn: $isOn)
                .font(NibFont.body)
                .toggleStyle(NibSwitchStyle())
        }
    }
}

struct NibSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NibSwitch(configuration: configuration)
    }
}

struct NibSwitch: View {
    let configuration: ToggleStyleConfiguration
    @State private var squash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NibSpacing.s) {
            configuration.label
            Spacer(minLength: NibSpacing.s)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? NibColor.success : NibColor.fill1)
                Capsule()
                    .fill(Color.white)
                    .frame(width: squash ? 35 : 27, height: squash ? 23 : 27)
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    .padding(2)
            }
            .frame(width: 51, height: 31)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func flip() {
        guard !reduceMotion && !NibMotion.forcesReduced else {
            configuration.isOn.toggle()
            return
        }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)) {
            squash = true
            configuration.isOn.toggle()
        } completion: {
            withAnimation(NibMotion.tap.animation) { squash = false }
        }
    }
}

/// Slider whose thumb is a bead: it stretches a little with drag speed (cap 0.10, `thumb` spring, about the grab
/// side) and settles in one small undershoot. A slider is a precision control: no jelly (DESIGN.md §13.3).
public struct NibSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let detents: [Double]
    @State private var stretch: CGFloat = 0
    /// −1 or 1: the side of the thumb the finger pulls from (the stretch trails behind it).
    @State private var grabSide: CGFloat = 0
    @State private var lastDetent: Double?

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, label: String, detents: [Double] = []) {
        self._value = value
        self.range = range
        self.label = label
        self.detents = detents
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = max(1, proxy.size.width - 28)
            let span = max(range.upperBound - range.lowerBound, Double.ulpOfOne)
            let fraction = CGFloat((value - range.lowerBound) / span)
            let s = DropletPhysics.clampStretch(stretch, cap: 0.10)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NibColor.fill1)
                    .frame(height: 4)
                Capsule()
                    .fill(NibColor.label)
                    .frame(width: 14 + fraction * w, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .shadow(color: NibColor.beadShadow, radius: 4, x: 0, y: 2)
                    .scaleEffect(x: 1 + s, y: 1 / (1 + s).squareRoot(), anchor: UnitPoint(x: 0.5 + grabSide / 2, y: 0.5))
                    .offset(x: fraction * w)
            }
            .frame(height: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in update(g, width: w, span: span) }
                .onEnded { _ in release() })
        }
        .frame(height: NibMetrics.hitTarget)
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(label) }
        }
    }

    private func update(_ g: DragGesture.Value, width w: CGFloat, span: Double) {
        let f = min(max((g.location.x - 14) / w, 0), 1)
        value = range.lowerBound + Double(f) * span
        if let hit = detents.first(where: { abs($0 - value) < span * 0.01 }), hit != lastDetent {
            lastDetent = hit
            NibHaptics.play(.detent)
        }
        let v = g.velocity.width
        grabSide = v > 0 ? 1 : (v < 0 ? -1 : grabSide)
        withAnimation(NibMotion.thumb.animation) {
            stretch = DropletPhysics.stretchTarget(speed: abs(v), cap: 0.10, vRef: 2600)
        }
    }

    private func release() {
        lastDetent = nil
        withAnimation(NibMotion.thumb.animation) { stretch = 0 }
    }
}

/// Thickness: three preset dots, the value in HUD type, and a bead slider (millimetres).
public struct NibStrokeWidthSlider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let presets: [Double]

    public init(width: Binding<Double>, range: ClosedRange<Double> = 0.1...3.0, presets: [Double] = [0.3, 0.5, 0.8]) {
        self._width = width
        self.range = range
        self.presets = presets
    }

    public var body: some View {
        NibInspectorSection(String(localized: "Thickness", bundle: .module),
                            value: String(format: String(localized: "%.2f mm", bundle: .module), width)) {
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                HStack(spacing: NibSpacing.s) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                        Button {
                            withAnimation(NibMotion.tap.animation) { width = preset }
                        } label: {
                            Circle()
                                .fill(NibColor.label)
                                .frame(width: CGFloat(5 + index * 3 + (index > 1 ? 1 : 0)),
                                       height: CGFloat(5 + index * 3 + (index > 1 ? 1 : 0)))
                                .frame(width: 44, height: 40)
                                .background(abs(width - preset) < 0.005 ? NibColor.fill3 : Color.clear,
                                            in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
                                .frame(minHeight: NibMetrics.hitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous)))
                        .accessibilityLabel(String(format: String(localized: "%.1f millimetres", bundle: .module), preset))
                        .accessibilityAddTraits(abs(width - preset) < 0.005 ? .isSelected : [])
                    }
                }
                NibSlider(value: $width, in: range, label: String(localized: "Thickness", bundle: .module), detents: presets)
            }
        }
    }
}

/// Segmented control: fill3 track (radius 9, 2 pt inset, 32 pt visual), knob on backgroundTertiary (radius 7). Each
/// segment's hit area is the full 44 pt height (the track is drawn inside it).
public struct NibSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var knob

    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(NibMotion.tap.animation) { selection = option }
                } label: {
                    Text(title(option))
                        .font(selected ? NibFont.footnoteEmphasis : NibFont.footnote)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                        .padding(.horizontal, NibSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: NibRadius.segmentKnob, style: .continuous)
                                    .fill(NibColor.backgroundTertiary)
                                    .nibElevation(.rest)
                                    .matchedGeometryEffect(id: "knob", in: knob)
                            }
                        }
                        .padding(.vertical, 8)                 // 28 + 16: the 44 pt hit area
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .background {
            RoundedRectangle(cornerRadius: NibRadius.segment, style: .continuous)
                .fill(NibColor.fill3)
                .padding(.vertical, 6)                         // the 32 pt visual track inside the 44 pt row
        }
    }
}

/// Search field. `.filled` on opaque surfaces; `.onDroplet` when it lives inside a Clear droplet (no glass on glass).
public struct NibSearchField: View {
    public enum Style: Sendable {
        case filled, onDroplet
    }

    @Binding var text: String
    let prompt: String
    let style: Style
    let onSubmit: () -> Void

    public init(text: Binding<String>, prompt: String, style: Style = .filled, onSubmit: @escaping () -> Void = {}) {
        self._text = text
        self.prompt = prompt
        self.style = style
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: NibSpacing.s) {
            Image(nib: .search)
                .font(NibFont.body)
                .foregroundStyle(NibColor.labelSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(NibFont.body)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(nib: .clearText)
                        .foregroundStyle(NibColor.labelTertiary)
                        .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                }
                .buttonStyle(NibPressStyle(shape: Circle()))
                .accessibilityLabel(String(localized: "Clear search", bundle: .module))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 0)
        .frame(minHeight: NibMetrics.hitTarget)
        .background(style == .filled ? NibColor.fill4 : Color.clear, in: Capsule())
    }
}

/// Text field for forms and the assistant composer (grows to `lines`).
public struct NibField: View {
    @Binding var text: String
    let prompt: String
    let lines: ClosedRange<Int>

    public init(text: Binding<String>, prompt: String, lines: ClosedRange<Int> = 1...1) {
        self._text = text
        self.prompt = prompt
        self.lines = lines
    }

    public var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(lines)
            .font(NibFont.chat)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: NibMetrics.hitTarget)
            .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.composer, style: .continuous))
    }
}

/// Chips: context ("Page 3 · Handwriting", removable), citations (accent wash, inline), filters. The visuals stay
/// 28 pt (20 pt for citations); every tappable part reaches 44 pt with padding that does not move the layout.
public struct NibChip: View {
    public enum Style: Sendable {
        case context, citation, filter(isSelected: Bool)
    }

    let title: String
    let symbol: NibSymbol?
    let style: Style
    let action: (() -> Void)?
    let onRemove: (() -> Void)?

    public init(_ title: String, symbol: NibSymbol? = nil, style: Style = .context, action: (() -> Void)? = nil,
                onRemove: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.action = action
        self.onRemove = onRemove
    }

    private var isCitation: Bool {
        if case .citation = style { return true }
        return false
    }

    private var isSelectedFilter: Bool {
        if case .filter(let selected) = style { return selected }
        return false
    }

    public var body: some View {
        HStack(spacing: 4) {
            Button {
                action?()
            } label: {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(nib: symbol).font(NibFont.caption1)
                    }
                    Text(title)
                        .font(isCitation ? NibFont.caption1Emphasis : NibFont.footnote)
                        .lineLimit(1)
                }
                .hitPadding(isCitation ? 12 : 8)
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            if let onRemove {
                Button(action: onRemove) {
                    Image(nib: .xmark).font(.system(size: 10, weight: .bold))
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 6)                   // 28 pt wide
                        .hitPadding(14)                            // 44 pt tall
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove \(title)", bundle: .module))
            }
        }
        .foregroundStyle(isCitation ? NibColor.accent : (isSelectedFilter ? NibColor.label : NibColor.labelSecondary))
        .padding(.horizontal, isCitation ? 6 : 10)
        .frame(minHeight: isCitation ? 20 : 28)
        .background(isCitation ? NibColor.accentWash : (isSelectedFilter ? NibColor.fill2 : NibColor.fill3),
                    in: RoundedRectangle(cornerRadius: isCitation ? NibRadius.badge : 14, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Grows the hit area vertically by `amount` on each side without changing layout (padding in, padding out).
    func hitPadding(_ amount: CGFloat) -> some View {
        padding(.vertical, amount).contentShape(Rectangle()).padding(.vertical, -amount)
    }
}
```

### 3.21 `NibKit/Sources/NibDesign/Components/Palette.swift`

```swift
import SwiftUI
import NibContracts

public struct NibTool: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let symbol: NibSymbol
    public let isPlugin: Bool
    public let hasSettings: Bool
    /// VoiceOver value, e.g. "Carbon, 0.5 millimetres" (DESIGN.md §12).
    public let value: String?
    /// The tool key (P, H, E, L, S, U, T, I, M, K, plus plugin keys).
    public let shortcut: KeyboardShortcut?
    /// What the tool lays down, shown on the glyph's colour layer: the current ink for pen and pencil, the current
    /// highlight colour for the highlighter, nil for every other tool.
    public let tint: Color?

    public init(id: String, label: String, symbol: NibSymbol, isPlugin: Bool = false, hasSettings: Bool = true,
                value: String? = nil, shortcut: KeyboardShortcut? = nil, tint: Color? = nil) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.isPlugin = isPlugin
        self.hasSettings = hasSettings
        self.value = value
        self.shortcut = shortcut
        self.tint = tint
    }
}

/// A quick colour slot: an ink or a custom colour.
public struct NibSwatch: Identifiable, Hashable {
    public let id: String
    public let color: Color
    public let name: String
    public let ringsLight: Bool
    public let ringsDark: Bool

    public init(ink: NibInk) {
        id = ink.rawValue
        color = ink.color
        name = ink.name
        ringsLight = ink.needsRing(dark: false)
        ringsDark = ink.needsRing(dark: true)
    }

    public init(id: String, color: Color, name: String, ringsLight: Bool = false, ringsDark: Bool = false) {
        self.id = id
        self.color = color
        self.name = name
        self.ringsLight = ringsLight
        self.ringsDark = ringsDark
    }
}

/// A colour well with a 2 pt label ring 2.5 pt outside it when selected. Hit target 44 pt. Inks that vanish against
/// the chrome (Chalk in light mode, Carbon and Midnight in dark mode) keep a 1 pt `swatchRing` always.
public struct NibPenSwatch: View {
    public enum Size: Sendable {
        case palette, popover, compact
    }

    let swatch: NibSwatch
    let isSelected: Bool
    let size: Size
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    public init(_ swatch: NibSwatch, isSelected: Bool, size: Size = .popover, action: @escaping () -> Void) {
        self.swatch = swatch
        self.isSelected = isSelected
        self.size = size
        self.action = action
    }

    private var diameter: CGFloat {
        switch size {
        case .palette: return 22
        case .popover: return 26
        case .compact: return 28
        }
    }

    public var body: some View {
        let ringed = scheme == .dark ? swatch.ringsDark : swatch.ringsLight
        Button(action: action) {
            Circle()
                .fill(swatch.color)
                .overlay {
                    Circle().strokeBorder(ringed ? NibColor.swatchRing : NibColor.swatchHairline, lineWidth: ringed ? 1 : 0.5)
                }
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(NibColor.label, lineWidth: 2)
                            .frame(width: diameter + 7, height: diameter + 7)
                    }
                }
                .animation(NibMotion.colorChange, value: isSelected)
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One tool in the palette. The selected glyph changes colour within 120 ms, before the bead arrives (C's rule).
/// It reads the bead itself (for the passing lens), so the palette's body never depends on the moving bead.
public struct NibToolButton: View {
    let tool: NibTool
    let isSelected: Bool
    let paletteID: String?
    let along: CGFloat
    let pitch: CGFloat
    let action: () -> Void
    @Environment(DropletField.self) private var field: DropletField?
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 23

    public init(tool: NibTool, isSelected: Bool, action: @escaping () -> Void) {
        self.init(tool: tool, isSelected: isSelected, paletteID: nil, along: 0, pitch: NibMetrics.palettePitch,
                  action: action)
    }

    init(tool: NibTool, isSelected: Bool, paletteID: String?, along: CGFloat, pitch: CGFloat, action: @escaping () -> Void) {
        self.tool = tool
        self.isSelected = isSelected
        self.paletteID = paletteID
        self.along = along
        self.pitch = pitch
        self.action = action
    }

    public var body: some View {
        let head = paletteID.flatMap { id in field?.beadNode(id).head }
        let magnification = head.map { BeadPhysics.passingLens(distance: abs($0 - along)) } ?? 1
        Button(action: action) {
            Image(nib: tool.symbol)
                .font(NibFont.glyph(.palette, size: min(glyph, 28)))
                .symbolRenderingMode(tool.tint == nil ? .hierarchical : .palette)
                .foregroundStyle(NibColor.label, tool.tint ?? NibColor.label)
                .opacity(isSelected ? 1 : 0.74)
                .animation(NibMotion.colorChange, value: isSelected)
                .overlay(alignment: .topTrailing) {
                    if tool.isPlugin {
                        Circle()
                            .fill(NibColor.labelSecondary)
                            .frame(width: 5, height: 5)
                            .offset(x: 4, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .scaleEffect(magnification)
                .frame(width: max(NibMetrics.hitTarget, pitch), height: max(NibMetrics.hitTarget, pitch))
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .nibShortcut(tool.shortcut)
        .accessibilityLabel(tool.isPlugin ? String(localized: "\(tool.label), plugin", bundle: .module) : tool.label)
        .accessibilityValue(tool.value ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(tool.label) } icon: { Image(nib: tool.symbol) }
        }
    }
}

/// The floating tool palette: tools, More, quick colours, plugin tools after a second divider, the selection bead,
/// docking to any edge (it re-forms between vertical and horizontal by gathering into a bead and spreading), the
/// selected tool's settings popover (buds out of the tool on a second tap), the More grid, and the active tool's
/// options bar. Place it as a full-size child of the `NibDropletContainer`.
///
/// `tools` is the customised palette (native and plugin tools, in order); `moreTools` is what More holds by default.
/// When the dock is too short, the least recently used tools collapse into More (never the selected one); a tool
/// chosen from More takes the last native slot.
public struct NibToolPalette<Settings: View>: View {
    static var moreID: String { "more" }

    let id: String
    let tools: [NibTool]
    let moreTools: [NibTool]
    @Binding var selection: String
    let swatches: [NibSwatch]
    @Binding var swatch: Int
    @Binding var dock: NibPaletteDock
    let allowedEdges: [NibDock]
    let reservedTrailing: CGFloat
    let options: ((String) -> AnyView?)?
    let settings: (String) -> Settings

    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nibLiquidMode) private var liquidMode
    @ScaledMetric(relativeTo: .body) private var scaledThick: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var scaledPitch: CGFloat = 44
    @State private var shownDock: NibPaletteDock?
    @State private var tapped: String?
    @State private var mode: DragMode?
    @State private var settingsOpen = false
    @State private var moreOpen = false
    @State private var recent: [String] = []
    @State private var popoverSize = CGSize(width: NibMetrics.popoverWidth, height: 412)
    @State private var moreSize = CGSize(width: NibMetrics.popoverWidth, height: 124)
    @State private var optionsSize = CGSize(width: 200, height: NibMetrics.barHeight)
    /// A released drag on its way to its dock: the one plip plays when it arrives (DESIGN.md §10.11).
    @State private var landing: DockLanding?
    /// Reduce Motion and Liquid Off cross-fade the palette to its new dock (DESIGN.md §10.10).
    @State private var fade: Double = 1

    enum DragMode {
        case move, scrub
    }

    struct Arrangement: Equatable {
        var natives: [NibTool]
        var more: [NibTool]
        var plugins: [NibTool]
        var hasMore: Bool { !more.isEmpty }
    }

    public init(id: String = "palette", tools: [NibTool], moreTools: [NibTool] = [], selection: Binding<String>,
                swatches: [NibSwatch], swatch: Binding<Int>, dock: Binding<NibPaletteDock>,
                allowedEdges: [NibDock] = NibDock.allCases, reservedTrailing: CGFloat = 0,
                options: ((String) -> AnyView?)? = nil, @ViewBuilder settings: @escaping (String) -> Settings) {
        self.id = id
        self.tools = tools
        self.moreTools = moreTools
        self._selection = selection
        self.swatches = swatches
        self._swatch = swatch
        self._dock = dock
        self.allowedEdges = allowedEdges
        self.reservedTrailing = reservedTrailing
        self.options = options
        self.settings = settings
    }

    // MARK: Geometry

    private var compact: Bool { sizeClass == .compact }
    /// 56 pt, growing to 64 at the type cap; pitch 44 (46 on iPhone), growing to 52 (54).
    private var thick: CGFloat { min(max(scaledThick, NibMetrics.paletteThickness), NibMetrics.paletteThicknessMax) }
    private var pitch: CGFloat {
        compact ? min(max(scaledPitch + 2, NibMetrics.palettePitchCompact), NibMetrics.palettePitchCompactMax)
                : min(max(scaledPitch, NibMetrics.palettePitch), NibMetrics.palettePitchMax)
    }
    private var current: NibPaletteDock { shownDock ?? dock }
    private var edges: [NibDock] { compact ? allowedEdges.filter { !$0.isVertical } : allowedEdges }

    private func length(natives: Int, more: Bool, plugins: Int) -> CGFloat {
        let colours = swatches.isEmpty ? 0 : NibMetrics.paletteDividerGap + CGFloat(swatches.count) * NibMetrics.paletteSwatchPitch
        let pluginPart = plugins == 0 ? 0 : NibMetrics.paletteDividerGap + CGFloat(plugins) * pitch
        return NibMetrics.paletteEndPadding * 2 + CGFloat(natives + (more ? 1 : 0)) * pitch + colours + pluginPart
    }

    private func length(_ a: Arrangement) -> CGFloat {
        length(natives: a.natives.count, more: a.hasMore, plugins: a.plugins.count)
    }

    /// Which tools show, which sit in More, which follow the second divider.
    private func arrange(maxLength: CGFloat) -> Arrangement {
        var natives = tools.filter { !$0.isPlugin }
        var plugins = tools.filter { $0.isPlugin }
        var more = moreTools
        // A tool chosen from More takes the last native slot for as long as it is selected.
        if let i = more.firstIndex(where: { $0.id == selection }) {
            let chosen = more.remove(at: i)
            if let last = natives.indices.last { more.insert(natives.remove(at: last), at: 0) }
            natives.append(chosen)
        }
        func rank(_ t: NibTool) -> Int { recent.firstIndex(of: t.id) ?? Int.max }
        // Too long for the dock: the least recently used collapse into More, plugins first, never the selected tool.
        while length(natives: natives.count, more: !more.isEmpty, plugins: plugins.count) > maxLength {
            let pool = (plugins.isEmpty ? natives : plugins).filter { $0.id != selection }
            guard let victim = pool.reversed().max(by: { rank($0) < rank($1) }) else { break }
            plugins.removeAll { $0 == victim }
            natives.removeAll { $0 == victim }
            more.insert(victim, at: 0)
        }
        return Arrangement(natives: natives, more: more, plugins: plugins)
    }

    /// The centre of every slot along the palette's axis, keyed by tool id (More under `moreID`).
    private func slots(_ a: Arrangement) -> [String: CGFloat] {
        var map: [String: CGFloat] = [:]
        var x = NibMetrics.paletteEndPadding
        for t in a.natives {
            map[t.id] = x + pitch / 2
            x += pitch
        }
        if a.hasMore {
            map[Self.moreID] = x + pitch / 2
            x += pitch
        }
        if !swatches.isEmpty {
            x += NibMetrics.paletteDividerGap + CGFloat(swatches.count) * NibMetrics.paletteSwatchPitch
        }
        if !a.plugins.isEmpty {
            x += NibMetrics.paletteDividerGap
            for t in a.plugins {
                map[t.id] = x + pitch / 2
                x += pitch
            }
        }
        return map
    }

    private func size(_ d: NibPaletteDock, _ a: Arrangement) -> CGSize {
        let l = length(a)
        return d.isVertical ? CGSize(width: thick, height: l) : CGSize(width: l, height: thick)
    }

    private func region(_ proxy: GeometryProxy) -> CGRect {
        DropletDockModel.region(size: proxy.size, safeArea: proxy.safeAreaInsets, compact: compact,
                                reservedTrailing: reservedTrailing)
    }

    /// The dock engine (DESIGN.md §10.11) for region `r`, shifted by `origin` into the container's space: the palette's
    /// size in each orientation, the docks this device offers, the capture radius and the meniscus.
    private func dockModel(_ r: CGRect, origin: CGPoint = .zero) -> DropletDockModel {
        DropletDockModel(region: r.offsetBy(dx: origin.x, dy: origin.y),
                         horizontal: CGSize(width: length(arrange(maxLength: r.width)), height: thick),
                         vertical: CGSize(width: thick, height: length(arrange(maxLength: r.height))),
                         docks: allowedEdges, compact: compact)
    }

    private func centre(_ d: NibPaletteDock, in r: CGRect) -> CGPoint {
        let f = dockModel(r).frame(for: d)
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// A slot's rect across the palette's full thickness, in the palette's centred coordinates.
    private func slotRect(_ along: CGFloat, _ d: NibPaletteDock, _ a: Arrangement) -> CGRect {
        let c = along - length(a) / 2
        return d.isVertical ? CGRect(x: -thick / 2, y: c - pitch / 2, width: thick, height: pitch)
                            : CGRect(x: c - pitch / 2, y: -thick / 2, width: pitch, height: thick)
    }

    /// Popovers bud beside the palette: to the right of a left dock, above a bottom dock, and so on.
    private func placement(_ d: NibPaletteDock) -> NibBudPlacement {
        switch d.edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .below
        case .bottom: return .above
        }
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { proxy in
            let r = region(proxy)
            let a = arrange(maxLength: current.isVertical ? r.height : r.width)
            let map = slots(a)
            let origin = proxy.frame(in: NibLiquid.space).origin
            let d = current
            let c = centre(d, in: r)
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let slotAt = { (along: CGFloat) -> CGRect in slotRect(along, d, a).offsetBy(dx: c.x, dy: c.y) }
            ZStack(alignment: .topLeading) {
                palette(d, a, map)
                    .gesture(dragGesture(region: r, origin: origin, arrangement: a, slots: map))
                    .opacity(fade)
                    .position(c)
                if let tool = a.natives.first(where: { $0.id == selection }) ?? a.plugins.first(where: { $0.id == selection }),
                   tool.hasSettings, let along = map[tool.id] {
                    popover(for: tool, anchor: slotAt(along), placement: placement(d), bounds: bounds)
                }
                if a.hasMore, let along = map[Self.moreID] {
                    moreGrid(a.more, anchor: slotAt(along), placement: placement(d), bounds: bounds)
                }
                if let options, let view = options(selection), let along = map[selection] {
                    NibToolOptionsBar(id: id + ".options") { view }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { optionsSize = $0 }
                        .position(placement(d).centre(size: optionsSize, beside: slotAt(along), gap: -1, in: bounds,
                                                      alignment: .centre))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onChange(of: AnchorKey(dock: d, slots: map), initial: true) { _, key in
                registerAnchors(key.slots, d, a)
                if let along = map[selection] { field?.setBead(id, head: along, glide: false) }
            }
            .background(DockArrivalWatcher(id: id, node: field?.node(id), field: field, landing: $landing))
            .onChange(of: selection) { _, newValue in
                let glide = tapped == newValue
                tapped = nil
                recent.removeAll { $0 == newValue }
                recent.insert(newValue, at: 0)
                if let along = slots(arrange(maxLength: current.isVertical ? r.height : r.width))[newValue] {
                    field?.setBead(id, head: along, glide: glide)
                }
                if !glide { settingsOpen = false }
                moreOpen = false
            }
        }
        .background(ReshapeWatcher(node: field?.node(id)) { shownDock = nil })
    }

    struct AnchorKey: Equatable {
        let dock: NibPaletteDock
        let slots: [String: CGFloat]
    }

    private func registerAnchors(_ map: [String: CGFloat], _ d: NibPaletteDock, _ a: Arrangement) {
        for (toolID, along) in map {
            field?.setLocalAnchor(id + "." + toolID, owner: id, rect: slotRect(along, d, a))
        }
    }

    private func palette(_ d: NibPaletteDock, _ a: Arrangement, _ map: [String: CGFloat]) -> some View {
        let layout = d.isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let s = size(d, a)
        return layout {
            ForEach(a.natives) { tool in toolButton(tool, d, map) }
            if a.hasMore {
                NibToolButton(tool: NibTool(id: Self.moreID, label: String(localized: "More tools", bundle: .module),
                                            symbol: .more),
                              isSelected: false, paletteID: id, along: map[Self.moreID] ?? 0, pitch: pitch) {
                    settingsOpen = false
                    moreOpen.toggle()
                    field?.poke(id)
                }
                .frame(width: d.isVertical ? thick : pitch, height: d.isVertical ? pitch : thick)
                .accessibilityAddTraits(.isButton)
            }
            if !swatches.isEmpty {
                divider(d)
                ForEach(Array(swatches.enumerated()), id: \.element.id) { index, sw in
                    NibPenSwatch(sw, isSelected: index == swatch, size: .palette) {
                        swatch = index
                        field?.poke(id, 1.3)
                    }
                    .frame(width: d.isVertical ? thick : NibMetrics.paletteSwatchPitch,
                           height: d.isVertical ? NibMetrics.paletteSwatchPitch : thick)
                }
            }
            if !a.plugins.isEmpty {
                divider(d)
                ForEach(a.plugins) { tool in toolButton(tool, d, map) }
            }
        }
        .padding(d.isVertical ? Edge.Set.vertical : Edge.Set.horizontal, NibMetrics.paletteEndPadding)
        .frame(width: s.width, height: s.height)
        .background(alignment: .topLeading) {
            NibSelectionBead(paletteID: id, vertical: d.isVertical, thickness: thick,
                             fallbackHead: map[selection] ?? 0,
                             ink: swatches.indices.contains(swatch) ? swatches[swatch].color : NibColor.label)
        }
        .contentShape(NibDropletShape())
        .nibChromeTypeCap()
        .droplet(id, style: .palette, managesDrag: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tools", bundle: .module))
        .accessibilityActions {
            ForEach(edges, id: \.self) { edge in
                Button(edge.moveTitle) { dock = NibPaletteDock(edge: edge, along: 0.5) }
            }
        }
    }

    private func toolButton(_ tool: NibTool, _ d: NibPaletteDock, _ map: [String: CGFloat]) -> some View {
        NibToolButton(tool: tool, isSelected: tool.id == selection, paletteID: id, along: map[tool.id] ?? 0,
                      pitch: pitch) {
            tap(tool)
        }
        .frame(width: d.isVertical ? thick : pitch, height: d.isVertical ? pitch : thick)
    }

    private func divider(_ d: NibPaletteDock) -> some View {
        Rectangle()
            .fill(NibColor.separator)
            .frame(width: d.isVertical ? 28 : 0.5, height: d.isVertical ? 0.5 : 28)
            .frame(width: d.isVertical ? thick : NibMetrics.paletteDividerGap,
                   height: d.isVertical ? NibMetrics.paletteDividerGap : thick)
            .accessibilityHidden(true)
    }

    private func tap(_ tool: NibTool) {
        moreOpen = false
        if tool.id == selection {
            if tool.hasSettings { settingsOpen.toggle() }
        } else {
            settingsOpen = false
            tapped = tool.id
            selection = tool.id
        }
        field?.poke(id)
    }

    private func popover(for tool: NibTool, anchor: CGRect, placement: NibBudPlacement, bounds: CGRect) -> some View {
        let gap = compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
        let width = compact ? max(0, bounds.width - 3 * NibSpacing.l) : NibMetrics.popoverWidth
        return NibPopoverPanel(title: tool.label, width: width) { settings(tool.id) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
            .droplet(id + ".settings", style: .popover)
            .budsFrom(id + "." + tool.id, isPresented: $settingsOpen)
            .position(placement.centre(size: popoverSize, beside: anchor, gap: gap, in: bounds))
    }

    private func moreGrid(_ tools: [NibTool], anchor: CGRect, placement: NibBudPlacement, bounds: CGRect) -> some View {
        let gap = compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
        return NibPopoverPanel(title: String(localized: "More tools", bundle: .module), width: NibMetrics.popoverWidth) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(tools) { tool in
                    Button {
                        moreOpen = false
                        tapped = tool.id
                        selection = tool.id
                    } label: {
                        VStack(spacing: 3) {
                            Image(nib: tool.symbol).font(NibFont.glyph(.panel, size: 22))
                            Text(tool.label).font(NibFont.caption2).lineLimit(1)
                        }
                        .foregroundStyle(tool.id == selection ? NibColor.label : NibColor.labelSecondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(tool.id == selection ? NibColor.fill3 : Color.clear,
                                    in: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                    .nibShortcut(tool.shortcut)
                    .accessibilityLabel(tool.label)
                    .accessibilityAddTraits(tool.id == selection ? .isSelected : [])
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { moreSize = $0 }
        .droplet(id + ".more", style: .popover)
        .budsFrom(id + "." + Self.moreID, isPresented: $moreOpen)
        .position(placement.centre(size: moreSize, beside: anchor, gap: gap, in: bounds))
    }

    private func dragGesture(region r: CGRect, origin: CGPoint, arrangement a: Arrangement,
                             slots map: [String: CGFloat]) -> some Gesture {
        let scrubbable = (a.natives + a.plugins).compactMap { t in map[t.id].map { (t.id, $0) } }
        return DragGesture(minimumDistance: DropletPhysics.pickupSlop, coordinateSpace: NibLiquid.space)
            .onChanged { value in
                guard let field else { return }
                if mode == nil {
                    let frame = field.visualFrame(id) ?? .zero
                    let vertical = current.isVertical
                    let startAlong = vertical ? value.startLocation.y - frame.minY : value.startLocation.x - frame.minX
                    let dAlong = vertical ? value.translation.height : value.translation.width
                    let dAcross = vertical ? value.translation.width : value.translation.height
                    let onSelected = map[selection].map { abs(startAlong - $0) < pitch / 2 } ?? false
                    if onSelected && abs(dAlong) > abs(dAcross) {
                        mode = .scrub
                    } else {
                        mode = .move
                        settingsOpen = false
                        moreOpen = false
                        landing = nil
                        field.dismissBuds()
                        DropletDockDriver(id: id, field: field).begin(at: value.startLocation)
                    }
                }
                switch mode {
                case .scrub:
                    let frame = field.visualFrame(id) ?? .zero
                    let a = current.isVertical ? value.location.y - frame.minY : value.location.x - frame.minX
                    let lo = scrubbable.map(\.1).min() ?? a, hi = scrubbable.map(\.1).max() ?? a
                    field.scrubBead(id, to: min(max(a, lo), hi))        // never onto More or the swatches
                case .move:
                    // Held, the palette is a bead of water: it follows with `follow`, and its meniscus reaches for the
                    // dock the finger is within capture of.
                    DropletDockDriver(id: id, field: field).move(to: value.location, model: dockModel(r, origin: origin))
                case .none:
                    break
                }
            }
            .onEnded { value in
                guard let field else { return }
                defer { mode = nil }
                if mode == .scrub {
                    let frame = field.visualFrame(id) ?? .zero
                    let a = current.isVertical ? value.location.y - frame.minY : value.location.x - frame.minX
                    field.endScrub(id)
                    guard let nearest = scrubbable.min(by: { abs($0.1 - a) < abs($1.1 - a) }) else { return }
                    tapped = nearest.0
                    if nearest.0 == selection {
                        field.setBead(id, head: nearest.1, glide: true)
                    } else {
                        selection = nearest.0
                    }
                    return
                }
                guard mode == .move else { return }
                // The projected finger picks the dock within the capture radius (else home); the palette springs there
                // with `snap` from the full release velocity, re-forms if the axis changes, and plips on arrival.
                let release = DropletDockDriver(id: id, field: field).release(
                    at: value.location, velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height),
                    from: current, model: dockModel(r, origin: origin))
                let next = release.dock
                let arrival = DockLanding(centre: CGPoint(x: release.frame.midX, y: release.frame.midY))
                if (reduceMotion || liquidMode == .off) && next != current {
                    // Fade out, move while invisible (the body glides with `reduced`), fade in.
                    withAnimation(NibMotion.exit) { fade = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        dock = next
                        landing = DockLanding(centre: arrival.centre)
                        DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.reduced.response) {
                            withAnimation(NibMotion.enter) { fade = 1 }
                        }
                    }
                    return
                }
                if next.isVertical != current.isVertical {
                    shownDock = current
                    field.beginReshape(id, towards: CGPoint(x: release.frame.midX, y: release.frame.midY),
                                       velocity: release.velocity)
                }
                landing = arrival
                dock = next
            }
    }
}

/// Watches one droplet's re-form phase without making its parent's body depend on the droplet's per-frame state.
struct ReshapeWatcher: View {
    let node: DropletNode?
    let onSpread: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: node?.presentation.reshape ?? .idle) { _, phase in
                if phase == .spreading { onSpread() }
            }
    }
}

/// The selection bead: a dense drop under the selected tool (head r 20, tail 0.78 r, neck ≥ 1.44·r_tail) tinted by the
/// current ink at 15 %. Body plus rim: no shadow, no specular, so it never reads as a raised button on the palette. It
/// glides as one drop and never splits (fix 1). It reads its own bead node, per frame, as a leaf.
struct NibSelectionBead: View {
    let paletteID: String
    let vertical: Bool
    let thickness: CGFloat
    let fallbackHead: CGFloat
    let ink: Color
    @Environment(DropletField.self) private var field: DropletField?

    var body: some View {
        let node = field?.beadNode(paletteID)
        let head = node?.head ?? fallbackHead, tail = node?.tail ?? fallbackHead
        let g = BeadPhysics.geometry(head: head, tail: tail, radius: NibMetrics.beadRadius)
        let across = thickness / 2
        let systemGlass = field?.usesSystemGlass ?? false
        Canvas { context, _ in
            func point(_ a: CGFloat) -> CGPoint { vertical ? CGPoint(x: across, y: a) : CGPoint(x: a, y: across) }
            let h = point(g.head), t = point(g.tail)
            var shape = Path(ellipseIn: CGRect(x: h.x - g.headRadius, y: h.y - g.headRadius,
                                               width: 2 * g.headRadius, height: 2 * g.headRadius))
            shape.addEllipse(in: CGRect(x: t.x - g.tailRadius, y: t.y - g.tailRadius,
                                        width: 2 * g.tailRadius, height: 2 * g.tailRadius))
            let neck = Path { p in
                p.move(to: h)
                p.addLine(to: t)
            }.strokedPath(StrokeStyle(lineWidth: g.neckWidth, lineCap: .round))
            let bead = shape.union(neck)
            context.fill(bead, with: .color(NibColor.beadBody))
            context.drawLayer { layer in
                layer.opacity = 0.15
                layer.fill(bead, with: .color(ink))
            }
            // The key rim on the top-left (iOS 17–25); inside iOS 26 glass the bead is a plain fill (DESIGN.md §10.7).
            context.drawNibBeadRim(bead, systemGlass: systemGlass)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

### 3.22 `NibKit/Sources/NibDesign/Components/Panels.swift`

```swift
import SwiftUI

/// Popover content chrome on Deep water: title (headline) and optional subtitle, 16 pt insets, scrolls past 520 pt.
/// Put it in a droplet: `.droplet(id, style: .popover).budsFrom(source, isPresented:)`, or use `NibBudPopover`.
/// One ScrollView that only bounces when it must: the content keeps its identity (and its @State and focus) when it
/// crosses 520 pt.
public struct NibPopoverPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let content: Content

    public init(title: String, subtitle: String? = nil, width: CGFloat = NibMetrics.popoverWidth,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(NibFont.headline)
                        .foregroundStyle(NibColor.label)
                    Spacer(minLength: NibSpacing.s)
                    if let subtitle {
                        Text(subtitle)
                            .font(NibFont.footnote)
                            .foregroundStyle(NibColor.labelSecondary)
                    }
                }
                content
            }
            .padding(NibSpacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .frame(maxHeight: NibMetrics.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Where a bud rests relative to its source (DESIGN.md §10.6). One placement rule for every popover, the palette's
/// included.
public enum NibBudPlacement: Sendable {
    case below, above, leading, trailing

    enum Alignment {
        /// Side placements: the popover's top sits 16 pt above the source's top (tool popovers).
        case top
        /// Side placements: centred on the source (the tool options bar).
        case centre
    }

    /// The centre of a `size` popover beside `anchor`, `gap` away, clamped (across the placement axis) inside `bounds`
    /// inset by the 16 pt chrome inset. All in one coordinate space.
    func centre(size: CGSize, beside anchor: CGRect, gap: CGFloat, in bounds: CGRect,
                alignment: Alignment = .top) -> CGPoint {
        let b = bounds.insetBy(dx: NibMetrics.chromeInset, dy: NibMetrics.chromeInset)
        let sideY = alignment == .top ? anchor.minY - NibSpacing.l + size.height / 2 : anchor.midY
        var c: CGPoint
        switch self {
        case .below: c = CGPoint(x: anchor.midX, y: anchor.maxY + gap + size.height / 2)
        case .above: c = CGPoint(x: anchor.midX, y: anchor.minY - gap - size.height / 2)
        case .trailing: c = CGPoint(x: anchor.maxX + gap + size.width / 2, y: sideY)
        case .leading: c = CGPoint(x: anchor.minX - gap - size.width / 2, y: sideY)
        }
        switch self {
        case .below, .above:
            c.x = min(max(c.x, b.minX + size.width / 2), max(b.minX + size.width / 2, b.maxX - size.width / 2))
        case .leading, .trailing:
            c.y = min(max(c.y, b.minY + size.height / 2), max(b.minY + size.height / 2, b.maxY - size.height / 2))
        }
        return c
    }
}

/// A popover that buds off `source` (a droplet id or a `nibBudAnchor`, even one another module owns: Share, the
/// document title, the magnifier) and positions itself beside it. Place it as a full-size child of the container.
public struct NibBudPopover<Content: View>: View {
    let id: String
    let source: String
    @Binding var isPresented: Bool
    let title: String
    let subtitle: String?
    let width: CGFloat
    let placement: NibBudPlacement
    let content: Content
    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var size = CGSize(width: NibMetrics.popoverWidth, height: 200)

    public init(id: String, source: String, isPresented: Binding<Bool>, title: String, subtitle: String? = nil,
                width: CGFloat = NibMetrics.popoverWidth, placement: NibBudPlacement = .below,
                @ViewBuilder content: () -> Content) {
        self.id = id
        self.source = source
        self._isPresented = isPresented
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.placement = placement
        self.content = content()
    }

    public var body: some View {
        let gap = sizeClass == .compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
        let anchor = field?.anchorRect(source) ?? .zero
        let bounds = field?.bounds ?? .zero
        NibPopoverPanel(title: title, subtitle: subtitle, width: width) { content }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .droplet(id, style: .popover)
            .budsFrom(source, isPresented: $isPresented)
            .position(placement.centre(size: size, beside: anchor, gap: gap, in: bounds))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A labelled section inside popovers and panels: label in footnote semibold secondary, optional value in HUD type,
/// optional link (for example "Custom…") with a 44 pt hit area.
public struct NibInspectorSection<Content: View>: View {
    let title: String
    let value: String?
    let action: NibAction?
    let content: Content

    public init(_ title: String, value: String? = nil, action: NibAction? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.value = value
        self.action = action
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Text(title)
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.labelSecondary)
                Spacer(minLength: NibSpacing.s)
                if let value {
                    Text(value)
                        .font(NibFont.hud)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                if let action {
                    Button(action: action.handler) {
                        Text(action.title)
                            .font(NibFont.footnote)
                            .foregroundStyle(NibColor.accent)
                            .hitPadding(13)
                    }
                    .buttonStyle(.plain)
                }
            }
            content
        }
    }
}

/// A 44 pt row inside popovers and panels.
public struct NibInspectorRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let symbol: NibSymbol?
    let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, symbol: NibSymbol? = nil,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            if let symbol {
                Image(nib: symbol)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                if let subtitle {
                    Text(subtitle)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            Spacer(minLength: NibSpacing.s)
            accessory
        }
        .frame(minHeight: NibMetrics.hitTarget)
    }
}

public extension NibInspectorRow where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: NibSymbol? = nil) {
        self.init(title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

/// A row for opaque grouped lists (Settings, plugin manager): optional 29 pt icon squircle, title, subtitle, accessory.
public struct NibRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let icon: NibSymbol?
    let iconTint: Color?
    let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, icon: NibSymbol? = nil, iconTint: Color? = nil,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            if let icon {
                Image(nib: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconTint == nil ? NibColor.labelSecondary : Color.white)
                    .frame(width: 29, height: 29)
                    .background(iconTint ?? NibColor.fill3,
                                in: RoundedRectangle(cornerRadius: NibRadius.icon, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                if let subtitle {
                    Text(subtitle)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: NibSpacing.s)
            accessory
        }
        .frame(minHeight: NibMetrics.hitTarget)
    }
}

public extension NibRow where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: NibSymbol? = nil, iconTint: Color? = nil) {
        self.init(title, subtitle: subtitle, icon: icon, iconTint: iconTint) { EmptyView() }
    }
}

/// Sheet header: Cancel (leading, accent text, ⎋), title (title3, up to 2 lines, never under the buttons), the sheet's
/// single Tinted action (trailing, ⏎). An HStack, so at AX sizes and in German the title wraps instead of overlapping.
public struct NibSheetHeader: View {
    let title: String
    let cancelTitle: String
    let primaryTitle: String?
    let isPrimaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void

    /// `cancelTitle` nil = "Cancel" (a default argument cannot read the internal `Bundle.module`).
    public init(_ title: String, cancelTitle: String? = nil,
                primaryTitle: String? = nil, isPrimaryEnabled: Bool = true, onCancel: @escaping () -> Void,
                onPrimary: @escaping () -> Void = {}) {
        self.title = title
        self.cancelTitle = cancelTitle ?? String(localized: "Cancel", bundle: .module)
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.onCancel = onCancel
        self.onPrimary = onPrimary
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            Button(cancelTitle, action: onCancel)
                .font(NibFont.body)
                .foregroundStyle(NibColor.accent)
                .buttonStyle(.plain)
                .frame(minHeight: NibMetrics.hitTarget)
                .keyboardShortcut(.cancelAction)
            Text(title)
                .font(NibFont.title3)
                .foregroundStyle(NibColor.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            if let primaryTitle {
                NibButton(primaryTitle, kind: .primary, size: .compact, shortcut: .defaultAction, action: onPrimary)
                    .disabled(!isPrimaryEnabled)
            }
        }
        .padding(.horizontal, NibSpacing.xl)
        .frame(minHeight: 60)
    }
}

public extension View {
    /// A sheet on an opaque grouped surface (no glass inside). iOS 26 keeps the system's own sheet material and radius.
    func nibSheet<SheetContent: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder content: @escaping () -> SheetContent) -> some View {
        sheet(isPresented: isPresented) {
            content().modifier(NibSheetChrome())
        }
    }
}

struct NibSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .presentationCornerRadius(NibRadius.sheet)
                .presentationBackground(NibColor.backgroundSecondary)
        }
    }
}

/// The header of every Deep panel: the assistant, plugin panels, the transcript, comments. Glyph in a 30 pt `fill3`
/// disc, title (headline), subtitle (caption1 secondary), optional badge, optional More menu, round Close. At least
/// 60 pt, growing with Dynamic Type.
public struct NibPanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let symbol: NibSymbol
    let badge: NibBadgeKind?
    let menu: Trailing
    let onClose: () -> Void

    public init(title: String, subtitle: String? = nil, symbol: NibSymbol, badge: NibBadgeKind? = nil,
                onClose: @escaping () -> Void, @ViewBuilder menu: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badge = badge
        self.onClose = onClose
        self.menu = menu()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(nib: symbol)
                .font(NibFont.glyph(.round))
                .foregroundStyle(NibColor.label)
                .frame(width: 30, height: 30)
                .background(NibColor.fill3, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: NibSpacing.s) {
                    Text(title)
                        .font(NibFont.headline)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let badge { NibBadge(badge) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(NibFont.caption1)
                        .foregroundStyle(NibColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: NibSpacing.s)
            menu
            NibIconButton(.xmark, label: String(localized: "Close \(title)", bundle: .module), size: .round,
                          action: onClose)
        }
        .padding(.leading, NibSpacing.l)
        .padding(.trailing, NibSpacing.xs)
        .padding(.vertical, NibSpacing.s)
        .frame(minHeight: 60)
    }
}

public extension NibPanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: NibSymbol, badge: NibBadgeKind? = nil,
         onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, badge: badge, onClose: onClose) { EmptyView() }
    }
}

/// Chrome Nib draws around a plugin panel: `NibPanelHeader` with the "Plugin" badge and More (Reload, Permissions,
/// Report a Problem). The plugin draws only inside `content`, and never draws its own glass.
public struct NibPluginPanelChrome<Content: View>: View {
    let name: String
    let symbol: NibSymbol
    let onReload: () -> Void
    let onPermissions: () -> Void
    let onReport: () -> Void
    let onClose: () -> Void
    let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(name: String, symbol: NibSymbol, onReload: @escaping () -> Void, onPermissions: @escaping () -> Void,
                onReport: @escaping () -> Void, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.name = name
        self.symbol = symbol
        self.onReload = onReload
        self.onPermissions = onPermissions
        self.onReport = onReport
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: name, symbol: symbol, badge: .plugin, onClose: onClose) {
                Menu {
                    Button(String(localized: "Reload", bundle: .module), action: onReload)
                    Button(String(localized: "Permissions", bundle: .module), action: onPermissions)
                    Button(String(localized: "Report a Problem", bundle: .module), action: onReport)
                } label: {
                    Image(nib: .more)
                        .font(NibFont.glyph(.panel))
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                }
                .accessibilityLabel(String(localized: "More", bundle: .module))
            }
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: 0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: NibMetrics.panelWidth(typeSize))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(name) plugin", bundle: .module))
    }
}
```

### 3.23 `NibKit/Sources/NibDesign/Components/Chrome.swift`

```swift
import SwiftUI
import UIKit

/// A top-bar droplet: a Clear capsule of icon buttons (44 pt, up to 52 pt at the Dynamic Type cap).
public struct NibBarGroup<Content: View>: View {
    let id: String
    let content: Content
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 44

    public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: min(max(scaledHeight, NibMetrics.barHeight), NibMetrics.barHeightMax))
        .nibChromeTypeCap()
        .droplet(id, style: .bar)
        .accessibilityElement(children: .contain)
    }
}

public struct NibToolbarItem: View {
    let symbol: NibSymbol
    let label: String
    let isOn: Bool
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    public init(_ symbol: NibSymbol, label: String, isOn: Bool = false, shortcut: KeyboardShortcut? = nil,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.isOn = isOn
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        NibIconButton(symbol, label: label, size: .bar, isOn: isOn, shortcut: shortcut, action: action)
    }
}

public struct NibBarSeparator: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(NibColor.separator)
            .frame(width: 0.5, height: 22)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// Document title in the leading bar droplet: title (barTitle) over the location. The subtitle sits on Clear, so it
/// is caption1 semibold in `label`: `labelSecondary` there is 1.7:1 over black ink (DESIGN.md §2.4).
public struct NibBarTitle: View {
    let title: String
    let subtitle: String?
    let subtitleIsWarning: Bool

    public init(title: String, subtitle: String? = nil, subtitleIsWarning: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsWarning = subtitleIsWarning
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(NibFont.barTitle)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(NibFont.caption1Emphasis)
                    .foregroundStyle(subtitleIsWarning ? NibColor.warning : NibColor.label)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, NibSpacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// A HUD droplet, always 40 pt tall: page counter, zoom, ruler angle, recording clock ("3 / 12", "125%", "04:12").
/// Both parts are `label` (text on Clear, DESIGN.md §2.4); the secondary part is lighter in weight, not in colour.
public struct NibHUD: View {
    let id: String
    let primary: String
    let secondary: String?
    let symbol: NibSymbol?
    let symbolLabel: String?
    let action: (() -> Void)?

    public init(id: String, primary: String, secondary: String? = nil, symbol: NibSymbol? = nil,
                symbolLabel: String? = nil, action: (() -> Void)? = nil) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.symbol = symbol
        self.symbolLabel = symbolLabel
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 2) {
            if let symbol {
                NibIconButton(symbol, label: symbolLabel ?? primary, size: .bar) { action?() }
            }
            HStack(spacing: 3) {
                Text(primary)
                if let secondary {
                    Text(secondary).fontWeight(.medium)
                }
            }
            .font(NibFont.hud)
            .foregroundStyle(NibColor.label)
        }
        .padding(.leading, symbol == nil ? 12 : 0)
        .padding(.trailing, 12)
        .frame(height: NibMetrics.hudHeight)
        .nibChromeTypeCap()
        .droplet(id, style: .hud)
        .accessibilityElement(children: .combine)
    }
}

/// The active tool's contextual options (CONTRACTS.md `ToolbarItemDescriptor.activeToolMenu`): a Clear bar droplet
/// that `NibToolPalette(options:)` fuses to the palette's far side, level with the selected tool. Tools never place
/// it themselves.
public struct NibToolOptionsBar<Content: View>: View {
    let id: String
    let content: Content

    public init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, NibSpacing.xs)
            .frame(height: NibMetrics.barHeight)
            .nibChromeTypeCap()
            .droplet(id, style: .bar)
            .accessibilityElement(children: .contain)
    }
}

/// A toast on Deep water: one line of callout and one action (usually Undo). Present it only with `.nibToast($item)`.
public struct NibToast: View {
    let message: String
    let action: NibAction?

    public init(_ message: String, action: NibAction? = nil) {
        self.message = message
        self.action = action
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            Text(message)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.label)
                .lineLimit(2)
            if let action {
                Button(action.title, action: action.handler)
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.accent)
                    .buttonStyle(.plain)
                    .padding(.horizontal, NibSpacing.m)
                    .frame(minHeight: NibMetrics.hitTarget)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, NibSpacing.xs)
        .frame(minHeight: 48)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }
}

/// One toast to show. Identity is the toast, not its text: the same message twice is two toasts.
public struct NibToastItem: Identifiable, Equatable {
    public let id = UUID()
    public let message: String
    public let action: NibAction?

    public init(_ message: String, action: NibAction? = nil) {
        self.message = message
        self.action = action
    }

    public static func == (a: NibToastItem, b: NibToastItem) -> Bool { a.id == b.id }
}

public extension View {
    /// Presents toasts (DESIGN.md §13.2): bottom centre, 24 pt above the safe area, budding up from below, one at a
    /// time (a new one replaces the one showing), announced by VoiceOver, dismissed after 6 s. The timer pauses while
    /// VoiceOver is running. Apply it to the content of a `NibDropletContainer`.
    func nibToast(_ item: Binding<NibToastItem?>) -> some View {
        modifier(NibToastPresenter(item: item))
    }
}

struct NibToastPresenter: ViewModifier {
    @Binding var item: NibToastItem?
    @State private var shown: NibToastItem?
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    NibToast(shown?.message ?? "", action: shown?.action)
                        .droplet("nib.toast", style: .toast)
                        .budsFrom("nib.toast.source", isPresented: $presented)
                        .padding(.bottom, NibSpacing.xxl)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .nibBudAnchor("nib.toast.source")          // it buds up from just below its rest
                }
            }
            .task(id: item?.id) {
                guard let next = item else {
                    presented = false
                    return
                }
                shown = next
                presented = true
                AccessibilityNotification.Announcement(next.message).post()
                var remaining = NibMotion.toastDuration
                while remaining > 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }                  // replaced by a newer toast
                    if !UIAccessibility.isVoiceOverRunning { remaining -= 0.25 }
                }
                presented = false
                if item?.id == next.id { item = nil }
            }
    }
}

/// A determinate 3 pt progress bar: export, import, study sessions (DESIGN.md §14.7, §14.11). Never a liquid loader.
public struct NibProgressBar: View {
    let value: Double

    public init(value: Double) { self.value = value }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NibColor.fill1)
                Capsule()
                    .fill(NibColor.label)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAddTraits(.updatesFrequently)
    }
}
```

### 3.24 `NibKit/Sources/NibDesign/Components/Library.swift`

```swift
import SwiftUI
import NibContracts

/// A document in the library: cover (5 pt at the spine, 8 pt at the fore-edge), title, subtitle, type badge, and a
/// check bead in select mode. Covers are cloth and paper, not water; inside a container give it
/// `.droplet(id, style: .card, bondsWith:)`, which only becomes water (a 3 pt envelope) while the card is lifted.
public struct NibDocumentCard<Cover: View>: View {
    let title: String
    let subtitle: String
    let isFavorite: Bool
    let typeBadge: NibSymbol?
    /// Select mode: nil outside it, otherwise whether this document is selected.
    let isSelected: Bool?
    let absorbOffset: CGSize?
    let cover: Cover
    @Environment(\.nibDropletIsLifted) private var isLifted
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(title: String, subtitle: String, isFavorite: Bool = false, typeBadge: NibSymbol? = nil,
                isSelected: Bool? = nil, absorbOffset: CGSize? = nil, @ViewBuilder cover: () -> Cover) {
        self.title = title
        self.subtitle = subtitle
        self.isFavorite = isFavorite
        self.typeBadge = typeBadge
        self.isSelected = isSelected
        self.absorbOffset = absorbOffset
        self.cover = cover()
    }

    public var body: some View {
        let size = sizeClass == .compact ? NibMetrics.coverSizeCompact : NibMetrics.coverSize
        let shape = UnevenRoundedRectangle(topLeadingRadius: NibRadius.coverSpine, bottomLeadingRadius: NibRadius.coverSpine,
                                           bottomTrailingRadius: NibRadius.coverEdge, topTrailingRadius: NibRadius.coverEdge,
                                           style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            cover
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay(alignment: .bottomTrailing) {
                    if let typeBadge {
                        NibBadge(.type(typeBadge)).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let isSelected {
                        NibCheckBead(isOn: isSelected).padding(6)
                    }
                }
                .nibElevation(isLifted ? .coverLifted : .cover)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if isFavorite {
                        Image(nib: .starFill)
                            .font(.system(size: 10))
                            .accessibilityLabel(String(localized: "Favourite", bundle: .module))
                    }
                    Text(subtitle)
                        .font(NibFont.caption1)
                        .lineLimit(1)
                }
                .foregroundStyle(NibColor.labelSecondary)
            }
            .opacity(isLifted ? 0 : 1)
            .animation(NibMotion.fade, value: isLifted)
        }
        .frame(width: size.width, alignment: .leading)
        .scaleEffect(absorbOffset == nil ? 1 : 0.12)
        .offset(absorbOffset ?? .zero)
        .opacity(absorbOffset == nil ? 1 : 0)
        .animation(NibMotion.absorb.animation, value: absorbOffset == nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits((isSelected ?? false) ? .isSelected : [])
    }
}

/// The select-mode check bead on covers and page thumbnails.
struct NibCheckBead: View {
    let isOn: Bool

    var body: some View {
        Image(nib: isOn ? .checkCircleFill : .circle)
            .font(.system(size: 22))
            .foregroundStyle(isOn ? NibColor.accent : NibColor.labelTertiary)
            .background { Circle().fill(NibColor.background).padding(2) }
            .accessibilityHidden(true)
    }
}

/// A plain cloth cover: flat colour, spine and elastic band. No gradients, no printed titles.
public struct NibClothCover: View {
    let cloth: NibCoverCloth

    public init(_ cloth: NibCoverCloth) { self.cloth = cloth }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                cloth.color
                Rectangle()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 13)
                Rectangle()
                    .fill(Color.black.opacity(cloth.isLight ? 0.45 : 0.30))
                    .frame(width: 5)
                    .offset(x: proxy.size.width - 22)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A folder tile (78 tall, radius 14) on backgroundSecondary. Its width comes from the grid on the 24 pt gutter; the
/// full name is one line with tail truncation. While a notebook is dragged it grows a water film; when the notebook
/// fuses with it the film tints with the accent wash.
public struct NibFolderTile: View {
    let name: String
    let count: String
    let color: Color
    let isTargeted: Bool
    let isFused: Bool

    public init(name: String, count: String, color: Color, isTargeted: Bool = false, isFused: Bool = false) {
        self.name = name
        self.count = count
        self.color = color
        self.isTargeted = isTargeted
        self.isFused = isFused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.tile, style: .continuous)
        HStack(spacing: NibSpacing.m) {
            Image(nib: .folderFill)
                .font(.system(size: 30))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(count)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: NibMetrics.folderTileMinWidth, maxWidth: .infinity, minHeight: NibMetrics.folderTileHeight)
        .background(NibColor.backgroundSecondary, in: shape)
        .overlay {
            if isTargeted {
                ZStack {
                    shape.fill(isFused ? NibColor.accentWash : NibColor.waterBody)
                    NibWaterRimLayer(cornerRadius: NibRadius.tile, rimOnly: true)   // a flat library: rim and line only
                }
                .padding(-4)
                .transition(.opacity)
            }
        }
        .scaleEffect(isFused ? 1.03 : 1)
        .animation(NibMotion.reflow.animation, value: isTargeted)
        .animation(NibMotion.lift.animation, value: isFused)
        .accessibilityElement(children: .combine)
    }
}

/// A library sidebar row (320 pt sidebar): 22 pt Regular glyph, title (body, one line, tail truncation), count.
/// Selected: `fill3` (radius 10), semibold title, accent glyph. Folder rows use the same full name as the tiles.
public struct NibSidebarRow: View {
    let title: String
    let symbol: NibSymbol
    let count: Int?
    let isSelected: Bool
    let glyphTint: Color?

    public init(_ title: String, symbol: NibSymbol, count: Int? = nil, isSelected: Bool = false, glyphTint: Color? = nil) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.isSelected = isSelected
        self.glyphTint = glyphTint
    }

    public var body: some View {
        HStack(spacing: 13) {
            Image(nib: symbol)
                .font(NibFont.glyph(.sidebar))
                .foregroundStyle(glyphTint ?? (isSelected ? NibColor.accent : NibColor.labelSecondary))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(isSelected ? NibFont.bodyEmphasis : NibFont.body)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NibSpacing.s)
            if let count {
                Text("\(count)")
                    .font(NibFont.chat)
                    .monospacedDigit()
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .padding(.horizontal, NibSpacing.m)
        .frame(minHeight: NibMetrics.hitTarget)
        .background(isSelected ? NibColor.fill3 : Color.clear,
                    in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A page thumbnail (radius 4) with its number; the current page has a 2 pt accent ring 3 pt outside (radius 7),
/// selection shows a check bead. While reordering, give it `.droplet(id, style: .thumbnail)` (a 3 pt envelope, radius 7).
public struct NibPageThumbnail<Content: View>: View {
    let number: Int
    let isCurrent: Bool
    let isSelected: Bool?
    let aspectRatio: CGFloat
    let width: CGFloat
    let content: Content

    public init(number: Int, isCurrent: Bool, isSelected: Bool? = nil, aspectRatio: CGFloat = 595.0 / 842.0,
                width: CGFloat = NibMetrics.thumbnailWidth, @ViewBuilder content: () -> Content) {
        self.number = number
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.aspectRatio = aspectRatio
        self.width = width
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 6) {
            content
                .frame(width: width, height: width / aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
                .nibElevation(.paper)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: NibRadius.thumbnail + 3, style: .continuous)
                            .strokeBorder(NibColor.accent, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let isSelected {
                        NibCheckBead(isOn: isSelected).padding(6)
                    }
                }
            Text("\(number)")
                .font(NibFont.caption1)
                .monospacedDigit()
                .foregroundStyle(isCurrent ? NibColor.accent : NibColor.labelSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Page \(number)", bundle: .module))
        .accessibilityAddTraits((isSelected ?? false) || isCurrent ? .isSelected : [])
    }
}

/// Onboarding progress (DESIGN.md §14.15): 8 pt beads 8 pt apart with the selection bead gliding between them.
public struct NibPageBeads: View {
    let count: Int
    let index: Int
    @Namespace private var bead

    public init(count: Int, index: Int) {
        self.count = count
        self.index = index
    }

    public var body: some View {
        HStack(spacing: NibSpacing.s) {
            ForEach(0..<max(count, 0), id: \.self) { i in
                Circle()
                    .fill(NibColor.fill1)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if i == index {
                            Circle()
                                .fill(NibColor.label)
                                .matchedGeometryEffect(id: "bead", in: bead)
                        }
                    }
            }
        }
        .animation(NibMotion.glide.animation, value: index)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Step \(index + 1) of \(count)", bundle: .module))
    }
}
```

### 3.25 `NibKit/Sources/NibDesign/Components/Assistant.swift`

```swift
import SwiftUI

public struct NibProposalChange: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case add, remove, change, destructive
    }

    public let id: String
    public let number: Int
    public let title: String
    public let location: String
    public let kind: Kind

    public init(id: String, number: Int, title: String, location: String, kind: Kind) {
        self.id = id
        self.number = number
        self.title = title
        self.location = location
        self.kind = kind
    }
}

/// An inline confirmation inside the proposal (never a modal).
public struct NibConfirmation: Sendable {
    public let command: String
    public let summary: String

    public init(command: String, summary: String) {
        self.command = command
        self.summary = summary
    }
}

public enum NibConfirmationChoice: Sendable {
    case allowOnce, allowForTurn, deny
}

/// The proposed-edit block of the assistant thread (DESIGN.md §14.9): numbered rows that match the proofreader badges
/// on the page, an include toggle on every row (a 22 pt ring with a `label` check), an "On page" toggle, destructive
/// rows with their own secondary button (`destructive` text on `fill3`) that Accept never covers, an optional inline
/// confirmation, and Accept N (the card's only filled button) / Discard.
public struct NibProposalCard: View {
    let changes: [NibProposalChange]
    @Binding var included: Set<String>
    @Binding var showsOnPage: Bool
    let confirmation: NibConfirmation?
    let needsReview: Bool
    let onAccept: () -> Void
    let onDiscard: () -> Void
    let onDestructive: (NibProposalChange) -> Void
    let onConfirmation: (NibConfirmationChoice) -> Void
    let onReview: () -> Void

    public init(changes: [NibProposalChange], included: Binding<Set<String>>, showsOnPage: Binding<Bool>,
                confirmation: NibConfirmation? = nil, needsReview: Bool = false,
                onAccept: @escaping () -> Void, onDiscard: @escaping () -> Void,
                onDestructive: @escaping (NibProposalChange) -> Void = { _ in },
                onConfirmation: @escaping (NibConfirmationChoice) -> Void = { _ in },
                onReview: @escaping () -> Void = {}) {
        self.changes = changes
        self._included = included
        self._showsOnPage = showsOnPage
        self.confirmation = confirmation
        self.needsReview = needsReview
        self.onAccept = onAccept
        self.onDiscard = onDiscard
        self.onDestructive = onDestructive
        self.onConfirmation = onConfirmation
        self.onReview = onReview
    }

    private var acceptCount: Int {
        changes.filter { $0.kind != .destructive && included.contains($0.id) }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Text(String(localized: "Proposed edit", bundle: .module))
                    .font(NibFont.button)
                    .foregroundStyle(NibColor.label)
                Text(String(localized: "\(changes.count) changes", bundle: .module))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                Spacer(minLength: NibSpacing.s)
                Button {
                    showsOnPage.toggle()
                } label: {
                    Label { Text(String(localized: "On page", bundle: .module)) } icon: { Image(nib: showsOnPage ? .eye : .eyeSlash) }
                        .font(NibFont.footnote)
                        .foregroundStyle(showsOnPage ? NibColor.accent : NibColor.labelSecondary)
                        .frame(minHeight: NibMetrics.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsOnPage ? .isSelected : [])
            }
            ForEach(changes) { change in
                row(change)
            }
            if let confirmation {
                confirmationRow(confirmation)
            }
            if needsReview {
                NibButton(String(localized: "Review \(changes.count) changes", bundle: .module), symbol: .citation, kind: .secondary,
                          size: .compact, action: onReview)
            }
            HStack(spacing: NibSpacing.s) {
                NibButton(String(localized: "Accept \(acceptCount)", bundle: .module), kind: .primary, size: .compact,
                          expands: true, shortcut: KeyboardShortcut(.return, modifiers: .command), action: onAccept)
                    .disabled(acceptCount == 0 || needsReview || confirmation != nil)
                NibButton(String(localized: "Discard", bundle: .module), kind: .secondary, size: .compact, expands: true, action: onDiscard)
            }
            Label {
                Text(String(localized: "Previewing on the page. Nothing changes until you accept.", bundle: .module))
            } icon: {
                Image(nib: .eye)
            }
            .font(NibFont.caption1)
            .foregroundStyle(NibColor.labelSecondary)
        }
        .padding(14)
        .background(NibColor.fill4, in: RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Proposed edit", bundle: .module))
    }

    private func row(_ change: NibProposalChange) -> some View {
        let isOn = included.contains(change.id)
        return HStack(alignment: .top, spacing: 10) {
            NibBadge(change.kind == .destructive ? .destructiveNumber(change.number) : .number(change.number))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.title)
                    .font(NibFont.chatEmphasis)
                    .foregroundStyle(NibColor.label)
                Text(change.location)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
                if change.kind == .destructive {
                    NibButton(change.title, kind: .destructive, size: .compact) { onDestructive(change) }  // fill3, red text
                }
            }
            Spacer(minLength: NibSpacing.s)
            if change.kind != .destructive {
                Button {
                    if isOn { included.remove(change.id) } else { included.insert(change.id) }
                } label: {
                    // A 22 pt ring with a `label` check: accent is for the focus ring only, so the card keeps one
                    // filled, coloured action (Accept).
                    Image(nib: isOn ? .checkCircle : .circle)
                        .font(.system(size: 22))
                        .foregroundStyle(isOn ? NibColor.label : NibColor.labelTertiary)
                        .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NibPressStyle(shape: Circle()))
                .accessibilityLabel(String(localized: "Include change \(change.number)", bundle: .module))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func confirmationRow(_ c: NibConfirmation) -> some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: 0.5)
            Label {
                Text(c.command).font(NibFont.footnoteEmphasis)
            } icon: {
                Image(nib: .permission).foregroundStyle(NibColor.warning)
            }
            Text(c.summary)
                .font(NibFont.footnote)
                .foregroundStyle(NibColor.labelSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.s) { confirmationButtons }
                VStack(alignment: .leading, spacing: 0) { confirmationButtons }
            }
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        NibButton(String(localized: "Allow once", bundle: .module), kind: .secondary, size: .compact) { onConfirmation(.allowOnce) }
        NibButton(String(localized: "Allow for this turn", bundle: .module), kind: .secondary, size: .compact) { onConfirmation(.allowForTurn) }
        NibButton(String(localized: "Deny", bundle: .module), kind: .plain, size: .compact) { onConfirmation(.deny) }
    }
}

/// What replaces the proposal after Accept: "Applied N changes · Undo ⌘Z · Show".
public struct NibProposalReceipt: View {
    let count: Int
    let onUndo: () -> Void
    let onShow: () -> Void

    public init(count: Int, onUndo: @escaping () -> Void, onShow: @escaping () -> Void) {
        self.count = count
        self.onUndo = onUndo
        self.onShow = onShow
    }

    public var body: some View {
        HStack(spacing: NibSpacing.s) {
            Image(nib: .checkmark)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NibColor.success)
                .accessibilityHidden(true)
            Text(String(localized: "Applied \(count) changes", bundle: .module))
                .font(NibFont.chatEmphasis)
                .foregroundStyle(NibColor.label)
            Spacer(minLength: NibSpacing.s)
            Button(action: onUndo) {
                HStack(spacing: 6) {
                    Text(String(localized: "Undo", bundle: .module))
                    KeyHint("⌘Z")
                }
                .frame(minHeight: NibMetrics.hitTarget)
            }
            .buttonStyle(.plain)
            .font(NibFont.button)
            .foregroundStyle(NibColor.accent)
            Button(String(localized: "Show", bundle: .module), action: onShow)
                .buttonStyle(.plain)
                .font(NibFont.button)
                .foregroundStyle(NibColor.accent)
                .frame(minHeight: NibMetrics.hitTarget)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The chip for a proposal on the page: drop mark, change name (15 pt semibold, text on Clear), Accept (accent disc),
/// Discard. It docks in the page's trailing margin (`NibTether`), never over ink, and never refracts.
public struct NibProposalChip: View {
    let title: String
    let onAccept: () -> Void
    let onDiscard: () -> Void

    public init(_ title: String, onAccept: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.title = title
        self.onAccept = onAccept
        self.onDiscard = onDiscard
    }

    public var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(nib: .assistant).foregroundStyle(NibColor.accent)
            }
            .font(NibFont.button)
            .foregroundStyle(NibColor.label)
            .padding(.leading, NibSpacing.m)
            Spacer(minLength: NibSpacing.xs)
            Button(action: onAccept) {
                Image(nib: .checkmark)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NibColor.onAccent)
                    .frame(width: 32, height: 32)
                    .background(NibColor.accent, in: Circle())
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NibPressStyle(shape: Circle()))
            .accessibilityLabel(String(localized: "Accept \(title)", bundle: .module))
            Button(action: onDiscard) {
                Image(nib: .xmark)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NibColor.labelSecondary)
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NibPressStyle(shape: Circle()))
            .accessibilityLabel(String(localized: "Discard \(title)", bundle: .module))
        }
        .frame(width: 204, height: NibMetrics.hitTarget)
        .nibChromeTypeCap()
        .accessibilityElement(children: .contain)
    }
}

/// A proposal chip docked on the page (DESIGN.md §14.9). At rest it is just the chip at `rest`, in the page's
/// trailing margin (compute it with `restingCentre`). While it is dragged, an anchor bead grows at `anchor` on the
/// change and a water stem joins them; pull far enough and the stem pinches at about 65 pt, leaving a 5 pt satellite
/// that flows back; release and the chip flows back to `rest` with `tether`, then the anchor dries away.
/// Place it as a full-size layer of the container; `anchor` and `rest` are in container coordinates.
public struct NibTether<Chip: View>: View {
    let id: String
    let anchor: CGPoint
    let rest: CGPoint
    let chip: Chip
    @Environment(DropletField.self) private var field: DropletField?

    public init(id: String, anchor: CGPoint, rest: CGPoint, @ViewBuilder chip: () -> Chip) {
        self.id = id
        self.anchor = anchor
        self.rest = rest
        self.chip = chip()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            TetherAnchor(id: id, anchor: anchor, node: field?.node(id + ".chip"))
            chip
                .droplet(id + ".chip", style: .chip)
                .position(rest)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Where the chip rests: its trailing edge `8` pt inside the page (never past `trailingLimit`, which keeps it
    /// 16 pt clear of a docked panel), level with `line` when that band is free of ink, otherwise in the free band
    /// nearest to it. Every stroke's bounds count, grown by `clearance` (8 pt). All in container coordinates.
    public static func restingCentre(chip size: CGSize, line: CGFloat, page: CGRect, trailingLimit: CGFloat,
                                     ink: [CGRect], clearance: CGFloat = 8) -> CGPoint {
        let right = min(page.maxX - NibSpacing.s, trailingLimit)
        let x = right - size.width / 2
        let blocked = ink.map { $0.insetBy(dx: -clearance, dy: -clearance) }
            .filter { $0.minX < right && $0.maxX > right - size.width }
        func free(_ y: CGFloat) -> Bool {
            let top = y - size.height / 2, bottom = y + size.height / 2
            return top >= page.minY - 0.01 && bottom <= page.maxY + 0.01
                && !blocked.contains { $0.minY < bottom - 0.01 && $0.maxY > top + 0.01 }
        }
        // The line itself and every band edge: a band exactly as tall as the chip is still found.
        let candidates = [line] + blocked.flatMap { [$0.maxY + size.height / 2, $0.minY - size.height / 2] }
        let y = candidates.filter(free).min { abs($0 - line) < abs($1 - line) } ?? line
        return CGPoint(x: x, y: y)
    }
}

/// The anchor bead exists only while the chip is dragged or flowing home, so at rest nothing hangs off the chip. It
/// reads the chip's node itself, so the tether's body does not depend on the chip's per-frame state.
struct TetherAnchor: View {
    let id: String
    let anchor: CGPoint
    let node: DropletNode?

    var body: some View {
        let p = node?.presentation
        if (p?.isLifted ?? false) || (p?.isSettling ?? false) {
            Color.clear
                .frame(width: 26, height: 26)
                .droplet(id + ".anchor", style: .anchor)
                .position(anchor)
                .accessibilityHidden(true)
        }
    }
}
```

### 3.26 `NibKit/Sources/NibDesign/Components/NibEmptyState.swift`

```swift
import SwiftUI

/// Empty states are typography only: a 44 pt glyph in tertiary, a New York title, one sentence, at most one primary
/// and one secondary action. No illustrations, no mascots.
public struct NibEmptyState: View {
    let symbol: NibSymbol
    let title: String
    let message: String?
    let primary: NibAction?
    let secondary: NibAction?

    public init(symbol: NibSymbol, title: String, message: String? = nil, primary: NibAction? = nil,
                secondary: NibAction? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: 0) {
            Image(nib: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(NibColor.labelTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(NibFont.emptyTitle)
                .foregroundStyle(NibColor.label)
                .multilineTextAlignment(.center)
                .padding(.top, NibSpacing.l)
            if let message {
                Text(message)
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, NibSpacing.s)
            }
            if primary != nil || secondary != nil {
                HStack(spacing: NibSpacing.m) {
                    if let primary {
                        NibButton(primary.title, kind: .primary, action: primary.handler)
                    }
                    if let secondary {
                        NibButton(secondary.title, kind: .secondary, action: secondary.handler)
                    }
                }
                .padding(.top, NibSpacing.xxl)
            }
        }
        .frame(maxWidth: 420)
        .padding(NibSpacing.xxl)
        .accessibilityElement(children: .contain)
    }
}
```

### 3.27 `NibKit/Sources/NibDesign/Gallery/NibDesignGallery.swift`

```swift
import SwiftUI
import NibContracts

/// Every component in its states on one static screen. NibTesting snapshots it in Light, Dark, Reduce Transparency,
/// Increase Contrast and AX3; reviewers diff the snapshots. No ScrollView: droplets never live in scrolling content.
/// The AX3 snapshot includes the one-line truncation cases (a long folder name on a tile and in the sidebar).
public struct NibDesignGallery: View {
    @State private var tool = "pen"
    @State private var swatch = 0
    @State private var dock = NibPaletteDock(edge: .leading)
    @State private var toggle = true
    @State private var slider = 0.6
    @State private var width = 0.5
    @State private var segment = "Edit"
    @State private var included: Set<String> = ["1", "2"]
    @State private var onPage = true
    @State private var search = ""
    @State private var inking = NibInkingState()

    public init() {}

    public var body: some View {
        ZStack {
            NibColor.desk.ignoresSafeArea()
            HStack(alignment: .top, spacing: NibSpacing.x3) {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    NibButton(String(localized: "New Notebook", bundle: .module), symbol: .plus, kind: .primary) {}
                    NibButton(String(localized: "Import", bundle: .module), kind: .secondary) {}
                    NibButton(String(localized: "Delete 4 items", bundle: .module), kind: .destructive, size: .compact) {}
                    NibToggle(String(localized: "Pressure sensitivity", bundle: .module), isOn: $toggle)
                    NibSlider(value: $slider, label: String(localized: "Pressure sensitivity", bundle: .module))
                    NibStrokeWidthSlider(width: $width)
                    NibSegmentedControl(selection: $segment, options: ["Ask", "Edit"]) { $0 }
                    NibSearchField(text: $search, prompt: String(localized: "Search", bundle: .module))
                    HStack {
                        NibChip(String(localized: "Page 3", bundle: .module), symbol: .textDocument, onRemove: {})
                        NibChip(String(localized: "Line 5", bundle: .module), symbol: .citation, style: .citation)
                        KeyHint("⌘K")
                        NibBadge(.number(1))
                        NibBadge(.plugin)
                    }
                    NibProgressBar(value: 0.4)
                    NibPageBeads(count: 4, index: 1)
                    // One-line truncation at AX3: the full folder name, never wrapped.
                    NibFolderTile(name: "Computer Science 9618", count: String(localized: "9 notebooks", bundle: .module),
                                  color: NibFolderColor.graphite.color)
                    NibSidebarRow("Computer Science 9618", symbol: .folderFill, count: 9,
                                  glyphTint: NibFolderColor.graphite.color)
                }
                .frame(width: 320)
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    NibProposalCard(changes: [
                        NibProposalChange(id: "1", number: 1, title: "Strike T = 2π√(k/m)", location: "Page 3 · line 5", kind: .remove),
                        NibProposalChange(id: "2", number: 2, title: "Write T = 2π√(m/k)", location: "Fountain pen · Carbon", kind: .add),
                        NibProposalChange(id: "3", number: 3, title: "Delete scribble", location: "Under the graph", kind: .destructive),
                    ], included: $included, showsOnPage: $onPage, onAccept: {}, onDiscard: {})
                    NibProposalReceipt(count: 2, onUndo: {}, onShow: {})
                    NibPanelHeader(title: String(localized: "Assistant", bundle: .module),
                                   subtitle: "Claude Sonnet 4.5 · your API key", symbol: .assistant, onClose: {})
                    NibEmptyState(symbol: .notebook, title: String(localized: "No notebooks yet", bundle: .module),
                                  message: String(localized: "Write something, or bring in a PDF.", bundle: .module),
                                  primary: NibAction(String(localized: "New Notebook", bundle: .module)) {},
                                  secondary: NibAction(String(localized: "Import", bundle: .module)) {})
                }
                .frame(width: 340)
                NibDropletContainer(inking: inking) {
                    ZStack(alignment: .topLeading) {
                        HStack {
                            NibBarGroup(id: "g.bar") {
                                NibToolbarItem(.undo, label: String(localized: "Undo", bundle: .module)) {}
                                NibToolbarItem(.redo, label: String(localized: "Redo", bundle: .module)) {}
                                NibBarSeparator()
                                NibToolbarItem(.search, label: String(localized: "Search", bundle: .module)) {}
                            }
                            NibHUD(id: "g.hud", primary: "3", secondary: "/ 12", symbol: .pages,
                                   symbolLabel: String(localized: "Pages", bundle: .module))
                        }
                        NibToolPalette(id: "g.palette", tools: [
                            NibTool(id: "pen", label: String(localized: "Pen", bundle: .module), symbol: .pen,
                                    value: "Carbon, 0.5 millimetres", tint: NibInk.carbon.color),
                            NibTool(id: "highlighter", label: String(localized: "Highlighter", bundle: .module),
                                    symbol: .highlighter, tint: NibHighlighter.lemon.color),
                            NibTool(id: "eraser", label: String(localized: "Eraser", bundle: .module), symbol: .eraser),
                            NibTool(id: "lasso", label: String(localized: "Lasso", bundle: .module), symbol: .lasso),
                        ], moreTools: [
                            NibTool(id: "laser", label: String(localized: "Laser", bundle: .module), symbol: .laser),
                        ], selection: $tool, swatches: NibInk.quickSlots.map { NibSwatch(ink: $0) }, swatch: $swatch,
                           dock: $dock) { _ in
                            Text(String(localized: "Settings", bundle: .module)).font(NibFont.body)
                        }
                    }
                }
                .frame(width: 420, height: 640)
            }
            .padding(NibSpacing.x3)
        }
    }
}
```

### 3.28 `NibKit/Tests/NibDesignTests/DropletPhysicsTests.swift`

```swift
import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

final class DropletPhysicsTests: XCTestCase {
    func testStretchPreservesVolumeIn3D() {
        for s in stride(from: -0.3, through: 0.6, by: 0.05) {
            for theta in stride(from: 0.0, through: Double.pi, by: 0.2) {
                let t = DropletPhysics.deformation(stretch: CGFloat(s), axis: CGFloat(theta))
                let area = t.a * t.d - t.b * t.c                 // along × across
                let depth = 1 / (1 + CGFloat(s)).squareRoot()      // the depth follows the cross axis
                XCTAssertEqual(area * depth, 1, accuracy: 1e-6)
            }
        }
    }

    func testNeckSplitsExactlyAtTheThreshold() {
        let params = NeckParams(join: 11, t0: 26, off: 44)
        let tMin = DropletMetrics.regular.minimumNeck
        let critical = params.off * (1 - pow(tMin / params.t0, 1 / 0.7))
        var bond = Bond()
        XCTAssertEqual(bond.update(gap: 10, params: params, minimumNeck: tMin, enabled: true, hysteresis: true), .joined)
        XCTAssertNil(bond.update(gap: critical - 0.01, params: params, minimumNeck: tMin, enabled: true, hysteresis: true))
        XCTAssertEqual(bond.update(gap: critical + 0.01, params: params, minimumNeck: tMin, enabled: true, hysteresis: true),
                       .split)
        XCTAssertEqual(critical, 31.5, accuracy: 0.6)             // palette ↔ bars pinch at ≈ 31 pt
    }

    func testWithoutHysteresisJoinAndSplitShareOneDistance() {
        let params = NeckParams(join: 11, t0: 26, off: 44)
        var bond = Bond()
        XCTAssertEqual(bond.update(gap: 10, params: params, minimumNeck: 10.76, enabled: true, hysteresis: false), .joined)
        XCTAssertEqual(bond.update(gap: 11.5, params: params, minimumNeck: 10.76, enabled: true, hysteresis: false), .split)
    }

    func testReduceMotionJumpsShapeToTargets() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 56, y: 469))
        d.stretch.velocity = 5
        d.lift.target = 1.05
        _ = d.step(1.0 / 120, style: .palette, reduceMotion: true, calm: false)
        XCTAssertEqual(d.stretch.value, 0, accuracy: 1e-9)
        XCTAssertEqual(d.lift.value, 1.05, accuracy: 1e-9)
    }

    func testReduceMotionPositionNeverOvershoots() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 44, y: 44))
        d.offset.snap(to: CGPoint(x: 100, y: 0))
        d.offset.target = .zero
        var minimum: CGFloat = 100
        for _ in 0..<240 {
            _ = d.step(1.0 / 120, style: .bar, reduceMotion: true, calm: false)
            minimum = min(minimum, d.offset.x.value)
        }
        XCTAssertGreaterThan(minimum, -0.5)
        XCTAssertEqual(d.offset.x.value, 0, accuracy: 0.05)
    }

    func testBeadNeverSplits() {
        for sep in stride(from: 0.0, through: 400.0, by: 10.0) {
            let g = BeadPhysics.geometry(head: 300, tail: 300 - CGFloat(sep), radius: 20)
            XCTAssertLessThanOrEqual(abs(g.head - g.tail), 1.0 * 20 + 1e-9)
            XCTAssertGreaterThanOrEqual(g.neckWidth / 2, 0.72 * g.tailRadius - 1e-9)
        }
    }

    func testSelectionBeadNeverOvershootsItsTool() {
        var head = SpringValue(0, epsilon: 0.05)
        head.target = 220                                          // five tools away
        var peak: CGFloat = 0
        var arrived: CGFloat?
        for i in 1...120 {
            head.step(1.0 / 120, spring: NibMotion.glide)
            peak = max(peak, head.value)
            if arrived == nil && abs(head.value - 220) < 1.2 { arrived = CGFloat(i) / 120 }
        }
        XCTAssertLessThanOrEqual(peak, 220 + 0.05)
        XCTAssertLessThan(arrived ?? 1, 0.3)
    }

    func testCarefulReleaseNeverFlings() {
        XCTAssertEqual(DropletPhysics.releaseVelocity(CGVector(dx: 3000, dy: 0), stillFor: 0.08), .zero)
        let capped = DropletPhysics.releaseVelocity(CGVector(dx: 9000, dy: 0), stillFor: 0.01)
        XCTAssertEqual(capped.dx, 5000, accuracy: 1e-6)
    }

    func testSlotSnapNeverOvershootsOrLeavesItsPath() {
        // A 2500 pt/s fling toward a slot, from near and far, plus a sideways component that must be dropped.
        for start in [CGPoint(x: -20, y: 0), CGPoint(x: -160, y: 30), CGPoint(x: -400, y: -60)] {
            var p = SpringPoint(start)
            p.target = .zero
            p.velocity = DropletPhysics.slotVelocity(CGVector(dx: 2500, dy: 900), displacement: start)
            XCTAssertLessThanOrEqual((p.velocity.dx * p.velocity.dx + p.velocity.dy * p.velocity.dy).squareRoot(), 1200 + 1e-6)
            for _ in 0..<240 {
                p.step(1.0 / 120, spring: NibMotion.slot)
                XCTAssertLessThanOrEqual(p.value.x, 0.05)                        // never past the slot
                XCTAssertLessThanOrEqual(abs(p.value.y), abs(start.y) + 0.05)     // never outside the start–slot box
            }
            XCTAssertEqual(p.value.x, 0, accuracy: 0.05)
        }
        // A fling away from the slot contributes nothing.
        XCTAssertEqual(DropletPhysics.slotVelocity(CGVector(dx: -3000, dy: 0), displacement: CGPoint(x: -50, y: 0)), .zero)
    }

    func testRenderedStretchNeverPassesItsCap() {
        for style in [DropletStyle.bar, .palette, .card, .chip, .popover, .toast] {
            for calm in [false, true] {
                var d = DropletDynamics()
                d.size.snap(to: CGPoint(x: 140, y: 182))
                d.offset.snap(to: CGPoint(x: 600, y: 0))
                d.offset.target = .zero
                d.offset.velocity = CGVector(dx: -5000, dy: 0)
                let cap = calm ? style.stretchCap / 2 : style.stretchCap
                var peak: CGFloat = 0, trough: CGFloat = 0
                for _ in 0..<360 {
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: calm)
                    peak = max(peak, d.renderStretch(cap: cap))
                    trough = min(trough, d.renderStretch(cap: cap))
                }
                XCTAssertLessThanOrEqual(peak, cap + 1e-9)
                XCTAssertGreaterThanOrEqual(trough, -0.4 * cap - 1e-9)
                XCTAssertEqual(d.stretch.value, 0, accuracy: 0.001)              // settled, not still wobbling
            }
        }
    }

    func testHandlesNeverDeform() {
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 12, y: 12))
        d.offset.velocity = CGVector(dx: 3000, dy: 0)
        _ = d.step(1.0 / 120, style: .handle, reduceMotion: false, calm: false)
        XCTAssertEqual(d.renderStretch(cap: DropletStyle.handle.stretchCap), 0, accuracy: 1e-12)
    }

    func testRubberBandIsContinuousAtTheEdges() {
        XCTAssertEqual(DropletPhysics.rubberBand(100, lo: 100, hi: 200), 100, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.rubberBand(99.999, lo: 100, hi: 200), 99.999, accuracy: 1e-3)
        XCTAssertGreaterThan(DropletPhysics.rubberBand(-10_000, lo: 100, hi: 200), 100 - DropletPhysics.rubberDimension)
    }

    func testFuseLeavesOnePointOverlapAndAnEightPointGlyphGap() {
        let hud = CGRect(x: 1074, y: 778, width: 104, height: 40)
        let palette = CGRect(x: 460, y: 770, width: 469, height: 56)
        let fused = DropletPhysics.fuse(palette, onto: hud)
        XCTAssertEqual(fused.maxX - hud.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(fused.midY, hud.midY, accuracy: 1e-9)          // centres within 24 pt align
        let endInset: CGFloat = 4.5
        XCTAssertGreaterThanOrEqual(endInset + endInset - 1, NibMetrics.minimumGlyphGap)
    }

    func testADockedPaletteFusesAlongItsDockOnly() {
        let hud = CGRect(x: 1074, y: 778, width: 104, height: 40)
        let palette = CGRect(x: 709, y: 762, width: 469, height: 56)          // docked at the bottom, over the HUD
        let r = DropletPhysics.restingRect(palette, near: hud, mergeDistance: 11, along: .horizontal)
        XCTAssertEqual(r.maxX - hud.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(r.minY, palette.minY, accuracy: 1e-9)                  // the dock keeps its edge
    }

    func testRestingGapsOfTwelveToFifteenPointsAreBanned() {
        let fixed = CGRect(x: 0, y: 0, width: 100, height: 44)
        let moving = CGRect(x: 113, y: 0, width: 100, height: 44)      // 13 pt gap
        let r = DropletPhysics.restingRect(moving, near: fixed, mergeDistance: 11)
        XCTAssertEqual(r.minX - fixed.maxX, 16, accuracy: 1e-9)
    }

    func testReshapeContentIsDarkOnlyBetween042And058() {
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.42), 1, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.58), 1, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.reshapeContentOpacity(progress: 0.46), 0.5, accuracy: 1e-9)
    }

    func testLongDropletsStretchOnlyAlongTheirOwnAxes() {
        XCTAssertEqual(DropletPhysics.axisLocked(stretch: 0.09, velocityAngle: 0, longAxis: 0), 0.09, accuracy: 1e-9)
        XCTAssertEqual(DropletPhysics.axisLocked(stretch: 0.09, velocityAngle: .pi / 2, longAxis: 0), -0.09, accuracy: 1e-9)
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 469, y: 56))
        d.offset.snap(to: .zero)
        d.offset.velocity = CGVector(dx: 1500, dy: 1500)
        _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
        XCTAssertEqual(d.axis, 0, accuracy: 1e-9)                      // no shear: the axis stays on the long side
    }

    func testTheStretchAxisNeverStepsAcrossAspectThree() {
        // Mid re-form the aspect crosses 3 while the droplet still moves diagonally: θ must follow, never jump.
        var d = DropletDynamics()
        d.axis = 52 * .pi / 180
        d.offset.snap(to: .zero)
        var previous = d.axis
        for w in stride(from: CGFloat(140), through: 196, by: 2) {
            d.size.snap(to: CGPoint(x: w, y: 56))                            // aspect sweeps through 2.5…3.5
            d.offset.velocity = CGVector(dx: 600, dy: 800)
            _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
            XCTAssertLessThan(abs(DropletPhysics.wrapHalfTurn(d.axis - previous)), 0.2)
            previous = d.axis
        }
        XCTAssertEqual(DropletPhysics.longAxisWeight(aspect: 2.5), 0, accuracy: 1e-12)
        XCTAssertEqual(DropletPhysics.longAxisWeight(aspect: 3.5), 1, accuracy: 1e-12)
    }

    func testStretchFromTheGrabPointKeepsTheGrabPointFixed() {
        let grab = CGPoint(x: -20, y: 250)
        let t = DropletPhysics.transform(offset: .zero, anchor: grab,
                                         linear: DropletPhysics.deformation(stretch: 0.09, axis: 0.7))
        let moved = grab.applying(t)
        XCTAssertEqual(moved.x, grab.x, accuracy: 1e-9)
        XCTAssertEqual(moved.y, grab.y, accuracy: 1e-9)
    }

    func testWobbleIsWaterNotJelly() {
        XCTAssertEqual(NibMotion.wobble(minor: 40).response, 0.14, accuracy: 1e-9)
        XCTAssertEqual(NibMotion.wobble(minor: 56).response, 0.1579, accuracy: 0.001)
        XCTAssertEqual(NibMotion.wobble(minor: 400).response, 0.26, accuracy: 1e-9)
        // Stretch springs ζ ≥ 0.65, position springs ζ ≥ 0.6, selection indicators and slots ζ 1 (DESIGN.md §9.1).
        XCTAssertGreaterThanOrEqual(NibMotion.wobble(minor: 44).dampingRatio, 0.65)
        XCTAssertGreaterThanOrEqual(NibMotion.thumb.dampingRatio, 0.65)
        for s in [NibMotion.tap, NibMotion.lift, NibMotion.snap, NibMotion.reflow, NibMotion.tether, NibMotion.bud,
                  NibMotion.budSize, NibMotion.reform, NibMotion.retract, NibMotion.sheet] {
            XCTAssertGreaterThanOrEqual(s.dampingRatio, 0.6)
        }
        for s in [NibMotion.glide, NibMotion.trail, NibMotion.slot] {
            XCTAssertEqual(s.dampingRatio, 1, accuracy: 1e-12)
        }
    }

    func testSpringsSettle() {
        var v = SpringValue(0)
        v.target = 100
        for _ in 0..<240 { v.step(1.0 / 120, spring: NibMotion.snap) }
        XCTAssertTrue(v.isResting)
        XCTAssertEqual(v.value, 100, accuracy: 0.02)
    }

    @MainActor
    func testTheChipDocksClearOfInkNearestItsLine() {
        let page = CGRect(x: 92, y: 92, width: 720, height: 742)
        let line: CGFloat = 466
        let ink = [CGRect(x: 605, y: 444, width: 187, height: 45),     // the ghost correction on the line
                   CGRect(x: 516, y: 549, width: 92, height: 31),      // "(constant)" below
                   CGRect(x: 444, y: 347, width: 215, height: 43)]     // "v = ±ω√(x₀² − x²)" above
        let size = CGSize(width: 204, height: 44)
        let c = NibTether<EmptyView>.restingCentre(chip: size, line: line, page: page, trailingLimit: 818, ink: ink)
        let chip = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        for r in ink { XCTAssertFalse(chip.insetBy(dx: 0.02, dy: 0.02).intersects(r.insetBy(dx: -8, dy: -8))) }
        XCTAssertEqual(chip.maxX, 804, accuracy: 1e-9)                 // docked at the trailing margin
        XCTAssertLessThan(abs(c.y - line), 60)                          // in the nearest free band, not far away
        let open = NibTether<EmptyView>.restingCentre(chip: size, line: line, page: page, trailingLimit: 818, ink: [])
        XCTAssertEqual(open.y, line, accuracy: 1e-9)                   // level with its line when nothing is in the way
    }

    func testClustersGroupOnlyLinkedDroplets() {
        typealias K = DropletField.PairKey
        let groups = WaterCluster.groups(["bar", "hud", "palette", "toast"],
                                         linked: [K("bar", "palette"), K("palette", "hud")])
        XCTAssertEqual(groups, [["bar", "hud", "palette"], ["toast"]])
    }
}
```

### 3.28a `NibKit/Tests/NibDesignTests/DropletDockTests.swift`

The dock model, the meniscus (reach, fuse at 20 pt, pinch at 51.6 / 56.5 pt), the follow lag, the one-dip settle across sizes and speeds, and the snap's single plip.

```swift
import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

/// The palette's water dock and hold (DESIGN.md §10.1–10.3, §10.10, §10.11).
final class DropletDockTests: XCTestCase {
    /// iPad Pro 11-inch landscape (1194 × 834, 24 pt status bar, 20 pt home indicator) with the 469 × 56 palette:
    /// region x 16…1178, y 92…798; centre lines left 44, right 1150, top 120 (+40), bottom 770.
    private let iPad = DropletDockModel(
        region: DropletDockModel.region(size: CGSize(width: 1194, height: 834),
                                        safeArea: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0), compact: false),
        length: 469, thickness: 56)

    /// iPhone (393 × 852, safe area 59 / 34) with the 349 × 56 palette: region y 127…810; top 155 (+40), bottom 782.
    private let iPhone = DropletDockModel(
        region: DropletDockModel.region(size: CGSize(width: 393, height: 852),
                                        safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), compact: true),
        length: 349, thickness: 56, compact: true)

    // MARK: Model

    func testRegionSitsBelowTheBarsSixteenPointsIn() {
        XCTAssertEqual(iPad.region, CGRect(x: 16, y: 92, width: 1162, height: 706))
        XCTAssertEqual(iPhone.region, CGRect(x: 16, y: 127, width: 361, height: 683))
        let reserved = DropletDockModel.region(size: CGSize(width: 1194, height: 834), safeArea: EdgeInsets(),
                                               compact: false, reservedTrailing: 344)
        XCTAssertEqual(reserved.maxX, 1194 - 16 - 344, accuracy: 1e-9)   // the right dock moves to the panel's edge
    }

    func testFramesSlideAlongTheirEdge() {
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .leading, along: 0.5)),
                       CGRect(x: 16, y: 210.5, width: 56, height: 469))
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .bottom, along: 0)), CGRect(x: 16, y: 742, width: 469, height: 56))
        XCTAssertEqual(iPad.frame(for: NibPaletteDock(edge: .trailing, along: 1)).maxY, 798, accuracy: 1e-9)
        let f = iPad.frame(for: NibPaletteDock(edge: .top, along: 0.3))
        XCTAssertEqual(iPad.along(ofFrame: f, on: .top), 0.3, accuracy: 1e-9)
    }

    func testReleaseProjectsTheFlingAndACarefulReleaseNeverFlings() {
        let p = CGPoint(x: 600, y: 400)
        let flung = DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 2000, dy: 0), stillFor: 0.01)
        XCTAssertEqual(flung.x, 840, accuracy: 1e-9)                                  // p + v·0.12 s
        XCTAssertEqual(flung.y, 400, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 2000, dy: 0), stillFor: 0.07), p)
        let capped = DropletDockModel.projectedPoint(finger: p, velocity: CGVector(dx: 9000, dy: 0), stillFor: 0)
        XCTAssertEqual(capped.x, 600 + 5000 * 0.12, accuracy: 1e-9)                  // capped at 5000 pt/s
    }

    func testTheTopIsChosenOnlyOnPurpose() {
        let p = CGPoint(x: 100, y: 150)                  // 30 pt below the top line, 56 pt from the left line
        XCTAssertEqual(iPad.distance(from: p, to: .top), 30 + 40, accuracy: 1e-9)
        XCTAssertEqual(iPad.nearestDock(to: p), .leading)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 600, y: 125)), .top)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 600, y: 700)), .bottom)
        XCTAssertEqual(iPad.nearestDock(to: CGPoint(x: 1100, y: 400)), .trailing)
    }

    func testCaptureRadiusOrHome() {
        XCTAssertEqual(DropletDockModel.captureRadius, 200)
        XCTAssertEqual(DropletDockModel.captureRadiusCompact, 160)
        let home = NibPaletteDock(edge: .leading, along: 0.2)
        // Mid-page: the nearest dock (bottom, 340 pt) is outside the capture radius, so the palette flows home.
        XCTAssertNil(iPad.capturedDock(at: CGPoint(x: 600, y: 430)))
        XCTAssertEqual(iPad.release(projected: CGPoint(x: 600, y: 430), from: home), home)
        // 170 pt above the bottom line: captured.
        XCTAssertEqual(iPad.capturedDock(at: CGPoint(x: 600, y: 600)), .bottom)
        // Exactly at the radius counts; one point further does not.
        XCTAssertEqual(iPad.capturedDock(at: CGPoint(x: 1150 - 200, y: 430)), .trailing)
        XCTAssertNil(iPad.capturedDock(at: CGPoint(x: 1150 - 201, y: 430)))
        // A fling from mid-page towards the right lands on the right edge, centred on the projected point.
        let flung = iPad.release(finger: CGPoint(x: 900, y: 430), velocity: CGVector(dx: 2500, dy: 0), stillFor: 0,
                                 from: home)
        XCTAssertEqual(flung.edge, .trailing)
        XCTAssertEqual(flung.along, (430 - 326.5) / 237, accuracy: 1e-9)
        // The same point released carefully (still ≥ 70 ms) does not fling: home.
        XCTAssertEqual(iPad.release(finger: CGPoint(x: 900, y: 430), velocity: CGVector(dx: 2500, dy: 0), stillFor: 0.2,
                                    from: home), home)
    }

    func testIPhoneDocksTopAndBottomOnly() {
        XCTAssertEqual(iPhone.docks, [.top, .bottom])
        XCTAssertNil(iPhone.capturedDock(at: CGPoint(x: 20, y: 470)))                   // the left edge is not a dock
        XCTAssertEqual(iPhone.capturedDock(at: CGPoint(x: 20, y: 650)), .bottom)
        XCTAssertEqual(iPhone.capturedDock(at: CGPoint(x: 200, y: 200)), .top)          // 45 + 40 = 85 ≤ 160
        XCTAssertEqual(iPhone.validated(NibPaletteDock(edge: .leading)).edge, .bottom)
        XCTAssertEqual(iPhone.validated(NibPaletteDock(edge: .top, along: 0.4)), NibPaletteDock(edge: .top, along: 0.4))
    }

    func testCommandValuesRoundTrip() {
        for edge in NibDock.allCases { XCTAssertEqual(NibDock(commandValue: edge.commandValue), edge) }
        XCTAssertEqual(NibDock.leading.commandValue, "left")
        XCTAssertEqual(NibDock.trailing.commandValue, "right")
        XCTAssertNil(NibDock(commandValue: "middle"))
    }

    // MARK: Meniscus

    func testMeniscusThicknessReachAndPinch() {
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 0), 26, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 36), 26 * pow(0.5, 0.7), accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: 72), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 72), 0, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 46), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DropletDockModel.meniscusReach(gap: 20), 1, accuracy: 1e-9)
        let pinch = DropletDockModel.meniscusPinchGap(minimumNeck: DropletMetrics.regular.minimumNeck)
        XCTAssertEqual(pinch, 51.6, accuracy: 0.2)                                     // holds on well past the 20 pt join
        XCTAssertEqual(DropletDockModel.meniscusThickness(gap: pinch), DropletMetrics.regular.minimumNeck, accuracy: 1e-6)
        XCTAssertEqual(DropletDockModel.meniscusPinchGap(minimumNeck: DropletMetrics.compact.minimumNeck), 56.5,
                       accuracy: 0.2)
    }

    func testMeniscusGrowsFusesHoldsOnAndPinches() {
        let dock = CGRect(x: 16, y: 210.5, width: 56, height: 469)                     // the left dock
        func body(gap: CGFloat) -> CGRect { CGRect(x: 72 + gap, y: 210.5, width: 56, height: 469) }
        let tMin = DropletMetrics.regular.minimumNeck
        var m = DockMeniscus()
        m.target = dock
        func run(_ gap: CGFloat, frames: Int = 40) {
            for _ in 0..<frames { _ = m.step(1.0 / 120, body: body(gap: gap), enabled: true, minimumNeck: tMin) }
        }
        run(100)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.segment)
        run(50)                                                          // inside 72 pt: a tongue reaches out
        XCTAssertEqual(m.phase, .reaching)
        let tongue = m.segment
        XCTAssertNotNil(tongue)
        if let tongue {
            XCTAssertLessThan(tongue.to.x, 122)                          // out of the body, towards the dock…
            XCTAssertGreaterThan(tongue.to.x - tongue.thickness / 2, 72)  // …not touching it yet
            XCTAssertEqual(tongue.thickness, DropletDockModel.meniscusThickness(gap: 50), accuracy: 0.1)
        }
        run(15)                                                          // inside 20 pt: it touches and fuses
        XCTAssertEqual(m.phase, .fused)
        XCTAssertLessThan(m.segment?.to.x ?? .infinity, 72)
        run(45)                                                          // pulled back out: it holds on
        XCTAssertEqual(m.phase, .fused)
        run(55)                                                          // thinner than the field can hold: it pinches
        XCTAssertEqual(m.phase, .retracting)
        run(60, frames: 120)
        XCTAssertNil(m.segment)
        m.target = nil
        run(60, frames: 120)
        XCTAssertTrue(m.isIdle)
    }

    func testNoMeniscusWithoutNecks() {
        var m = DockMeniscus()
        m.target = CGRect(x: 16, y: 0, width: 56, height: 469)
        for _ in 0..<60 {
            _ = m.step(1.0 / 120, body: CGRect(x: 80, y: 0, width: 56, height: 469), enabled: false, minimumNeck: 10.76)
        }
        XCTAssertNil(m.segment)                                          // Reduce Motion, Calm and Liquid Off
    }

    // MARK: Hold and snap

    func testSpringsAreTheSpecifiedOnes() {
        XCTAssertEqual(NibMotion.follow, NibSpring(response: 0.085, dampingRatio: 1.0))
        XCTAssertEqual(NibMotion.snap, NibSpring(response: 0.50, dampingRatio: 0.80))
        XCTAssertEqual(NibMotion.reflow, NibSpring(response: 0.44, dampingRatio: 0.86))
        XCTAssertEqual(NibMotion.hudLinger, 0.6, accuracy: 1e-12)
        XCTAssertTrue(NibHapticEvent.allCases.contains(.plip))
    }

    /// The held palette trails the finger slightly (the water's weight) and catches up once the finger stops.
    func testAHeldDropletLagsTheFingerSlightly() {
        XCTAssertEqual(DropletPhysics.followLag(speed: 1000), 27.06, accuracy: 0.01)
        var d = DropletDynamics()
        d.size.snap(to: CGPoint(x: 469, y: 56))
        d.positionSpring = NibMotion.follow
        var finger: CGFloat = 0
        var lag: CGFloat = 0
        for _ in 0..<60 {                                               // 0.5 s at 1000 pt/s
            finger += 1000.0 / 120
            d.offset.target = CGPoint(x: finger, y: 0)
            _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false)
            lag = finger - d.offset.x.value
        }
        XCTAssertGreaterThan(lag, 15)                                   // it lags…
        XCTAssertLessThan(lag, 30)                                      // …by about 27 ms of travel, never more
        for _ in 0..<24 { _ = d.step(1.0 / 120, style: .palette, reduceMotion: false, calm: false) }
        XCTAssertLessThan(abs(finger - d.offset.x.value), 1)             // caught up within 0.2 s
        XCTAssertLessThanOrEqual(d.offset.x.value, finger + 0.05)       // and never passes the finger
    }

    /// Water, not jelly: as the held palette slows to a stop its stretch dips below zero once, by a visible but small
    /// amount (3–10 % of the peak), and never bounces back up.
    func testTheSettleIsOneSmallDip() {
        for (w, h, style) in [(CGFloat(469), CGFloat(56), DropletStyle.palette), (140, 182, .card), (44, 44, .bar)] {
            for speed in [CGFloat(300), 1500, 4000] {
                var d = DropletDynamics()
                d.size.snap(to: CGPoint(x: w, y: h))
                d.positionSpring = NibMotion.follow
                var finger: CGFloat = 0
                var peak: CGFloat = 0
                for _ in 0..<48 {
                    finger += speed / 120
                    d.offset.target = CGPoint(x: finger, y: 0)
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: false)
                    peak = max(peak, d.stretch.value)
                }
                var trough: CGFloat = 0
                var rebound: CGFloat = -1
                for _ in 0..<180 {                                       // the finger stops
                    _ = d.step(1.0 / 120, style: style, reduceMotion: false, calm: false)
                    if d.stretch.value < trough {
                        trough = d.stretch.value
                        rebound = -1
                    } else if trough < 0 {
                        rebound = max(rebound, d.stretch.value)
                    }
                }
                XCTAssertGreaterThan(peak, 0)
                XCTAssertLessThanOrEqual(-trough, 0.10 * peak, "\(style) at \(speed) pt/s undershoots more than 10 %")
                XCTAssertGreaterThanOrEqual(-trough, 0.03 * peak, "\(style) at \(speed) pt/s has no visible settle")
                XCTAssertLessThan(rebound, 0.01 * peak, "\(style) at \(speed) pt/s bounces back up (jelly)")
                XCTAssertEqual(d.stretch.value, 0, accuracy: 0.001)
            }
        }
    }

    /// The dock snap starts from the release velocity, overshoots a little (about 4 pt) and plays exactly one plip.
    func testTheSnapPlipsOnceOnArrival() {
        for (start, velocity) in [(CGFloat(-300), CGFloat(0)), (-300, 2000), (-600, 5000), (-100, -1500)] {
            var p = SpringPoint(CGPoint(x: start, y: 0))
            p.target = .zero
            p.velocity = CGVector(dx: velocity, dy: 0)
            var landing: DockLanding? = DockLanding(centre: .zero, since: 0)
            var plips = 0
            var arrivedAt: Double?
            var overshoot: CGFloat = 0
            for i in 1...240 {
                p.step(1.0 / 120, spring: NibMotion.snap)
                overshoot = max(overshoot, p.value.x)
                let now = Double(i) / 120
                if let l = landing {
                    switch l.check(body: p.value, settling: !p.isResting, now: now) {
                    case .arrived:
                        plips += 1
                        arrivedAt = now
                        landing = nil
                    case .expired:
                        landing = nil
                    case .waiting:
                        break
                    }
                }
            }
            XCTAssertEqual(plips, 1)
            XCTAssertLessThan(arrivedAt ?? 1, 0.4)
            XCTAssertLessThan(overshoot, 12)
            XCTAssertTrue(p.isResting)
        }
    }

    func testALandingThatNeverArrivesExpiresSilently() {
        let l = DockLanding(centre: .zero, since: 0)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: true, now: 1.0), .waiting)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: true, now: 1.6), .expired)
        XCTAssertEqual(l.check(body: CGPoint(x: 1, y: 1), settling: true, now: 0.2), .arrived)
        XCTAssertEqual(l.check(body: CGPoint(x: 50, y: 0), settling: false, now: 0.2), .arrived)   // came to rest
    }
}
```

### 3.28b `NibKit/Tests/NibDesignTests/NibReflowTests.swift`

The reflow model: slots, one-slot shifts across rows, hysteresis at a boundary, the outside margin, pause, the combine zone, the move's neighbours, and the observable's drop, cancel, measured-frame mapping and combine arming.

```swift
import XCTest
import CoreGraphics
import SwiftUI
@testable import NibDesign

/// The library's live reorder (DESIGN.md §10.12, §14.1): the gap follows the finger with hysteresis, neighbours move
/// one slot, a combine zone holds the reflow, and a drop reports (from, to).
final class NibReflowTests: XCTestCase {
    /// Four 140 × 182 covers per row on the 24 pt gutter: a 164 × 206 pitch.
    private let layout = NibReflowLayout(columns: 4, cell: CGSize(width: 140, height: 182))
    private let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]

    private func centre(_ i: Int) -> CGPoint {
        let r = layout.slot(i)
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func model(dragging id: String, combines: Bool = false) -> NibReflowModel<String> {
        NibReflowModel(ids: ids, slots: layout.slots(count: ids.count), dragged: id, combines: combines)!
    }

    func testGridSlots() {
        XCTAssertEqual(layout.slot(0), CGRect(x: 0, y: 0, width: 140, height: 182))
        XCTAssertEqual(layout.slot(5), CGRect(x: 164, y: 206, width: 140, height: 182))
        XCTAssertNil(NibReflowModel(ids: ids, slots: layout.slots(count: 3), dragged: "a"))
        XCTAssertNil(NibReflowModel(ids: ids, slots: layout.slots(count: ids.count), dragged: "z"))
    }

    func testNeighboursShiftOneSlotTowardsHome() {
        var m = model(dragging: "b")
        XCTAssertEqual(m.insertion, 1)
        XCTAssertTrue(m.update(finger: centre(3)))
        XCTAssertEqual(m.insertion, 3)
        XCTAssertEqual(m.targetIndex(of: "a"), 0)
        XCTAssertEqual(m.targetIndex(of: "c"), 1)
        XCTAssertEqual(m.targetIndex(of: "d"), 2)
        XCTAssertEqual(m.targetIndex(of: "b"), 3)
        XCTAssertEqual(m.targetIndex(of: "e"), 4)
        XCTAssertEqual(m.offset(of: "c"), CGSize(width: -164, height: 0))
        XCTAssertEqual(m.offset(of: "e"), .zero)
        // Backwards across a row: the gap moves to 0 and a shifts forward into slot 1.
        XCTAssertTrue(m.update(finger: centre(0)))
        XCTAssertEqual(m.targetIndex(of: "a"), 1)
        XCTAssertEqual(m.targetIndex(of: "c"), 2)
        XCTAssertEqual(m.offset(of: "a"), CGSize(width: 164, height: 0))
    }

    func testTheGapWrapsRows() {
        var m = model(dragging: "b")
        m.update(finger: centre(5))
        XCTAssertEqual(m.insertion, 5)
        XCTAssertEqual(m.targetIndex(of: "e"), 3)                                     // row 2 → end of row 1
        XCTAssertEqual(m.offset(of: "e"), CGSize(width: 3 * 164, height: -206))
        XCTAssertEqual(m.targetIndex(of: "f"), 4)
        XCTAssertEqual(m.targetIndex(of: "g"), 6)
    }

    func testHysteresisKeepsTheGapStillAtABoundary() {
        var m = model(dragging: "b")
        m.update(finger: centre(3))
        let mid = (centre(2).x + centre(3).x) / 2                                     // 480
        // Jitter of ±5 pt around the midpoint between two slots never moves the gap.
        for dx in stride(from: CGFloat(-5), through: 5, by: 1) {
            XCTAssertFalse(m.update(finger: CGPoint(x: mid + dx, y: 91)))
            XCTAssertEqual(m.insertion, 3)
        }
        // 12 pt past the midpoint (half of the 24 pt hysteresis) it moves, and then holds on the other side.
        XCTAssertFalse(m.update(finger: CGPoint(x: mid - 11, y: 91)))
        XCTAssertTrue(m.update(finger: CGPoint(x: mid - 13, y: 91)))
        XCTAssertEqual(m.insertion, 2)
        XCTAssertFalse(m.update(finger: CGPoint(x: mid + 11, y: 91)))
        XCTAssertEqual(m.insertion, 2)
    }

    func testOutsideTheGridTheGapClosesAtHome() {
        var m = model(dragging: "b")
        m.update(finger: centre(3))
        XCTAssertTrue(m.update(finger: CGPoint(x: -200, y: 91)))                      // over the sidebar
        XCTAssertEqual(m.insertion, 1)
        XCTAssertNil(m.move)
        XCTAssertEqual(m.offset(of: "c"), .zero)
    }

    func testPausedHoldsEverything() {
        var m = model(dragging: "b")
        XCTAssertFalse(m.update(finger: centre(3), paused: true))
        XCTAssertEqual(m.insertion, 1)
    }

    func testACoverHoldsStillWhileTheFingerIsInItsCombineZone() {
        var m = model(dragging: "b", combines: true)
        // The finger on d's centre: d is the combine candidate and does not move away.
        XCTAssertEqual(m.combineCandidate(at: centre(3)), "d")
        XCTAssertFalse(m.update(finger: centre(3)))
        XCTAssertEqual(m.insertion, 1)
        // The dragged card's own slot is never a combine target.
        XCTAssertNil(m.combineCandidate(at: centre(1)))
        // At d's edge (outside its inner 70 %) the reflow goes on and d makes room.
        let edge = CGPoint(x: layout.slot(3).minX + 10, y: 91)
        XCTAssertNil(m.combineCandidate(at: edge))
        XCTAssertTrue(m.update(finger: edge))
        XCTAssertEqual(m.insertion, 3)
        XCTAssertEqual(m.targetIndex(of: "d"), 2)
        // Page thumbnails never combine.
        XCTAssertNil(model(dragging: "b").combineCandidate(at: centre(3)))
    }

    func testDropReportsFromToAndNeighbours() {
        var m = model(dragging: "b")
        XCTAssertNil(m.move)
        m.update(finger: centre(3))
        let move = m.move
        XCTAssertEqual(move?.id, "b")
        XCTAssertEqual(move?.from, 1)
        XCTAssertEqual(move?.to, 3)
        XCTAssertEqual(move?.after, "d")
        XCTAssertEqual(move?.before, "e")
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 1, to: 3), ["a", "c", "d", "b", "e", "f", "g", "h"])
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 6, to: 0), ["g", "a", "b", "c", "d", "e", "f", "h"])
        XCTAssertEqual(NibReflowModel.reordered(ids, from: 9, to: 0), ids)
        let first = NibReflowMove(id: "c", from: 2, to: 0, in: ids)
        XCTAssertNil(first.after)
        XCTAssertEqual(first.before, "a")
        let last = NibReflowMove(id: "a", from: 0, to: 7, in: ids)
        XCTAssertEqual(last.after, "h")
        XCTAssertNil(last.before)
    }

    // MARK: The observable

    func testALiveReorderEndsInAReorder() {
        let reflow = NibReflow<String>(layout: layout, combines: false)
        reflow.begin("b", order: ids, at: centre(1))
        XCTAssertTrue(reflow.isDragging)
        XCTAssertTrue(reflow.isCarried("b"))
        reflow.move(to: CGPoint(x: centre(2).x, y: 91))
        reflow.move(to: centre(3))
        XCTAssertEqual(reflow.offset(for: "c"), CGSize(width: -164, height: 0))
        XCTAssertTrue(reflow.animatesOffsets)
        let drop = reflow.end(velocity: CGVector(dx: 300, dy: 0))
        XCTAssertEqual(drop, .reorder(NibReflowMove(id: "b", from: 1, to: 3, in: ids)))
        XCTAssertFalse(reflow.animatesOffsets)                     // the data now holds the order: no spring back
        XCTAssertEqual(reflow.offset(for: "c"), .zero)
        XCTAssertEqual(reflow.carrierFrame, layout.slot(3))        // the carrier lands in the gap
        reflow.landed()
        XCTAssertNil(reflow.carried)
        XCTAssertTrue(reflow.animatesOffsets)
    }

    func testCancelSpringsEveryoneBack() {
        let reflow = NibReflow<String>(layout: layout, combines: false)
        reflow.begin("b", order: ids, at: centre(1))
        reflow.move(to: centre(3))
        reflow.cancel()
        XCTAssertTrue(reflow.animatesOffsets)
        XCTAssertEqual(reflow.carrierFrame, layout.slot(1))
    }

    func testMeasuredFramesMapTheMoveToTheFullOrder() {
        // Only c…f are on screen (a lazy grid): the move still comes back in the caller's order.
        let reflow = NibReflow<String>(combines: false)
        for (i, id) in ["c", "d", "e", "f"].enumerated() { reflow.frames[id] = layout.slot(i) }
        reflow.begin("c", order: ids, at: centre(0))
        reflow.move(to: centre(2))
        XCTAssertEqual(reflow.end(), .reorder(NibReflowMove(id: "c", from: 2, to: 4, in: ids)))
    }

    func testHoldingOverACoverArmsACombineAndPausesTheReflow() {
        let reflow = NibReflow<String>(layout: layout, combines: true)
        reflow.begin("b", order: ids, at: centre(1))
        reflow.move(to: centre(3))
        XCTAssertNil(reflow.armed)                                 // proximity alone draws nothing
        let held = expectation(description: "held 380 ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + NibMotion.combineHold + 0.15) { held.fulfill() }
        wait(for: [held], timeout: 2)
        XCTAssertEqual(reflow.armed, "d")
        XCTAssertEqual(reflow.armedFrame, layout.slot(3))
        reflow.move(to: CGPoint(x: layout.slot(3).minX + 6, y: 91))  // still over d: armed, reflow paused
        XCTAssertEqual(reflow.armed, "d")
        XCTAssertEqual(reflow.offset(for: "c"), .zero)
        XCTAssertEqual(reflow.end(), .combine("b", into: "d"))
        XCTAssertEqual(reflow.carrierFrame, layout.slot(3))        // it flows into the cover…
        XCTAssertEqual(reflow.armedFrame, layout.slot(3))          // …which stays until the card is in
        reflow.landed()
        XCTAssertNil(reflow.armed)
    }
}
```

---

## 4. Lint rules

`Scripts/lint.py` fails CI for any file under `NibKit/Sources/Feat*/`, `Nib/` or `NibWidgets/` (not `NibDesign`) on:

| Rule | Rejected | Use instead |
|---|---|---|
| Raw colour | `Color(red:`, `UIColor(red:`, `Color(hex`, `#colorLiteral`, `Color(.sRGB`, a six-digit hex literal (`\b0x[0-9A-Fa-f]{6}\b`, checked only on lines that also contain `Color`, `UIColor` or `nib`, so ZIP and PDF magic numbers in FeatImport, FeatBackup and FeatCollab pass), `.opacity(` applied directly to `Color.black`/`Color.white` | `NibColor`, `NibUIColor`, `NibInk`, `NibPaper` (their `color` / `uiColor`) |
| Raw type | `.font(.system(size:`, `Font.custom(`, `UIFont.systemFont(ofSize:`, `UIFont(name:`, `.kerning(`, `.tracking(` | `NibFont`, `NibUIFont`, `NibFont.glyph(_:)` / `NibUIFont.glyph(_:)` for SF Symbol sizes |
| Raw radius | a numeric literal in `.cornerRadius(`, `RoundedRectangle(cornerRadius:`, `layer.cornerRadius =`, `UnevenRoundedRectangle(` | `NibRadius`, `NibDropletShape` |
| Raw shadow | `.shadow(`, `layer.shadowOpacity`, `layer.shadowRadius` | `.nibElevation(_:)`, `CALayer.nibElevation(_:path:dark:)` |
| Raw motion | `withAnimation(` without `NibMotion`, `.animation(.easeIn`/`.easeOut`/`.easeInOut`/`.linear`/`.default`/`.bouncy`/`.snappy`/`.smooth`, `.spring(` without a `NibMotion` token, `UIView.animate(withDuration:`, `CABasicAnimation(` | `NibMotion.x.animation` (it honours Reduce Motion and Liquid Off itself), `NibMotion.animate`, `NibMotion.animateUIKit` |
| Materials and glass | `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, `.thickMaterial`, `.ultraThickMaterial`, `Material.` (not `DropletMaterial.`), `UIBlurEffect`, `UIVisualEffectView`, `UIGlassEffect`, `UIGlassContainerEffect`, `.glassEffect(`, `GlassEffectContainer`, `.buttonStyle(.glass` | `.droplet(_:style:)`, `nibGlass`, opaque surfaces |
| Raw haptics | `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator`, `CHHapticEngine`, `.sensoryFeedback(` | `NibHaptics.play`, `.nibHaptic` (`UICanvasFeedbackGenerator` is allowed in FeatPencilHardware and FeatTransform only) |
| Symbols | `Image(systemName:`, `UIImage(systemName:`, `Label(…, systemImage:` | `Image(nib:)`, `UIImage(nib:)`, `NibSymbol`, `NibSymbol(systemName:)` for a descriptor's icon string |
| Banned glyphs and copy | `"sparkles"`, `"sparkle"`, `"wand.and.stars"`, `"wand.and.rays"`; any emoji in a string literal (`\p{Extended_Pictographic}`); the words `seamless`, `elevate`, `unleash`, `supercharge`, `magic` in `String(localized:` | a drop mark for AI, plain verbs |
| US spellings in UI copy | inside `String(localized:`: `color`, `favorite`, `customize`, `organize`, `summarize`, `recognize`, `center`, `gray`, `canceled`, `behavior` (any case; not in identifiers) | British English: colour, favourite, customise, organise, summarise, recognise, centre, grey, cancelled, behaviour |
| Toasts | `.droplet(` with `style: .toast` | `.nibToast($item)`, which places, times and announces them |
| Droplets in scrolling content | `.droplet(` inside a `ScrollView`/`List` body in the same file | chrome belongs to the container above the content |
| Shaders | `.layerEffect(`, `.distortionEffect(`, `.colorEffect(`, `ShaderLibrary` | NibDesign components (the canvas is never shaded; there is no tap ripple) |

`Scripts/a11y_lint.py` also requires an `accessibilityLabel` (or a `label:` argument) on every `NibIconButton`, `Button` whose label is only an `Image`, and every `.droplet(` that has no text content.

Inside `NibDesign` itself, review checks that every `String(localized:` passes `bundle: .module`.

---

## 5. Device checks the simulator cannot make

The code compiles and the physics is unit-tested in CI, but these seven things can only be judged on hardware. They are the first `tools/smoke` scripts for F111, and nothing ships until a person has looked at each one:

1. **iOS 26 glass follows our geometry.** The body is sized by `.frame` and moved by `.offset` after `.glassEffect`, which the union honours. Necks are rotated capsules (`rotationEffect` after `glassEffect`): check that they merge. If they don't, set `NeckGlassLayer` necks to axis-aligned capsules. Check too that `Glass.identity` over the body tint (while the Pencil is down) is indistinguishable at 22 %. Check that the held rim (`NibLiftRim`, plus-lighter) lands on the system's own rim as one brighter edge, not as a second line inside it, on capsules and on 26 and 28 pt corners; if it doubles, move it out by the difference.
2. **The iOS 17 field costs ≤ 1.2 ms of GPU per frame on an A12** (iPad mini 5 / iPhone XS), **measured again with per-cluster canvases**. Measure it with the Metal HUD (`MTL_HUD_ENABLED=1`) while dragging the palette over the page, and check with Instruments that the main thread stays under 3 ms per frame (only the moving droplet's node and its cluster's canvas update). If the GPU goes over, `WaterOpaqueLayer` (one path union, no blur, no shader) is the automatic Calm path, and it must measure cheaper than the field.
3. **Touches pass through the container to the canvas** where no droplet is drawn (ZStack sibling layout, §2), and never while a bud is open (the dismiss area covers the safe-area strips).
4. **The Pencil is not rejected by chrome gestures on iOS 17.** SwiftUI gestures can't filter touch type, so a Pencil press that starts on a droplet can drag it. The editor sets PencilKit's `drawingPolicy` so strokes that start on the page never reach chrome. Revisit with `UIGestureRecognizerRepresentable` (`allowedTouchTypes = [.direct]`, iOS 18) after the device check.
5. **Blur radius calibration.** `GraphicsContext.Filter.blur(radius:)` is treated as σ. If bridges start noticeably later or earlier than 11 pt on device, adjust `DropletMetrics.regular.fieldBlur`; `minimumNeck` follows it automatically.
6. **Contrast over ink.** With the palette and bars over a page of black handwriting, the bar subtitle and HUD digits (`label`, semibold) read at ≥ 4.5:1 in light mode, and dark-mode Clear over white paper (80 %) is a dark surface, not a grey blob (DESIGN.md §2.4). On iOS 26, check the same for Deep popovers and the assistant as plain Regular glass (no tint): 15 pt body text over dense handwriting. If a panel fails, the fix is the panel's placement or the system's Tinted glass preference, not a tint on the glass.
7. **The rim reads as Apple's.** Side by side with a system toolbar on iOS 26, a Clear droplet on iOS 17 or 18 shows a thin rim brightest at the top-left corner, fainter at the bottom-right, none at the other two corners, no second line inside it and no grey band; a dragged droplet's rim visibly brightens and settles back with the lift.
8. **The dock and the reflow feel like water.** Hold the palette and drag it at walking speed and then flick it: it trails the finger slightly (never more than about 27 ms of travel), stretches, and dips once as it stops, with no second bounce. Bring it within 72 pt of an edge: the meniscus reaches out, fuses at 20 pt, and pinches at about 52 pt when pulled back. Release: one plip as it lands, none from the overshoot. In the library, drag a notebook along a row and back across a boundary slowly: the gap moves once per slot and never flickers; hold over a cover's centre: it arms after 380 ms and nothing moves until the finger leaves it.

---

## NibDesign v2 additions

The gaps the first wave of feature agents reported (tools/fleet/contract-gaps.md, their `ponytail:` stand-ins) and the components the 61 features without a branch will need (docs/forge-spec.json), closed inside `NibDesign`. Everything is additive: no public declaration was renamed or removed, and every v1 initialiser still resolves (`NibDesignV2Tests.testEveryInitialiserResolves` calls each v1 initialiser beside its v2 overload). §3 above lists the v1 sources; the files on disk are authoritative for the v2 members below. New components live in new files under `Components/`; DESIGN.md §4–8 and §13 carry the spec rows.

Tests: `NibKit/Tests/NibDesignTests/NibDesignV2Tests.swift` (every symbol token resolves and is allowed on the CI OS, the swatch ring rule reproduces `NibInk.needsRing`, width text in both units, waveform bars, presence folding, outline indent, principal mapping, QR rendering, UIKit type roles, CSS tokens, the floating host, every initialiser).

### 1. Tokens

**`NibSymbol`** (`Tokens/NibSymbol.swift`, DESIGN.md §8.3): 72 new tokens plus `imagePlayground`, an OS-gated `NibSymbol?`. `static let all: [NibSymbol]` (internal) lists every token for the gallery and the resolve test.

```swift
// Tools and colour
static let eyedropper, customColour, drawShape, layers, editHandwriting, recognisedText, convertToText, straighten,
           insertSpace, math, graph, table, dragHandle: NibSymbol
// Editing
static let cut, copy, paste, duplicate, link, arrange, screenshot, crop, flipHorizontal, flipVertical, replace, unlock,
           touchID, print, saveToFiles, newWindow, externalLink, qrCode: NibSymbol
static var imagePlayground: NibSymbol? { get }       // nil below iOS 18.1
// Text formatting
static let bold, italic, underline, strikethrough, textSuperscript, textSubscript, inlineCode, fontSize, alignLeft,
           alignCentre, alignRight, justify, listBulleted, listNumbered, checklist, indent, outdent, lineSpacing: NibSymbol
// Audio, time, places
static let recordDot, skipBack10, skipForward10, transcript, speak, timer, stopwatch, lap, history, profile, language,
           notifications, reminder, info, advanced, templates, minimap, fitToContent, calendar, cloud, backup,
           diagnostics, dictionary: NibSymbol
```

| Gap | Resolved by | Replaces |
|---|---|---|
| F008 no eyedropper / colour-picker glyph | `.eyedropper`, `.customColour` | F008 `PresetSymbols` (FeatPresets/ColorSlotEditor.swift) |
| F014 no paste glyph | `.paste` (menu icon string: `NibSymbol.paste.name`) | F014 `icon: nil` on Paste and Match Style (FeatClipboard/FeatClipboardFeature.swift) |
| F018 no new-window glyph | `.newWindow` | F018 `WindowMenus.newWindowIcon` literal (FeatWindows/FeatWindowsFeature.swift) |
| F026, F028 no text-format glyphs (bold, italic, underline, strikethrough, alignment, lists, indent, outdent, line spacing) | `.bold` … `.lineSpacing` | F026 `TextFormatOptions.symbol(_:fallback:)` (FeatTextBox/TextFormatInspector.swift); F028 `PageTextGlyph` (FeatPageText/PageTextEditor.swift) |
| F027 no profile, language, notifications, templates, about, advanced, external-link glyphs | `.profile`, `.language`, `.notifications`, `.templates`, `.info`, `.advanced`, `.externalLink` | F027 literals in FeatSettings/FeatSettingsFeature.swift, LanguagePage.swift, SettingsRootViewController.swift |
| F030 no Draw Shape glyph | `.drawShape` | F030's use of `.documentWrite` (FeatShapeRecognition/FeatShapeRecognitionFeature.swift) |
| F034 no crop, flip, replace, paste, Image Playground glyphs | `.crop`, `.flipHorizontal`, `.flipVertical`, `.replace`, `.paste`, `.imagePlayground` | F034 `ImageIcons` (FeatImages/ImageTool.swift) |
| F037 no link glyph | `.link`, `.copy` | F037 icon-less Copy Link entry (FeatComments) |
| F041 no layers glyph | `.layers` | F041 `LayerGlyph` (FeatLayers/LayersPanel.swift) |
| F044 no minimap, fit, templates glyphs | `.minimap`, `.fitToContent`, `.templates` | F044 `MinimapView` statics and the BoardsPanel literal (FeatWhiteboard) |
| F052 no record-dot or ±10 s glyphs | `.recordDot`, `.skipBack10`, `.skipForward10` | F052 AudioPanel.swift statics and `recordDot` (FeatAudio) |
| F058 no straighten, align, insert space, cut, paste, colour, edit-all glyphs | `.straighten`, `.alignLeft`/`.alignCentre`/`.alignRight`, `.insertSpace`, `.cut`, `.paste`, `.customColour`, `.recognisedText`, `.editHandwriting` | F058 `SmartInkSymbol` (FeatSmartInk/EditHandwritingMode.swift) |
| F062 no timer, stopwatch, flag glyphs | `.timer`, `.stopwatch`, `.lap` | F062 `TimeKeeperView` statics (FeatTimeKeeper) |

**`NibFont` / `NibUIFont`** (`Tokens/NibFont.swift`, DESIGN.md §4.1):

```swift
extension NibFont {
    static let badgeNumber: Font                       // SF Rounded bold footnote (NibBadge .number now uses it)
    static let documentBody: Font                      // New York 17
    static func documentHeading(_ level: Int) -> Font  // New York bold title / title2 / title3
}
extension NibUIFont {   // every §4.1 role for UIKit except math; all scale with UIFontMetrics
    static var display, displayEditorial, title1, title2, title3, emptyTitle, cardFace, bodyEmphasis, callout,
               chatEmphasis, button, footnoteEmphasis, caption1Emphasis, caption2, hudLarge, badgeNumber, code,
               documentBody: UIFont { get }
    static func documentHeading(_ level: Int) -> UIFont
}
```

Resolves F037, F039, F046, F047 (UIKit roles built with `NibUIFont.font(…)` by hand) and F102/F103 (text-document body and headings). Replaces `NibUIFont.font(.body, design: .serif)` and the serif `title1/2/3` headings in FeatTextDoc (F047), `font(.footnote, weight: .bold, design: .rounded)` for comment pins (F037), `font(.caption2, weight: .medium)` in FeatRuler (F039), `font(.body/.footnote, weight: .semibold)` in FeatOutline (F046).

**`NibSpacing.swift`** (DESIGN.md §5, §5.1, §5.2, §6):

```swift
extension NibRadius { static let ruler: CGFloat /* 6 */; static let pageWash: CGFloat /* 4 */ }
extension NibMetrics {
    static let optionTileHeight, statusDot, presenceBead, liveCursorBead, tabCapsuleHeight, rowThumbnailWidth,
               outlineIndent, settingsSectionListWidth, searchWidth, searchResultsMaxHeight, commandBarWidth,
               onboardingCardWidth, zoomPaneHeight, audioBarWidth, textColumnWidth, laserDot, laserGlow, laserTrail,
               proposalBadgeX, popoverContentWidth, handleBead, rotationHandleOffset: CGFloat
    static let presenceMaxShown, maxVisibleTabs, outlineMaxDepth: Int
    static let settingsSheetSize, newDocumentSheetSize, coverPreviewSize, coverStripSize, paperTileSize,
               pluginManagerSheetSize, developerConsoleSize, floatingPanelSize, searchSnippetSize, studyCardSize,
               minimapSize, minimapSizeCompact: CGSize
}
public enum NibStroke {   // hairline 0.5, outline 0.8, thin 1, emphasis 1.5, ring 2, thick 3, ringOutset 3
    static let dash: [CGFloat]            // [4, 4]
    static let dashed: StrokeStyle        // thin + dash, for SwiftUI
    static var layerDash: [NSNumber]      // for CAShapeLayer.lineDashPattern
}
public enum NibOpacity { static let disabled, unselectedTool, recede, ghostInk, replayPending, laserGlow: Double }
```

| Gap | Resolved by | Replaces |
|---|---|---|
| F014 no stroke or border-width token | `NibStroke.ring` (drop highlight) | `NibSpacing.xxs` as a line width (FeatClipboard/CanvasDragDrop.swift) |
| F026 no focus-outline width or dash token | `NibStroke.thin` + `NibStroke.layerDash` | `lineWidth = 1`, `lineDashPattern = [4, 4]` (FeatTextBox/TextBoxEditor.swift) |
| F027 no settings sheet, section list or stroke tokens | `NibMetrics.settingsSheetSize`, `.settingsSectionListWidth`; `NibStroke.thin`, `.thick` | F027 local constants (FeatSettings/SettingsRootViewController.swift, StylusPage.swift). The 56 pt posture cell stays local: it is one screen's layout, not a system measure |
| F028 no hairline divider token | `NibStroke.hairline`, `NibStroke.thin`; `NibPenSwatch.Size.palette.diameter` | F028 `BarLiteral` (FeatPageText/PageTextEditor.swift) |
| F039 no ruler radius (and no HUD linger, now `NibMotion.hudLinger` from the physics branch) | `NibRadius.ruler` | `NibRadius.badge` on the ruler body; `RulerAttachment.hudLinger` (FeatRuler) |
| F040 no laser metrics | `NibMetrics.laserDot`, `.laserGlow`, `.laserTrail`, `NibOpacity.laserGlow` | F040 `LaserStyle` sizes (FeatLaser/FeatLaserFeature.swift); the 0.6 s fade is a motion token (below) |
| F044 no minimap size; no selection ring | `NibMetrics.minimapSize`, `.minimapSizeCompact`; `.nibSelectionRing(_:cornerRadius:)` | F044 `MinimapGeometry.mapSize(compact:)` derived from the thumbnail width (FeatWhiteboard/MinimapView.swift) |
| F046 no row-thumbnail or indent metrics | `NibMetrics.rowThumbnailWidth`, `.outlineIndent`, `.outlineMaxDepth` | F046 `OutlineMetrics` (FeatOutline/OutlinePanel.swift) |
| Unbuilt F019, F021, F045, F050, F052, F056, F072, F073, F080, F085, F093, F108 | the §14 screen metrics, `NibOpacity.ghostInk`, `.replayPending` | – |

### 2. Palette, tools and swatches

```swift
// Components/Palette.swift
extension NibTool {
    let registersShortcut: Bool
    init(id:label:symbol:isPlugin:hasSettings:value:shortcut: KeyboardShortcut?, registersShortcut: Bool, tint:)
}
extension NibSwatch {
    let pattern: NibSwatchPattern?
    init(id: String, color: Color, name: String, ringsLight: Bool = false, ringsDark: Bool = false,
         pattern: NibSwatchPattern?)
}
extension NibPenSwatch {
    init(_ swatch: NibSwatch, pattern: NibSwatchPattern?, isSelected: Bool, size: Size = .popover, action:)
}
extension NibPenSwatch.Size { var diameter: CGFloat }
struct NibWidthPresetButton: View { init(diameter: CGFloat, isSelected: Bool, label: String, action: @escaping () -> Void) }
extension NibMetrics { static let widthPresetDots: [CGFloat]; static func widthPresetDot(_ index: Int) -> CGFloat }
extension View { func nibTooltip(_ text: String) -> some View }   // Components/Buttons.swift
// NibIconButton, NibToolButton, NibDropletButton, NibOptionTile, NibWidthPresetButton read `isEnabled` and dim to 40 %
extension NibToolPalette {
    init(id:tools:moreTools:selection:swatches:swatch:dock:allowedEdges:reservedTrailing:
         toolOptions: @escaping (String) -> NibToolOptions?, settingsPresented: Binding<Bool>? = nil,
         morePresented: Binding<Bool>? = nil, onReselect: ((String) -> Void)? = nil,
         @ViewBuilder settings: @escaping (String) -> Settings)
}
// Components/NibToolOptions.swift
struct NibToolOptions { init(bar: AnyView, popover: NibToolOptionsPopover? = nil)
                        init<Bar: View>(popover: NibToolOptionsPopover? = nil, @ViewBuilder bar: () -> Bar) }
struct NibToolOptionsPopover { init<C: View>(source: String, isPresented: Binding<Bool>, title: String,
                                             subtitle: String? = nil, @ViewBuilder content: () -> C) }
extension View { func onNibBudChange(_ action: @escaping (Bool) -> Void) -> some View
                 func nibShortcutHint(_ shortcut: KeyboardShortcut?) -> some View }
// Components/NibSwatches.swift
struct NibSwatchPattern: Hashable { init(id: String, image: UIImage, tilePoints: CGFloat = 11, name: String? = nil) }
extension NibSwatch { init(id: String, hex: UInt32, name: String, pattern: NibSwatchPattern? = nil)
                      init(ink: NibInk, pattern: NibSwatchPattern?)
                      init(highlighter:), init(paper:), init(cloth:), init(folder:) }
extension NibHighlighter, NibPaper, NibCoverCloth, NibFolderColor { var name: String }
struct NibSwatchGrid: View { init(swatches:selection: Binding<String?>, columns: Int = 6, noneLabel: String? = nil,
                                  size: NibPenSwatch.Size = .popover) }
struct NibOptionTile<Preview: View>: View { init(_ title:isSelected:action:preview:), init(_ title:symbol:isSelected:action:) }
struct NibOptionGlyph: View
extension UIImage { static func nibSwatch(_ swatch: NibSwatch, size: NibPenSwatch.Size = .palette,
                                          isSelected: Bool = false) -> UIImage }
```

| Gap | Resolved by | Replaces |
|---|---|---|
| F008 NibPenSwatch has no tape-pattern overlay | `NibSwatch(pattern:)`, `NibPenSwatch(_:pattern:…)`, `NibSwatchPattern` (the palette's quick swatches show patterns too) | F008 `PatternSwatch` (FeatPresets/ColorSlotEditor.swift). `PatternTile`'s loader stays in the feature: it produces the `UIImage` |
| F008 a tool options bar cannot bud a popover | `NibToolPalette(toolOptions:)` returning `NibToolOptions(popover:)`; the palette places the popover as a full-size child, beside the bar, and closes it on tool change | F008's inline Thickness and colour-editor modes of the bar (FeatPresets). Needs the contract change below so a `ToolMenuDescriptor` can carry the popover |
| F016 the palette reports no re-tap and hides its popover state; no public open-bud signal | `onReselect:`, `settingsPresented:`, `morePresented:`, `.onNibBudChange(_:)` | F016 `settingsBudOpen` / the `hasSettings` toggle trick and `ToolSettingsBud` (FeatToolbar/ActiveToolMenuHost.swift); the iOS 18 `hitTest` guess in FeatToolbar/ToolbarView.swift becomes "while a bud is open, keep every touch" |
| F043 no tooltips on icon and tool buttons; `NibIconButton` does not dim when disabled; no public preset-dot sizes | `nibTooltip` built into `NibIconButton`, `NibToolButton` and `NibWidthPresetButton`; those and `NibDropletButton`, `NibOptionTile` dim themselves; `NibWidthPresetButton`, `NibMetrics.widthPresetDots`; `NibStroke.hairline` for the hover-dot outline | F043's `.help(…)` and `.opacity(… disabledOpacity)` on palette buttons and `PalettePlan.dotSizes` / `widthRow` (FeatPencilHardware/SqueezePalette.swift). Drop the hand dimming when merging: it would now dim twice |
| F016 tool keys register twice | `NibTool(shortcut:registersShortcut: false)` + `nibShortcutHint` | F016's `shortcut: nil` on palette tools, which hid the KeyHints |
| F009, F008, F026, F036, F044 local colour-name tables | `NibHighlighter.name`, `NibPaper.name`, `NibCoverCloth.name`, `NibFolderColor.name` | F009 `NibHighlighter.title` (FeatHighlighter/HighlighterTool.swift), F008 `highlighterName`, F026 `highlighterName` / `paperName`, F044 `BoardPaper.title`. F036's sticky colours are its own palette and keep their names |
| F028, F026 no UIKit swatch image | `UIImage.nibSwatch(_:size:isSelected:)` (light and dark in one asset, pattern included) | F028 `PageTextBar.swatch(_:ring:)`, F026 `swatchImage(_:)` |
| Unbuilt F007, F013, F031, F033, F036, F040 colour and choice grids | `NibSwatchGrid`, `NibOptionTile` | – |

### 3. Controls, badges and library

```swift
extension NibButton.Kind { case destructivePlain }
extension NibBadgeKind { case principal(NibPrincipalKind); case capsule(String) }
enum NibPrincipalKind: String, CaseIterable, Sendable { case you, assistant, plugin, bridge, collaborator
                                                        init(_ principal: Principal); var title: String; var symbol: NibSymbol }
extension NibStrokeWidthSlider { enum Unit { case millimetres, points }
                                 init(width:range:presets:title: String, unit: Unit) }
extension NibProgressBar { enum Style { case standard, critical }; init(value: Double, style: Style) }
extension NibFolderTile { init(name:count:color:glyph: NibFolderGlyph, isTargeted:isFused:) }
enum NibFolderGlyph: Hashable, Sendable { case symbol(NibSymbol), emoji(String) }
struct NibFolderGlyphView: View { init(glyph:color:size:) }
```

| Gap | Resolved by | Replaces |
|---|---|---|
| F010 NibStrokeWidthSlider is millimetres-only and titled "Thickness" | `NibStrokeWidthSlider(width:range:presets:title:unit: .points)` | F010's hand-built size presets (FeatEraser/EraserSettingsView.swift) |
| F010 no destructive plain button | `NibButton(kind: .destructivePlain)` | `NibButton(.destructive)` for Clear Page (FeatEraser) |
| F015 NibBadge has no principal kind | `NibBadge(.principal(NibPrincipalKind(principal)))` | F015 `PrincipalBadge` and `HistoryPrincipal.Kind.title/.symbol` (FeatUndoUI/HistoryPanel.swift) |
| F020 NibFolderTile has no icon or emoji | `NibFolderTile(glyph:)`, `NibFolderGlyphView` | F020's own Favourites tile and `FolderGlyph` (FeatLibraryOrganize/FeatLibraryOrganizeFeature.swift, FavoritesPanel.swift) |
| F062 NibProgressBar has no critical tint | `NibProgressBar(value:style: .critical)` | F062 `TimeKeeperProgress` (FeatTimeKeeper) |
| Unbuilt F080 "Update" capsule; F013 "Made by Assistant" | `NibBadge(.capsule("Update"))`, `NibPrincipalKind.title` | – |

### 4. New components

```swift
// Components/NibStatus.swift
struct NibHUDGroup<Content: View>: View { init(id: String, @ViewBuilder content: () -> Content) }
struct NibHUDText: View { init(_ primary: String, secondary: String? = nil) }
struct NibStatusDot: View { enum Kind { case unseen, connected, recording, warning }; init(_ kind: Kind) }
struct NibPresenceStack: View { struct Person { init(id:name:initials:colorIndex:) }; init(_ people: [Person], compact: Bool = false) }
struct NibWaveform: View { init(levels: [Double], bars: Int = 24, height: CGFloat = 20) }
struct NibBanner: View { enum Style { case info, warning }
                         init(_ message: String, style: Style = .warning, symbol: NibSymbol? = nil, action: NibAction? = nil) }
struct NibTraceRow: View { enum Phase { case running, done, warning }; init(_ text: String, phase: Phase) }
struct NibDropletButton: View { enum Kind { case clear, tinted }
                                init(id:title:symbol:detail:kind:shortcut:action:), init(id:symbol:label:kind:shortcut:action:) }
// Components/NibForms.swift
struct NibSecureField: View { init(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {}) }
struct NibCodeBlock: View { init(_ text: String, onCopy: (() -> Void)? = nil) }
struct NibQRCode: View { init(_ payload: String, label: String) }
struct NibPermissionRow<Accessory: View>: View { enum Change { case unchanged, added, removed }
                                                 init(_ text:symbol:change:accessory:), init(_ text:symbol:change:) }
// Components/NibLists.swift
struct NibOutlineRow<Leading: View>: View { init(_ title:depth:pageLabel:isSelected:isExpanded:reservesDisclosure:leading:) }
struct NibMiniPageThumbnail<Content: View>: View { init(aspectRatio:width:content:) }
struct NibPaperTile<Content: View>: View { init(name:isSelected:size:action:content:) }
struct NibFlashcard<Front: View, Back: View>: View { init(isFlipped:fill:front:back:) }
extension View { func nibSelectionRing(_ isSelected: Bool, cornerRadius: CGFloat) -> some View
                 func nibFadeBottomEdge(_ height: CGFloat = NibSpacing.l) -> some View }
// Components/NibFloatingHost.swift
@MainActor @Observable final class NibFloatingHost {
    init(); var toast: NibToastItem?; var toastBinding: Binding<NibToastItem?> { get }
    func present<C: View>(_ id: String, @ViewBuilder content: () -> C); func dismiss(_ id: String)
    func isPresenting(_ id: String) -> Bool; var presentedIDs: [String] { get }
    func setAnchor(_ id: String, rect: CGRect); @discardableResult func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool
    func removeAnchor(_ id: String); func containerRect(_ rect: CGRect, from view: UIView) -> CGRect?
    func post(_ toast: NibToastItem)
}
struct NibFloatingLayer: View { init(host: NibFloatingHost) }
// Components/NibCanvasHandles.swift (UIKit)
final class NibHandleView: UIView { enum Style { case clear, tinted }; var style: Style; init(style: Style = .clear) }
final class NibFrameView: UIView { init(frame: CGRect) }
// Components/NibPageThumbnailView.swift (UIKit) and Components/Library.swift
final class NibPageThumbnailView: UIView { var image: UIImage?; var isCurrent: Bool; var aspectRatio: CGFloat; var width: CGFloat
                                           init(width: CGFloat = NibMetrics.rowThumbnailWidth, aspectRatio: CGFloat = 595.0 / 842.0) }
extension NibPageThumbnail { init(number:isCurrent:isSelected:aspectRatio:width:showsNumber: Bool, content:) }
// Components/NibWebTokens.swift
enum NibWebTokens { static func stylesheet(for traits: UITraitCollection) -> String
                    static func variables(for traits: UITraitCollection) -> [(name: String, value: String)] }
```

| Gap | Resolved by | Replaces |
|---|---|---|
| NibBudPopover and droplets are unreachable from UIKit code and canvas attachments (F026 keyboard-bar popovers, F029 return pill, F037 thread popover, F038 zoom frame, F039 angle HUD, F044 minimap, F052 recording HUD and audio bar, F062 Time Keeper bar, F063 presenter HUD) and `nibToast` needs a container (F020) | `NibFloatingHost` + `NibFloatingLayer`: present by id, bud from a UIKit rect (`setAnchor(_:rect:in:)`), `post(toast)` | The system UIKit popover (F026), the static `nibGlass` HUDs hosted in the canvas (F029, F039, F062, F063), F037's floating Deep panel for one thread, F038's rigid UIKit box, F020's VoiceOver-only announcements. Needs the chrome to install the layer (below) |
| F038, F012 a canvas attachment cannot put a `frame` or `handle` droplet on the canvas | `NibHandleView` (rigid 12 pt bead, `clear` or `tinted`), `NibFrameView` (rim and water line, radius 18); `NibMetrics.handleBead`, `.rotationHandleOffset`, `.zoomPaneHeight`, `.popoverContentWidth`; `NibStroke.emphasis` / `.thin` for the 1.5 / 1 pt outlines | F038's UIKit box (FeatZoomWindow, accent outline over `accentWash`) and its local pane metrics; F012's CALayer beads (FeatTransform/SelectionHandles.swift) |
| F046 no hierarchical row, no 40 pt thumbnail without a number, no UIKit thumbnail | `NibOutlineRow`, `NibMiniPageThumbnail`, `NibPageThumbnail(…, showsNumber: false)`, `NibPageThumbnailView` (UIKit cells) | F046 `BookmarkRowView` and `PageThumbnailImage` (FeatOutline/OutlinePanel.swift) and the thumbnail layers of its UIKit `OutlineCell`, which keeps the drag table and takes `NibMetrics.outlineIndent` / `.rowThumbnailWidth` / `NibUIFont` |
| F052, F056, F063, F091, F108 HUDs with several parts | `NibHUDGroup`, `NibHUDText`, `NibStatusDot`, `NibWaveform` | F052's recorder row in the Audio tab, F063's `presentation.hud` content |
| Unbuilt F019, F021, F045, F050, F070, F071, F072, F076, F079, F080, F081, F085, F086, F091, F094, F103, F108 | `NibDropletButton`, `NibBanner`, `NibTraceRow`, `NibSecureField`, `NibCodeBlock`, `NibQRCode`, `NibPermissionRow`, `NibPresenceStack`, `NibPaperTile`, `nibSelectionRing`, `nibFadeBottomEdge`, `NibFlashcard`, `NibOutlineRow`, `NibWebTokens` (plugin HTML panels' `--nib-*` variables, DESIGN.md §14.10) | – |

### 5. Localisation

`Localizable.xcstrings` now lists every `String(localized:bundle: .module)` key of the module (157, with format specifiers as Swift emits them: `%@`, `%lld`), with translator comments on the colour, paper, cloth and principal names and the unit strings, so F095 can translate the design system's own strings.

### 6. What still needs another owner

| Needed change | Owner | For |
|---|---|---|
| `ToolMenuDescriptor` (or `ToolbarItemDescriptor.activeToolMenu`) carries an optional popover: `source` anchor id, `title`, `isPresented`, content; F016 passes it as `NibToolOptions(popover:)` | NibContracts, then F016 | F008 |
| A per-window accessor for the chrome's `NibFloatingHost` and `NibInkingState` (a `ServiceKeys` constant or `DocumentEditing` properties) | NibContracts | F012, F016, F026, F029, F037, F038, F039, F044, F052, F062, F063 |
| Install `NibFloatingLayer(host:)` in the document chrome's container and present `host.toastBinding`; the library root does the same for its container | F017, F019 | as above, F020 |
| A SwiftUI `ui.screens.toolbar` rendered inside the chrome's one container (the palette's second container cannot merge or share buds) | NibContracts, F016, F017 | F016 |
| A public inking input for a lone `nibGlass` surface outside a container (`nibIsInking` is internal) | Glass optics (Modifiers/NibSurfaces.swift, Liquid/NibLiquid.swift) | F062, F044 |
| A pure-black letterbox colour token (`#000000`) for external displays | Glass optics (Tokens/NibColor.swift) | F063 |
| Droplets that follow a canvas transform per frame (a refracting, stretching zoom frame on the canvas); `NibHandleView` / `NibFrameView` draw the rigid look with the water tokens meanwhile | Glass optics | F012, F038 |
| Gallery entries for every v2 component and token | Glass optics (Gallery/**) | DESIGN.md §13 "every state is in the gallery" |
| `NibMotion.laserFadeDuration` (0.6 s as a `TimeInterval` for CALayer fades; `laserFade` is only a SwiftUI `Animation`). `NibMotion.hudLinger` (F039) landed with the physics branch | Drag physics (Tokens/NibMotion.swift) | F040 |
| A Pencil Pro alignment haptic features may request (`UICanvasFeedbackGenerator.alignmentOccurred(at:)` behind `NibHaptics`) | Drag physics (Tokens/NibHaptics.swift) | F030, F039, F043 |
| Move `nibShortcutHint` beside `nibShortcut` in Modifiers/NibInteraction.swift (it lives in Components/NibToolOptions.swift until then) | Drag physics | – |
| DESIGN.md §14.11 puts caption2 on the Clear grading droplets, which §2.4 bans; `NibDropletButton` uses caption1 semibold `label`. §14.12 (laser `destructive`) and §14.3 (Vermilion default) disagree | DESIGN.md §14 owner | F050, F040 |
