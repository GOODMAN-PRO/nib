import SwiftUI

/// What `NibToolPalette(toolOptions:)` shows for the active tool (DESIGN.md §13.3): the options bar fused to the
/// palette and, optionally, one popover budded from a control inside that bar. The bar's droplet clips its content,
/// so a popover cannot live inside it; the palette places this one as a full-size child of the container instead.
public struct NibToolOptions {
    public let bar: AnyView
    public let popover: NibToolOptionsPopover?

    public init(bar: AnyView, popover: NibToolOptionsPopover? = nil) {
        self.bar = bar
        self.popover = popover
    }

    public init<Bar: View>(popover: NibToolOptionsPopover? = nil, @ViewBuilder bar: () -> Bar) {
        self.bar = AnyView(bar())
        self.popover = popover
    }
}

/// A popover that buds from a `nibBudAnchor(source)` inside the options bar: a thickness slider, a colour editor.
/// It is a Deep `NibPopoverPanel`, as wide as the tool's settings popover, placed beside the bar by the palette's own
/// rule. One popover at a time: open it only while the settings popover is closed.
public struct NibToolOptionsPopover {
    public let source: String
    public let isPresented: Binding<Bool>
    public let title: String
    public let subtitle: String?
    public let content: AnyView

    public init<Content: View>(source: String, isPresented: Binding<Bool>, title: String, subtitle: String? = nil,
                               @ViewBuilder content: () -> Content) {
        self.source = source
        self.isPresented = isPresented
        self.title = title
        self.subtitle = subtitle
        self.content = AnyView(content())
    }
}

public extension View {
    /// Calls `action` with true when a bud (a popover, the More grid, a budded menu) opens anywhere in the enclosing
    /// `NibDropletContainer`, and with false once the last one has closed. While a bud is open a touch outside it only
    /// dismisses it (DESIGN.md §10.6), so a UIKit host that forwards touches to the canvas must stop doing so.
    /// Outside a container it reports false once.
    func onNibBudChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(NibBudChangeModifier(action: action))
    }

    /// Shows `shortcut` as a `KeyHint` below the control after 500 ms of hover and while ⌘ is held, without
    /// registering it: for controls whose key command the shell already registers (the palette's tool keys).
    /// `nibShortcut(_:)` registers and shows. `nil` does nothing.
    func nibShortcutHint(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(NibShortcutHintModifier(shortcut: shortcut))
    }
}

struct NibBudChangeModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(DropletField.self) private var field: DropletField?

    func body(content: Content) -> some View {
        content.onChange(of: field?.hasOpenBud ?? false, initial: true) { _, open in action(open) }
    }
}

struct NibShortcutHintModifier: ViewModifier {
    let shortcut: KeyboardShortcut?
    @Environment(\.nibShowsKeyHints) private var commandHeld
    @State private var hovered = false
    @State private var hoverWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
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
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(NibMotion.fade, value: commandHeld || hovered)
    }
}
