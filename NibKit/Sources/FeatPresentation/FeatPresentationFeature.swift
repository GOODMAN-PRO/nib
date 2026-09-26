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

        // Share & Export › Presentation Mode, only while a display is connected. The mode in use carries a checkmark
        // (menu entries have no checked state, so each mode has a plain and a checked entry and one of them shows).
        // The page modes need a page: they are offered in notebooks and whiteboards, Mirror everywhere. Choosing a
        // mode also shows a blanked screen again.
        let submenu = String(localized: "Presentation Mode")
        for (i, mode) in ExternalDisplayMode.menuOrder.enumerated() {
            for checked in [false, true] {
                app.ui.menus.register(MenuItemDescriptor(
                    id: "presentation.mode." + mode.rawValue + (checked ? ".current" : ""), title: mode.title,
                    icon: checked ? NibSymbol.checkmark.name : nil, location: .shareExport, order: 800 + i, owner: id,
                    command: PresentSetMode.id,
                    params: { _ in ["mode": .string(mode.rawValue), "blank": .bool(false)] },
                    isVisible: { ctx in
                        controller.isConnected && (controller.mode == mode) == checked
                            && (mode == .mirror || PresentationController.hasPages(ctx))
                    },
                    submenu: submenu))
            }
        }

        app.ui.canvasAttachments.register(CanvasAttachmentDescriptor(id: "presentation.hud", owner: id, order: 900) { _ in
            PresenterHUDAttachment(controller: controller)
        })
    }
}

// MARK: - Controller

/// The feature's one service (`services.get("presentation.controller")`): connected displays, the mode (a device
/// setting) and Blank. Each connected display gets its own view model and view controller for its lifetime.
@MainActor
final class PresentationController: ObservableObject {
    static let serviceKey = "presentation.controller"

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

    init(app: NibApp) {
        self.app = app
        // `present.setMode` and `settings.set presentation.mode` both land here.
        NotificationCenter.default.publisher(for: SettingsStore.didChange, object: app.settings)
            .sink { [weak self] note in
                guard (note.userInfo?["name"] as? String) == PresentationSettings.mode.name else { return }
                self?.modeDidChange()
            }
            .store(in: &cancellables)
    }

    var mode: ExternalDisplayMode { app.settings.get(PresentationSettings.mode) }
    var isConnected: Bool { !connections.isEmpty }
    /// A page mode on a connected display (the presenter HUD shows).
    var isPresenting: Bool { isConnected && mode != .mirror }
    var displayNames: [String] { connections.map { $0.name } }

    /// The page modes need a page to show: only notebooks and whiteboards have one.
    static func hasPages(_ ctx: MenuContext) -> Bool {
        guard let doc = ctx.doc ?? ctx.session?.document,
              let kind = try? ctx.app.workspace.content(doc).meta.kind else { return false }
        return kind == .notebook || kind == .whiteboard
    }

    /// Blank needs a display to black out: with none connected it stays off, so the next display never starts black.
    func setBlank(_ on: Bool) {
        let on = on && isConnected
        if blank != on { blank = on }
        let mode = self.mode
        for c in connections { c.model.apply(mode: mode, blank: on) }
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
        return PresentationViewController(model: model)
    }

    func disconnect(_ id: ObjectIdentifier) {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[i].model.stop()
        connections.remove(at: i)
        if connections.isEmpty && blank { blank = false }
    }

