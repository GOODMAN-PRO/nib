import SwiftUI
import UIKit
import Combine
import NibContracts
import NibDesign

@MainActor
struct DocumentSearchPanel: View {
    let app: NibApp
    let session: EditorSession
    @ObservedObject var state: SearchState
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        VStack(spacing: 0) {
            if sizeClass == .compact {
                SearchInput(app: app, session: session, state: state)
                    .padding(NibSpacing.l)
            }
            SearchResults(app: app, session: session, state: state)
        }
        .background(NibColor.backgroundSecondary)
        .onAppear {
            if !state.isPresented || state.scope == "lib" {
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
        .frame(maxWidth: NibMetrics.searchWidth)
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
