import UIKit
import SwiftUI
import NibContracts
import NibDesign

/// Root of every window. Owns the tab model and implements `SceneNavigator`; everything visible is provided by
/// features through `app.ui.screens` (library, document chrome, settings, onboarding) with minimal fallbacks.
@MainActor
final class ShellViewController: UIViewController, SceneNavigator, UIGestureRecognizerDelegate {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    private var content: UIViewController?
    private var tabBar: UIView?
    private var qaProbe: QAStateProbe?
    private var failureObserver: NSObjectProtocol?
    /// What the window shows right now, for key commands (`KeyCommandContext`): a document of `shownKind`, or the
    /// library / onboarding. `activeDocument` stays the selected tab while the library shows.
    private var showsDocument = false
    private var shownKind: DocumentKind?
    /// The UIKeyCommands last handed to UIKit, rebuilt when the registry or the window's context changes.
    private var keyCommandCache: (generation: UInt64, context: KeyCommandContext, commands: [UIKeyCommand])?
    private var heldKeyModifiers = ShellPhysicalModifiers()

    init(app: NibApp) {
        self.app = app
        self.session = EditorSession()
        super.init(nibName: nil, bundle: nil)
        app.services.sessions.add(session)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keep physical chord tracking with the responder that owns its lifetime.
    /// A forwarded printable key can omit a modifier delivered as a separate press.
    private struct ShellPhysicalModifiers {
        private var held: Set<UIKeyboardHIDUsage> = []

        mutating func began(_ code: UIKeyboardHIDUsage) {
            if Self.flag(for: code) != nil { held.insert(code) }
        }

        mutating func ended(_ code: UIKeyboardHIDUsage) { held.remove(code) }
        mutating func reset() { held.removeAll() }

        func combined(key: UIKeyModifierFlags, event: UIKeyModifierFlags) -> UIKeyModifierFlags {
            held.reduce(into: key.union(event)) { flags, code in
                if let flag = Self.flag(for: code) { flags.formUnion(flag) }
            }
        }

        private static func flag(for code: UIKeyboardHIDUsage) -> UIKeyModifierFlags? {
            switch code {
            case .keyboardLeftGUI, .keyboardRightGUI: .command
            case .keyboardLeftShift, .keyboardRightShift: .shift
            case .keyboardLeftAlt, .keyboardRightAlt: .alternate
            case .keyboardLeftControl, .keyboardRightControl: .control
            default: nil
            }
        }
    }

    var rootViewController: UIViewController? { self }

    override func viewDidLoad() {
        super.viewDidLoad()
        synchroniseLiquidMode()
        NotificationCenter.default.addObserver(self, selector: #selector(synchroniseLiquidMode),
            name: SettingsStore.didChange, object: app.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(clearHardwareModifiers),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareWindowDidResign(_:)),
            name: UIWindow.didResignKeyNotification, object: nil)
        let focusTap = UITapGestureRecognizer(target: self, action: #selector(reclaimLibraryKeyFocusAfterTap))
        focusTap.cancelsTouchesInView = false
        focusTap.delaysTouchesBegan = false
        focusTap.delaysTouchesEnded = false
        focusTap.delegate = self
        view.addGestureRecognizer(focusTap)
        view.backgroundColor = .systemBackground
        if NibUITestMode.isEnabled {
            let probe = QAStateProbe(shell: self)
            qaProbe = probe
            view.addSubview(probe)
            view.addSubview(probe.clipboardProbe)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (shell: ShellViewController, _: UITraitCollection) in
            shell.synchroniseContentAppearance()
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?["error"] as? NibError)?.message ?? "Something went wrong"
            Task { @MainActor in self?.toastIfActive(message) }
        }
        showInitialScreen()
    }

