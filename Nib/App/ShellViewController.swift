import UIKit
import SwiftUI
import NibContracts

/// Root of every window. Owns the tab model and implements `SceneNavigator`; everything visible is provided by
/// features through `app.ui.screens` (library, document chrome, settings, onboarding) with minimal fallbacks.
@MainActor
final class ShellViewController: UIViewController, SceneNavigator {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    private var content: UIViewController?
    private var tabBar: UIView?
    private var failureObserver: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        self.session = EditorSession()
        super.init(nibName: nil, bundle: nil)
        app.services.sessions.add(session)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var rootViewController: UIViewController? { self }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        failureObserver = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?["error"] as? NibError)?.message ?? "Something went wrong"
            Task { @MainActor in self?.toast(message) }
        }
        if let onboarding = app.ui.screens.onboarding?(app, self) {
            display(onboarding)
        } else {
            showLibrary(folder: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
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

    // MARK: SceneNavigator

    func showLibrary(folder: FolderID?) {
        session.document = nil
        display(app.ui.screens.libraryRoot?(app, self) ?? FallbackLibraryViewController(app: app, navigator: self))
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
        let editor = app.ui.editors.get(kind.rawValue)?.make(doc, session, app)
            ?? FallbackEditorViewController(message: "No editor is installed for \(kind.rawValue) documents.")
        display(app.ui.screens.documentContainer?(editor, doc, app, self) ?? editor)
        if let p = page { session.editor?.reveal(page: p, rect: nil, animated: false) }
    }

    func closeDocument(_ doc: DocumentID) {
        openDocuments.removeAll { $0 == doc }
        guard activeDocument == doc else {
            refreshTabBar()
            return
        }
        activeDocument = nil
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
        top.present(viewController, animated: true)
    }

    // MARK: Keyboard (every shortcut is a registered KeyCommandDescriptor that runs a command)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let inDocument = activeDocument != nil
        return app.content.keyCommands.all.compactMap { d -> UIKeyCommand? in
            switch d.scope {
            case .global: break
            case .library: if inDocument { return nil }
            case .document: if !inDocument { return nil }
            case .canvas: if !inDocument || session.isEditingText { return nil }
            }
            let command = UIKeyCommand(title: d.title, action: #selector(runKeyCommand(_:)),
                                       input: ShellViewController.keyInput(d.shortcut.key),
                                       modifierFlags: ShellViewController.modifierFlags(d.shortcut.modifiers),
                                       propertyList: d.id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func runKeyCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String, let d = app.content.keyCommands.get(id) else { return }
        app.perform(d.command, d.params, session: session)
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
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        content = vc
        refreshTabBar()
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
