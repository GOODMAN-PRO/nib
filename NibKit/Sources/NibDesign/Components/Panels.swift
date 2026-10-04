import SwiftUI
import UIKit

/// Popover content chrome on Deep water: title (headline) and optional subtitle, 16 pt insets, scrolls past 520 pt.
/// Put it in a droplet: `.droplet(id, style: .popover).budsFrom(source, isPresented:)`, or use `NibBudPopover`.
/// One ScrollView that only bounces when it must: the content keeps its identity (and its @State and focus) when it
/// crosses 520 pt.
public struct NibPopoverPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let content: Content
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = NibMetrics.popoverMaxHeight
    @Environment(DropletField.self) private var field: DropletField?
    @Environment(\.nibBud) private var bud

    public init(title: String, subtitle: String? = nil, width: CGFloat = NibMetrics.popoverWidth,
                maxHeight: CGFloat = NibMetrics.popoverMaxHeight, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.maxHeight = maxHeight
        self.content = content()
    }

    public var body: some View {
        let isPresented = bud?.isPresented.wrappedValue ?? true
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
            // Empty insets and gaps are part of the scrolling surface. Without a
            // hit shape, a drag there can reach chrome or the outside-tap catcher.
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // A native viewport can round the same content to adjacent fractional
                // heights. Feeding that noise into its own frame restarts layout forever.
                if abs(height - contentHeight) > 0.5 { contentHeight = height }
            }
            .background(PopoverScrollInteraction(isPresented: isPresented))
        }
        // Gate the native scroll host at its source, not only the animated droplet around it.
        // UIKit can rebuild/re-enable that host during a glass or layout update. A closed
        // menu must immediately stop intercepting Library, width slots and other menus,
        // even while its retained content is still animating out.
        .scrollDisabled(!isPresented)
        .allowsHitTesting(isPresented)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: min(width, viewport.width))
        .frame(height: min(contentHeight, maxHeight, NibMetrics.popoverMaxHeight, viewport.height))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHidden(!isPresented)
    }

    private var viewport: CGSize {
        guard let bounds = field?.bounds, NibGeometry.isUsable(bounds) else {
            return CGSize(width: width, height: maxHeight)
        }
        return CGSize(width: max(0, bounds.width - 2 * NibMetrics.chromeInset),
                      height: max(0, bounds.height - 2 * NibMetrics.chromeInset))
    }
}

