import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Draft (pure)

/// What the folder sheet edits. Pure, so the params it sends are unit-tested.
struct FolderDraft: Equatable {
    var title: String
    var color: RGBA
    /// SF Symbol name or one emoji; nil = the default folder glyph.
    var icon: String?
    var favorite: Bool
    var parent: FolderID?

    static let defaultIcon = "folder.fill"

    enum TitleProblem: Equatable { case empty, separator, leadingDot, tooLong }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Folder names are directory names in the library folder, on any Files provider.
    var titleProblem: TitleProblem? {
        let t = trimmedTitle
        if t.isEmpty { return .empty }
        if t.contains("/") || t.contains(":") { return .separator }
        if t.hasPrefix(".") { return .leadingDot }
        if t.utf8.count > 255 { return .tooLong }
        return nil
    }

    /// "#RRGGBB", or "#RRGGBBAA" when the colour is not opaque.
    var colorHex: String { FolderDraft.hex(color) }

    static func hex(_ c: RGBA) -> String { c.a == 255 ? String(c.hex.prefix(7)) : c.hex }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA", with or without the "#".
    static func parseHex(_ text: String) -> RGBA? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        return RGBA(hex: s)
    }

    /// Exactly one emoji (a single grapheme, including flags, keycaps and skin-tone or ZWJ sequences). A text-style
    /// symbol counts only with the emoji variation selector, so "1" or "#" alone never does.
    static func isSingleEmoji(_ s: String) -> Bool {
        guard s.count == 1, let character = s.first, let first = character.unicodeScalars.first else { return false }
        let scalars = character.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (first.properties.isEmoji && scalars.contains { $0 == "\u{FE0F}" })
    }

    /// `folder.create` params (the caller-chosen `id` lets the sheet star the new folder in the same undo group).
    func createParams(id: FolderID) -> JSONValue {
        var o: [String: JSONValue] = ["title": .string(trimmedTitle), "color": .string(colorHex), "id": .string(id.raw)]
        if let parent { o["parent"] = .string(NodeRef.folder(parent).description) }
        if let icon { o["icon"] = .string(icon) }
        return .object(o)
    }

    /// `folder.setStyle` params for what changed since `original`; nil when nothing did. Choosing the default glyph
    /// again sends `folder.fill`, the glyph a folder without an icon shows anyway.
    func styleParams(folder: FolderID, since original: FolderDraft) -> JSONValue? {
        var o: [String: JSONValue] = [:]
        if color != original.color { o["color"] = .string(colorHex) }
        if icon != original.icon { o["icon"] = .string(icon ?? FolderDraft.defaultIcon) }
        if favorite != original.favorite { o["favorite"] = .bool(favorite) }
        guard !o.isEmpty else { return nil }
        o["folder"] = .string(NodeRef.folder(folder).description)
        return .object(o)
    }
}

// MARK: - Palette and icons

/// Folder colours are inks (DESIGN.md §3.6); any other colour comes from the hex field or the system picker.
enum FolderColour {
    static let presets = NibFolderColor.allCases
    static let standard = NibFolderColor.cobalt

    static func rgba(_ colour: NibFolderColor) -> RGBA { rgba(hex: colour.ink.hex) }

    static func rgba(hex h: UInt32) -> RGBA {
        RGBA(UInt8((h >> 16) & 0xFF), UInt8((h >> 8) & 0xFF), UInt8(h & 0xFF))
    }

    /// The user's folder colour (data, not a UI colour); nil = the standard Cobalt.
    static func color(_ value: RGBA?) -> Color {
        let c = value ?? rgba(standard)
        let packed = UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
        return Color(cgColor: NibPalette.cgColor(packed, alpha: CGFloat(c.alpha)))
    }

    static func preset(_ value: RGBA) -> NibFolderColor? { presets.first { rgba($0) == value } }

    /// A colour from the system colour picker, clamped to sRGB bytes.
    static func rgba(_ color: Color) -> RGBA? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RGBA(byte(r), byte(g), byte(b), byte(a))
    }

    static func name(_ value: RGBA) -> String { preset(value)?.ink.name ?? FolderDraft.hex(value) }
}

