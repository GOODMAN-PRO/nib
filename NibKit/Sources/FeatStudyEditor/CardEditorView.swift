import SwiftUI
import UIKit
import PencilKit
import PhotosUI
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - Layout

enum CardLayout {
    /// The preview card (DESIGN.md §14.11: 560 × 360, radius 20, `cardFace`).
    static let cardWidth = CGFloat(CardFaces.canvas.width)
    static let aspect = CGFloat(CardFaces.canvas.width / CardFaces.canvas.height)
    /// The editor pane: the card and its 24 pt margins.
    static let paneWidth = cardWidth + 2 * NibSpacing.xxl
}

// MARK: - Editor root

/// Two opaque panes on iPad (the card list and the card editor), the list alone on iPhone with the card editor in a
/// sheet. No droplets: study-card lists are never liquid (DESIGN.md §10.15); the document chrome floats above.
struct StudySetEditorView: View {
    @ObservedObject var model: StudySetModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if model.isMissing {
                NibEmptyState(symbol: .studySets, title: String(localized: "This study set is not available"),
                              message: String(localized: "It may have been moved to the Trash on another device."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sizeClass == .compact {
                CardListPane(model: model, compact: true)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        CardListPane(model: model, compact: false)
                        Rectangle()
                            .fill(NibColor.separatorSoft)
                            .frame(width: 0.5)
                            .accessibilityHidden(true)
                        CardEditorPane(model: model)
                            .frame(width: min(CardLayout.paneWidth, proxy.size.width * 0.55))
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The document chrome's bars float over the top of the editor.
            Color.clear.frame(height: NibMetrics.barTopGap + NibMetrics.barHeight)
        }
        .background(NibColor.background)
        .nibSheet(isPresented: $model.showsCardSheet) {
            CardEditorSheet(model: model)
        }
    }
}

// MARK: - Card list

struct CardListPane: View {
    @ObservedObject var model: StudySetModel
    let compact: Bool
    @State private var confirmsDelete = false
    @State private var showsMoveSheet = false

    var body: some View {
        let count = model.selected.count
        let deleteTitle = count == 1 ? String(localized: "Delete 1 Card") : String(localized: "Delete \(count) Cards")
        VStack(spacing: 0) {
            StudySetHeader(model: model, onDelete: { confirmsDelete = true }, onMove: { showsMoveSheet = true })
            Rectangle()
                .fill(NibColor.separatorSoft)
                .frame(height: 0.5)
                .accessibilityHidden(true)
            if model.cards.isEmpty {
                NibEmptyState(symbol: .studySets, title: String(localized: "No cards yet"),
                              message: String(localized: "Add a term and its definition, or paste handwriting you lassoed."),
                              primary: model.readOnly ? nil : NibAction(String(localized: "New Card"), handler: {
                                  Task { await model.addCard(after: nil) }
                              }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardList(model: model, compact: compact)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(deleteTitle, role: .destructive) {
                let ids = model.orderedSelection
                Task {
                    await model.delete(ids)
                    model.selecting = false
                }
            }
        } message: {
            Text(String(localized: "You can undo this."))
        }
        .nibSheet(isPresented: $showsMoveSheet) {
            MoveToSetSheet(model: model, cards: model.orderedSelection, isPresented: $showsMoveSheet)
        }
    }
}

struct StudySetHeader: View {
    @ObservedObject var model: StudySetModel
    let onDelete: () -> Void
    let onMove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            HStack(alignment: .center, spacing: NibSpacing.s) {
                VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                    Text(String(localized: "Cards"))
                        .font(NibFont.title3)
                        .foregroundStyle(NibColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.cards.count == 1 ? String(localized: "1 card") : String(localized: "\(model.cards.count) cards"))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                Spacer(minLength: NibSpacing.s)
                LanguageMenu(model: model)
                if let scratch = model.scratchPanel {
                    NibIconButton(.quickNote, label: String(localized: "Scratch Paper"), size: .panel) {
                        Task { await model.open(scratch) }
                    }
                }
                if !model.cards.isEmpty && !model.readOnly {
                    NibButton(model.selecting ? String(localized: "Done") : String(localized: "Select"), kind: .plain,
                              size: .compact) {
                        model.selecting.toggle()
                    }
                }
            }
            HStack(spacing: NibSpacing.s) {
                if model.selecting {
                    selectionActions
                } else {
                    studyActions
                }
            }
        }
        .padding(.horizontal, NibSpacing.l)
        .padding(.vertical, NibSpacing.m)
    }

    @ViewBuilder private var studyActions: some View {
        if let practice = model.practicePanel {
            NibButton(String(localized: "Practice"), kind: .secondary, size: .compact) {
                Task { await model.open(practice) }
            }
            .disabled(model.cards.isEmpty)
        }
        if let learn = model.smartLearnPanel {
            NibButton(String(localized: "Smart Learn"), kind: .secondary, size: .compact) {
                Task { await model.open(learn) }
            }
            .disabled(model.cards.isEmpty)
        }
        Spacer(minLength: 0)
        if !model.readOnly && !model.cards.isEmpty {         // the empty state carries New Card otherwise
            NibButton(String(localized: "New Card"), symbol: .plus, kind: .primary, size: .compact,
                      shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                Task { await model.addCard(after: model.current) }
            }
        }
    }

    @ViewBuilder private var selectionActions: some View {
        let count = model.selected.count
        Text(count == 1 ? String(localized: "1 selected") : String(localized: "\(count) selected"))
            .font(NibFont.footnote)
            .foregroundStyle(NibColor.labelSecondary)
        Spacer(minLength: 0)
        NibButton(String(localized: "Move To…"), symbol: .folder, kind: .secondary, size: .compact, action: onMove)
            .disabled(count == 0)
        NibButton(count == 1 ? String(localized: "Delete 1 Card") : String(localized: "Delete \(count) Cards"),
                  kind: .destructive, size: .compact, action: onDelete)
            .disabled(count == 0)
    }
}

/// The set's language (per-set: recognition, search and read-aloud), as a plain text menu.
struct LanguageMenu: View {
    @ObservedObject var model: StudySetModel

    var body: some View {
        Menu {
            Picker(String(localized: "Language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(model.languageChoices, id: \.self) { code in
                    Text(StudySetModel.languageName(code)).tag(code)
                }
            }
        } label: {
            HStack(spacing: NibSpacing.xs) {
                Text(StudySetModel.languageName(model.language))
                    .font(NibFont.footnote)
                    .lineLimit(1)
                Image(nib: .chevronDown)
                    .font(NibFont.caption1)
            }
            .foregroundStyle(NibColor.accent)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .disabled(model.readOnly)
        .accessibilityLabel(String(localized: "Language"))
        .accessibilityValue(StudySetModel.languageName(model.language))
    }
}

struct CardList: View {
    @ObservedObject var model: StudySetModel
    let compact: Bool
    @FocusState private var focus: CardField?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                    CardRow(model: model, card: card, number: index + 1, compact: compact, focus: $focus)
                        .id(card.id)
                        .listRowInsets(EdgeInsets(top: NibSpacing.xs, leading: NibSpacing.l, bottom: NibSpacing.xs,
                                                  trailing: NibSpacing.l))
                        .listRowBackground(rowBackground(card.id))
                        .listRowSeparatorTint(NibColor.separator)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !model.readOnly && !model.selecting {
                                Button {
                                    Task { await model.addCard(after: card.id) }
                                } label: {
                                    Label { Text(String(localized: "Add Card")) } icon: { Image(nib: .plus) }
                                }
                                .tint(NibColor.accent)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !model.readOnly && !model.selecting {
                                Button(role: .destructive) {
                                    Task { await model.delete([card.id]) }
                                } label: {
                                    Label { Text(String(localized: "Delete")) } icon: { Image(nib: .trash) }
                                }
                            }
                        }
                        .contextMenu {
                            CardMenu(model: model, card: card.id)
                        }
                }
                .onMove { source, destination in
                    Task { await model.move(from: source, to: destination) }
                }
                .moveDisabled(model.readOnly || model.selecting)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focus) { _, new in
                if let new {
                    if model.focus != new { model.focus = new }
                } else if model.focus?.inPane == false {
                    model.focus = nil
                }
            }
            .onChange(of: model.focus, initial: true) { _, new in
                let mine = new?.inPane == false ? new : nil
                guard focus != mine else { return }
                if let id = mine?.card { proxy.scrollTo(id) }
                focus = mine
            }
        }
    }

