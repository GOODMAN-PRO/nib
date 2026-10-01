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
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = NibMetrics.popoverMaxHeight
    @Environment(DropletField.self) private var field: DropletField?

    public init(title: String, subtitle: String? = nil, width: CGFloat = NibMetrics.popoverWidth,
                maxHeight: CGFloat = NibMetrics.popoverMaxHeight, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.maxHeight = maxHeight
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: min(width, viewport.width))
        .frame(height: min(contentHeight, maxHeight, NibMetrics.popoverMaxHeight, viewport.height))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var viewport: CGSize {
        guard let bounds = field?.bounds, NibGeometry.isUsable(bounds) else {
            return CGSize(width: width, height: maxHeight)
        }
        return CGSize(width: max(0, bounds.width - 2 * NibMetrics.chromeInset),
                      height: max(0, bounds.height - 2 * NibMetrics.chromeInset))
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
            let bounds = CGRect(x: frame.minX + safe.leading, y: frame.minY + safe.top,
                                width: max(0, frame.width - safe.leading - safe.trailing),
                                height: max(0, frame.height - safe.top - safe.bottom))
            let available = placement.availableSize(beside: anchor, gap: gap, in: bounds)
            let centre = placement.centre(size: size, beside: anchor, gap: gap, in: bounds)
            NibPopoverPanel(title: title, subtitle: subtitle, width: min(width, available.width),
                            maxHeight: available.height) { content }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .droplet(id, style: .popover)
                .budsFrom(source, isPresented: $isPresented)
                .position(x: centre.x - frame.minX, y: centre.y - frame.minY)
        }
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
            chrome(content)
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
            HStack(spacing: 0) {
                menu
                NibIconButton(.xmark, label: String(localized: "Close \(title)", bundle: .module), size: .round,
                              action: onClose)
            }
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
