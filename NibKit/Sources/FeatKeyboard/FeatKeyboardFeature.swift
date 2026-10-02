import SwiftUI
import Combine
import UIKit
import NibContracts
import NibDesign

/// Keyboard shortcuts and pointer (F073): T-085, D-082, P-050 to P-055, P-057, T-111.
///
/// - Registers the global, library and document key commands (`GlobalShortcuts`), each mapped to a command another
///   feature owns, with discoverability titles; the shell turns them into UIKeyCommands and passes
///   `resolvedParams(for:)`, so keys that read the window use `sessionParams`.
/// - Never registers a key combination twice: another owner that maps the same keys keeps them, and this feature's
///   shortcut comes back when it goes (`KeyboardRuntime`), live, as features and plugins register and unregister.
///   Clashes between two other owners are the shell's (`KeyCommandRouting.active`); the list marks the keys that lose
///   everywhere.
/// - Settings › General › Keyboard and Pointer: the single-key shortcut switch (`keyboard.singleKeyShortcuts`, run
///   through `settings.set`) and every shortcut, searchable, with the text formatting keys the text views handle.
///   Contract gap: `KeyCommandContext` has no single-key flag for `KeyCommandRouting` to filter on, so while the switch
///   is off the runtime moves every owner's single-key descriptors to a placement no window offers
///   (`KeyPlacement.inert`) and gives them back when it is on again.
/// - Pointer: right-click on a page runs `menu.showAt`, ⌘-scroll zooms towards the pointer, UIKit buttons in the
///   chrome hover (`PointerSupport`).
public enum FeatKeyboardFeature: NibFeature {
    public static let id = "keyboard"

    public static func register(_ app: NibApp) {
        KeyboardSettings.declare(app.settings, owner: id)
        let catalog = GlobalShortcuts.catalog(app: app, owner: id)
        app.services.set(KeyboardRuntime(app: app, owner: id, catalog: catalog), for: KeyboardRuntime.serviceKey)
        for d in catalog { app.content.keyCommands.register(d) }
        PointerSupport.register(app, owner: id)
        KeyboardPanels.register(app, owner: id)
        LibraryCreationShortcuts.register(app, owner: id)
        CanvasChromeShortcuts.register(app, owner: id)

        var page = SettingsPageDescriptor(id: KeyboardSettingsPage.id, title: String(localized: "Keyboard and Pointer"),
                                          icon: NibSymbol.keyboard.name, section: .general, order: 400, owner: id) { app in
            AnyView(KeyboardSettingsView(app: app))
        }
        page.keywords = [String(localized: "shortcuts"), String(localized: "hardware keyboard"),
                         String(localized: "single-key"), String(localized: "trackpad"), String(localized: "mouse"),
                         String(localized: "right-click"), String(localized: "hotkeys")]
        app.ui.settingsPages.register(page)

        app.ui.menus.register(MenuItemDescriptor(
            id: "keyboard.appMenu.shortcuts", title: String(localized: "Keyboard Shortcuts"), icon: NibSymbol.keyboard.name,
            location: .appMenu, order: 850, owner: id, command: CommandIDs.settingsOpen,
            params: { _ in ["page": .string(KeyboardSettingsPage.id)] }))
    }

    public static func start(_ app: NibApp) async {
        app.services.get(KeyboardRuntime.serviceKey, as: KeyboardRuntime.self)?.start()
    }
}

/// Keep creation commands below the library's hosting boundary using a native responder.
/// Invisible SwiftUI shortcut buttons can consume keys without delivering their actions
/// in an embedded host. The registry remains the sole command source.
@MainActor
enum LibraryCreationShortcuts {
    static let overlayID = "keyboard.libraryCreation"
    static let shortcuts: Set<KeyShortcut> = [
        KeyShortcut("n", [.command, .option]), KeyShortcut("n", [.command, .shift]),
        KeyShortcut("t", [.command, .shift]), KeyShortcut("w", [.command, .shift])
    ]