    private func modeDidChange() {
        objectWillChange.send()
        let mode = self.mode
        for c in connections { c.model.apply(mode: mode, blank: blank) }
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

/// DESIGN.md §14.12: a Clear HUD while presenting. iPad: top centre, level with the bars ("Presenting on …", the
/// page count, Laser, Blank Screen, Stop). iPhone: bottom centre above the palette (Stop, Laser, page count).
@MainActor
final class PresenterHUDModel: ObservableObject {
    enum Layout { case regular, narrow, compact }

    @Published var layout = Layout.regular
    @Published var displayName = ""
    /// The mode's title ("Full Page"), for VoiceOver: the menu shows the mode only as a checkmark icon.
    @Published var modeTitle = ""
    @Published var page = 0
    @Published var pageCount = 0
    @Published var laserAvailable = false
    @Published var laserOn = false
    @Published var blank = false
}

struct PresenterHUDActions {
    let toggleLaser: () -> Void
    let toggleBlank: () -> Void
    let stop: () -> Void
}

struct PresenterHUD: View {
    @ObservedObject var model: PresenterHUDModel
    let actions: PresenterHUDActions

    var body: some View {
        HStack(spacing: 0) {
            if model.layout == .compact {
                stopButton
                if model.laserAvailable { laserButton }
                pageCount
            } else {
                presenting
                NibBarSeparator()
                pageCount
                NibBarSeparator()
                if model.laserAvailable { laserButton }
                blankButton
                stopButton
            }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .nibGlass(.clear)
        .nibChromeTypeCap()
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hudLabel)
    }

    private var presentingText: String { String(localized: "Presenting on \(model.displayName)") }

    /// "Presenting Full Page on Living Room TV" (and whether the screen is blanked): VoiceOver hears the mode here.
    private var hudLabel: String {
        let presenting = String(localized: "Presenting \(model.modeTitle) on \(model.displayName)")
        return model.blank ? presenting + ", " + String(localized: "screen blanked") : presenting
    }

    private var presenting: some View {
        HStack(spacing: NibSpacing.s) {
            Image(nib: .externalDisplay)
                .font(NibFont.glyph(.bar))
            if model.layout == .regular {
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
        Text(verbatim: "\(model.page) / \(model.pageCount)")
            .font(NibFont.hud)
            .foregroundStyle(NibColor.label)
            .padding(.horizontal, NibSpacing.m)
            .accessibilityLabel(String(localized: "Page \(model.page) of \(model.pageCount)"))
    }

    private var laserButton: some View {
        NibIconButton(.laser, label: String(localized: "Laser Pointer"), size: .bar, isOn: model.laserOn,
                      action: actions.toggleLaser)
    }

    private var blankButton: some View {
        NibIconButton(model.blank ? .eye : .eyeSlash,
                      label: model.blank ? String(localized: "Show Screen") : String(localized: "Blank Screen"),
                      size: .bar, isOn: model.blank, action: actions.toggleBlank)
    }

    private var stopButton: some View {
        NibIconButton(.stop, label: String(localized: "Stop Presenting"), size: .bar, action: actions.stop)
    }
}

/// Hosts the presenter HUD on the active canvas while a page mode is on an external display (or the display is
/// blanked, in any mode, so Blank can be undone). It floats over the visible part of the canvas and claims the touches
/// that land on it, so they never ink.
/// ponytail: a canvas attachment with static glass (the chrome's droplet container has no slot for feature HUDs and
/// `nibIsInking` is internal to NibDesign, so it cannot recede while the Pencil is down); contract gap reported,
/// move it into the container when a feature-HUD slot or a public inking signal lands.
@MainActor
final class PresenterHUDAttachment: CanvasAttachment {
    /// Canvases at least this wide (iPad landscape) spell out where they are presenting; narrower ones show the glyph.
    static let fullLabelWidth: CGFloat = 1100

    private let controller: PresentationController
    private let model = PresenterHUDModel()
    private weak var host: CanvasHost?
    private var hosting: UIHostingController<PresenterHUD>?
    private var watches = Set<AnyCancellable>()
    private var commits: EventSubscription?
    private var refreshScheduled = false
    /// The HUD's measured size, kept while its content and the available width stay the same (scrolling only moves it).
    private var fitted: (width: CGFloat, size: CGSize)?
    private var contentChanged = false

    init(controller: PresentationController) {
        self.controller = controller
    }

    func attach(to host: CanvasHost) {
        self.host = host
        let actions = PresenterHUDActions(toggleLaser: { [weak self] in self?.toggleLaser() },
                                          toggleBlank: { [weak self] in self?.toggleBlank() },
                                          stop: { [weak self] in self?.stop() })
        let hosting = UIHostingController(rootView: PresenterHUD(model: model, actions: actions))
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        hosting.view.isHidden = true
        host.canvasView.addSubview(hosting.view)
        self.hosting = hosting

        // What the HUD says changes only with the controller, the page, the tool or the page table; scrolling and
        // zooming (`canvasDidChange`) only move it.
        controller.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        host.session.$page.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        host.session.$tool.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        let doc = host.documentID
        commits = host.app.bus.observeCommits { [weak self] changeset in
            if changeset.headChanged(doc) { self?.scheduleRefresh() }
        }
        // The active window changes on activation, and (Split View, Stage Manager: both scenes stay active) when the
        // other window becomes key.
        let center = NotificationCenter.default
        center.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        center.publisher(for: UIWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watches)
        center.publisher(for: UIContentSizeCategory.didChangeNotification)
            .sink { [weak self] _ in
                self?.fitted = nil
                self?.scheduleRefresh()
            }
            .store(in: &watches)
        refresh()
    }

    func detach(from host: CanvasHost) {
        watches.removeAll()
        commits?.cancel()
        commits = nil
        hosting?.view.removeFromSuperview()
        hosting = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        reposition()
    }

    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        guard let view = hosting?.view, !view.isHidden else { return false }
        return view.frame.contains(viewPoint)
    }

    /// Publishers fire before their value changes: refresh once the change has landed.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// Visibility and content, then position.
    private func refresh() {
        guard let host = host, let hosting = hosting else { return }
        let session = host.session
        let visible = (controller.isPresenting || controller.blank) && host.app.services.sessions.active === session
        hosting.view.isHidden = !visible
        guard visible else { return }

        update(\.displayName, controller.displayNames.first ?? String(localized: "External Display"))
        update(\.modeTitle, controller.mode.title)
        if let content = try? host.app.workspace.content(host.documentID) {
            let pages = content.livePages                  // one filter and sort for both numbers
            update(\.pageCount, pages.count)
            update(\.page, session.page.flatMap { id in pages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
        }
        update(\.laserAvailable, host.app.ui.canvasTools.get("laser") != nil)
        update(\.laserOn, session.tool == "laser")
        update(\.blank, controller.blank)
        reposition()
    }

    /// Layout and position only: cheap enough for every scroll and zoom frame.
    private func reposition() {
        guard let host = host, let hosting = hosting, !hosting.view.isHidden else { return }
        let canvas = host.canvasView
        let bounds = canvas.bounds
        let layout: PresenterHUDModel.Layout = bounds.width < NibMetrics.compactBreakpoint ? .compact
            : (bounds.width >= Self.fullLabelWidth ? .regular : .narrow)
        update(\.layout, layout)
        if contentChanged {
            // SwiftUI renders the new state on its next pass: measure now, and once more after it has.
            contentChanged = false
            fitted = nil
            Task { [weak self] in
                self?.fitted = nil
                self?.reposition()
            }
        }

        let inset = NibMetrics.chromeInset
        let maxWidth = max(0, bounds.width - 2 * inset)
        if fitted?.width != maxWidth {
            let fitting = hosting.sizeThatFits(in: CGSize(width: maxWidth, height: NibMetrics.hitTarget))
            fitted = (maxWidth, CGSize(width: min(fitting.width, maxWidth), height: NibMetrics.hitTarget))
        }
        let size = fitted?.size ?? .zero
        let safe = canvas.safeAreaInsets
        let y: CGFloat
        if layout == .compact {
            y = bounds.maxY - safe.bottom - NibSpacing.s - NibMetrics.paletteThickness - NibSpacing.l - size.height
        } else {
            y = bounds.minY + safe.top + NibMetrics.barTopGap + (NibMetrics.barHeight - size.height) / 2
        }
        hosting.view.frame = CGRect(x: bounds.midX - size.width / 2, y: y, width: size.width, height: size.height)
        canvas.bringSubviewToFront(hosting.view)
    }

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<PresenterHUDModel, T>, _ value: T) {
        guard model[keyPath: key] != value else { return }
        model[keyPath: key] = value
        contentChanged = true
    }

    private func toggleLaser() {
        guard let host = host else { return }
        let session = host.session
        let back = session.previousTool.flatMap { $0 == "laser" ? nil : $0 } ?? "pen"
        host.app.perform(CommandIDs.toolSelect, ["tool": .string(session.tool == "laser" ? back : "laser")], session: session)
    }

    private func toggleBlank() {
        guard let host = host else { return }
        host.app.perform(PresentSetMode.id, ["mode": .string(controller.mode.rawValue), "blank": .bool(!controller.blank)],
                         session: host.session)
    }

    /// Back to mirroring the whole screen, never black.
    private func stop() {
        guard let host = host else { return }
        host.app.perform(PresentSetMode.id, ["mode": .string(ExternalDisplayMode.mirror.rawValue), "blank": .bool(false)],
                         session: host.session)
    }
}
