import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

enum SearchLayoutMeasurement {
    /// Compare against the retained value, so subpixel noise is ignored but real movement accumulates.
    static func changed(_ old: CGRect?, _ new: CGRect?, scale: CGFloat) -> Bool {
        guard let old, let new else { return old != new }
        let pixel = 1 / max(1, scale)
        return abs(old.minX - new.minX) > pixel || abs(old.minY - new.minY) > pixel
            || abs(old.width - new.width) > pixel || abs(old.height - new.height) > pixel
    }
}

/// Geometry shared by the panel and counter, independent of their measured sizes/positions.
struct SearchWindowGeometry: Equatable {
    var bounds: CGRect
    var safeArea: UIEdgeInsets
    var keyboard: CGRect?
}

/// Measurements in the presenting window, unaffected by the keyboard changing the visible aspect ratio.
struct SearchViewport: Equatable {
    var windowSize: CGSize
    var availableHeight: CGFloat
    /// The visible part of the host, expressed in the host's own coordinates.
    var visibleBounds: CGRect
    var columnTop: CGFloat = 0
    var windowGeometry: SearchWindowGeometry?

    func differs(from old: SearchViewport?, scale: CGFloat) -> Bool {
        guard let old else { return true }
        let window = CGRect(origin: .zero, size: windowSize)
        let oldWindow = CGRect(origin: .zero, size: old.windowSize)
        return SearchLayoutMeasurement.changed(oldWindow, window, scale: scale)
            || old.windowGeometry != windowGeometry
            || SearchLayoutMeasurement.changed(old.visibleBounds, visibleBounds, scale: scale)
            || abs(old.availableHeight - availableHeight) > 1 / max(1, scale)
            || abs(old.columnTop - columnTop) > 1 / max(1, scale)
    }

    static var idealHeight: CGFloat {
        NibMetrics.barHeight + NibMetrics.minimumRestingGap + NibMetrics.searchResultsMaxHeight
            + navigationReserve
    }
    // The page HUD and match HUD can occupy two rows in Split View. Keep both outside Deep.
    static var navigationReserve: CGFloat {
        2 * (NibMetrics.hitTarget + NibMetrics.minimumRestingGap)
    }
    static func panelWidth(availableWidth: CGFloat, windowSize: CGSize?) -> CGFloat {
        guard let windowSize else { return max(0, availableWidth) }
        let available = max(0, min(availableWidth, windowSize.width - 2 * NibMetrics.chromeInset))
        return windowSize.width > windowSize.height ? min(NibMetrics.searchWidth, available) : available
    }
    static func hostBounds(proposedSize: CGSize, viewport: SearchViewport?) -> CGRect {
        let proposed = CGRect(origin: .zero, size: proposedSize)
        let visible = proposed.intersection(viewport?.visibleBounds ?? proposed)
        return visible.isEmpty ? .zero : visible
    }
    /// The library supplies global coordinates; translate into this host before clipping.
    /// Never paint or catch taps over its sibling sidebar or top chrome.
    static func libraryContentBounds(hostBounds: CGRect, column: CGRect?, hostOrigin: CGPoint) -> CGRect {
        guard let column else { return hostBounds }
        let localColumn = column.offsetBy(dx: -hostOrigin.x, dy: -hostOrigin.y)
        let bounds = hostBounds.intersection(localColumn)
        return bounds.isEmpty ? .zero : bounds
    }
    /// ChromeOverlayGeometry stacks the centred match HUD above colliding bottom HUDs using
    /// their measured widths, not ChromeLayout's sidebar docking breakpoint. Read that final
    /// placement: the counter's distance from the usable bottom includes every occupied row.
    static func navigationRows(counterAvailableHeight: CGFloat) -> Int {
        let row = NibMetrics.hitTarget + NibMetrics.minimumRestingGap
        return max(1, Int(ceil((counterAvailableHeight + NibMetrics.minimumRestingGap) / row)))
    }
    func navigationRows(counterTop: CGFloat?) -> Int {
        guard let counterTop else { return 2 }
        // Use the panel's keyboard boundary, even if a floating keyboard intersects the
        // results but not the narrower counter. Both positions are in window coordinates.
        return Self.navigationRows(counterAvailableHeight: columnTop + availableHeight - counterTop)
    }
    func navigationRows(counterPlacement: SearchViewport?) -> Int {
        // A no-hit query removes the counter's reader. Never combine its old absolute
        // coordinate with a resized window, changed safe area or dismissed/moved keyboard.
        guard let counterPlacement, counterPlacement.windowGeometry == windowGeometry,
              counterPlacement.windowSize == windowSize else { return 2 }
        return navigationRows(counterTop: counterPlacement.columnTop)
    }
    static func resultsHeight(availableHeight: CGFloat, reservesNavigation: Bool,
                              navigationRows: Int = 2) -> CGFloat {
        let reserve = CGFloat(max(0, navigationRows)) * (NibMetrics.hitTarget + NibMetrics.minimumRestingGap)
        return max(0, min(NibMetrics.searchResultsMaxHeight,
            availableHeight - NibMetrics.barHeight - NibMetrics.minimumRestingGap
                - (reservesNavigation ? reserve : 0)))
    }
    static func measure(windowBounds: CGRect, safeArea: UIEdgeInsets, frame: CGRect,
                        keyboard: CGRect?) -> SearchViewport {
        var bottom = windowBounds.maxY - safeArea.bottom - NibMetrics.chromeInset
        if let keyboard, keyboard.intersects(frame), keyboard.maxY > frame.minY {
            bottom = min(bottom, keyboard.minY - NibMetrics.minimumRestingGap)
        }
        let visible = windowBounds.intersection(frame)
        return SearchViewport(windowSize: windowBounds.size, availableHeight: max(0, bottom - frame.minY),
            visibleBounds: visible.isEmpty ? .zero : visible.offsetBy(dx: -frame.minX, dy: -frame.minY),
            columnTop: frame.minY,
            windowGeometry: SearchWindowGeometry(bounds: windowBounds, safeArea: safeArea, keyboard: keyboard))
    }
}

