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
