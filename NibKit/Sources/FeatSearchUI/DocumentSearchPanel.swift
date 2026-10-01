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
    var body: some View {
        // The chrome host supplies the region below the bars, inset by chromeInset (16 pt).
        // Keep the field and results in that same column, including regular-width iPad portrait.
        VStack(spacing: NibMetrics.minimumRestingGap) {
            DocumentSearchField(app: app, session: session, state: state)
            SearchResults(app: app, session: session, state: state)
                .frame(maxWidth: .infinity)
                .frame(idealHeight: NibMetrics.searchResultsMaxHeight, maxHeight: NibMetrics.searchResultsMaxHeight)
                .droplet("searchui.documentResults", style: .panel)
                .budsFrom("searchui.documentField", isPresented: presentationBinding, instant: state.instant)
        }
        .frame(maxWidth: .infinity, alignment: .top)
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
    @State private var searchPresented = true

    var body: some View {
        NavigationStack {
            SearchResults(app: app, session: session, state: state)
                .background(NibColor.background)
                .navigationTitle(String(localized: "Search"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: searchBinding(app: app, session: session, state: state),
                    isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Find in this document"))
                .onSubmit(of: .search) {
                    app.perform(CommandIDs.searchStep, ["direction": "next"], session: session)
                }
                .onChange(of: state.focusGeneration) { _, _ in searchPresented = true }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NibButton(String(localized: "Close search"), kind: .plain) {
                            app.perform(CommandIDs.searchOpen, ["scope": .string(state.scope), "close": true], session: session)
                        }
                    }
                }
        }
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
