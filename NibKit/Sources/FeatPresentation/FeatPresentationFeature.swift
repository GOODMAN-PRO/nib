import UIKit
import SwiftUI
import Combine
import AVFoundation
import NibContracts
import NibDesign

/// Presentation mode (F063): the external display (AirPlay or cable) shows the active page (Presenter Page, Full
/// Page) or snapshots of the whole window (Mirror Entire Screen), with the presenter's laser. Parity D-083, S-071,
/// S-073, P-064.
public enum FeatPresentationFeature: NibFeature {
    public static let id = "presentation"

    public static func register(_ app: NibApp) {
        let controller = PresentationController(app: app)
        app.services.set(controller, for: PresentationController.serviceKey)
        app.settings.declare(PresentationSettings.mode,
                             summary: "What an external display shows: mirror, presenter (page follows zoom) or fullPage.",
                             owner: id, schema: .str(choices: ExternalDisplayMode.allCases.map { $0.rawValue }))
        app.commands.register(PresentSetMode.self)
        app.ui.externalDisplay = { scene in controller.makeViewController(for: scene) }

        // Share & Export › Presentation Mode, only while a display is connected. The mode in use carries the menu's
        // checkmark. The page modes need a page: they are offered in notebooks and whiteboards, Mirror everywhere.
        // Choosing a mode also shows a blanked screen again.
        let submenu = String(localized: "Presentation Mode")
        for (i, mode) in ExternalDisplayMode.menuOrder.enumerated() {
            var entry = MenuItemDescriptor(
                id: PresentationController.menuID(mode), title: mode.title, location: .shareExport, order: 800 + i,
                owner: id, command: PresentSetMode.id,
                params: { _ in ["mode": .string(mode.rawValue), "blank": .bool(false)] },
                isVisible: { ctx in
                    controller.isConnected && (mode == .mirror || PresentationController.hasPages(ctx))
                },
                submenu: submenu)
            entry.isChecked = { _ in controller.mode == mode }
            app.ui.menus.register(entry)
        }

        // The presenter HUD (DESIGN.md §14.12): a Clear HUD in the presenting window's droplet container, so it merges
        // with the bars and recedes while the Pencil is down. iPad: top centre, under the bars. iPhone: bottom centre,
        // above the palette.
        for compact in [false, true] {
            app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
                id: compact ? PresentationController.compactHUDID : PresentationController.hudID, owner: id,
                placement: compact ? .bottom : .top, surface: .hud, order: 900, recedesWhileWriting: true,
                isVisible: { ctx in ctx.kind != nil && ctx.isCompact == compact && controller.showsHUD(in: ctx.session) },
                makeView: { ctx in
                    AnyView(PresenterHUD(app: ctx.app, session: ctx.session, controller: controller, compact: compact))
                }))
        }
    }
}

// MARK: - Controller

/// The feature's one service (`services.get("presentation.controller")`): connected displays, the mode (a device
/// setting) and Blank. Each connected display gets its own view model and view controller for its lifetime.
@MainActor
final class PresentationController: ObservableObject {
    static let serviceKey = "presentation.controller"
    /// The presenter HUD's chrome overlays: regular width (top centre) and compact width (bottom centre).
    static let hudID = "presentation.hud"
    static let compactHUDID = "presentation.hud.compact"

    static func menuID(_ mode: ExternalDisplayMode) -> String { "presentation.mode." + mode.rawValue }

    struct Connection {
        let id: ObjectIdentifier
        let name: String
        let model: PresentationViewModel
        /// The scene's disconnect notification (nil for displays connected without a scene, in tests).
        var watch: AnyCancellable?
    }

    unowned let app: NibApp
    @Published private(set) var blank = false
    @Published private(set) var connections: [Connection] = []
    private var cancellables = Set<AnyCancellable>()
    private var activations: EventSubscription?

    init(app: NibApp) {
        self.app = app
        // `present.setMode` and `settings.set presentation.mode` both land here.
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .sink { [weak self] note in
                guard (note.userInfo?["name"] as? String) == PresentationSettings.mode.name else { return }
                self?.modeDidChange()
            }
            .store(in: &cancellables)
        // The HUD follows the active window (the shell activates the key window's session).
        activations = app.events.subscribe { [weak self] event in
            guard event.type == NibEventType.sessionActivated else { return }
            self?.chromeDidChange()
        }
    }

    var mode: ExternalDisplayMode { app.settings.get(PresentationSettings.mode) }
    var isConnected: Bool { !connections.isEmpty }
    /// A page mode on a connected display (the presenter HUD shows).
    var isPresenting: Bool { isConnected && mode != .mirror }
    var displayNames: [String] { connections.map { $0.name } }