/// Uses this view's window (never the main screen), including Stage Manager and floating keyboards.
@MainActor
struct SearchViewportReader: UIViewRepresentable {
    // A moved ancestor need not resize the sensor. Supplying its SwiftUI position makes
    // updateUIView schedule another window-coordinate measurement after HUD placement.
    var layoutPosition: CGPoint = .zero
    var onChange: (SearchViewport) -> Void
    func makeUIView(context: Context) -> Sensor { Sensor(onChange: onChange) }
    func updateUIView(_ view: Sensor, context: Context) { view.onChange = onChange; view.setNeedsLayout() }

    final class Sensor: UIView {
        var onChange: (SearchViewport) -> Void
        private var keyboardScreenFrame: CGRect?
        private var last: SearchViewport?
        #if DEBUG
        private let layoutTrace = SearchLayoutTrace()
        #endif

        init(onChange: @escaping (SearchViewport) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { return nil }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        @objc private func keyboardChanged(_ note: Notification) {
            #if DEBUG
            let next = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            layoutTrace.write("sensor keyboard", old: keyboardScreenFrame, new: next)
            #endif
            keyboardScreenFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            report()
        }
        private func report() {
            guard let window, bounds.width > 0 else { return }
            let frame = convert(bounds, to: window)
            let keyboard = keyboardScreenFrame.map {
                window.convert($0, from: window.screen.coordinateSpace)
            } ?? window.keyboardLayoutGuide.layoutFrame
            // Test intersection against the full column, including the reserved HUD area.
            let column = CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                height: max(0, window.bounds.maxY - frame.minY))
            let next = SearchViewport.measure(windowBounds: window.bounds, safeArea: window.safeAreaInsets,
                frame: column, keyboard: keyboard)
            guard next.differs(from: last, scale: window.screen.scale) else { return }
            #if DEBUG
            layoutTrace.write("sensor viewport", old: last, new: Optional(next))
            #endif
            last = next
            DispatchQueue.main.async { [weak self] in
                guard let self, self.last == next else { return }
                self.onChange(next)
            }
        }
    }
}

@MainActor
struct DocumentSearchPanel: View {
    @Environment(\.displayScale) private var displayScale
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var viewport: SearchViewport?
    #if DEBUG
    @State private var layoutTrace = SearchLayoutTrace()
    #endif

    var body: some View {
        // The chrome host supplies the column below the bars. Its natural-height proposal does
        // not account for the keyboard or bottom HUDs, so constrain the scrolling surface here.
        GeometryReader { geometry in
            let width = SearchViewport.panelWidth(availableWidth: geometry.size.width,
                windowSize: viewport?.windowSize)
            let height = SearchViewport.resultsHeight(availableHeight: min(geometry.size.height,
                viewport?.availableHeight ?? geometry.size.height), reservesNavigation: true,
                navigationRows: viewport?.navigationRows(counterPlacement: state.navigationCounterPlacement) ?? 2)
            VStack(spacing: NibMetrics.minimumRestingGap) {
                DocumentSearchField(app: app, session: session, state: state)
                SearchResults(app: app, session: session, state: state)
                    .frame(height: height, alignment: .top)
                    .searchLayoutFrame("document.results")
                    .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                    .droplet("searchui.documentResults", style: .panel)
                    .budsFrom("searchui.documentField", isPresented: presentationBinding, instant: state.instant)
            }
            .frame(width: width)
            .background(alignment: .top) {
                SearchViewportReader { next in
                    guard next.differs(from: viewport, scale: displayScale) else { return }
                    #if DEBUG
                    layoutTrace.write("document viewport", old: viewport, new: Optional(next))
                    #endif
                    viewport = next
                }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(idealHeight: SearchViewport.idealHeight, maxHeight: SearchViewport.idealHeight)
    }
    private var presentationBinding: Binding<Bool> {
        Binding(get: { state.isPresented }, set: { value in
            if !value {
                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
            }
        })
    }
}

/// iPhone uses system search over a full-screen, dry results list, never navigator tabs.
@MainActor
struct DocumentSearchSheet: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var body: some View {
        PhoneSearchContent(app: app, session: session, state: state,
            prompt: state.searchPrompt)
        .onAppear {
            if !state.isPresented || state.isLibraryScope {
                app.perform(CommandIDs.searchOpen, ["scope": "document", "instant": true], session: session)
            }
        }
    }
}

@MainActor
struct DocumentSearchField: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var body: some View {
        HStack(spacing: NibSpacing.s) {
            SearchInput(app: app, session: session, state: state, style: .onDroplet)
            NibIconButton(.xmark, label: String(localized: "Close search")) {
                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
            }
            .accessibilityIdentifier("cmd." + CommandIDs.searchOpen)
        }
        .padding(.trailing, NibSpacing.xs)
        .frame(maxWidth: .infinity)
        .nibChromeTypeCap()
        .droplet("searchui.documentField", style: .bar)
        .budsFrom("searchui.find", isPresented: Binding(get: { state.isPresented }, set: { value in
            if !value {
                app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
            }
        }), instant: state.instant)
    }
}