/// SwiftUI can keep a hidden popover's native scroll view above neighbouring controls.
/// Disable that UIKit hit target as well as the droplet's SwiftUI gestures, retaining its closing animation.
struct PopoverScrollInteraction: UIViewRepresentable {
    let isPresented: Bool
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.isPresented = isPresented
        view.updateScrollView()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.retire()
    }
    final class Probe: UIView {
        private static let owners = NSMapTable<UIScrollView, Probe>.weakToWeakObjects()
        var isPresented = true
        private var retired = false
        private weak var scrollHost: UIScrollView?
        private var hideAfterFade: DispatchWorkItem?
        override func didMoveToWindow() { super.didMoveToWindow(); updateScrollView() }
        override func layoutSubviews() { super.layoutSubviews(); updateScrollView() }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
        func retire() {
            // Removing a floating entry can detach the probe before its closing
            // task fires. Retire the native container while we still own it;
            // SwiftUI may retain it for a transition after the content is gone.
            retired = true
            isPresented = false
            hideAfterFade?.cancel()
            hideAfterFade = nil
            guard let scrollHost, Self.owners.object(forKey: scrollHost) === self else { return }
            scrollHost.endEditing(true)
            scrollHost.isUserInteractionEnabled = false
            scrollHost.accessibilityElementsHidden = true
            scrollHost.isHidden = true
        }
        func updateScrollView() {
            guard !retired else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    // SwiftUI can temporarily reuse one native scroll container
                    // across retained buds during rotation or replacement. A
                    // closing probe must not reclaim it from the visible bud.
                    if !isPresented, let owner = Self.owners.object(forKey: scroll),
                       owner !== self, owner.isPresented { return }
                    if scrollHost !== scroll {
                        hideAfterFade?.cancel()
                        hideAfterFade = nil
                        scrollHost = scroll
                    }
                    Self.owners.setObject(self, forKey: scroll)
                    // A retained closing popover must also release its text
                    // responder, so subsequent hardware keys reach the editor.
                    if !isPresented { scroll.endEditing(true) }
                    scroll.isUserInteractionEnabled = isPresented
                    scroll.accessibilityElementsHidden = !isPresented
                    if !isPresented && (scroll.bounds.isEmpty || scroll.frame.isInfinite || scroll.frame.isNull) {
                        // A collapsed native host has no visible fade to preserve.
                        // Hide it before accessibility asks UIKit for an invalid hit point.
                        hideAfterFade?.cancel()
                        hideAfterFade = nil
                        scroll.isHidden = true
                    }
                    if isPresented {
                        hideAfterFade?.cancel()
                        hideAfterFade = nil
                        scroll.isHidden = false
                    } else if !scroll.isHidden, hideAfterFade == nil {
                        // accessibilityElementsHidden hides children, but UIKit can
                        // still expose the scroll container itself after the bud's
                        // transform collapses its frame. Retain the view/offset and
                        // the 120 ms closing fade (DESIGN §10.6), then hide it natively.
                        let work = DispatchWorkItem { [weak self, weak scroll] in
                            guard let self, let scroll, !self.isPresented,
                                  Self.owners.object(forKey: scroll) === self else { return }
                            scroll.isHidden = true
                            self.hideAfterFade = nil
                        }
                        hideAfterFade = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
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

    private var opposite: Self {
        switch self {
        case .below: return .above
        case .above: return .below
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    private func insetBounds(_ bounds: CGRect) -> CGRect {
        let bounds = NibGeometry.rect(bounds)
        let inset = NibMetrics.chromeInset
        return CGRect(x: bounds.minX + min(inset, bounds.width / 2),
                      y: bounds.minY + min(inset, bounds.height / 2),
                      width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - 2 * inset))
    }

    private func room(beside anchor: CGRect, gap: CGFloat, in bounds: CGRect) -> CGFloat {
        switch self {
        case .below: return max(0, bounds.maxY - anchor.maxY - gap)
        case .above: return max(0, anchor.minY - bounds.minY - gap)
        case .leading: return max(0, anchor.minX - bounds.minX - gap)
        case .trailing: return max(0, bounds.maxX - anchor.maxX - gap)
        }
    }

    /// Constrain the scrolling viewport before measuring it, choosing the larger side if necessary.
    func availableSize(beside anchor: CGRect, gap: CGFloat, in bounds: CGRect) -> CGSize {
        let anchor = NibGeometry.rect(anchor), gap = max(0, NibGeometry.finite(gap))
        let b = insetBounds(bounds)
        let room = max(room(beside: anchor, gap: gap, in: b), opposite.room(beside: anchor, gap: gap, in: b))
        switch self {
        case .below, .above: return CGSize(width: b.width, height: min(b.height, room))
        case .leading, .trailing: return CGSize(width: min(b.width, room), height: b.height)
        }
    }

    /// Geometry measurement arrives after layout. Fit the cached measurement
    /// before positioning too, so a newly shown keyboard cannot push a focused
    /// popover below its smaller scrolling viewport for that first layout.
    func fittedSize(_ measured: CGSize, beside anchor: CGRect, gap: CGFloat, in bounds: CGRect) -> CGSize {
        let available = availableSize(beside: anchor, gap: gap, in: bounds)
        let measured = NibGeometry.size(measured)
        return CGSize(width: min(measured.width, available.width), height: min(measured.height, available.height))
    }

    /// Prefer the requested side, flip when it cannot fit, then clamp both axes to the chrome inset.
    func centre(size: CGSize, beside anchor: CGRect, gap: CGFloat, in bounds: CGRect,
                alignment: Alignment = .top) -> CGPoint {
        let size = NibGeometry.size(size), anchor = NibGeometry.rect(anchor)
        let gap = max(0, NibGeometry.finite(gap)), b = insetBounds(bounds)
        let extent = (self == .below || self == .above) ? size.height : size.width
        let preferred = room(beside: anchor, gap: gap, in: b)
        let alternate = opposite.room(beside: anchor, gap: gap, in: b)
        let side = preferred < extent && alternate > preferred ? opposite : self
        let sideY = alignment == .top ? anchor.minY - NibSpacing.l + size.height / 2 : anchor.midY
        var c: CGPoint
        switch side {
        case .below: c = CGPoint(x: anchor.midX, y: anchor.maxY + gap + size.height / 2)
        case .above: c = CGPoint(x: anchor.midX, y: anchor.minY - gap - size.height / 2)
        case .trailing: c = CGPoint(x: anchor.maxX + gap + size.width / 2, y: sideY)
        case .leading: c = CGPoint(x: anchor.minX - gap - size.width / 2, y: sideY)
        }
        func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, extent: CGFloat) -> CGFloat {
            guard extent <= upper - lower else { return (lower + upper) / 2 }
            return Swift.min(Swift.max(value, lower + extent / 2), upper - extent / 2)
        }
        c.x = clamp(c.x, min: b.minX, max: b.maxX, extent: size.width)
        c.y = clamp(c.y, min: b.minY, max: b.maxY, extent: size.height)
        return NibGeometry.point(c)
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
    @State private var keyboardFrame: CGRect?

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
        GeometryReader { proxy in
            let gap = sizeClass == .compact ? NibMetrics.popoverGapCompact : NibMetrics.popoverGap
            let anchor = field?.anchorRect(source) ?? .zero
            let frame = proxy.frame(in: NibLiquid.space)
            let safe = proxy.safeAreaInsets
            let safeBounds = CGRect(x: frame.minX + safe.leading, y: frame.minY + safe.top,
                                width: max(0, frame.width - safe.leading - safe.trailing),
                                height: max(0, frame.height - safe.top - safe.bottom))
            let bounds = PopoverKeyboardViewport.available(in: safeBounds,
                keyboard: keyboardFrame?.offsetBy(dx: frame.minX, dy: frame.minY))
            let available = placement.availableSize(beside: anchor, gap: gap, in: bounds)
            let fitted = placement.fittedSize(size, beside: anchor, gap: gap, in: bounds)
            let centre = placement.centre(size: fitted, beside: anchor, gap: gap, in: bounds)
            NibPopoverPanel(title: title, subtitle: subtitle, width: min(width, available.width),
                            maxHeight: available.height) { content }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .droplet(id, style: .popover)
                .budsFrom(source, isPresented: $isPresented)
                .position(x: centre.x - frame.minX, y: centre.y - frame.minY)
        }
        .background(PopoverKeyboardOcclusionReader(frame: $keyboardFrame))
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
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
                    .nibCommand(action.command)
                    .nibInspectorAction(action.handler)
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
    let primaryCommand: String?

    /// `cancelTitle` nil = "Cancel" (a default argument cannot read the internal `Bundle.module`).
    public init(_ title: String, cancelTitle: String? = nil,
                primaryTitle: String? = nil, isPrimaryEnabled: Bool = true, onCancel: @escaping () -> Void,
                onPrimary: @escaping () -> Void = {}, primaryCommand: String? = nil) {
        self.title = title
        self.cancelTitle = cancelTitle ?? String(localized: "Cancel", bundle: .module)
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.primaryCommand = primaryCommand
    }

    public var body: some View {
        HStack(spacing: NibSpacing.m) {
            Button(cancelTitle, action: onCancel)
                .accessibilityIdentifier("sheet.dismiss")
                .font(NibFont.body)
                .foregroundStyle(NibColor.accent)
                .buttonStyle(.plain)
                .frame(minHeight: NibMetrics.hitTarget)
                .keyboardShortcut(.cancelAction)
                .nibNativeAction(onCancel)
            Text(title)
                .font(NibFont.title3)
                .foregroundStyle(NibColor.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            if let primaryTitle {
                NibButton(primaryTitle, kind: .primary, size: .compact, shortcut: .defaultAction, action: onPrimary)
                    .nibCommand(primaryCommand)
                    .nibNativeAction(onPrimary)
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

    /// Item-driven sheets use the same sizing and opaque chrome as Boolean-driven sheets.
    func nibSheet<Item: Identifiable, SheetContent: View>(item: Binding<Item?>,
                                                         @ViewBuilder content: @escaping (Item) -> SheetContent) -> some View {
        sheet(item: item) { item in
            content(item).modifier(NibSheetChrome())
        }
    }
}

struct NibSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            NibSheetContentLayout {
                chrome(content)
            }
            .presentationSizing(.form.fitted(horizontal: true, vertical: true))
        } else {
            chrome(content)
        }
    }

    @ViewBuilder private func chrome(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .presentationCornerRadius(NibRadius.sheet)
                .presentationBackground(NibColor.backgroundSecondary)
        }
    }
}

/// Native lists have no useful intrinsic height. Give flexible content a form-sized
/// proposal during ideal sizing, without imposing that height on an intrinsic sheet
/// (or on the finite viewport supplied by a keyboard or a smaller window).
private struct NibSheetContentLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        if let height = proposal.height, height.isFinite {
            return content.sizeThatFits(proposal)
        }
        let intrinsic = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let form = content.sizeThatFits(ProposedViewSize(width: proposal.width,
                                                       height: NibMetrics.newDocumentSheetSize.height))
        // A fixed-height view returns the same size for both proposals. A List/ScrollView
        // expands to fill the form proposal instead of collapsing to its ~10 pt ideal.
        return form.height > intrinsic.height ? form : intrinsic
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
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

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        glyph
                        heading.fixedSize(horizontal: true, vertical: true)
                        Spacer(minLength: NibSpacing.s)
                        controls
                    }
                    stacked
                }
            }
        }
        .padding(.leading, NibSpacing.l)
        .padding(.trailing, NibSpacing.xs)
        .padding(.vertical, NibSpacing.s)
        .frame(minHeight: 60)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack {
                glyph
                Spacer(minLength: NibSpacing.s)
                controls
            }
            heading
                .padding(.trailing, NibSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var glyph: some View {
        Image(nib: symbol)
            .font(NibFont.glyph(.round))
            .foregroundStyle(NibColor.label)
            .frame(width: 30, height: 30)
            .background(NibColor.fill3, in: Circle())
            .accessibilityHidden(true)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: NibSpacing.s) {
                Text(title)
                    .font(NibFont.headline)
                    .foregroundStyle(NibColor.label)
                    .accessibilityAddTraits(.isHeader)
                if let badge { NibBadge(badge) }
            }
            if let subtitle {
                Text(subtitle)
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            menu
            NibIconButton(.xmark, label: String(localized: "Close \(title)", bundle: .module), size: .round,
                          action: onClose)
                .accessibilityIdentifier("cmd.panel.close")
        }
    }
}