    /// The presenter HUD shows in the active window while a page mode is on a display, or while the display is
    /// blanked (in any mode, so Blank can be undone).
    func showsHUD(in session: EditorSession) -> Bool {
        (isPresenting || blank) && app.services.sessions.active === session
    }

    /// The page modes need a page to show: only notebooks and whiteboards have one.
    static func hasPages(_ ctx: MenuContext) -> Bool {
        hasPages(ctx.app, doc: ctx.doc ?? ctx.session?.document)
    }

    static func hasPages(_ app: NibApp, doc: DocumentID?) -> Bool {
        guard let doc = doc, let kind = try? app.workspace.content(doc).meta.kind else { return false }
        return kind == .notebook || kind == .whiteboard
    }

    /// Blank needs a display to black out: with none connected it stays off, so the next display never starts black.
    func setBlank(_ on: Bool) {
        let on = on && isConnected
        if blank != on { blank = on }
        let mode = self.mode
        for c in connections { c.model.apply(mode: mode, blank: on) }
        chromeDidChange()
    }

    /// `ui.externalDisplay`: called by the shell when an AirPlay or cable display connects.
    func makeViewController(for scene: UIWindowScene) -> UIViewController {
        let id = ObjectIdentifier(scene)
        let viewController = connect(id: id, name: ExternalDisplayName.current(), source: LivePageSource(app: app))
        let watch = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification, object: scene)
            .sink { [weak self] _ in self?.disconnect(id) }
        if let i = connections.firstIndex(where: { $0.id == id }) { connections[i].watch = watch }
        return viewController
    }

    /// A display connected: it gets its own view model and view controller for as long as it stays connected, and
    /// `present.setMode` / `settings.set` switch that same pair in place.
    func connect(id: ObjectIdentifier, name: String, source: PresentationPageSource) -> PresentationViewController {
        disconnect(id)                                  // the same scene connecting again replaces its old model
        if connections.isEmpty && blank { blank = false }
        let model = PresentationViewModel(source: source, mode: mode, blank: blank)
        connections.append(Connection(id: id, name: name, model: model, watch: nil))
        model.setNeedsUpdate()
        if isPresenting {
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "Presenting \(mode.title) on \(name)"))
        }
        chromeDidChange()
        return PresentationViewController(model: model)
    }

    func disconnect(_ id: ObjectIdentifier) {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[i].model.stop()
        connections.remove(at: i)
        if connections.isEmpty && blank { blank = false }
        chromeDidChange()
    }

    private func modeDidChange() {
        objectWillChange.send()
        let mode = self.mode
        for c in connections { c.model.apply(mode: mode, blank: blank) }
        chromeDidChange()
    }

    /// The HUD's visibility and the menu's checkmarks read this controller, which the chrome does not observe.
    private func chromeDidChange() {
        app.ui.setNeedsChromeUpdate()
    }
}

/// iOS has no public name for an external screen; the audio route of an AirPlay or HDMI display carries it
/// ("Living Room TV").
enum ExternalDisplayName {
    static func current() -> String {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        if let port = ports.first(where: { $0.portType == .airPlay || $0.portType == .HDMI }), !port.portName.isEmpty {
            return port.portName
        }
        return String(localized: "External Display")
    }
}

// MARK: - Presenter HUD

/// What one window's presenter HUD says. It follows the controller, the window's page, tool and document, and the
/// document's page table; the chrome builds one per window while the HUD is up.
@MainActor
final class PresenterHUDModel: ObservableObject {
    @Published private(set) var displayName = ""
    /// The mode's title ("Full Page"), for VoiceOver: the menu shows the mode only as a checkmark.
    @Published private(set) var modeTitle = ""
    /// The window's document has pages (notebooks, whiteboards): the page count and the laser show.
    @Published private(set) var hasPages = false
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var laserAvailable = false
    @Published private(set) var laserOn = false
    @Published private(set) var blank = false