    static func register(_ app: NibApp, owner: String) {
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: overlayID, owner: owner, placement: .center, surface: .none,
            recedesWhileWriting: false, isVisible: { $0.kind == nil && $0.session.document == nil }) {
                AnyView(LibraryCreationShortcutView(context: $0))
            })
    }

    static func descriptors(in context: ChromeContext) -> [KeyCommandDescriptor] {
        guard context.kind == nil, context.session.document == nil else { return [] }
        let keys = KeyCommandContext(docKind: nil, isEditingText: context.session.isEditingText,
                                     hasTabs: !(context.navigator?.openDocuments.isEmpty ?? true))
        return KeyCommandRouting.active(context.app.content.keyCommands.all, in: keys).filter {
            shortcuts.contains(ShortcutRules.normalized($0.shortcut))
        }
    }

    /// Revalidate at dispatch: a plugin may have replaced a descriptor since UIKit queried it.
    static func perform(_ id: String, in context: ChromeContext) {
        guard let descriptor = descriptors(in: context).first(where: { $0.id == id }),
              let navigator = context.navigator, navigator.session === context.session,
              !CanvasKeyboardFocus.hasModal(navigator.rootViewController) else { return }
        if let window = navigator.rootViewController?.viewIfLoaded?.window, !window.isKeyWindow { return }
        context.app.ui.activeNavigator = navigator
        context.app.services.sessions.activate(context.session)
        context.app.perform(descriptor.command, descriptor.resolvedParams(for: context.session),
                            session: context.session)
    }

    static func shortcut(_ key: KeyShortcut) -> KeyboardShortcut {
        var modifiers: EventModifiers = []
        if key.modifiers.contains(.command) { modifiers.insert(.command) }
        if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if key.modifiers.contains(.option) { modifiers.insert(.option) }
        if key.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key.key.lowercased().first ?? " "), modifiers: modifiers)
    }
}

private struct LibraryCreationShortcutView: UIViewRepresentable {
    let context: ChromeContext

    func makeUIView(context: Context) -> LibraryCreationKeyboardResponder {
        LibraryCreationKeyboardResponder(context: self.context)
    }

    func updateUIView(_ view: LibraryCreationKeyboardResponder, context: Context) {
        view.context = self.context
        view.scheduleFocus()
    }

    static func dismantleUIView(_ view: LibraryCreationKeyboardResponder, coordinator: ()) {
        view.context = nil
        view.resignFirstResponder()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LibraryCreationKeyboardResponder,
                     context: Context) -> CGSize? { .zero }
}

/// A non-text responder: no keyboard, touch target or duplicate SwiftUI key binding.
/// Native key commands remain discoverable and dispatch through the invoking window.
@MainActor
final class LibraryCreationKeyboardResponder: UIView {
    var context: ChromeContext?
    private let observers = NotificationBag()
    private var focusScheduled = false

    init(context: ChromeContext) {
        self.context = context
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        for name in [UIWindow.didBecomeKeyNotification, UIScene.didActivateNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidHideNotification, .nibChromeNeedsUpdate] {
            observers.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                KeyboardRuntime.onMain { self?.scheduleFocus() }
            })
        }
    }

    required init?(coder: NSCoder) { nil }
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleFocus()
    }

    func scheduleFocus() {
        guard context != nil, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            self.restoreFocus()
        }
    }

    func restoreFocus() {
        guard let context, let window, window.isKeyWindow, !isFirstResponder,
              !context.session.isEditingText, !descriptors.isEmpty,
              CanvasKeyboardFocus.mayReplace(CanvasKeyboardFocus.firstResponder(in: window), canvas: self) else { return }
        becomeFirstResponder()
    }

    private var descriptors: [KeyCommandDescriptor] {
        guard let context, let window, window.isKeyWindow,
              context.navigator?.session === context.session,
              context.navigator?.rootViewController?.viewIfLoaded?.window === window,
              !CanvasKeyboardFocus.hasModal(window.rootViewController) else { return [] }
        return LibraryCreationShortcuts.descriptors(in: context)
    }

    override var keyCommands: [UIKeyCommand]? {
        descriptors.map { descriptor in
            let key = descriptor.shortcut
            var modifiers: UIKeyModifierFlags = []
            if key.modifiers.contains(.command) { modifiers.insert(.command) }
            if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
            if key.modifiers.contains(.option) { modifiers.insert(.alternate) }
            if key.modifiers.contains(.control) { modifiers.insert(.control) }
            let command = UIKeyCommand(title: descriptor.title, action: #selector(runCreationKey(_:)),
                                       input: key.key.lowercased(), modifierFlags: modifiers, propertyList: descriptor.id)
            command.wantsPriorityOverSystemBehavior = true
            return command.nibCommand(descriptor.command)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(runCreationKey(_:)) else { return super.canPerformAction(action, withSender: sender) }
        // UIKit first discovers targets with a nil/non-command sender.
        guard let command = sender as? UIKeyCommand else { return !descriptors.isEmpty }
        return descriptors.contains { $0.id == command.propertyList as? String }
    }

    @objc private func runCreationKey(_ command: UIKeyCommand) {
        guard let context, let descriptor = descriptors.first(where: { $0.id == command.propertyList as? String }) else { return }
        LibraryCreationShortcuts.perform(descriptor.id, in: context)
    }
}