    private func rowBackground(_ id: NibID) -> some View {
        RoundedRectangle(cornerRadius: NibRadius.sidebarRow, style: .continuous)
            .fill(!compact && !model.selecting && model.current == id ? NibColor.fill3 : Color.clear)
            .padding(.horizontal, NibSpacing.s)
    }
}

/// One card: number, Term | Definition (stacked on iPhone), image slots for picture and freeform sides.
struct CardRow: View {
    @ObservedObject var model: StudySetModel
    let card: StudyCard
    let number: Int
    let compact: Bool
    var focus: FocusState<CardField?>.Binding

    private var isSelected: Bool { model.selected.contains(card.id) }

    var body: some View {
        HStack(alignment: .top, spacing: NibSpacing.m) {
            if model.selecting {
                Image(nib: isSelected ? .checkCircleFill : .circle)
                    .font(NibFont.glyph(.panel))
                    .foregroundStyle(isSelected ? NibColor.accent : NibColor.labelTertiary)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityHidden(true)
            }
            Text(verbatim: "\(number)")
                .font(NibFont.footnote)
                .monospacedDigit()
                .foregroundStyle(NibColor.labelSecondary)
                .frame(minWidth: NibSpacing.xxl, minHeight: NibMetrics.hitTarget, alignment: .trailing)
                .accessibilityHidden(true)
            sides
            if compact && !model.selecting {
                NibIconButton(.forward, label: String(localized: "Edit Card \(number)"), size: .panel) {
                    model.current = card.id
                    model.showsCardSheet = true
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.selecting {
                if isSelected { model.selected.remove(card.id) } else { model.selected.insert(card.id) }
            } else {
                model.current = card.id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Card \(number)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(String(localized: "Move Up"))) { Task { await model.moveUp(card.id) } }
        .accessibilityAction(named: Text(String(localized: "Move Down"))) { Task { await model.moveDown(card.id) } }
        .accessibilityAction(named: Text(String(localized: "Delete Card"))) { Task { await model.delete([card.id]) } }
    }

    @ViewBuilder private var sides: some View {
        if compact {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                SideCell(model: model, card: card, side: .front, compact: compact, focus: focus)
                SideCell(model: model, card: card, side: .back, compact: compact, focus: focus)
            }
        } else {
            HStack(alignment: .top, spacing: NibSpacing.m) {
                SideCell(model: model, card: card, side: .front, compact: compact, focus: focus)
                Rectangle()
                    .fill(NibColor.separator)
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                SideCell(model: model, card: card, side: .back, compact: compact, focus: focus)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SideCell: View {
    @ObservedObject var model: StudySetModel
    let card: StudyCard
    let side: CardSide
    let compact: Bool
    var focus: FocusState<CardField?>.Binding

    var body: some View {
        let field = CardField(card: card.id, side: side)
        Group {
            if model.mode(card.id, side) == .text {
                TextField(side.title, text: Binding(get: { model.text(field.key, in: model.card(card.id) ?? card) },
                                                    set: { model.setText($0, for: field) }),
                          axis: .vertical)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1...6)
                    .focused(focus, equals: field)
                    .disabled(model.readOnly || model.selecting)
                    .frame(minHeight: NibMetrics.hitTarget)
                    .accessibilityLabel(side.title)
            } else {
                Button {
                    model.current = card.id
                    model.side = side
                    if compact { model.showsCardSheet = true }
                } label: {
                    FaceThumbnail(model: model, card: card, side: side)
                }
                .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                .disabled(model.selecting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrop(of: CardPaste.dropTypes, isTargeted: nil) { providers in
            model.drop(providers, card: card.id, side: side)
        }
    }
}

/// A picture or freeform side in the list: a slot of light paper (paper is never inverted).
struct FaceThumbnail: View {
    let model: StudySetModel
    let card: StudyCard
    let side: CardSide

    var body: some View {
        let face = side.face(card)
        let mode = model.mode(card.id, side)
        let shape = RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
        ZStack {
            if mode == .image, face.kind == .image, let asset = face.asset {
                CardPicture(model: model, asset: asset)
                    .padding(NibSpacing.xs)
            } else if mode == .ink, let ink = model.inkPicture(face, key: model.inkKey(card, side)) {
                Image(uiImage: ink)
                    .resizable()
                    .scaledToFit()
                    .padding(NibSpacing.xs)
                    .accessibilityLabel(String(localized: "Handwriting"))
            } else {
                Text(mode == .image ? String(localized: "Add Image") : String(localized: "Draw"))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
        .frame(maxWidth: NibMetrics.thumbnailWidth)
        .frame(height: 72)
        .background(NibPaper.white.color, in: shape)
        .overlay { shape.strokeBorder(NibColor.separator, lineWidth: 0.5) }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
        .accessibilityValue(side.title)
    }
}

/// A picture stored in the set, loaded off the main thread.
struct CardPicture: View {
    let model: StudySetModel
    let asset: AssetRef
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(nib: .warningTriangle)
                    .font(NibFont.glyph(.panel))
                    .foregroundStyle(NibColor.labelTertiary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.name) {
            failed = false
            image = await model.picture(asset)
            failed = image == nil
        }
        .accessibilityElement()
        .accessibilityLabel(failed ? String(localized: "Picture that could not be shown") : String(localized: "Picture"))
    }
}

/// The card menu: every `MenuLocation.card` entry (this feature's, other features', plugins'), then Move to Study Set.
struct CardMenu: View {
    @ObservedObject var model: StudySetModel
    let card: NibID

    var body: some View {
        let items = model.readOnly ? [] : model.app.ui.menuItems(.card, model.menuContext(card))
        let groups = items.compactMap { $0.submenu }.reduce(into: [String]()) { list, name in
            if !list.contains(name) { list.append(name) }
        }
        ForEach(items.filter { $0.submenu == nil }, id: \.id) { item in
            MenuEntry(item: item) { model.perform(item, for: card) }
        }
        ForEach(groups, id: \.self) { group in
            Menu(group) {
                ForEach(items.filter { $0.submenu == group }, id: \.id) { item in
                    MenuEntry(item: item) { model.perform(item, for: card) }
                }
            }
        }
        let sets = model.otherSets
        if !model.readOnly && !sets.isEmpty {
            Menu(String(localized: "Move to Study Set")) {
                ForEach(sets) { node in
                    Button(node.title) {
                        Task { await model.moveCards([card], to: node.id) }
                    }
                }
            }
        }
    }
}

struct MenuEntry: View {
    let item: MenuItemDescriptor
    let action: () -> Void

    var body: some View {
        Button(role: item.destructive ? .destructive : nil, action: action) {
            if let symbol = item.icon.flatMap({ NibSymbol(systemName: $0) }) {
                Label { Text(item.title) } icon: { Image(nib: symbol) }
            } else {
                Text(item.title)
            }
        }
    }
}

struct MoveToSetSheet: View {
    let model: StudySetModel
    let cards: [NibID]
    @Binding var isPresented: Bool

    var body: some View {
        let sets = model.otherSets
        VStack(spacing: 0) {
            NibSheetHeader(cards.count == 1 ? String(localized: "Move 1 Card") : String(localized: "Move \(cards.count) Cards"),
                           onCancel: { isPresented = false })
            if sets.isEmpty {
                NibEmptyState(symbol: .studySets, title: String(localized: "No other study sets"),
                              message: String(localized: "Create another study set in the library, then move cards into it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sets) { node in
                    Button {
                        isPresented = false
                        Task { await model.moveCards(cards, to: node.id) }
                    } label: {
                        NibRow(node.title, icon: .studySets)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

// MARK: - Card editor

struct CardEditorSheet: View {
    @ObservedObject var model: StudySetModel

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(String(localized: "Edit Card"), cancelTitle: String(localized: "Close"),
                           onCancel: { model.showsCardSheet = false })
            CardEditorPane(model: model)
        }
    }
}

/// The selected card on light paper: Term | Definition, Text | Image | Freeform per side, paste and drop.
struct CardEditorPane: View {
    @ObservedObject var model: StudySetModel
    @FocusState private var focus: CardField?
    @State private var tool = CardInkTool.pen(.carbon)
    @State private var photo: PhotosPickerItem?
    @State private var targeted = false

    var body: some View {
        Group {
            if let card = model.currentCard {
                let mode = model.mode(card.id, model.side)
                ScrollView {
                    VStack(spacing: NibSpacing.l) {
                        navigation(card)
                        NibSegmentedControl(selection: $model.side, options: CardSide.allCases) { $0.title }
                        NibSegmentedControl(selection: modeBinding(card), options: CardFaceKind.allCases) { $0.title }
                            .disabled(model.readOnly)
                        surface(card, mode: mode)
                        controls(card, mode: mode)
                    }
                    .padding(NibSpacing.xxl)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(mode == .ink)
                .scrollDismissesKeyboard(.interactively)
            } else {
                NibEmptyState(symbol: .studySets, title: String(localized: "No card selected"),
                              message: String(localized: "Choose a card in the list, or add one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NibColor.desk)
        .onChange(of: focus) { _, new in
            if let new {
                if model.focus != new { model.focus = new }
            } else if model.focus?.inPane == true {
                model.focus = nil
            }
        }
        .onChange(of: model.focus, initial: true) { _, new in
            let mine = new?.inPane == true ? new : nil
            if focus != mine { focus = mine }
        }
        .onChange(of: photo) { _, item in
            guard let item, let id = model.current else { return }
            let side = model.side
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.setImage(data, card: id, side: side)
                }
            }
        }
        .onDisappear {
            if model.focus?.inPane == true { model.focus = nil }
        }
    }

    private func navigation(_ card: StudyCard) -> some View {
        let index = model.index(card.id) ?? 0
        let isLast = index == model.cards.count - 1
        return HStack(spacing: NibSpacing.s) {
            NibIconButton(.back, label: String(localized: "Previous Card"), size: .panel) {
                Task { await model.step(-1) }
            }
            .disabled(index == 0)
            Spacer(minLength: 0)
            Text(String(localized: "\(index + 1) of \(model.cards.count)"))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.labelSecondary)
            Spacer(minLength: 0)
            if isLast && !model.readOnly {
                NibIconButton(.plus, label: String(localized: "Add Card"), size: .panel) {
                    Task { await model.step(1) }
                }
            } else {
                NibIconButton(.forward, label: String(localized: "Next Card"), size: .panel) {
                    Task { await model.step(1) }
                }
                .disabled(isLast)
            }
        }
    }

    private func modeBinding(_ card: StudyCard) -> Binding<CardFaceKind> {
        Binding(get: { model.mode(card.id, model.side) },
                set: { model.setMode($0, card: card.id, side: model.side) })
    }

    private func textBinding(_ card: StudyCard, _ side: CardSide) -> Binding<String> {
        let field = CardField(card: card.id, side: side, inPane: true)
        return Binding(get: { model.text(field.key, in: model.card(card.id) ?? card) },
                       set: { model.setText($0, for: field) })
    }

    private func surface(_ card: StudyCard, mode: CardFaceKind) -> some View {
        let side = model.side
        let shape = RoundedRectangle(cornerRadius: NibRadius.studyCard, style: .continuous)
        let swipes = mode != .ink && focus == nil
        return GeometryReader { proxy in
            face(card, side: side, mode: mode, size: proxy.size)
        }
        .aspectRatio(CardLayout.aspect, contentMode: .fit)
        .frame(maxWidth: CardLayout.cardWidth)
        .background(NibPaper.white.color, in: shape)
        .clipShape(shape)
        .overlay {
            if targeted { shape.strokeBorder(NibColor.accent, lineWidth: 2) }
        }
        .nibElevation(.rest)
        .environment(\.colorScheme, .light)                        // paper is never inverted
        .onDrop(of: CardPaste.dropTypes, isTargeted: $targeted) { providers in
            model.drop(providers, card: card.id, side: side)
        }
        .simultaneousGesture(swipe, including: swipes ? .all : .subviews)
    }

    /// A horizontal swipe on the card moves to the next card (adding one after the last) or the previous one.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: NibSpacing.x3)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 80, abs(dx) > 2 * abs(value.translation.height) else { return }
                Task { await model.step(dx < 0 ? 1 : -1) }
            }
    }

    @ViewBuilder
    private func face(_ card: StudyCard, side: CardSide, mode: CardFaceKind, size: CGSize) -> some View {
        let face = side.face(card)
        switch mode {
        case .text:
            TextField(side.title, text: textBinding(card, side), axis: .vertical)
                .font(NibFont.cardFace)
                .foregroundStyle(NibColor.label)
                .multilineTextAlignment(.center)
                .lineLimit(1...8)
                .focused($focus, equals: CardField(card: card.id, side: side, inPane: true))
                .disabled(model.readOnly)
                .padding(NibSpacing.x3)
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(side.title)
        case .image:
            if face.kind == .image, let asset = face.asset {
                CardPicture(model: model, asset: asset)
                    .padding(NibSpacing.m)
                    .frame(width: size.width, height: size.height)
            } else {
                VStack(spacing: NibSpacing.s) {
                    Image(nib: .image)
                        .font(NibFont.glyph(.bar))
                        .accessibilityHidden(true)
                    Text(String(localized: "Choose a photo, paste a picture or drop one here."))
                        .font(NibFont.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(NibColor.labelSecondary)
                .padding(NibSpacing.x3)
                .frame(width: size.width, height: size.height)
            }
        case .ink:
            let canvas = face.kind == .ink ? (face.size ?? CardFaces.canvas) : CardFaces.canvas
            let scale = min(size.width / CGFloat(canvas.width), size.height / CGFloat(canvas.height))
            InkCanvas(strokes: face.kind == .ink ? (face.ink ?? []) : [], token: model.inkKey(card, side),
                      canvas: CGSize(width: canvas.width, height: canvas.height), scale: scale, tool: tool,
                      isEditable: !model.readOnly) { strokes in
                Task { await model.update(card.id, side, CardFace(kind: .ink, ink: strokes, size: canvas)) }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func controls(_ card: StudyCard, mode: CardFaceKind) -> some View {
        let side = model.side
        if !model.readOnly {
            HStack(spacing: NibSpacing.xs) {
                switch mode {
                case .text:
                    EmptyView()
                case .image:
                    PhotosPicker(selection: $photo, matching: .images) {
                        HStack(spacing: NibSpacing.s) {
                            Image(nib: .image)
                            Text(String(localized: "Choose Photo"))
                        }
                        .font(NibFont.button)
                        .foregroundStyle(NibColor.label)
                        .padding(.horizontal, NibSpacing.l)
                        .frame(minHeight: 38)
                        .background(NibColor.fill3, in: Capsule())
                        .frame(minHeight: NibMetrics.hitTarget)
                    }
                    if side.face(card).kind == .image {
                        NibIconButton(.trash, label: String(localized: "Remove Image"), size: .panel) {
                            Task { await model.removePicture(card: card.id, side: side) }
                        }
                    }
                case .ink:
                    ForEach(NibInk.quickSlots, id: \.self) { ink in
                        NibPenSwatch(NibSwatch(ink: ink), isSelected: tool == .pen(ink), size: .compact) {
                            tool = .pen(ink)
                        }
                    }
                    NibIconButton(.eraser, label: String(localized: "Eraser"), size: .panel, isOn: tool == .eraser) {
                        tool = .eraser
                    }
                    NibIconButton(.trash, label: String(localized: "Clear Drawing"), size: .panel) {
                        Task { await model.update(card.id, side, CardFace(kind: .ink, ink: [], size: CardFaces.canvas)) }
                    }
                }
                Spacer(minLength: 0)
                NibButton(String(localized: "Paste"), kind: .secondary, size: .compact) {
                    Task { await model.paste(into: card.id, side: side) }
                }
            }
        }
    }
}

// MARK: - Freeform ink

enum CardInkTool: Hashable {
    case pen(NibInk)
    case eraser

    var pkTool: PKTool {
        switch self {
        case .pen(let ink): return PKInkingTool(.monoline, color: ink.uiColor, width: CardInk.width)
        case .eraser: return PKEraserTool(.vector)
        }
    }
}

enum CardInk {
    static let width: CGFloat = 3

    /// A captured PencilKit stroke in the model, styled from its own ink.
    static func stroke(from pk: PKStroke) -> Stroke {
        var style: InkStyle
        switch pk.ink.inkType {
        case .pencil: style = InkStyle(tool: .pencil, pen: nil)
        case .marker: style = InkStyle(tool: .highlighter, pen: nil)
        case .pen: style = InkStyle(tool: .pen, pen: .brush)
        case .fountainPen: style = InkStyle(tool: .pen, pen: .fountain)
        default: style = InkStyle(tool: .pen, pen: .ball)
        }
        style.color = RGBA(pk.ink.color)
        var stroke = PKBridge.stroke(from: pk, style: style)
        stroke.style.width = Double(stroke.points.map { max($0.width, $0.height) }.max() ?? Float(width))
        return stroke
    }

    /// Carbon on light paper, Chalk on dark paper.
    static func quickInks(on paper: RGBA) -> [NibInk] {
        let luminance = (0.299 * Double(paper.r) + 0.587 * Double(paper.g) + 0.114 * Double(paper.b)) / 255
        return luminance < 0.5 ? [.chalk, .cobalt, .vermilion] : NibInk.quickSlots
    }
}

/// A small PencilKit canvas for one freeform side: page-point coordinates at `canvas` size, zoomed to fit. Every
/// finished stroke or erase hands the whole side back as model strokes.
struct InkCanvas: UIViewRepresentable {
    let strokes: [Stroke]
    /// Changes whenever the stored side changes (card, side, revision).
    let token: String
    let canvas: CGSize
    let scale: CGFloat
    let tool: CardInkTool
    let isEditable: Bool
    let onChange: ([Stroke]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.drawingPolicy = .anyInput
        view.backgroundColor = .clear
        view.isOpaque = false
        view.overrideUserInterfaceStyle = .light                 // ink on paper is never inverted
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.delegate = context.coordinator
        view.accessibilityLabel = String(localized: "Drawing area")
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        view.tool = tool.pkTool
        view.drawingGestureRecognizer.isEnabled = isEditable
        let s = max(scale, 0.01)
        if abs(view.zoomScale - s) > 0.0001 {
            view.maximumZoomScale = max(s, view.maximumZoomScale)
            view.minimumZoomScale = min(s, view.minimumZoomScale)
            view.zoomScale = s
            view.minimumZoomScale = s
            view.maximumZoomScale = s
        }
        view.contentSize = CGSize(width: canvas.width * s, height: canvas.height * s)
        if coordinator.token != token {
            coordinator.token = token
            if strokes != coordinator.committed { coordinator.load(strokes, into: view) }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (([Stroke]) -> Void)?
        var token = ""
        /// The strokes the canvas shows as the model has them.
        private(set) var committed: [Stroke]?
        private var shown = Data()

        func load(_ strokes: [Stroke], into view: PKCanvasView) {
            committed = strokes
            let drawing = PKBridge.drawing(strokes)
            shown = drawing.dataRepresentation()
            view.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let data = canvasView.drawing.dataRepresentation()
            guard data != shown else { return }                  // our own load, not the user
            shown = data
            let strokes = canvasView.drawing.strokes.map { CardInk.stroke(from: $0) }
            committed = strokes
            onChange?(strokes)
        }
    }
}

// MARK: - Scratch paper

/// A blank sheet of the default paper for working things out while studying. Nothing on it is saved.
enum ScratchPaper {
    static let panelID = "studyeditor.scratch"

    @MainActor
    static func descriptor(owner: String) -> PanelDescriptor {
        PanelDescriptor(id: panelID, title: String(localized: "Scratch Paper"), icon: NibSymbol.quickNote.name,
                        placement: .floating, order: 600, owner: owner, docKinds: [.studySet]) { context in
            AnyView(ScratchPaperView(paper: ScratchPaper.paper(context.app), onClose: context.dismiss))
        }
    }

    /// The default template's paper colour, without its rules.
    @MainActor
    static func paper(_ app: NibApp) -> RGBA {
        let ref = app.settings.get(NibSettings.defaultPaper)
        guard let template = app.content.template(ref) else { return .white }
        let params = template.defaults.merging(ref.params) { _, new in new }
        return template.render(params, template.preferredSize ?? .a4, 1).paper
    }
}

@MainActor
final class ScratchPad: ObservableObject {
    let canvas: PKCanvasView = {
        let view = PKCanvasView()
        view.drawingPolicy = .anyInput
        view.backgroundColor = .clear
        view.isOpaque = false
        view.overrideUserInterfaceStyle = .light
        view.isScrollEnabled = false
        view.accessibilityLabel = String(localized: "Scratch paper drawing area")
        return view
    }()

    func clear() { canvas.drawing = PKDrawing() }
}

struct ScratchCanvas: UIViewRepresentable {
    let pad: ScratchPad
    let tool: CardInkTool

    func makeUIView(context: Context) -> PKCanvasView { pad.canvas }

    func updateUIView(_ view: PKCanvasView, context: Context) { view.tool = tool.pkTool }
}

struct ScratchPaperView: View {
    let paper: RGBA
    let onClose: @MainActor () -> Void
    @StateObject private var pad = ScratchPad()
    @State private var tool: CardInkTool

    init(paper: RGBA, onClose: @escaping @MainActor () -> Void) {
        self.paper = paper
        self.onClose = onClose
        _tool = State(initialValue: .pen(CardInk.quickInks(on: paper)[0]))
    }

    var body: some View {
        VStack(spacing: 0) {
            NibPanelHeader(title: String(localized: "Scratch Paper"), subtitle: String(localized: "Not saved"),
                           symbol: .quickNote, onClose: { onClose() })
            ScratchCanvas(pad: pad, tool: tool)
                .background(Color(uiColor: paper.uiColor))
                .clipShape(RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous))
                .padding(.horizontal, NibSpacing.l)
            HStack(spacing: NibSpacing.xs) {
                ForEach(CardInk.quickInks(on: paper), id: \.self) { ink in
                    NibPenSwatch(NibSwatch(ink: ink), isSelected: tool == .pen(ink), size: .popover) { tool = .pen(ink) }
                }
                NibIconButton(.eraser, label: String(localized: "Eraser"), size: .panel, isOn: tool == .eraser) {
                    tool = .eraser
                }
                Spacer(minLength: 0)
                NibButton(String(localized: "Clear Paper"), kind: .secondary, size: .compact) { pad.clear() }
            }
            .padding(.horizontal, NibSpacing.l)
            .padding(.vertical, NibSpacing.s)
        }
        .frame(minWidth: 300, idealWidth: NibMetrics.panelWidth, minHeight: 360, idealHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Scratch Paper"))
    }
}

// MARK: - Paste and drop

/// A lasso copy (`app.nib.fragment`: {format, items, assets: {name: base64}, bounds}).
struct CardFragment {
    var items: [Item]
    var assets: [String: Data]
}

/// What a paste or a drop offers: a Nib fragment, picture bytes, plain text (any combination).
struct PastedContent {
    var fragment: CardFragment?
    var image: Data?
    var text: String?

    var available: Set<CardFaceKind> {
        let items = fragment?.items ?? []
        let ink = items.contains { $0.kind == .stroke && $0.stroke?.style.tool != .tape }
        let pictured = items.contains { item in
            guard let name = item.image?.asset.name else { return false }
            return fragment?.assets[name] != nil
        }
        var out = Set<CardFaceKind>()
        if !(text ?? "").isEmpty || ink || !CardPaste.typedText(items).isEmpty { out.insert(.text) }
        if image != nil || ink || pictured { out.insert(.image) }
        if ink { out.insert(.ink) }
        return out
    }
}

enum CardPaste {
    static let fragmentType = "app.nib.fragment"

    /// The app exports `app.nib.fragment` (project.yml, conforms to public.json).
    static var dropTypes: [UTType] { [UTType(exportedAs: fragmentType, conformingTo: .json), .image, .plainText] }

    static func fragment(from data: Data) -> CardFragment? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              json["format"]?.stringValue?.hasPrefix("nib-fragment/") == true,
              let items = try? (json["items"] ?? .array([])).decode([Item].self) else { return nil }
        var assets: [String: Data] = [:]
        for (name, value) in json["assets"]?.objectValue ?? [:] {
            if let base64 = value.stringValue, let bytes = Data(base64Encoded: base64) { assets[name] = bytes }
        }
        return CardFragment(items: items.filter { !$0.deleted }, assets: assets)
    }

    /// The side's input mode wins when the content can fill it; otherwise the closest thing it carries.
    static func choose(for mode: CardFaceKind, available: Set<CardFaceKind>) -> CardFaceKind? {
        let preference: [CardFaceKind]
        switch mode {
        case .text: preference = [.text, .image, .ink]
        case .image: preference = [.image, .ink, .text]
        case .ink: preference = [.ink, .image, .text]
        }
        return preference.first { available.contains($0) }
    }

    /// Typed text of lassoed text boxes and sticky notes, top to bottom.
    static func typedText(_ items: [Item]) -> [String] {
        items.compactMap { item -> (y: Double, text: String)? in
            let text = (item.text?.text.plainText ?? item.sticky?.text.plainText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (item.bounds.minY, text)
        }
        .sorted { $0.y < $1.y }
        .map { $0.text }
    }

    /// Lassoed ink as a freeform side: centred on the card and scaled down (never up) to fit inside the margin.
    static func inkFace(from items: [Item], canvas: PageSize = CardFaces.canvas, margin: Double = 24) -> CardFace? {
        let strokes = items.compactMap { $0.kind == .stroke ? $0.stroke : nil }.filter { $0.style.tool != .tape }
        guard let first = strokes.first else { return nil }
        let bounds = strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let fit = min(1, (canvas.width - 2 * margin) / max(bounds.width, 1), (canvas.height - 2 * margin) / max(bounds.height, 1))
        let t = Affine.translation(-bounds.minX, -bounds.minY)
            .concatenating(.scale(fit, fit))
            .concatenating(.translation((canvas.width - bounds.width * fit) / 2, (canvas.height - bounds.height * fit) / 2))
        return CardFace(kind: .ink, ink: strokes.map { $0.transformed(by: t) }, size: canvas)
    }

    /// A lassoed picture's own bytes, else the lassoed ink rendered on transparent paper.
    static func imageData(from fragment: CardFragment) -> Data? {
        for item in fragment.items {
            if let name = item.image?.asset.name, let bytes = fragment.assets[name] { return bytes }
        }
        let strokes = fragment.items.compactMap { $0.kind == .stroke ? $0.stroke : nil }
        guard let first = strokes.first else { return nil }
        let bounds = strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }.insetBy(-8)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKBridge.drawing(strokes).image(from: bounds.cg, scale: 2)
        }
        return image?.pngData()
    }

    @MainActor
    static func fromPasteboard(_ board: UIPasteboard) -> PastedContent {
        var content = PastedContent()
        if let data = board.data(forPasteboardType: fragmentType) { content.fragment = fragment(from: data) }
        for type in [UTType.png, .jpeg, .gif, .heic] where content.image == nil {
            content.image = board.data(forPasteboardType: type.identifier)
        }
        if content.image == nil, board.hasImages { content.image = board.image?.pngData() }
        if board.hasStrings { content.text = board.string }
        return content
    }

    static func load(_ providers: [NSItemProvider]) async -> PastedContent {
        var content = PastedContent()
        for provider in providers {
            if content.fragment == nil, provider.hasItemConformingToTypeIdentifier(fragmentType),
               let bytes = await loadData(provider, fragmentType) {
                content.fragment = fragment(from: bytes)
            }
            if content.image == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let bytes = await loadData(provider, UTType.image.identifier) {
                content.image = bytes
            }
            if content.text == nil, provider.canLoadObject(ofClass: NSString.self) {
                content.text = await loadString(provider)
            }
        }
        return content
    }

    private static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
    }
}

enum CardImages {
    /// Picture bytes as a set stores them: PNG, JPEG and GIF kept as they are, anything else (HEIC, TIFF) as PNG.
    static func normalized(_ data: Data) -> (data: Data, ext: String)? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "png") }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "jpg") }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (data, "gif") }
        guard let png = UIImage(data: data)?.pngData() else { return nil }
        return (png, "png")
    }
}