    /// Re-evaluate first run after asynchronous fixture/library preparation finishes.
    func showInitialScreen() {
        if NibUITestMode.isEnabled && !UITestFixture.isReady {
            display(FallbackEditorViewController(message: "Preparing test fixture…"))
        } else if let onboarding = app.ui.screens.onboarding?(app, self) {
            display(onboarding)
        } else {
            showLibrary(folder: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchroniseContentAppearance()
        reclaimKeyFocusIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        if let bar = tabBar {
            bar.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: 36)
            content?.view.frame = CGRect(x: 0, y: top + 36, width: view.bounds.width, height: max(0, view.bounds.height - top - 36))
        } else {
            content?.view.frame = view.bounds
        }
    }

    // MARK: Window activation (key-window tracking)

    /// Makes this window the one that app-level commands target: `ui.activeNavigator` (what `ctx.navigator` returns to
    /// `window.showLibrary`, `doc.open`, `panel.open`…) and the active session (`ctx.activeSession`, `session.activated`).
    /// The scene delegate calls it when the window becomes key or its scene becomes active, and the key-command bridge
    /// before every command it runs.
    func activateWindow() {
        ShellViewController.noteActivation(self)
        if app.ui.activeNavigator !== self { app.ui.activeNavigator = self }
        app.services.sessions.activate(session)   // emits `session.activated` only when it changes
    }

    /// Every window, most recently activated first: which one takes over when the active window closes.
    private static var activationOrder: [WeakShell] = []

    private struct WeakShell {
        weak var shell: ShellViewController?
    }

    private static func noteActivation(_ shell: ShellViewController) {
        guard activationOrder.first?.shell !== shell else { return }
        activationOrder.removeAll { $0.shell == nil || $0.shell === shell }
        activationOrder.insert(WeakShell(shell: shell), at: 0)
    }

    /// The window among `candidates` that was activated most recently (nil when none of them ever was).
    static func mostRecentlyActivated(among candidates: [ShellViewController]) -> ShellViewController? {
        activationOrder.lazy.compactMap { $0.shell }.first { shell in candidates.contains { $0 === shell } }
    }

    /// Forgets a window whose scene went away.
    static func windowDidClose(_ shell: ShellViewController) {
        activationOrder.removeAll { $0.shell == nil || $0.shell === shell }
    }

    /// The window became key (the scene delegate observes `UIWindow.didBecomeKeyNotification`): commands now target it,
    /// and it takes keyboard focus when nothing inside it has it, so its key commands work at once.
    func windowDidBecomeKey() {
        activateWindow()
        reclaimKeyFocusIfNeeded()
    }

    /// True when this window is the key window, i.e. the one that receives hardware keys.
    var isKeyWindow: Bool { viewIfLoaded?.window?.isKeyWindow ?? false }

    // MARK: Presentation state of the content (status bar, home indicator, system edge gestures)

    // The shown screen decides (the document chrome hides the status bar for P-106 / `editing.hideStatusBar`,
    // presentation and full-screen modes hide the home indicator and defer edge gestures).
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForStatusBarStyle: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
    override var childViewControllerForPointerLock: UIViewController? { content }

    private func contentPresentationDidChange() {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfPrefersPointerLocked()
    }

    // MARK: SceneNavigator

    func showLibrary(folder: FolderID?) {
        session.document = nil
        showsDocument = false
        shownKind = nil
        display(app.ui.screens.libraryRoot?(app, self) ?? FallbackLibraryViewController(app: app, navigator: self))
        // Apply the requested folder to this window after the library has created its session model.
        if app.commands.entry(CommandIDs.librarySetView) != nil {
            app.perform(CommandIDs.librarySetView, ["folder": .string(folder.map { NodeRef.folder($0).description } ?? "lib")], session: session)
        }
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if let gate = app.ui.openGate, mode != .newWindow {
            Task { @MainActor in
                if await gate(doc) { self.performOpen(doc, page: page, mode: mode) }
            }
        } else {
            performOpen(doc, page: page, mode: mode)
        }
    }

    private func performOpen(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if mode == .newWindow {
            let activity = NSUserActivity(activityType: "app.nib.openDocument")
            activity.userInfo = ["doc": doc.raw, "page": page?.raw ?? ""]
            let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: nil)
            UIApplication.shared.activateSceneSession(for: request, errorHandler: nil)
            return
        }
        guard let docContent = try? app.workspace.content(doc) else {
            toast("Could not open the document")
            return
        }
        let asTab = mode == .newTab || app.settings.get(NibSettings.openAsTabs)
        if !openDocuments.contains(doc) {
            if !asTab, let current = activeDocument, let i = openDocuments.firstIndex(of: current) {
                openDocuments[i] = doc
            } else {
                openDocuments.append(doc)
            }
        }
        activeDocument = doc
        session.document = doc
        session.selection = Selection()
        session.page = page ?? docContent.livePages.first?.id
        let kind = docContent.meta.kind
        showsDocument = true
        shownKind = kind
        let editor = app.ui.editors.get(kind.rawValue)?.make(doc, session, app)
            ?? FallbackEditorViewController(message: "No editor is installed for \(kind.rawValue) documents.")
        display(app.ui.screens.documentContainer?(editor, doc, app, self) ?? editor)
        if let p = page { session.editor?.reveal(page: p, rect: nil, animated: false) }
    }