/// SwiftUI's document chrome can consume hardware-key dispatch before it reaches the
/// UIKit canvas responder. Install bindings in that hosting tree as well. Both routes
/// use the registry's winner and resolve parameters only in the invoking scene.
@MainActor
enum CanvasChromeShortcuts {
    static let overlayID = "keyboard.canvasShortcuts"
    private static let catalogKeys = Set(GlobalShortcuts.catalog(app: nil, owner: FeatKeyboardFeature.id)
        .filter { $0.docKinds == ShortcutContext.canvasKinds }
        .map { ShortcutRules.normalized($0.shortcut) })

    static func register(_ app: NibApp, owner: String) {
        app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: overlayID, owner: owner, placement: .center, surface: .none,
            recedesWhileWriting: false, docKinds: ShortcutContext.canvasKinds) {
                AnyView(CanvasChromeShortcutView(context: $0))
            })
    }

    static func descriptors(in context: ChromeContext) -> [KeyCommandDescriptor] {
        guard let kind = context.kind, ShortcutContext.canvasKinds.contains(kind),
              context.session.document != nil,
              ShortcutContext(session: context.session, app: context.app).kind == kind else { return [] }
        let window = context.navigator?.rootViewController?.viewIfLoaded?.window
        let typing = context.session.isEditingText || window.map {
            CanvasKeyboardFocus.isTextInput(CanvasKeyboardFocus.firstResponder(in: $0))
        } == true
        let keys = KeyCommandContext(docKind: kind, isEditingText: typing, hasTabs: true)
        return KeyCommandRouting.active(context.app.content.keyCommands.all, in: keys).filter {
            guard KeyCommandRouting.overridesSystemKeys($0, in: keys) else { return false }
            if catalogKeys.contains(ShortcutRules.normalized($0.shortcut)) { return true }
            guard $0.scope == .canvas || $0.scope == .document,
                  let kinds = $0.docKinds, !kinds.isEmpty else { return false }
            return kinds.isSubset(of: ShortcutContext.canvasKinds)
        }
    }

    static func perform(_ id: String, in context: ChromeContext) {
        guard let navigator = context.navigator, navigator.session === context.session,
              !CanvasKeyboardFocus.hasModal(navigator.rootViewController),
              let descriptor = descriptors(in: context).first(where: { $0.id == id }) else { return }
        if let window = navigator.rootViewController?.viewIfLoaded?.window, !window.isKeyWindow { return }
        context.app.ui.activeNavigator = navigator
        context.app.services.sessions.activate(context.session)
        context.app.perform(descriptor.command, descriptor.resolvedParams(for: context.session),
                            session: context.session)
    }

    static func shortcut(_ key: KeyShortcut) -> KeyboardShortcut {
        let equivalent: KeyEquivalent
        switch key.key.lowercased() {
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "escape": equivalent = .escape
        case "delete": equivalent = .delete
        case "tab": equivalent = .tab
        case "return": equivalent = .return
        case "space": equivalent = .space
        default: equivalent = KeyEquivalent(key.key.lowercased().first ?? " ")
        }
        return KeyboardShortcut(equivalent, modifiers: LibraryCreationShortcuts.shortcut(key).modifiers)
    }
}