    private unowned let app: NibApp
    private weak var session: EditorSession?
    private let controller: PresentationController
    private var watches = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(app: NibApp, session: EditorSession, controller: PresentationController) {
        self.app = app
        self.session = session
        self.controller = controller
        // Publishers fire before their value changes: refresh once the change has landed.
        controller.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        session.$document.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        session.$page.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        session.$tool.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        let commits = app.bus.observeCommits { [weak self] changeset in
            guard let self = self, let doc = self.session?.document, changeset.headChanged(doc) else { return }
            self.scheduleRefresh()
        }
        AnyCancellable { commits.cancel() }.store(in: &watches)
        refresh()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        update(\.displayName, controller.displayNames.first ?? String(localized: "External Display"))
        update(\.modeTitle, controller.mode.title)
        update(\.blank, controller.blank)
        let doc = session?.document
        let hasPages = PresentationController.hasPages(app, doc: doc)
        update(\.hasPages, hasPages)
        if hasPages, let doc = doc, let content = try? app.workspace.content(doc) {
            let pages = content.livePages                      // one filter and sort for both numbers
            update(\.pageCount, pages.count)
            update(\.page, session?.page.flatMap { id in pages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
        } else {
            update(\.pageCount, 0)
            update(\.page, 0)
        }
        update(\.laserAvailable, hasPages && app.ui.canvasTools.get("laser") != nil)
        update(\.laserOn, session?.tool == "laser")
    }

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<PresenterHUDModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    // MARK: Actions (all through commands)

    func toggleLaser() {
        guard let session = session else { return }
        let back = session.previousTool.flatMap { $0 == "laser" ? nil : $0 } ?? "pen"
        app.perform(CommandIDs.toolSelect, ["tool": .string(session.tool == "laser" ? back : "laser")], session: session)
    }

    func toggleBlank() {
        app.perform(PresentSetMode.id, ["mode": .string(controller.mode.rawValue), "blank": .bool(!controller.blank)],
                    session: session)
    }

    /// Back to mirroring the whole screen, never black.
    func stop() {
        app.perform(PresentSetMode.id, ["mode": .string(ExternalDisplayMode.mirror.rawValue), "blank": .bool(false)],
                    session: session)
    }
}

/// DESIGN.md §14.12: the presenter HUD's content. The chrome gives it the Clear HUD droplet. iPad: "Presenting on …"
/// (the glyph alone when the window is too narrow for the words), the page count, Laser, Blank Screen, Stop. iPhone:
/// Stop, Laser, the page count.
struct PresenterHUD: View {
    @StateObject private var model: PresenterHUDModel
    let compact: Bool

    init(app: NibApp, session: EditorSession, controller: PresentationController, compact: Bool) {
        _model = StateObject(wrappedValue: PresenterHUDModel(app: app, session: session, controller: controller))
        self.compact = compact
    }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 0) {
                    stopButton
                    if model.laserAvailable { laserButton }
                    if model.hasPages { pageCount }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    regular(spelledOut: true)
                    regular(spelledOut: false)
                }
            }
        }
        .padding(.horizontal, NibSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hudLabel)
    }

    private func regular(spelledOut: Bool) -> some View {
        HStack(spacing: 0) {
            presenting(spelledOut: spelledOut)
            NibBarSeparator()
            if model.hasPages {
                pageCount
                NibBarSeparator()
            }
            if model.laserAvailable { laserButton }
            blankButton
            stopButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var presentingText: String { String(localized: "Presenting on \(model.displayName)") }

    /// "Presenting Full Page on Living Room TV" (and whether the screen is blanked): VoiceOver hears the mode here.
    private var hudLabel: String {
        let presenting = String(localized: "Presenting \(model.modeTitle) on \(model.displayName)")
        return model.blank ? presenting + ", " + String(localized: "screen blanked") : presenting
    }

    private func presenting(spelledOut: Bool) -> some View {
        HStack(spacing: NibSpacing.s) {
            Image(nib: .externalDisplay)
                .font(NibFont.glyph(.bar))
            if spelledOut {
                Text(presentingText)
                    .font(NibFont.barTitle)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(NibColor.label)
        .padding(.leading, NibSpacing.m)
        .padding(.trailing, NibSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hudLabel)
    }

    private var pageCount: some View {
        NibHUDText("\(model.page) / \(model.pageCount)")
            .padding(.horizontal, NibSpacing.xs)
            .accessibilityLabel(String(localized: "Page \(model.page) of \(model.pageCount)"))
    }

    private var laserButton: some View {
        NibIconButton(.laser, label: String(localized: "Laser Pointer"), size: .bar, isOn: model.laserOn,
                      action: { model.toggleLaser() })
    }

    private var blankButton: some View {
        NibIconButton(model.blank ? .eye : .eyeSlash,
                      label: model.blank ? String(localized: "Show Screen") : String(localized: "Blank Screen"),
                      size: .bar, isOn: model.blank, action: { model.toggleBlank() })
    }

    private var stopButton: some View {
        NibIconButton(.stop, label: String(localized: "Stop Presenting"), size: .bar, action: { model.stop() })
    }
}
