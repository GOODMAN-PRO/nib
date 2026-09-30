import SwiftUI
import UIKit
import NibContracts
import NibDesign

public enum FeatReplayFeature: NibFeature {
    public static let id = "replay"

    public static func register(_ app: NibApp) {
        let controller = ReplayController(app: app)
        app.services.set(controller, for: ReplayController.serviceKey)
        app.commands.register(ReplaySetMode.self)
        app.commands.register(ReplaySeekToItem.self)
        app.commands.register(ReplayTapAt.self)
        app.content.tapHandlers.register(TapHandlerDescriptor(
            id: "replay.handwriting", owner: id, gesture: .tap, command: CommandIDs.replayTapAt,
            order: 50, itemKinds: [.stroke], worksInReadOnly: true))
        for mode in ReplayMode.allCases {
            var menu = MenuItemDescriptor(
                id: "replay.mode." + mode.rawValue, title: ReplayLabels.title(mode), icon: NibSymbol.history.name,
                location: .documentMore, order: 410 + (ReplayMode.allCases.firstIndex(of: mode) ?? 0), owner: id,
                command: CommandIDs.replaySetMode, params: { _ in ["mode": .string(mode.rawValue), "enabled": true] },
                isVisible: { $0.session?.replay != nil }, submenu: String(localized: "Note Replay"))
            menu.isChecked = { $0.session?.replay?.mode == mode }
            app.ui.menus.register(menu)
        }
        app.ui.menus.register(MenuItemDescriptor(
            id: "replay.options", title: String(localized: "Replay Options"), icon: NibSymbol.history.name,
            location: .documentMore, order: 415, owner: id, command: CommandIDs.panelOpen,
            params: { _ in ["id": "replay.options"] }, isVisible: { $0.session?.document != nil }))
        app.ui.menus.register(MenuItemDescriptor(
            id: "replay.item", title: String(localized: "Replay Handwriting"), icon: NibSymbol.play.name,
            location: .objectMenu, order: 450, owner: id, command: CommandIDs.replaySeekToItem,
            params: { ctx in ["ref": .string(ctx.ref ?? ctx.selection.refs.first ?? "")] },
            isVisible: { $0.itemKinds == [.stroke] && ($0.ref != nil || $0.selection.items.count == 1) }))
        app.ui.panels.register(PanelDescriptor(
            id: "replay.options", title: String(localized: "Note Replay"), icon: NibSymbol.history.name,
            placement: .sheet, order: 450, owner: id, docKinds: [.notebook, .whiteboard]) { context in
                if let session = context.session {
                    return AnyView(ReplayOptionsView(app: context.app, session: session, options: controller.options(for: session)))
                }
                return AnyView(NibEmptyState(symbol: .history, title: String(localized: "Open a note"),
                                            message: String(localized: "Play a recording to replay its handwriting.")))
            })
        let modes = ReplayMode.allCases
        for (index, mode) in modes.enumerated() {
            var key = KeyCommandDescriptor(
                id: "replay.modeKey." + mode.rawValue, title: ReplayLabels.title(mode),
                shortcut: KeyShortcut(String(index + 1), [.command, .option, .shift]),
                command: CommandIDs.replaySetMode, params: ["mode": .string(mode.rawValue), "enabled": true],
                scope: .canvas, owner: id)
            key.docKinds = [.notebook, .whiteboard]
            app.content.keyCommands.register(key)
        }
    }

    public static func start(_ app: NibApp) async { ReplayController.of(app.services)?.start() }
}

@MainActor
enum ReplayLabels {
    static func title(_ mode: ReplayMode) -> String {
        switch mode {
        case .spotlight: return String(localized: "Spotlight")
        case .reveal: return String(localized: "Reveal")
        case .showAll: return String(localized: "Static")
        }
    }
    static func detail(_ mode: ReplayMode) -> String {
        switch mode {
        case .spotlight: return String(localized: "Fade handwriting ahead of the recording.")
        case .reveal: return String(localized: "Draw handwriting as the recording reaches it.")
        case .showAll: return String(localized: "Keep all handwriting visible.")
        }
    }
}