    /// contracts-v2 (G1): a restored tab joins the tab strip without being shown and without building its editor;
    /// selecting it later opens it (through `ui.openGate`) like any other tab.
    func addTab(_ doc: DocumentID) {
        guard !openDocuments.contains(doc) else { return }
        openDocuments.append(doc)
        refreshTabBar()
    }

    func closeDocument(_ doc: DocumentID) {
        openDocuments.removeAll { $0 == doc }
        guard activeDocument == doc else {
            refreshTabBar()
            return
        }
        activeDocument = nil
        // Closing a tab behind the library must not replace the library (or detach its active modal).
        guard session.document != nil else {
            refreshTabBar()
            return
        }
        if let next = openDocuments.last {
            openDocument(next, page: nil, mode: .replace)
        } else {
            showLibrary(folder: nil)
        }
    }

    func showSettings(page: String?) {
        let root = app.ui.screens.settingsRoot?(app, self) ?? FallbackSettingsViewController(app: app)
        presentModal(UINavigationController(rootViewController: root))
    }

    func presentModal(_ viewController: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        // Resolve from this scene, never from a process-global current trait collection.
        viewController.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        top.present(viewController, animated: true)
    }

    // MARK: Keyboard (every shortcut is a registered KeyCommandDescriptor that runs a command)

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // UIKit calls this only for presses not consumed by a UIKeyCommand.
        // Embedded SwiftUI hosts can leave a registered command unhandled even
        // with this shell as first responder, in documents as well as the library.
        // Replay the same validated route (including scope and text-input priority);
        // never intercept typing or dispatch a recognised shortcut a second time.
        for press in presses { if let key = press.key { heldKeyModifiers.began(key.keyCode) } }
        var unhandled = presses
        for press in presses {
            guard let key = press.key else { continue }
            let input: String
            switch key.keyCode {
            case .keyboardReturnOrEnter, .keypadEnter: input = "return"
            case .keyboardEscape: input = "escape"
            case .keyboardTab: input = "tab"
            case .keyboardDeleteOrBackspace: input = "delete"
            case .keyboardUpArrow: input = "up"
            case .keyboardDownArrow: input = "down"
            case .keyboardLeftArrow: input = "left"
            case .keyboardRightArrow: input = "right"
            case .keyboardSpacebar: input = "space"
            default: input = key.charactersIgnoringModifiers.lowercased()
            }
            // A forwarded press can carry the chord on its event rather than its
            // individual UIKey. Keep both, or Command-D becomes the plain D tool
            // shortcut and Command-Option-0 selects a colour instead of zooming.
            let flags = heldKeyModifiers.combined(key: key.modifierFlags, event: event?.modifierFlags ?? [])
            var modifiers: KeyModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            #if DEBUG
            NSLog("%@", "[Key routing] unhandled \(input) key flags \(key.modifierFlags.rawValue) event flags \(event?.modifierFlags.rawValue ?? 0)")
            #endif
            guard let descriptor = KeyCommandRouting.unhandledPress(KeyShortcut(input, modifiers),
                descriptors: app.content.keyCommands.all, in: keyCommandContext),
                  let command = keyCommands?.first(where: { $0.propertyList as? String == descriptor.id }),
                  let action = command.action, canPerformAction(action, withSender: command) else { continue }
            runKeyCommand(command)
            unhandled.remove(press)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldKeyModifiers.ended(key.keyCode) } }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldKeyModifiers.ended(key.keyCode) } }
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { heldKeyModifiers.reset() }
        return resigned
    }

    @objc private func clearHardwareModifiers() { heldKeyModifiers.reset() }

    @objc private func hardwareWindowDidResign(_ notification: Notification) {
        if notification.object as? UIWindow === viewIfLoaded?.window { heldKeyModifiers.reset() }
    }

    /// What decides which key commands are live in this window: the document kind it shows, whether text has the
    /// keyboard (a Nib text editor sets `session.isEditingText`; any other text field or view in the window counts too,
    /// so typing in a search field or a rename alert never switches tools), and whether it has tabs (the tab keys stay
    /// live in the library while the tab strip shows).
    var keyCommandContext: KeyCommandContext {
        let typing = session.isEditingText || ShellFocus.isEditingText(in: viewIfLoaded?.window)
        return KeyCommandContext(inDocument: showsDocument, docKind: shownKind, isEditingText: typing,
                                 hasTabs: !openDocuments.isEmpty)
    }

    /// One UIKeyCommand per shortcut: the registered descriptors live in this window (`KeyScope`, `docKinds`), the most
    /// specific winning a shared shortcut (`KeyCommandRouting`), in registry order.
    override var keyCommands: [UIKeyCommand]? {
        guard !hasPresentedModal else { return [] }
        let context = keyCommandContext
        let generation = app.content.keyCommands.generation
        if let cache = keyCommandCache, cache.generation == generation, cache.context == context { return cache.commands }
        let commands = KeyCommandRouting.active(app.content.keyCommands.all, in: context)
            .filter { KeyCommandRouting.overridesSystemKeys($0, in: context) }.map { d -> UIKeyCommand in
            let command = UIKeyCommand(title: d.title, action: #selector(runKeyCommand(_:)),
                                       input: ShellViewController.keyInput(d.shortcut.key),
                                       modifierFlags: ShellViewController.modifierFlags(d.shortcut.modifiers),
                                       propertyList: d.id)
            command.wantsPriorityOverSystemBehavior = KeyCommandRouting.overridesSystemKeys(d, in: context)
            return command.nibCommand(d.command)
        }
        keyCommandCache = (generation, context, commands)
        return commands
    }

    @objc private func runKeyCommand(_ sender: UIKeyCommand) {
        #if DEBUG
        NSLog("%@", "[Library key diagnostic] command \(String(describing: sender.propertyList)) typing \(keyCommandContext.isEditingText)")
        #endif
        guard let d = liveKeyCommand(sender) else { return }
        activateWindow()
        let params = d.resolvedParams(for: session)
        switch undoRoute(d, params: params) {
        case .window?:
            undoWindow(redo: d.command == CommandIDs.redo)
        case .nothing?:
            return
        case .document?, nil:
            app.perform(d.command, params, session: session)
        }
    }

    /// Menu and discoverability validation: a key command is enabled while it is live in this window, and ⌘Z / ⇧⌘Z
    /// while the document's history or the window's UndoManager has a step. A disabled key falls through to the system.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(runKeyCommand(_:)) else { return super.canPerformAction(action, withSender: sender) }
        guard !hasPresentedModal else { return false }
        // UIKit also probes a selector with a nil/non-command sender when building
        // the hardware-key routing table. Rejecting that probe disables every shortcut.
        guard let command = sender as? UIKeyCommand else {
            return KeyCommandRouting.active(app.content.keyCommands.all, in: keyCommandContext)
                .contains { KeyCommandRouting.overridesSystemKeys($0, in: keyCommandContext) }
        }
        guard let d = liveKeyCommand(command) else { return false }
        return undoRoute(d, params: d.resolvedParams(for: session)) != .nothing
    }

    /// Titles follow the registry; ⌘Z / ⇧⌘Z falling back to the window's UndoManager name its step ("Undo Move Palette").
    override func validate(_ command: UICommand) {
        super.validate(command)
        guard command.action == #selector(runKeyCommand(_:)), let id = command.propertyList as? String,
              let d = app.content.keyCommands.get(id) else { return }
        command.title = d.title
        if case .window? = undoRoute(d, params: d.resolvedParams(for: session)), let manager = windowUndoManager {
            command.title = d.command == CommandIDs.redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        }
    }

    /// The descriptor behind a UIKeyCommand this shell built, when it is still registered and live in this window.
    private func liveKeyCommand(_ command: UIKeyCommand) -> KeyCommandDescriptor? {
        guard !hasPresentedModal,
              let id = command.propertyList as? String, let d = app.content.keyCommands.get(id),
              d.isActive(in: keyCommandContext),
              KeyCommandRouting.overridesSystemKeys(d, in: keyCommandContext) else { return nil }
        return d
    }

    /// The window's UndoManager: window-level steps that are not in any document ("Move Palette", F016).
    private var windowUndoManager: UndoManager? { viewIfLoaded?.window?.undoManager }

    /// Where `edit.undo` / `edit.redo` act (nil for any other command): the document's history while it has a step,
    /// else the window's UndoManager.
    private func undoRoute(_ d: KeyCommandDescriptor, params: JSONValue) -> UndoRoute? {
        UndoRoute.forCommand(d.command, params: params, session: session, history: app.bus.history,
                             window: windowUndoManager)
    }

    private func undoWindow(redo: Bool) {
        // NSUndoManager closes one open top-level group itself; undoing inside a nested group or a replay would throw.
        guard let manager = windowUndoManager, manager.groupingLevel <= 1,
              !manager.isUndoing, !manager.isRedoing else { return }
        if redo {
            if manager.canRedo { manager.redo() }
        } else if manager.canUndo {
            manager.undo()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func reclaimLibraryKeyFocusAfterTap() {
        guard !showsDocument else { return }
        // SwiftUI finishes updating button/scroll focus after delivering the tap.
        DispatchQueue.main.async { [weak self] in self?.reclaimKeyFocusIfNeeded() }
    }

    /// A sheet owns the keyboard from presentation through dismissal, including
    /// the interval before its first text field acquires focus.
    private var hasPresentedModal: Bool {
        func hasModal(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.children.contains(where: hasModal)
        }
        return hasModal(self)
    }

    /// Library controls can take non-text focus without providing the shell's registered keys.
    /// Keep the shell focused there; a text input, sheet, or document editor keeps its own responder.
    private func reclaimKeyFocusIfNeeded() {
        guard let window = viewIfLoaded?.window else { return }
        // SwiftUI may present from a child host. During the transition no field
        // has focus yet; claiming it here would take the new dialog's keyboard.
        let hasCommandResponder = ShellFocus.hasFocus(in: window) &&
            ShellFocus.firstResponder()?.keyCommands?.contains(where: { command in
                guard let id = command.propertyList as? String else { return false }
                return app.content.keyCommands.get(id) != nil
            }) == true
        guard !hasCommandResponder,
            ShellFocusPolicy.shouldReclaim(isKeyWindow: window.isKeyWindow, shellHasFocus: isFirstResponder,
            hasModal: hasPresentedModal, isEditingText: ShellFocus.isEditingText(in: window),
            showsDocument: showsDocument, hasFocusedResponder: ShellFocus.hasFocus(in: window)) else { return }
        // A library can supply a native key responder within its SwiftUI host.
        // Let it recover focus before falling back to the scene's command table.
        if !showsDocument, content?.becomeFirstResponder() == true { return }
        #if DEBUG
        NSLog("%@", "[Library key diagnostic] reclaim from \(String(describing: ShellFocus.firstResponder()))")
        #endif
        becomeFirstResponder()
    }

    private static func keyInput(_ key: String) -> String {
        switch key {
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "escape": return UIKeyCommand.inputEscape
        case "delete": return UIKeyCommand.inputDelete
        case "tab": return "\t"
        case "return": return "\r"
        case "space": return " "
        default: return key
        }
    }

    private static func modifierFlags(_ m: KeyModifiers) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.option) { flags.insert(.alternate) }
        if m.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: URLs

    /// File URLs (Open In / share sheet) go to `import.files`; nib:// URLs to `app.openURL`.
    func handle(url: URL) {
        if url.isFileURL {
            app.perform(CommandIDs.importFiles, ["urls": [.string(url.absoluteString)]], session: session)
        } else {
            app.perform(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)], session: session)
        }
    }

    // MARK: Private

    private func display(_ vc: UIViewController) {
        if let old = content {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        setOverrideTraitCollection(chromeTraits, forChild: vc)
        view.addSubview(vc.view)
        if let qaProbe {
            view.bringSubviewToFront(qaProbe)
            view.bringSubviewToFront(qaProbe.clipboardProbe)
        }
        vc.didMove(toParent: self)
        content = vc
        keyCommandCache = nil
        refreshTabBar()
        contentPresentationDidChange()
        // The new screen may take focus as it appears; only when nothing did does the shell take it.
        Task { @MainActor [weak self] in self?.reclaimKeyFocusIfNeeded() }
    }

    @objc private func synchroniseLiquidMode() {
        traitOverrides[NibLiquidModeTrait.self] = NibLiquidMode(rawValue: app.settings.get(NibSettings.liquidMode)) ?? .full
    }

    private var chromeTraits: UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: traitCollection.userInterfaceStyle),
            UITraitCollection(accessibilityContrast: traitCollection.accessibilityContrast)
        ])
    }

    /// Child hosting controllers can be created before joining the window. Refresh their inherited scene traits
    /// both at attachment and on changes, without changing document/paper colours or rebuilding their state.
    private func synchroniseContentAppearance() {
        for child in children {
            setOverrideTraitCollection(chromeTraits, forChild: child)
            child.viewIfLoaded?.setNeedsLayout()
            child.viewIfLoaded?.setNeedsDisplay()
        }
        var presented = presentedViewController
        while let controller = presented {
            controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            presented = controller.presentedViewController
        }
    }

    private func refreshTabBar() {
        tabBar?.removeFromSuperview()
        tabBar = nil
        if activeDocument != nil, let bar = app.ui.sceneHooks?.makeTabBar(self) {
            view.addSubview(bar)
            tabBar = bar
        }
        view.setNeedsLayout()
    }

    /// Command failures are posted app-wide; only the window the user is working in shows them.
    private func toastIfActive(_ message: String) {
        guard app.ui.activeNavigator === self || app.ui.activeNavigator == nil else { return }
        toast(message)
    }

    private func toast(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        let width = min(view.bounds.width - 32, 480)
        let size = label.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: (view.bounds.width - size.width - 24) / 2,
                             y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 48,
                             width: size.width + 24, height: size.height + 16)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - Keyboard focus

