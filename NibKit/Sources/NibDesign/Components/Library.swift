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
    let glyph: NibFolderGlyph
    let isTargeted: Bool
    let isFused: Bool

    public init(name: String, count: String, color: Color, isTargeted: Bool = false, isFused: Bool = false) {
        self.init(name: name, count: count, color: color, glyph: .symbol(.folderFill), isTargeted: isTargeted,
                  isFused: isFused)
    }

    /// v2: a folder with its own glyph (a symbol in the folder colour, or the emoji the person picked).
    public init(name: String, count: String, color: Color, glyph: NibFolderGlyph, isTargeted: Bool = false,
                isFused: Bool = false) {
        self.name = name
        self.count = count
        self.color = color
        self.glyph = glyph
        self.isTargeted = isTargeted
        self.isFused = isFused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.tile, style: .continuous)
        HStack(spacing: NibSpacing.m) {
            NibFolderGlyphView(glyph: glyph, color: color, size: 30)
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

/// A folder's glyph (v2): the folder symbol, another symbol the person chose, or their emoji. Folder emoji are the
/// person's content, not Nib's iconography, so they are shown as they are.
public enum NibFolderGlyph: Hashable, Sendable {
    case symbol(NibSymbol)
    case emoji(String)
}

/// A folder's glyph at a size: tiles (30), sidebar rows (22), menus. Symbols take the folder colour.
public struct NibFolderGlyphView: View {
    let glyph: NibFolderGlyph
    let color: Color
    let size: CGFloat

    public init(glyph: NibFolderGlyph, color: Color, size: CGFloat) {
        self.glyph = glyph
        self.color = color
        self.size = size
    }

    public var body: some View {
        Group {
            switch glyph {
            case .symbol(let symbol):
                Image(nib: symbol)
                    .font(.system(size: size))
                    .foregroundStyle(color)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: size))
            }
        }
        .accessibilityHidden(true)
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
    let showsNumber: Bool
    let content: Content

    public init(number: Int, isCurrent: Bool, isSelected: Bool? = nil, aspectRatio: CGFloat = 595.0 / 842.0,
                width: CGFloat = NibMetrics.thumbnailWidth, @ViewBuilder content: () -> Content) {
        self.init(number: number, isCurrent: isCurrent, isSelected: isSelected, aspectRatio: aspectRatio, width: width,
                  showsNumber: true, content: content)
    }

    /// v2: `showsNumber: false` for rows that say the page themselves (outline and bookmark rows use
    /// `width: NibMetrics.rowThumbnailWidth`); VoiceOver still reads "Page N".
    public init(number: Int, isCurrent: Bool, isSelected: Bool? = nil, aspectRatio: CGFloat = 595.0 / 842.0,
                width: CGFloat = NibMetrics.thumbnailWidth, showsNumber: Bool, @ViewBuilder content: () -> Content) {
        self.number = number
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.aspectRatio = aspectRatio
        self.width = width
        self.showsNumber = showsNumber
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
            if showsNumber {
                Text("\(number)")
                    .font(NibFont.caption1)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? NibColor.accent : NibColor.labelSecondary)
            }
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