@MainActor
struct ReplayOptionsView: View {
    let app: NibApp
    @ObservedObject var session: EditorSession
    @ObservedObject var options: ReplayOptions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                NibToggle(String(localized: "Replay handwriting"), isOn: binding(\.enabled, param: "enabled"))
                VStack(spacing: NibSpacing.xs) {
                    ForEach(ReplayMode.allCases, id: \.self) { mode in
                        NibButton(ReplayLabels.title(mode), symbol: options.mode == mode ? .checkCircle : .circle,
                                  kind: .plain, expands: true) { set(["mode": .string(mode.rawValue), "enabled": true]) }
                            .accessibilityValue(options.mode == mode ? String(localized: "Selected") : "")
                            .accessibilityHint(ReplayLabels.detail(mode))
                    }
                }
                Text(ReplayLabels.detail(options.mode))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NibToggle(String(localized: "Follow handwriting across pages"), isOn: binding(\.followAlong, param: "followAlong"))
                NibButton(options.fullScreen ? String(localized: "Exit Full Screen") : String(localized: "Replay in Full Screen"),
                          symbol: .present, expands: true) {
                    set(["fullScreen": .bool(!options.fullScreen)])
                }
                .disabled(session.replay == nil)
                Text(String(localized: "Tap handwriting to hear the recording from one second before it was written."))
                    .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NibSpacing.l)
        }
        .background(NibColor.background)
    }

    private func binding(_ key: ReferenceWritableKeyPath<ReplayOptions, Bool>, param: String) -> Binding<Bool> {
        Binding(get: { options[keyPath: key] }, set: { set([param: .bool($0)]) })
    }
    private func set(_ params: JSONValue) {
        let base: JSONValue = ["mode": .string(options.mode.rawValue)]
        app.perform(CommandIDs.replaySetMode, base.merging(params), session: session)
    }
}

/// Full-screen uses the registered canvas with a read-only session, rather than a raster snapshot or another renderer.
/// The controls occupy an opaque dock below the canvas, so no glass ever covers handwriting.
@MainActor
final class ReplayFullScreenController: UIViewController {
    private let canvas: UIViewController
    private let replaySession: EditorSession
    private let source: EditorSession
    private let app: NibApp
    private let options: ReplayOptions
    private var onClose: (() -> Void)?

    init(canvas: UIViewController, replaySession: EditorSession, source: EditorSession, app: NibApp,
         options: ReplayOptions, onClose: @escaping () -> Void) {
        self.canvas = canvas; self.replaySession = replaySession; self.source = source
        self.app = app; self.options = options; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { return nil }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NibUIColor.background
        addChild(canvas)
        view.addSubview(canvas.view)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        canvas.didMove(toParent: self)
        let dock = UIHostingController(rootView: ReplayFullScreenDock(app: app, source: source, options: options))
        dock.sizingOptions = [.intrinsicContentSize]
        addChild(dock); view.addSubview(dock.view); dock.view.translatesAutoresizingMaskIntoConstraints = false
        dock.didMove(toParent: self)
        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: dock.view.topAnchor),
            dock.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        replaySession.editor = canvas as? DocumentEditing
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onClose?(); onClose = nil
        }
    }
}

@MainActor
private struct ReplayFullScreenDock: View {
    let app: NibApp
    let source: EditorSession
    @ObservedObject var options: ReplayOptions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.m) { controls }
            VStack(spacing: NibSpacing.s) { controls }
        }
        .padding(NibSpacing.m)
        .frame(maxWidth: .infinity)
        .background(NibColor.background)
    }
    @ViewBuilder private var controls: some View {
        NibButton(String(localized: "Play or Pause"), symbol: .play, kind: .plain) {
            app.perform(CommandIDs.audioPlay, ["toggle": true], session: source)
        }
        NibToggle(String(localized: "Follow pages"), isOn: Binding(get: { options.followAlong }, set: {
            app.perform(CommandIDs.replaySetMode, ["mode": .string(options.mode.rawValue), "followAlong": .bool($0)], session: source)
        }))
        NibButton(String(localized: "Exit Full Screen"), symbol: .xmark, kind: .plain,
                  shortcut: KeyboardShortcut(.escape, modifiers: [])) {
            app.perform(CommandIDs.replaySetMode, ["mode": .string(options.mode.rawValue), "fullScreen": false], session: source)
        }
    }
}
