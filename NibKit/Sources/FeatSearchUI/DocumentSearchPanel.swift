import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

/// Measurements in the presenting window, unaffected by the keyboard changing the visible aspect ratio.
struct SearchViewport: Equatable {
    var windowSize: CGSize
    var availableHeight: CGFloat
    /// The visible part of the host, expressed in the host's own coordinates.
    var visibleBounds: CGRect

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
    static func resultsHeight(availableHeight: CGFloat, reservesNavigation: Bool) -> CGFloat {
        max(0, min(NibMetrics.searchResultsMaxHeight,
            availableHeight - NibMetrics.barHeight - NibMetrics.minimumRestingGap
                - (reservesNavigation ? navigationReserve : 0)))
    }
    static func measure(windowBounds: CGRect, safeArea: UIEdgeInsets, frame: CGRect,
                        keyboard: CGRect?) -> SearchViewport {
        var bottom = windowBounds.maxY - safeArea.bottom - NibMetrics.chromeInset
        if let keyboard, keyboard.intersects(frame), keyboard.maxY > frame.minY {
            bottom = min(bottom, keyboard.minY - NibMetrics.minimumRestingGap)
        }
        let visible = windowBounds.intersection(frame)
        return SearchViewport(windowSize: windowBounds.size, availableHeight: max(0, bottom - frame.minY),
            visibleBounds: visible.isEmpty ? .zero : visible.offsetBy(dx: -frame.minX, dy: -frame.minY))
    }
}

/// Uses this view's window (never the main screen), including Stage Manager and floating keyboards.
@MainActor
struct SearchViewportReader: UIViewRepresentable {
    var onChange: (SearchViewport) -> Void
    func makeUIView(context: Context) -> Sensor { Sensor(onChange: onChange) }
    func updateUIView(_ view: Sensor, context: Context) { view.onChange = onChange; view.setNeedsLayout() }

    final class Sensor: UIView {
        var onChange: (SearchViewport) -> Void
        private var keyboardScreenFrame: CGRect?
        private var last: SearchViewport?

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
            guard next != last else { return }
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
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @State private var viewport: SearchViewport?

    var body: some View {
        // The chrome host supplies the column below the bars. Its natural-height proposal does
        // not account for the keyboard or bottom HUDs, so constrain the scrolling surface here.
        GeometryReader { geometry in
            let width = SearchViewport.panelWidth(availableWidth: geometry.size.width,
                windowSize: viewport?.windowSize)
            let height = SearchViewport.resultsHeight(availableHeight: min(geometry.size.height,
                viewport?.availableHeight ?? geometry.size.height), reservesNavigation: true)
            VStack(spacing: NibMetrics.minimumRestingGap) {
                DocumentSearchField(app: app, session: session, state: state)
                SearchResults(app: app, session: session, state: state)
                    .frame(height: height, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: NibRadius.panel, style: .continuous))
                    .droplet("searchui.documentResults", style: .panel)
                    .budsFrom("searchui.documentField", isPresented: presentationBinding, instant: state.instant)
            }
            .frame(width: width)
            .background(alignment: .top) {
                SearchViewportReader { viewport = $0 }
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
            prompt: String(localized: "Find in this document"))
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
    var body: some View {
        NibHUDGroup(id: "searchui.matchCounter") {
            NibIconButton(.back, label: String(localized: "Find previous")) {
                app.perform(CommandIDs.searchStep, ["direction": "previous"], session: session)
            }
            .nibShortcutHint(KeyboardShortcut("g", modifiers: [.command, .shift]))
            NibHUDText(state.countLabel)
                .accessibilityLabel(String(localized: "Search result \(state.countLabel)"))
            NibIconButton(.forward, label: String(localized: "Find next")) {
                app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
            }
            .nibShortcutHint(KeyboardShortcut("g", modifiers: [.command]))
        }
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