struct FolderIconChoice: Hashable {
    let symbol: NibSymbol
    let label: String
}

/// SF Symbols offered for folders (a name this OS lacks is left out). An emoji is the other option.
enum FolderIcons {
    private static let names: [(String, String)] = [
        ("folder.fill", String(localized: "Folder")), ("book.closed.fill", String(localized: "Book")),
        ("books.vertical.fill", String(localized: "Books")), ("graduationcap.fill", String(localized: "Graduation cap")),
        ("pencil", String(localized: "Pencil")), ("doc.text.fill", String(localized: "Document")),
        ("atom", String(localized: "Atom")), ("flask.fill", String(localized: "Flask")),
        ("function", String(localized: "Function")), ("x.squareroot", String(localized: "Square root")),
        ("sum", String(localized: "Sum")), ("chart.bar.fill", String(localized: "Chart")),
        ("globe.europe.africa.fill", String(localized: "Globe")), ("leaf.fill", String(localized: "Leaf")),
        ("brain.head.profile", String(localized: "Brain")), ("stethoscope", String(localized: "Stethoscope")),
        ("laptopcomputer", String(localized: "Laptop")), ("music.note", String(localized: "Music")),
        ("paintpalette.fill", String(localized: "Palette")), ("camera.fill", String(localized: "Camera")),
        ("briefcase.fill", String(localized: "Briefcase")), ("calendar", String(localized: "Calendar")),
        ("lightbulb.fill", String(localized: "Light bulb")), ("star.fill", String(localized: "Star")),
        ("heart.fill", String(localized: "Heart")), ("house.fill", String(localized: "Home")),
        ("airplane", String(localized: "Travel")), ("cart.fill", String(localized: "Shopping")),
        ("person.2.fill", String(localized: "People")), ("gamecontroller.fill", String(localized: "Games")),
        ("sportscourt.fill", String(localized: "Sport")), ("hammer.fill", String(localized: "Tools")),
        ("tag.fill", String(localized: "Tag")), ("archivebox.fill", String(localized: "Archive")),
        ("bookmark.fill", String(localized: "Bookmark")), ("trophy.fill", String(localized: "Trophy")),
    ]

    static let choices: [FolderIconChoice] = names.compactMap { pair in
        NibSymbol(systemName: pair.0).map { FolderIconChoice(symbol: $0, label: pair.1) }
    }

    /// A stored icon as a symbol: unknown names, emoji and nil fall back to the folder glyph.
    static func symbol(_ name: String?) -> NibSymbol {
        name.flatMap { NibSymbol(systemName: $0) } ?? .folderFill
    }

    static func label(_ icon: String?) -> String {
        guard let icon else { return String(localized: "Folder") }
        if FolderDraft.isSingleEmoji(icon) { return icon }
        return choices.first { $0.symbol.name == icon }?.label ?? String(localized: "Symbol")
    }
}

// MARK: - The sheet

/// Folder creation and customisation (D-009, D-010): name, a palette of folder inks plus hex and the system colour
/// picker, an SF Symbol or an emoji, location (new folders) and Favourites. An opaque grouped sheet with one primary
/// action; it runs `folder.create` or `library.rename` + `folder.setStyle` as one undo group.
struct FolderStyleSheet: View {
    enum Mode: Equatable {
        case create(parent: FolderID?)
        case edit(FolderID)

        var isCreate: Bool {
            if case .create = self { return true }
            return false
        }

        var title: String { isCreate ? String(localized: "New Folder") : String(localized: "Customise Folder") }

        var panelID: String {
            switch self {
            case .create(let parent): return parent.map { OrganizePanel.newFolder + "." + $0.raw } ?? OrganizePanel.newFolder
            case .edit(let folder): return OrganizePanel.folderStyle + "." + folder.raw
            }
        }
    }

    enum IconKind: String, CaseIterable, Hashable {
        case symbol, emoji