/// Which responder has the keyboard in the key window. UIKit has no public accessor, so a nil-targeted action asks
/// the first responder to identify itself (it reaches the window, scene or application when nothing has focus).
@MainActor
enum ShellFocus {
    fileprivate static weak var captured: UIResponder?

    static func firstResponder() -> UIResponder? {
        captured = nil
        defer { captured = nil }
        UIApplication.shared.sendAction(#selector(UIResponder.nibShellCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return captured
    }

    /// True when a view or view controller inside `window` has the keyboard.
    static func hasFocus(in window: UIWindow) -> Bool {
        guard let responder = firstResponder() else { return false }
        return self.window(of: responder) === window
    }

    /// True when an editable text field or text view (or another text input) in `window` has the keyboard.
    static func isEditingText(in window: UIWindow?) -> Bool {
        guard let window, let responder = firstResponder(), self.window(of: responder) === window else { return false }
        if let textView = responder as? UITextView { return textView.isEditable }
        if let field = responder as? UITextField { return field.isEnabled }
        // Hosting/keyboard responders can implement UIKeyInput just to receive keys.
        // Only an actual text input should suppress library focus reclamation.
        return responder is UITextInput
    }

    private static func window(of responder: UIResponder) -> UIWindow? {
        if responder is UIWindow { return nil }   // the window itself: nothing inside it has focus
        if let view = responder as? UIView { return view.window }
        if let controller = responder as? UIViewController { return controller.viewIfLoaded?.window }
        return nil
    }
}

extension UIResponder {
    @objc fileprivate func nibShellCaptureFirstResponder(_ sender: Any?) {
        ShellFocus.captured = self
    }
}

// MARK: - Fallback screens (used only when the providing feature is missing or disabled)

final class FallbackLibraryViewController: UITableViewController {
    private let app: NibApp
    private weak var navigator: SceneNavigator?
    private var nodes: [LibraryNode] = []

    init(app: NibApp, navigator: SceneNavigator) {
        self.app = app
        self.navigator = navigator
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        nodes = app.services.library?.allNodes().filter { $0.kind == .document } ?? []
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(nodes.count, 1) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = nodes.isEmpty ? "No documents (library feature not installed)" : nodes[indexPath.row].title
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < nodes.count else { return }
        navigator?.openDocument(nodes[indexPath.row].id, page: nil, mode: .replace)
    }
}

final class FallbackEditorViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 32, dy: 32)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

final class FallbackSettingsViewController: UITableViewController {
    private let app: NibApp
    private var pages: [SettingsPageDescriptor] { app.ui.settingsPages.all }

    init(app: NibApp) {
        self.app = app
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "sheet.dismiss"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pages.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = pages[indexPath.row].title
        config.image = UIImage(systemName: pages[indexPath.row].icon)
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let page = pages[indexPath.row]
        navigationController?.pushViewController(UIHostingController(rootView: page.makeView(app)), animated: true)
    }
}