@MainActor
struct SearchCounter: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    var usesHUD = true
    var body: some View {
        Group {
            if usesHUD {
                NibHUDGroup(id: "searchui.matchCounter") { controls }
                    .background {
                        GeometryReader { geometry in
                            SearchViewportReader(layoutPosition: geometry.frame(in: .global).origin) { viewport in
                                guard state.isPresented else { return }
                                if state.navigationCounterPlacement != viewport {
                                    state.navigationCounterPlacement = viewport
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
            } else {
                HStack(spacing: NibSpacing.s) { controls }
                    .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget)
                    .padding(.horizontal, NibSpacing.l)
                    .accessibilityElement(children: .contain)
            }
        }
    }
    @ViewBuilder private var controls: some View {
        NibIconButton(.back, label: String(localized: "Find previous")) {
            app.perform(CommandIDs.searchStep, ["direction": "previous"], session: session)
        }
        .disabled(!state.canStepMatches)
        .accessibilityIdentifier("cmd." + CommandIDs.searchStep)
        .nibShortcutHint(KeyboardShortcut("g", modifiers: [.command, .shift]))
        Group {
            if usesHUD {
                NibHUDText(state.countLabel)
            } else {
                Text(state.countLabel)
                    .font(NibFont.callout)
                    .monospacedDigit()
                    .foregroundStyle(NibColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(String(localized: "Search result \(state.countLabel)"))
        NibIconButton(.forward, label: String(localized: "Find next")) {
            app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
        }
        .disabled(!state.canStepMatches)
        .accessibilityIdentifier("cmd." + CommandIDs.searchStep)
        .nibShortcutHint(KeyboardShortcut("g", modifiers: [.command]))
    }
}

/// Dry, non-interactive page washes. Never attached to the active tool's preview layer and hidden while inking.
@MainActor
final class SearchHighlights: CanvasAttachment {
    let state: SearchState
    private weak var host: CanvasHost?
    let layer = CALayer()
    private var changeSubscription: AnyCancellable?
    private var notificationSubscription: AnyCancellable?
    private var inkingSubscription: EventSubscription?
    private var expiry: Task<Void, Never>?

    init(state: SearchState) { self.state = state }
    func attach(to host: CanvasHost) {
        self.host = host
        host.canvasView.layer.addSublayer(layer)
        changeSubscription = state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        notificationSubscription = NotificationCenter.default.publisher(for: .searchHighlightsChanged, object: state)
            .sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        inkingSubscription = host.session.inking.observe { [weak self] _ in self?.update() }
        update()
    }
    func detach(from host: CanvasHost) {
        changeSubscription?.cancel()
        notificationSubscription?.cancel()
        inkingSubscription?.cancel()
        expiry?.cancel()
        layer.removeFromSuperlayer()
        self.host = nil
    }
    func canvasDidChange(_ host: CanvasHost) { update() }
    func update() {
        guard let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard !host.session.inking.isInking else { return }
        let flashing = state.flashUntil.map { $0 > Date() } ?? false
        for hit in state.visibleMatches {
            guard state.isPresented || (flashing && state.flashID == hit.id),
                  NodeRef(hit.doc)?.documentID == host.documentID,
                  let page = hit.page.flatMap({ NodeRef($0)?.pageID }),
                  let rect = hit.rect, !rect.isEmpty, let transform = host.pageTransform(page) else { continue }
            let wash = CAShapeLayer()
            let path = CGPath(roundedRect: rect.cg, cornerWidth: NibRadius.pageWash, cornerHeight: NibRadius.pageWash, transform: nil)
            var affine = transform
            wash.path = path.copy(using: &affine)
            wash.fillColor = NibUIColor.accentWash.resolvedColor(with: host.canvasView.traitCollection).cgColor
            if state.selectedID == hit.id {
                wash.strokeColor = NibUIColor.accent.resolvedColor(with: host.canvasView.traitCollection).cgColor
                wash.lineWidth = NibStroke.thin
            }
            layer.addSublayer(wash)
        }
        expiry?.cancel()
        if flashing, let until = state.flashUntil {
            expiry = Task { @MainActor [weak self] in
                let remaining = max(0, until.timeIntervalSinceNow)
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
                self?.update()
            }
        }
    }
}