public extension NibPanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: NibSymbol, badge: NibBadgeKind? = nil,
         onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, badge: badge, onClose: onClose) { EmptyView() }
    }
}

/// Chrome Nib draws around a plugin panel: `NibPanelHeader` with the "Plugin" badge and More (Reload, Permissions,
/// Report a problem). The plugin draws only inside `content`, and never draws its own glass.
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
                    Button(String(localized: "Report a problem", bundle: .module), action: onReport)
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

// Keep popover geometry and its UIKit reader together with their host.
private enum PopoverKeyboardViewport {
    static func available(in bounds: CGRect, keyboard: CGRect?) -> CGRect {
        // UIKit can send an absent/invalid frame while moving a floating
        // keyboard between scenes. It must not collapse every open popover.
        guard let keyboard, !keyboard.isNull, !keyboard.isInfinite, !keyboard.isEmpty,
              keyboard.minX.isFinite, keyboard.minY.isFinite,
              keyboard.width.isFinite, keyboard.height.isFinite,
              keyboard.intersects(bounds) else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                      height: max(0, min(bounds.maxY, keyboard.minY) - bounds.minY))
    }
}

/// Keyboard occlusion in the containing view's coordinates, including windowed iPad scenes.
private struct PopoverKeyboardOcclusionReader: UIViewRepresentable {
    @Binding var frame: CGRect?

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = { frame = $0 }
        return probe
    }
    func updateUIView(_ view: Probe, context: Context) { view.changed = { frame = $0 } }

    final class Probe: UIView {
        var changed: ((CGRect?) -> Void)?
        private var screenFrame: CGRect?
        private var reported: CGRect?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyboard(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hideKeyboard(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        @objc private func updateKeyboard(_ notification: Notification) {
            screenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            report()
        }
        @objc private func hideKeyboard(_ notification: Notification) { screenFrame = nil; report() }
        private func report() {
            guard let window else { return }
            let next = screenFrame.map { convert(NibKeyboardGeometry.frame($0, in: window), from: window) }
            guard reported != next else { return }
            reported = next
            DispatchQueue.main.async { [weak self] in self?.changed?(next) }
        }
    }
}