private struct CanvasChromeShortcutView: View {
    let context: ChromeContext
    @State private var revision = 0

    var body: some View {
        let _ = revision
        Group {
            ForEach(CanvasChromeShortcuts.descriptors(in: context), id: \.id) { descriptor in
                Button(descriptor.title) { CanvasChromeShortcuts.perform(descriptor.id, in: context) }
                    .keyboardShortcut(CanvasChromeShortcuts.shortcut(descriptor.shortcut))
            }
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange,
                                                        object: context.app.content.keyCommands)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .nibChromeNeedsUpdate)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { _ in revision += 1 }
    }
}

enum KeyboardSettingsPage {
    static let id = "keyboard.settings"
}

// MARK: - Shortcut text

enum ShortcutFormatter {
    /// "⌥⌘N", "⌃⌘S", "⌫": the glyphs Apple uses in menus and the ⌘-hold overlay, modifiers in ⌃⌥⇧⌘ order.
    static func display(_ shortcut: KeyShortcut) -> String {
        var out = ""
        if shortcut.modifiers.contains(.control) { out += "⌃" }
        if shortcut.modifiers.contains(.option) { out += "⌥" }
        if shortcut.modifiers.contains(.shift) { out += "⇧" }
        if shortcut.modifiers.contains(.command) { out += "⌘" }
        return out + glyph(shortcut.key)
    }

    static func glyph(_ key: String) -> String {
        switch key.lowercased() {
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "return": return "⏎"
        case "tab": return "⇥"
        case "space": return String(localized: "Space")
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "-": return "−"
        default: return key.uppercased()
        }
    }

    /// What VoiceOver reads: "Option Command N".
    static func spoken(_ shortcut: KeyShortcut) -> String {
        var words: [String] = []
        if shortcut.modifiers.contains(.control) { words.append(String(localized: "Control")) }
        if shortcut.modifiers.contains(.option) { words.append(String(localized: "Option")) }
        if shortcut.modifiers.contains(.shift) { words.append(String(localized: "Shift")) }
        if shortcut.modifiers.contains(.command) { words.append(String(localized: "Command")) }
        words.append(keyName(shortcut.key))
        return words.joined(separator: " ")
    }

    static func keyName(_ key: String) -> String {
        switch key.lowercased() {
        case "escape": return String(localized: "Escape")
        case "delete": return String(localized: "Delete")
        case "return": return String(localized: "Return")
        case "tab": return String(localized: "Tab")
        case "space": return String(localized: "Space")
        case "up": return String(localized: "Up Arrow")
        case "down": return String(localized: "Down Arrow")
        case "left": return String(localized: "Left Arrow")
        case "right": return String(localized: "Right Arrow")
        case "+": return String(localized: "Plus")
        case "-": return String(localized: "Minus")
        case "=": return String(localized: "Equals")
        case "[": return String(localized: "Left Bracket")
        case "]": return String(localized: "Right Bracket")
        case ",": return String(localized: "Comma")
        case ".": return String(localized: "Full Stop")
        case "/": return String(localized: "Slash")
        default: return key.uppercased()
        }
    }
}

// MARK: - Shortcut list (P-057)

struct ShortcutEntry: Identifiable, Equatable {
    enum Status: Equatable {
        case active
        /// Switched off by the single-key setting.
        case singleKeysOff
        /// Another shortcut wins these keys wherever this one works (`ShortcutRules.hidden`).
        case keysTaken
    }

    let id: String
    let title: String
    let keys: String
    let spoken: String
    let status: Status

    var isOff: Bool { status != .active }
}

struct ShortcutSection: Identifiable, Equatable {
    enum Group: Hashable {
        case scope(KeyScope)
        /// Keys the text views handle themselves while text is being edited (display only).
        case textEditing
    }