        var title: String { self == .symbol ? String(localized: "Symbol") : String(localized: "Emoji") }
    }

    let app: NibApp
    let mode: Mode
    let onDone: () -> Void
    private let original: FolderDraft
    @State private var draft: FolderDraft
    @State private var hexText: String
    @State private var iconKind: IconKind
    @State private var emojiText: String
    @State private var isSaving = false
    @State private var choosingLocation = false
    @FocusState private var nameFocused: Bool

    init(app: NibApp, mode: Mode, onDone: @escaping () -> Void) {
        self.app = app
        self.mode = mode
        self.onDone = onDone
        let start = FolderStyleSheet.initialDraft(app, mode)
        let emoji = start.icon.map { FolderDraft.isSingleEmoji($0) } ?? false
        original = start
        _draft = State(initialValue: start)
        _hexText = State(initialValue: start.colorHex)
        _iconKind = State(initialValue: emoji ? .emoji : .symbol)
        _emojiText = State(initialValue: emoji ? (start.icon ?? "") : "")
    }

    /// Registers (once) the sheet panel for `mode` and returns its id, so a menu entry or a key command can open it
    /// with `panel.open {id}` (the command carries no arguments, so the target folder is part of the id).
    /// ponytail: one panel per customised folder; a `panel.open` argument would make this a single descriptor.
    static func panel(_ app: NibApp, _ mode: Mode) -> String {
        if app.ui.panels.get(mode.panelID) == nil { register(app, mode) }
        return mode.panelID
    }

    /// Registers the sheet panel for `mode` (at launch for the root New Folder sheet, which reads no registry).
    static func register(_ app: NibApp, _ mode: Mode) {
        app.ui.panels.register(PanelDescriptor(
            id: mode.panelID, title: mode.title, icon: NibSymbol.folder.name, placement: .sheet, order: 0,
            owner: FeatLibraryOrganizeFeature.id) { ctx in
                AnyView(FolderStyleSheet(app: ctx.app, mode: mode, onDone: { ctx.dismiss() }))
            })
    }

    static func initialDraft(_ app: NibApp, _ mode: Mode) -> FolderDraft {
        let standard = FolderColour.rgba(FolderColour.standard)
        switch mode {
        case .create(let parent):
            return FolderDraft(title: "", color: standard, icon: nil, favorite: false, parent: parent)
        case .edit(let folder):
            let node = app.services.library?.node(folder)
            let icon = node?.style?.icon.flatMap { $0.isEmpty || $0 == FolderDraft.defaultIcon ? nil : $0 }
            return FolderDraft(title: node?.title ?? "", color: node?.style?.color ?? standard, icon: icon,
                               favorite: node.map { Favouriting.isFavourite($0) } ?? false, parent: node?.parent)
        }
    }

    /// Runs the commands for a finished sheet as one undo group. Returns false when a command failed (the shell
    /// shows the error).
    static func commit(_ app: NibApp, mode: Mode, draft: FolderDraft, original: FolderDraft) async -> Bool {
        let group = NibID.make().raw
        switch mode {
        case .create:
            let id = NibID.make()
            guard let result = await Organize.run(app, "folder.create", draft.createParams(id: id), group: group) else {
                return false
            }
            guard draft.favorite else { return true }
            let ref = result["ref"]?.stringValue ?? NodeRef.folder(id).description
            let star: JSONValue = ["folder": .string(ref), "favorite": true]
            return await Organize.run(app, "folder.setStyle", star, group: group) != nil
        case .edit(let folder):
            if draft.trimmedTitle != original.trimmedTitle {
                let rename: JSONValue = ["ref": .string(NodeRef.folder(folder).description),
                                         "title": .string(draft.trimmedTitle)]
                guard await Organize.run(app, "library.rename", rename, group: group) != nil else { return false }
            }
            guard let style = draft.styleParams(folder: folder, since: original) else { return true }
            return await Organize.run(app, "folder.setStyle", style, group: group) != nil
        }
    }

    private var canSave: Bool {
        !isSaving && draft.titleProblem == nil && (mode.isCreate || draft != original)
    }

