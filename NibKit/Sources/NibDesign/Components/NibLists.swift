import SwiftUI

// MARK: - Outline rows

/// A row of an outline or any hierarchical list (DESIGN.md §14.4 Outline and Bookmarks, §14.17 text-document
/// outline): indented 16 pt per level (deeper levels stop indenting at `NibMetrics.outlineMaxDepth`), an optional
/// disclosure chevron, an optional leading preview (a `NibMiniPageThumbnail`), the title in body, the page in hud type.
/// Selected on `fill3` (radius 10). At least 44 pt. It lives on opaque or Deep surfaces, never on Clear.
public struct NibOutlineRow<Leading: View>: View {
    let title: String
    let depth: Int
    let pageLabel: String?
    let isSelected: Bool
    let isExpanded: Binding<Bool>?
    let reservesDisclosure: Bool
    let leading: Leading

    /// - Parameters:
    ///   - depth: 1 is the top level.
    ///   - isExpanded: shows the chevron; nil for a leaf.
    ///   - reservesDisclosure: keeps the chevron's room on leaves so titles line up in a tree; false in flat lists.
    public init(_ title: String, depth: Int = 1, pageLabel: String? = nil, isSelected: Bool = false,
                isExpanded: Binding<Bool>? = nil, reservesDisclosure: Bool = true,
                @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.depth = depth
        self.pageLabel = pageLabel
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.reservesDisclosure = reservesDisclosure
        self.leading = leading()
    }

    /// The leading indent of a row at `depth`.
    static func indent(depth: Int) -> CGFloat {
        CGFloat(min(max(depth, 1), NibMetrics.outlineMaxDepth) - 1) * NibMetrics.outlineIndent
    }

    /// The chevron's visual width; its hit area is widened to 44 without moving the layout.
    static var disclosureWidth: CGFloat { 28 }

    public var body: some View {
        HStack(spacing: NibSpacing.s) {
            if let isExpanded {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    Image(nib: isExpanded.wrappedValue ? .chevronDown : .forward)
                        .font(NibFont.footnoteEmphasis)
                        .foregroundStyle(NibColor.labelSecondary)
                        .frame(width: Self.disclosureWidth, height: NibMetrics.hitTarget)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded.wrappedValue ? String(localized: "Collapse \(title)", bundle: .module)
                                                            : String(localized: "Expand \(title)", bundle: .module))
            } else if reservesDisclosure {
                Color.clear
                    .frame(width: Self.disclosureWidth, height: 1)
                    .accessibilityHidden(true)
            }
            leading
            Text(title)
                .font(isSelected ? NibFont.bodyEmphasis : NibFont.body)
                .foregroundStyle(NibColor.label)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pageLabel {
                Text(pageLabel)
                    .font(NibFont.hud)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .padding(.leading, NibSpacing.xs + Self.indent(depth: depth))
        .padding(.trailing, NibSpacing.m)
        .frame(minHeight: NibMetrics.hitTarget)
        .background(isSelected ? NibColor.fill3 : Color.clear,
                    in: RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public extension NibOutlineRow where Leading == EmptyView {
    init(_ title: String, depth: Int = 1, pageLabel: String? = nil, isSelected: Bool = false,
         isExpanded: Binding<Bool>? = nil, reservesDisclosure: Bool = true) {
        self.init(title, depth: depth, pageLabel: pageLabel, isSelected: isSelected, isExpanded: isExpanded,
                  reservesDisclosure: reservesDisclosure) { EmptyView() }
    }
}

/// A page render small enough for a row (DESIGN.md §14.4: bookmark rows carry a 40 pt thumbnail): radius 4, paper
/// elevation, no number. Decorative for VoiceOver; the row says which page it is.
public struct NibMiniPageThumbnail<Content: View>: View {
    let aspectRatio: CGFloat
    let width: CGFloat
    let content: Content

    public init(aspectRatio: CGFloat = 595.0 / 842.0, width: CGFloat = NibMetrics.rowThumbnailWidth,
                @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.width = width
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: width, height: width / max(aspectRatio, 0.01))
            .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
            .nibElevation(.paper)
            .accessibilityHidden(true)
    }
}

// MARK: - Choosable papers and covers

public extension View {
    /// The selection ring (DESIGN.md §14.6): 2 pt accent, 3 pt outside a shape of `cornerRadius`, concentric with it.
    /// The current page, the chosen paper, cover or app icon: one selection language per sheet.
    func nibSelectionRing(_ isSelected: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius + NibStroke.ringOutset, style: .continuous)
                    .strokeBorder(NibColor.accent, lineWidth: NibStroke.ring)
                    .padding(-NibStroke.ringOutset)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Fades the bottom `height` points of scrolling content (DESIGN.md §14.6: a cut-off row reads as "more below",
    /// not as a clipping bug). A mask, so it works on any background.
    func nibFadeBottomEdge(_ height: CGFloat = NibSpacing.l) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [Color.black, Color.clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
        }
    }
}

/// A paper, template or cover to choose (DESIGN.md §14.6): its render (radius 4, paper elevation) and its name below;
/// selected: the accent selection ring and the name in accent. 104 × 135 in the paper grid; pass
/// `NibMetrics.coverStripSize` for the cover strip.
public struct NibPaperTile<Content: View>: View {
    let name: String
    let isSelected: Bool
    let size: CGSize
    let action: () -> Void
    let content: Content

    public init(name: String, isSelected: Bool, size: CGSize = NibMetrics.paperTileSize, action: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.name = name
        self.isSelected = isSelected
        self.size = size
        self.action = action
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                content
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .nibElevation(.paper)
                    .nibSelectionRing(isSelected, cornerRadius: NibRadius.thumbnail)
                Text(name)
                    .font(NibFont.caption1)
                    .foregroundStyle(isSelected ? NibColor.accent : NibColor.labelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: size.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: shape))
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Study card

/// A study card (DESIGN.md §14.11): paper, not water. Radius 20, E1, its face in `cardFace` as the caller sets it.
/// Flipping turns it around the Y axis with `sheet` (no bounce), each face drawn only on its own half-turn; under
/// Reduce Motion it cross-fades. VoiceOver reads only the face that shows. The caller sizes it
/// (`NibMetrics.studyCardSize`, or the width − 32 on iPhone) and flips it (tap, Space).
public struct NibFlashcard<Front: View, Back: View>: View {
    let isFlipped: Bool
    let fill: Color
    let front: Front
    let back: Back
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isFlipped: Bool, fill: Color = NibColor.backgroundTertiary, @ViewBuilder front: () -> Front,
                @ViewBuilder back: () -> Back) {
        self.isFlipped = isFlipped
        self.fill = fill
        self.front = front()
        self.back = back()
    }

    public var body: some View {
        Group {
            if reduceMotion || NibMotion.forcesReduced {
                ZStack {
                    face(front).opacity(isFlipped ? 0 : 1).accessibilityHidden(isFlipped)
                    face(back).opacity(isFlipped ? 1 : 0).accessibilityHidden(!isFlipped)
                }
                .animation(NibMotion.enter, value: isFlipped)
            } else {
                NibFlip(angle: isFlipped ? 180 : 0, front: face(front), back: face(back))
                    .animation(NibMotion.sheet.animation, value: isFlipped)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func face<V: View>(_ content: V) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: NibRadius.studyCard, style: .continuous))
            .nibElevation(.rest)
    }
}

/// The half-turns of a flip: the front until 90°, then the back (itself turned 180° so it reads the right way round).
struct NibFlip<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                front
            } else {
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}