    let group: Group
    let entries: [ShortcutEntry]

    var id: String {
        switch group {
        case .scope(let scope): return scope.rawValue
        case .textEditing: return "textEditing"
        }
    }

    var scope: KeyScope? {
        if case .scope(let scope) = group { return scope }
        return nil
    }
}

/// A shortcut the list shows but nobody registers.
struct ListedShortcut: Equatable {
    let id: String
    let title: String
    let shortcut: KeyShortcut
}

enum ShortcutDirectory {
    static let scopeOrder: [KeyScope] = [.global, .library, .document, .canvas]

    /// The formatting keys of the text box editor (F026, P-055): its text view's own UIKeyCommands, live only while it
    /// edits, so they are listed here and never registered.
    static var textEditingKeys: [ListedShortcut] {
        [ListedShortcut(id: "text.bold", title: String(localized: "Bold"), shortcut: KeyShortcut("b", .command)),
         ListedShortcut(id: "text.italic", title: String(localized: "Italic"), shortcut: KeyShortcut("i", .command)),
         ListedShortcut(id: "text.underline", title: String(localized: "Underline"), shortcut: KeyShortcut("u", .command)),
         ListedShortcut(id: "text.strikethrough", title: String(localized: "Strikethrough"),
                        shortcut: KeyShortcut("x", [.command, .shift])),
         ListedShortcut(id: "text.alignLeft", title: String(localized: "Align Left"), shortcut: KeyShortcut("{", .command)),
         ListedShortcut(id: "text.alignCentre", title: String(localized: "Align Centre"),
                        shortcut: KeyShortcut("|", .command)),
         ListedShortcut(id: "text.alignRight", title: String(localized: "Align Right"),
                        shortcut: KeyShortcut("}", .command)),
         ListedShortcut(id: "text.outdent", title: String(localized: "Outdent"), shortcut: KeyShortcut("tab", .shift)),
         ListedShortcut(id: "text.finishEditing", title: String(localized: "Finish Editing"),
                        shortcut: KeyShortcut("escape"))]
    }

    /// Every titled shortcut (those the single-key setting switched off, then the registered ones, marking those
    /// another shortcut wins everywhere), grouped by where it works and sorted by title, then the text editing keys;
    /// `query` matches titles and keys. Untitled aliases (⌘= for ⌘+) are left out.
    static func sections(active: [KeyCommandDescriptor], off: [KeyCommandDescriptor] = [], query: String) -> [ShortcutSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = ShortcutRules.hidden(in: active)
        var seen = Set<String>()
        var entries: [ShortcutSection.Group: [ShortcutEntry]] = [:]

        func add(id: String, title raw: String, shortcut: KeyShortcut, group: ShortcutSection.Group,
                 status: ShortcutEntry.Status) {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(id).inserted else { return }
            let keys = ShortcutFormatter.display(shortcut)
            if !q.isEmpty, !title.localizedStandardContains(q), !keys.localizedStandardContains(q) { return }
            entries[group, default: []].append(ShortcutEntry(id: id, title: title, keys: keys,
                                                             spoken: ShortcutFormatter.spoken(shortcut), status: status))
        }

        for d in off {
            add(id: d.id, title: d.title, shortcut: d.shortcut, group: .scope(d.scope), status: .singleKeysOff)
        }
        for d in active {
            add(id: d.id, title: d.title, shortcut: d.shortcut, group: .scope(d.scope),
                status: hidden.contains(d.id) ? .keysTaken : .active)
        }
        for k in textEditingKeys {
            add(id: k.id, title: k.title, shortcut: k.shortcut, group: .textEditing, status: .active)
        }

        let groups = scopeOrder.map { ShortcutSection.Group.scope($0) } + [.textEditing]
        return groups.compactMap { group in
            guard let list = entries[group], !list.isEmpty else { return nil }
            let sorted = list.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return ShortcutSection(group: group, entries: sorted)
        }
    }