    private var isEmojiIcon: Bool { draft.icon.map { FolderDraft.isSingleEmoji($0) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(mode.title,
                           primaryTitle: mode.isCreate ? String(localized: "Create Folder") : String(localized: "Save Changes"),
                           isPrimaryEnabled: canSave, onCancel: { onDone() }, onPrimary: { save() })
            List {
                Section { preview }
                Section {
                    nameField
                } header: {
                    OrganizeSectionLabel(String(localized: "Name"))
                } footer: {
                    if let message = titleMessage {
                        Text(message).font(NibFont.caption1).foregroundStyle(NibColor.destructive)
                    }
                }
                Section {
                    colourSection
                } header: {
                    OrganizeSectionLabel(String(localized: "Colour"))
                }
                Section {
                    iconSection
                } header: {
                    OrganizeSectionLabel(String(localized: "Icon"))
                }
                if mode.isCreate {
                    Section {
                        locationRow
                    } header: {
                        OrganizeSectionLabel(String(localized: "Location"))
                    }
                }
                Section {
                    NibToggle(String(localized: "Show in Favourites"), isOn: $draft.favorite)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(NibColor.groupedBackground)
        .onAppear { if mode.isCreate { nameFocused = true } }
        .nibSheet(isPresented: $choosingLocation) {
            DestinationPickerSheet(
                title: String(localized: "Choose Location"), actionTitle: String(localized: "Choose Folder"),
                rows: DestinationPickerSheet.folderRows(app.services.library?.allNodes() ?? []),
                initial: draft.parent.map { NodeRef.folder($0).description } ?? DestinationPickerSheet.root,
                onCancel: { choosingLocation = false },
                onChoose: { key in
                    draft.parent = DestinationPickerSheet.folder(key)
                    choosingLocation = false
                })
        }
    }

    // MARK: Sections

    private var preview: some View {
        VStack(spacing: NibSpacing.s) {
            FolderGlyph(style: FolderStyle(color: draft.color, icon: draft.icon), size: 56)
            Text(draft.trimmedTitle.isEmpty ? String(localized: "Untitled Folder") : draft.trimmedTitle)
                .font(NibFont.headline)
                .foregroundStyle(NibColor.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NibSpacing.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Preview"))
        .accessibilityValue(previewValue)
    }

    private var previewValue: String {
        [draft.trimmedTitle, FolderColour.name(draft.color), FolderIcons.label(draft.icon)]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var nameField: some View {
        TextField(String(localized: "Folder name"), text: $draft.title)
            .font(NibFont.body)
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit { if canSave { save() } }
            .frame(minHeight: NibMetrics.hitTarget)
    }

    private var titleMessage: String? {
        switch draft.titleProblem {
        case .separator: return String(localized: "Folder names can't contain / or :.")
        case .leadingDot: return String(localized: "Folder names can't start with a full stop.")
        case .tooLong: return String(localized: "Use a shorter name.")
        case .empty, nil: return nil
        }
    }

    @ViewBuilder private var colourSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.hitTarget), spacing: NibSpacing.xs)],
                  alignment: .leading, spacing: NibSpacing.xs) {
            ForEach(FolderColour.presets, id: \.self) { preset in
                NibPenSwatch(NibSwatch(ink: preset.ink), isSelected: FolderColour.preset(draft.color) == preset,
                             size: .compact) { setColour(FolderColour.rgba(preset)) }
            }
        }
        VStack(alignment: .leading, spacing: NibSpacing.xxs) {
            HStack(spacing: NibSpacing.m) {
                Text(String(localized: "Hex"))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                TextField(String(localized: "Hex colour"), text: $hexText)
                    .font(NibFont.body.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onChange(of: hexText) { _, text in
                        if let parsed = FolderDraft.parseHex(text) { draft.color = parsed }
                    }
                    .onSubmit { hexText = draft.colorHex }
                    .accessibilityLabel(String(localized: "Hex colour"))
            }
            .frame(minHeight: NibMetrics.hitTarget)
            if FolderDraft.parseHex(hexText) == nil {
                Text(String(localized: "Enter a colour as # and six hex digits."))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.destructive)
            }
        }
        ColorPicker(String(localized: "Custom colour"), selection: customColour, supportsOpacity: false)
            .font(NibFont.body)
            .frame(minHeight: NibMetrics.hitTarget)
    }

    private var customColour: Binding<Color> {
        Binding(get: { FolderColour.color(draft.color) },
                set: { picked in
                    if let value = FolderColour.rgba(picked) { setColour(value.withAlpha(1)) }
                })
    }

    private func setColour(_ value: RGBA) {
        draft.color = value
        hexText = FolderDraft.hex(value)
    }

    @ViewBuilder private var iconSection: some View {
        NibSegmentedControl(selection: $iconKind, options: IconKind.allCases) { $0.title }
        if iconKind == .symbol {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: NibMetrics.hitTarget), spacing: NibSpacing.xs)],
                      spacing: NibSpacing.xs) {
                ForEach(FolderIcons.choices, id: \.self) { choice in symbolButton(choice) }
            }
        } else {
            VStack(alignment: .leading, spacing: NibSpacing.xxs) {
                HStack(spacing: NibSpacing.m) {
                    TextField(String(localized: "Type one emoji"), text: $emojiText)
                        .font(NibFont.title2)
                        .autocorrectionDisabled()
                        .onChange(of: emojiText) { _, text in applyEmoji(text) }
                        .accessibilityLabel(String(localized: "Emoji"))
                    if isEmojiIcon {
                        NibButton(String(localized: "Clear Emoji"), kind: .plain, size: .compact) {
                            emojiText = ""
                            draft.icon = nil
                        }
                    }
                }
                .frame(minHeight: NibMetrics.hitTarget)
                Text(String(localized: "Switch to the emoji keyboard and pick one."))
                    .font(NibFont.caption1)
                    .foregroundStyle(NibColor.labelSecondary)
            }
        }
    }

    private func symbolButton(_ choice: FolderIconChoice) -> some View {
        let selected = !isEmojiIcon && (draft.icon ?? FolderDraft.defaultIcon) == choice.symbol.name
        return Button {
            draft.icon = choice.symbol.name == FolderDraft.defaultIcon ? nil : choice.symbol.name
            emojiText = ""
        } label: {
            Image(nib: choice.symbol)
                .font(NibFont.glyph(.panel))
                .foregroundStyle(FolderColour.color(draft.color))
                .frame(width: 40, height: 40)
                .background(selected ? NibColor.fill3 : Color.clear, in: Circle())
                .overlay {
                    if selected { Circle().stroke(NibColor.label, lineWidth: 2) }
                }
                .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Circle()))
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Keeps the field to one emoji: the last one typed wins; anything else is refused.
    private func applyEmoji(_ text: String) {
        guard let last = text.last.map({ String($0) }) else {
            if isEmojiIcon { draft.icon = nil }
            return
        }
        if FolderDraft.isSingleEmoji(last) {
            draft.icon = last
            if text != last { emojiText = last }
        } else {
            emojiText = isEmojiIcon ? (draft.icon ?? "") : ""
        }
    }

    private var locationRow: some View {
        let parent = draft.parent.flatMap { app.services.library?.node($0) }
        let title = parent?.title ?? String(localized: "Library")
        return Button { choosingLocation = true } label: {
            HStack(spacing: NibSpacing.m) {
                if let parent {
                    FolderGlyph(style: parent.style, size: 20)
                } else {
                    Image(nib: .library)
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.labelSecondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NibSpacing.s)
                Image(nib: .forward)
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Location"))
        .accessibilityValue(title)
        .accessibilityHint(String(localized: "Chooses the folder the new folder goes in."))
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let draft = self.draft
        let original = self.original
        let mode = self.mode
        let app = self.app
        Task {
            let ok = await FolderStyleSheet.commit(app, mode: mode, draft: draft, original: original)
            isSaving = false
            guard ok else { return }
            NibHaptics.play(.success)
            Organize.announce(mode.isCreate ? String(localized: "Created \(draft.trimmedTitle).")
                                            : String(localized: "Saved \(draft.trimmedTitle)."))
            onDone()
        }
    }
}

/// A grouped-list section label: footnote semibold in secondary, never all caps.
struct OrganizeSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(NibFont.footnoteEmphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Destination picker

/// Choose where things go: the library root and every folder (nested), or a notebook (Trash › Move for pages).
struct DestinationPickerSheet: View {
    struct Row: Identifiable, Hashable {
        enum Glyph: Hashable {
            case folder(FolderStyle?)
            case symbol(NibSymbol)
        }

        /// `lib`, `folder:F` or `doc:D`.
        let id: String
        let title: String
        let depth: Int
        let glyph: Glyph
    }

    static let root = "lib"

    let title: String
    let actionTitle: String
    let rows: [Row]
    let onCancel: () -> Void
    let onChoose: (String) -> Void
    @State private var choice: String?

    init(title: String, actionTitle: String, rows: [Row], initial: String? = nil,
         onCancel: @escaping () -> Void, onChoose: @escaping (String) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.rows = rows
        self.onCancel = onCancel
        self.onChoose = onChoose
        _choice = State(initialValue: initial)
    }

    /// The library root, then folders depth-first by name. Folders whose parent is unknown sit at the root.
    static func folderRows(_ nodes: [LibraryNode]) -> [Row] {
        let folders = nodes.filter { $0.kind == .folder && $0.trashedAt == nil }
        let ids = Set(folders.map { $0.id })
        let byParent = Dictionary(grouping: folders) { f -> FolderID? in f.parent.flatMap { ids.contains($0) ? $0 : nil } }
        var out = [Row(id: root, title: String(localized: "Library"), depth: 0, glyph: .symbol(.library))]
        var seen = Set<FolderID>()
        func visit(_ parent: FolderID?, _ depth: Int) {
            let children = (byParent[parent] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for folder in children where seen.insert(folder.id).inserted {
                out.append(Row(id: NodeRef.folder(folder.id).description, title: folder.title, depth: depth + 1,
                               glyph: .folder(folder.style)))
                visit(folder.id, depth + 1)
            }
        }
        visit(nil, 0)
        return out
    }

    /// Notebooks by name (pages can only move into notebooks), leaving out `excluding`.
    static func notebookRows(_ nodes: [LibraryNode], excluding: Set<DocumentID> = []) -> [Row] {
        nodes.filter { $0.kind == .document && $0.documentKind == .notebook && $0.trashedAt == nil && !excluding.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { Row(id: NodeRef.document($0.id).description, title: $0.title, depth: 0, glyph: .symbol(.notebook)) }
    }

    /// The folder a folder-row key names; nil for the library root.
    static func folder(_ key: String) -> FolderID? {
        if case .folder(let f)? = NodeRef(key) { return f }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader(title, primaryTitle: actionTitle, isPrimaryEnabled: choice != nil,
                           onCancel: { onCancel() },
                           onPrimary: { if let choice { onChoose(choice) } })
            List {
                ForEach(rows) { row in rowView(row) }
            }
            .listStyle(.insetGrouped)
        }
        .background(NibColor.groupedBackground)
    }

    private func rowView(_ row: Row) -> some View {
        let selected = choice == row.id
        return Button { choice = row.id } label: {
            HStack(spacing: NibSpacing.m) {
                Group {
                    switch row.glyph {
                    case .folder(let style):
                        FolderGlyph(style: style, size: 22)
                    case .symbol(let symbol):
                        Image(nib: symbol)
                            .font(NibFont.glyph(.sidebar))
                            .foregroundStyle(NibColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 28)
                Text(row.title)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NibSpacing.s)
                if selected {
                    Image(nib: .checkmark)
                        .font(NibFont.bodyEmphasis)
                        .foregroundStyle(NibColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(min(row.depth, 6)) * NibSpacing.l)
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