    static func title(_ group: ShortcutSection.Group) -> String {
        switch group {
        case .scope(.global): return String(localized: "Everywhere")
        case .scope(.library): return String(localized: "Library")
        case .scope(.document): return String(localized: "Documents")
        case .scope(.canvas): return String(localized: "On the Page")
        case .textEditing: return String(localized: "While Editing Text")
        }
    }

    static func footer(_ group: ShortcutSection.Group) -> String? {
        switch group {
        case .scope(.canvas): return String(localized: "These work while you are not typing in a text box.")
        case .textEditing: return String(localized: "These work while you type in a text box.")
        default: return nil
        }
    }
}

// MARK: - Settings › General › Keyboard and Pointer

/// Opaque grouped list (DESIGN.md §14.8): the single-key switch, the pointer gestures, and every shortcut. Changing the
/// switch runs `settings.set`, so the assistant, plugins and the bridge can do the same.
struct KeyboardSettingsView: View {
    let app: NibApp
    @State private var revision = 0
    @State private var query = ""

    private var runtime: KeyboardRuntime? { app.services.get(KeyboardRuntime.serviceKey, as: KeyboardRuntime.self) }

    var body: some View {
        let _ = revision
        let enabled = app.settings.get(KeyboardSettings.singleKeyShortcuts)
        let sections = ShortcutDirectory.sections(active: app.content.keyCommands.all,
                                                  off: runtime?.withheldDescriptors ?? [], query: query)
        List {
            Section {
                KeyboardSettingToggle(app: app, title: String(localized: "Single-key shortcuts"),
                                      name: KeyboardSettings.singleKeyShortcuts.name, stored: enabled)
            } footer: {
                Text(String(localized: "Switch tools with one key, such as P for the pen or E for the eraser. They never fire while you type."))
            }

            Section {
                NibRow(String(localized: "Show every shortcut"),
                       subtitle: String(localized: "Hold Command on any screen to see what its keys do.")) {
                    KeyHint("⌘").accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                NibRow(String(localized: "Page menu"),
                       subtitle: String(localized: "Right-click or click with two fingers on a page."))
                NibRow(String(localized: "Zoom"),
                       subtitle: String(localized: "Hold Command and scroll to zoom towards the pointer. Pinch on a trackpad works too.")) {
                    KeyHint("⌘").accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text(String(localized: "Pointer and trackpad"))
            }

            Section {
                NibSearchField(text: $query, prompt: String(localized: "Search shortcuts"))
                    .listRowInsets(EdgeInsets(top: NibSpacing.xs, leading: NibSpacing.m, bottom: NibSpacing.xs,
                                              trailing: NibSpacing.m))
                    .listRowBackground(Color.clear)
            } header: {
                Text(String(localized: "Shortcuts"))
            }

            if sections.isEmpty {
                Section {
                    Text(String(localized: "No shortcuts match your search."))
                        .font(NibFont.footnote)
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        ShortcutRow(entry: entry)
                    }
                } header: {
                    Text(ShortcutDirectory.title(section.group))
                } footer: {
                    if let footer = ShortcutDirectory.footer(section.group) { Text(footer) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Keyboard and Pointer"))
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange).receive(on: DispatchQueue.main)) { _ in
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange, object: app.content.keyCommands)
            .receive(on: DispatchQueue.main)) { _ in
            revision += 1
        }
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry

    private var note: String? {
        switch entry.status {
        case .active: return nil
        case .singleKeysOff: return String(localized: "Off")
        case .keysTaken: return String(localized: "Off: another shortcut uses these keys")
        }
    }

    var body: some View {
        NibRow(entry.title, subtitle: note) {
            KeyHint(entry.keys)
                .opacity(entry.isOff ? NibOpacity.disabled : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(note.map { "\(entry.spoken), \($0)" } ?? entry.spoken)
    }
}

/// A switch bound to one declared setting; flipping it runs `settings.set`, and a call that fails puts the switch back.
private struct KeyboardSettingToggle: View {
    let app: NibApp
    let title: String
    let name: String
    let stored: Bool
    @State private var isOn = true

    var body: some View {
        NibToggle(title, isOn: $isOn)
            .onAppear { isOn = stored }
            .onChange(of: stored) { _, value in isOn = value }
            .onChange(of: isOn) { _, value in
                guard value != stored else { return }
                let params: JSONValue = ["name": .string(name), "value": .bool(value)]
                Task { @MainActor in
                    do {
                        _ = try await app.bus.execute(CommandIDs.settingsSet, params, session: app.services.sessions.active)
                    } catch {
                        isOn = stored
                    }
                }
            }
    }
}

// MARK: - Sheets opened from the keyboard (⌘R Rename, ⌥⌘G Go to Page)

@MainActor
enum KeyboardPanels {
    static func register(_ app: NibApp, owner: String) {
        var rename = PanelDescriptor(id: KeyboardPanelIDs.rename, title: String(localized: "Rename"),
                                     icon: NibSymbol.documentWrite.name, placement: .sheet, order: 0, owner: owner) { ctx in
            AnyView(RenameDocumentSheet(app: ctx.app, doc: ctx.session?.document, dismiss: ctx.dismiss))
        }
        rename.providesHeader = true
        app.ui.panels.register(rename)

        var goTo = PanelDescriptor(id: KeyboardPanelIDs.goToPage, title: String(localized: "Go to Page"),
                                   icon: NibSymbol.pages.name, placement: .sheet, order: 0, owner: owner,
                                   docKinds: ShortcutContext.canvasKinds) { ctx in
            AnyView(GoToPageSheet(app: ctx.app, session: ctx.session, dismiss: ctx.dismiss))
        }
        goTo.providesHeader = true
        app.ui.panels.register(goTo)
    }
}

/// Title rules for Rename (the title is the package's file name).
enum RenameRules {
    enum Problem: Equatable {
        case empty, unchanged, tooLong, reservedCharacter, leadingDot
    }

    static let maxLength = 200

    static func trimmed(_ title: String) -> String {
        title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func problem(_ title: String, current: String?) -> Problem? {
        let t = trimmed(title)
        if t.isEmpty { return .empty }
        if t == current { return .unchanged }
        if t.count > maxLength { return .tooLong }
        if t.contains("/") || t.contains(":") { return .reservedCharacter }
        if t.hasPrefix(".") { return .leadingDot }
        return nil
    }

    static func message(_ problem: Problem) -> String? {
        switch problem {
        case .empty, .unchanged: return nil
        case .tooLong: return String(localized: "Use \(maxLength) characters or fewer.")
        case .reservedCharacter: return String(localized: "Titles can’t contain / or :.")
        case .leadingDot: return String(localized: "Titles can’t start with a full stop.")
        }
    }
}

/// Page numbers typed into Go to Page.
enum PageJump {
    /// The 0-based index of the page a typed number (1-based) names; nil when it is not a page of the document.
    static func index(_ input: String, pageCount: Int) -> Int? {
        let digits = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(digits), n >= 1, n <= pageCount else { return nil }
        return n - 1
    }
}

/// ⌘R: rename the open document (`library.rename`). Opens with the title selected so typing replaces it.
struct RenameDocumentSheet: View {
    let app: NibApp
    let doc: DocumentID?
    let dismiss: @MainActor () -> Void
    @State private var title = ""
    @State private var current: String?
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        let problem = RenameRules.problem(title, current: current)
        VStack(alignment: .leading, spacing: 0) {
            NibSheetHeader(String(localized: "Rename"), primaryTitle: String(localized: "Rename"),
                           isPrimaryEnabled: doc != nil && problem == nil && !isWorking,
                           onCancel: { dismiss() }, onPrimary: { commit() })
            if doc == nil {
                Text(String(localized: "Open a document to rename it."))
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.labelSecondary)
                    .padding(.horizontal, NibSpacing.xl)
            } else {
                VStack(alignment: .leading, spacing: NibSpacing.s) {
                    NibField(text: $title, prompt: String(localized: "Title"))
                        .focused($focused)
                        .submitLabel(.done)
                        .accessibilityLabel(String(localized: "Title"))
                    if let message = error ?? problem.flatMap(RenameRules.message) {
                        Text(message)
                            .font(NibFont.footnote)
                            .foregroundStyle(error == nil ? NibColor.labelSecondary : NibColor.destructive)
                    }
                }
                .padding(.horizontal, NibSpacing.xl)
            }
            Spacer(minLength: NibSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NibColor.backgroundSecondary)
        .presentationDetents([.medium])
        .onChange(of: title) { _, value in
            error = nil
            // The field grows to a second line on Return; Return means Rename here.
            if value.contains("\n") {
                title = value.replacingOccurrences(of: "\n", with: "")
                commit()
            }
        }
        .task {
            guard let doc else { return }
            let name = app.services.library?.node(doc)?.title
            current = name
            title = name ?? ""
            focused = true
        }
    }

    private func commit() {
        guard let doc, RenameRules.problem(title, current: current) == nil, !isWorking else { return }
        isWorking = true
        let params: JSONValue = ["ref": .string(NodeRef.document(doc).description),
                                 "title": .string(RenameRules.trimmed(title))]
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(CommandIDs.libraryRename, params, session: app.services.sessions.active)
                dismiss()
            } catch {
                self.error = NibError.wrap(error).message
                isWorking = false
            }
        }
    }
}

/// ⌥⌘G: jump to a page (a board on a whiteboard) by number (`view.goToPage`).
struct GoToPageSheet: View {
    let app: NibApp
    let session: EditorSession?
    let dismiss: @MainActor () -> Void
    @State private var input = ""
    @State private var pages: [PageID] = []
    @State private var currentIndex: Int?
    @State private var isBoard = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let target = PageJump.index(input, pageCount: pages.count)
        let title = isBoard ? String(localized: "Go to Board") : String(localized: "Go to Page")
        VStack(alignment: .leading, spacing: 0) {
            NibSheetHeader(title, primaryTitle: String(localized: "Go"), isPrimaryEnabled: target != nil,
                           onCancel: { dismiss() }, onPrimary: { go() })
            VStack(alignment: .leading, spacing: NibSpacing.s) {
                NibField(text: $input, prompt: placeholder)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .accessibilityLabel(isBoard ? String(localized: "Board number") : String(localized: "Page number"))
                Text(error ?? rangeHint)
                    .font(NibFont.footnote)
                    .foregroundStyle(error == nil ? NibColor.labelSecondary : NibColor.destructive)
            }
            .padding(.horizontal, NibSpacing.xl)
            Spacer(minLength: NibSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NibColor.backgroundSecondary)
        .presentationDetents([.medium])
        .onChange(of: input) { _, value in
            error = nil
            if value.contains("\n") {
                input = value.replacingOccurrences(of: "\n", with: "")
                go()
            }
        }
        .task { load() }
    }

    private var placeholder: String {
        guard let i = currentIndex else { return isBoard ? String(localized: "Board number") : String(localized: "Page number") }
        return isBoard ? String(localized: "Board \(i + 1) of \(pages.count)")
                       : String(localized: "Page \(i + 1) of \(pages.count)")
    }

    private var rangeHint: String {
        pages.isEmpty ? String(localized: "This document has no pages.")
                      : String(localized: "Enter a number from 1 to \(pages.count).")
    }

    private func load() {
        guard let doc = session?.document, let content = try? app.workspace.content(doc) else { return }
        pages = content.livePages.map { $0.id }
        isBoard = content.meta.kind == .whiteboard
        currentIndex = session?.page.flatMap { content.pageIndex($0) }
        focused = true
    }

    private func go() {
        guard let doc = session?.document, let index = PageJump.index(input, pageCount: pages.count) else { return }
        let params: JSONValue = ["page": .string(NodeRef.page(doc, pages[index]).description)]
        Task { @MainActor in
            do {
                _ = try await app.bus.execute(CommandIDs.viewGoToPage, params, session: session)
                dismiss()
            } catch {
                self.error = NibError.wrap(error).message
            }
        }
    }
}
