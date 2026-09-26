import Foundation
import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Text (pure; unit-tested)

enum BridgeFormat {
    /// "192.168.1.20:7331", "[fd7a:115c:a1e0::1]:7331".
    static func hostPort(_ host: String, _ port: Int) -> String {
        "\(BridgeAddress.urlHost(host)):\(port)"
    }

    /// "just now", "2 min. ago" (abbreviated) or "2 minutes ago" (full, for VoiceOver).
    static func relative(_ at: Double, now: Date = Date(), full: Bool = false) -> String {
        let date = Date(timeIntervalSince1970: at)
        if abs(now.timeIntervalSince(date)) < 5 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = full ? .full : .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func clientTitle(_ client: BridgeSnapshot.Client) -> String {
        guard let version = client.version, !version.isEmpty else { return client.name }
        return "\(client.name) \(version)"
    }

    /// "12 calls · connected" / "1 call · seen 4 min. ago".
    static func clientDetail(_ client: BridgeSnapshot.Client, now: Date = Date()) -> String {
        let calls = client.calls == 1 ? String(localized: "1 call") : String(localized: "\(String(client.calls)) calls")
        let seen = client.sessions > 0
            ? String(localized: "connected")
            : String(localized: "seen \(relative(client.lastSeen, now: now))")
        return calls + " \u{00B7} " + seen
    }

    /// "page.add by claude-code, 2 min. ago" / "item.delete by claude-code failed (user_denied), just now".
    static func callText(_ call: BridgeSnapshot.Call, now: Date = Date(), full: Bool = false) -> String {
        let when = relative(call.at, now: now, full: full)
        if call.ok {
            return String(localized: "\(call.what) by \(call.client), \(when)")
        }
        let reason = call.error ?? String(localized: "error")
        return String(localized: "\(call.what) by \(call.client) failed (\(reason)), \(when)")
    }
}

/// What the status pill says for a bridge state (DESIGN.md §14.2 and §14.9: a `connected` dot and the client's name
/// while an agent is connected; the address while none is; a `warning` dot when the bridge cannot run).
struct BridgePillPresentation: Equatable {
    enum Dot: Equatable {
        case none, connected, warning
    }

    var dot: Dot
    var primary: String
    var secondary: String?
    var accessibilityLabel: String

    /// A last call older than this is not named in the pill (the popover still shows it).
    static let recentCall: TimeInterval = 600

    /// The pill shows while the bridge is meant to run: on, starting, or needing attention. Not while it is off or
    /// paused in the background (then nobody sees the chrome anyway).
    static func isVisible(_ snapshot: BridgeSnapshot?) -> Bool {
        guard let s = snapshot, s.enabled else { return false }
        switch s.state {
        case .starting, .listening, .failed, .tokenMissing: return true
        case .off, .suspended: return false
        }
    }

    static func make(_ s: BridgeSnapshot, compact: Bool, now: Date = Date()) -> BridgePillPresentation {
        let bridge = String(localized: "Bridge")
        switch s.state {
        case .tokenMissing:
            return BridgePillPresentation(dot: .warning, primary: bridge,
                                          secondary: compact ? nil : String(localized: "Credentials missing"),
                                          accessibilityLabel: String(localized: "MCP bridge off: credentials missing"))
        case .failed:
            return BridgePillPresentation(dot: .warning, primary: bridge,
                                          secondary: compact ? nil : String(localized: "Couldn't start"),
                                          accessibilityLabel: String(localized: "MCP bridge couldn't start"))
        case .off, .suspended, .starting:
            return BridgePillPresentation(dot: .none, primary: bridge,
                                          secondary: compact ? nil : String(localized: "Starting"),
                                          accessibilityLabel: String(localized: "MCP bridge starting"))
        case .listening:
            let address = s.urls.first.flatMap { BridgeAddress.host(fromURL: $0) }.map { BridgeFormat.hostPort($0, s.port) }
            var label = address.map { String(localized: "MCP bridge on at \($0)") } ?? String(localized: "MCP bridge on")
            guard let first = s.clients.first else {
                label += ". " + String(localized: "No clients connected")
                return BridgePillPresentation(dot: .none, primary: bridge, secondary: compact ? nil : address,
                                              accessibilityLabel: label)
            }
            let names = s.clients.map { $0.name }
            label += ". " + String(localized: "Connected: \(ListFormatter.localizedString(byJoining: names))")
            let call = s.lastCall.flatMap { now.timeIntervalSince1970 - $0.at <= recentCall ? $0 : nil }
            if let call = call {
                label += ". " + String(localized: "Last call: \(BridgeFormat.callText(call, now: now, full: true))")
            }
            var extra: [String] = []
            if names.count > 1 { extra.append("+\(names.count - 1)") }
            if let call = call, !compact { extra.append(call.what) }
            return BridgePillPresentation(dot: .connected, primary: first.name,
                                          secondary: extra.isEmpty ? nil : extra.joined(separator: " \u{00B7} "),
                                          accessibilityLabel: label)
        }
    }
}

// MARK: - Pill

/// Per window: whether the pill's details popover is open, and what went wrong in it.
@MainActor
final class BridgePillState: ObservableObject {
    @Published var detailsPresented = false
    @Published var error: String?
    @Published var busy = false
}

/// The bridge status pill in the document chrome (`ui.chromeOverlays`, `.topLeading`, `.pill`): a dot and the connected
/// client (or the address), budding a popover with the address, the clients and the last call. The chrome gives it its
/// Clear pill droplet and fades it while the Pencil is down; it draws no glass of its own.
struct BridgeStatusPill: View {
    @ObservedObject var monitor: BridgeMonitor
    let context: ChromeContext
    @StateObject private var state = BridgePillState()

    var body: some View {
        let presentation = monitor.snapshot.map { BridgePillPresentation.make($0, compact: context.isCompact) }
        Button(action: toggleDetails) {
            HStack(spacing: NibSpacing.xxs) {
                if let kind = presentation?.dot.statusKind {
                    NibStatusDot(kind)
                        .padding(.leading, NibSpacing.s)
                }
                NibHUDText(presentation?.primary ?? String(localized: "Bridge"), secondary: presentation?.secondary)
            }
            .frame(minHeight: NibMetrics.hitTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .nibBudAnchor(BridgeUIIDs.pillAnchor)
        .nibChromeTypeCap()
        .accessibilityLabel(presentation?.accessibilityLabel ?? String(localized: "MCP bridge"))
        .accessibilityHint(String(localized: "Shows the address, the clients and the last call."))
        .accessibilityAddTraits(state.detailsPresented ? .isSelected : [])
        .onAppear { monitor.watch() }
        .onDisappear {
            monitor.unwatch()
            state.detailsPresented = false
            context.floatingHost?.dismiss(BridgeUIIDs.detailsPopover)
        }
    }

    private func toggleDetails() {
        let app = context.app
        guard let host = context.floatingHost else {
            // A chrome without a floating host (older shells): the details live in Settings › Bridge.
            BridgeNavigation.openSettings(app, navigator: context.navigator)
            return
        }
        if !host.isPresenting(BridgeUIIDs.detailsPopover) {
            host.present(BridgeUIIDs.detailsPopover,
                         content: AnyView(BridgeDetailsPopover(monitor: monitor, state: state, app: app)))
        }
        state.error = nil
        state.detailsPresented.toggle()
    }
}

extension BridgePillPresentation.Dot {
    var statusKind: NibStatusDot.Kind? {
        switch self {
        case .none: return nil
        case .connected: return .connected
        case .warning: return .warning
        }
    }
}

/// The pill's Deep popover: where clients reach the bridge, who is connected, the last call, and the two things people
/// do from here (turn the bridge off, open its settings).
struct BridgeDetailsPopover: View {
    @ObservedObject var monitor: BridgeMonitor
    @ObservedObject var state: BridgePillState
    let app: NibApp

    var body: some View {
        NibBudPopover(id: BridgeUIIDs.detailsPopover, source: BridgeUIIDs.pillAnchor, isPresented: $state.detailsPresented,
                      title: String(localized: "MCP Bridge"), subtitle: monitor.snapshot?.state.title, placement: .below) {
            VStack(alignment: .leading, spacing: NibSpacing.l) {
                details
                actions
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        let now = Date()
        if let s = monitor.snapshot {
            if s.state == .tokenMissing {
                NibBanner(String(localized: "Credentials missing. Re-enter them in Settings by issuing a new token."),
                          symbol: .key)
            } else if s.state == .failed {
                NibBanner(s.error ?? String(localized: "The bridge couldn't start. Try another port in Settings."))
            }
            let hosts = s.urls.compactMap { BridgeAddress.host(fromURL: $0) }
            if !hosts.isEmpty {
                NibInspectorSection(String(localized: "Address")) {
                    ForEach(hosts, id: \.self) { host in
                        HStack(spacing: NibSpacing.s) {
                            Text(verbatim: BridgeFormat.hostPort(host, s.port))
                                .font(NibFont.hud)
                                .foregroundStyle(NibColor.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .textSelection(.enabled)
                            Spacer(minLength: NibSpacing.s)
                            Text(BridgeNetworkRules.kind(ofHost: host).title)
                                .font(NibFont.caption1)
                                .foregroundStyle(NibColor.labelSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            NibInspectorSection(String(localized: "Clients"), value: String(s.clients.count)) {
                if s.clients.isEmpty {
                    Text(String(localized: "No clients yet"))
                        .font(NibFont.body)
                        .foregroundStyle(NibColor.labelSecondary)
                }
                ForEach(s.clients, id: \.name) { client in
                    NibInspectorRow(BridgeFormat.clientTitle(client), subtitle: BridgeFormat.clientDetail(client, now: now),
                                    symbol: .bridge)
                        .accessibilityElement(children: .combine)
                }
            }
            if let call = s.lastCall {
                NibInspectorSection(String(localized: "Last Call")) {
                    NibTraceRow(BridgeFormat.callText(call, now: now), phase: call.ok ? .done : .warning)
                }
            }
        } else if let error = monitor.refreshError {
            NibBanner(error)
        }
        if let error = state.error {
            NibBanner(error)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.s) {
                turnOffButton
                settingsButton
            }
            VStack(spacing: NibSpacing.s) {
                turnOffButton
                settingsButton
            }
        }
    }

    private var turnOffButton: some View {
        NibButton(String(localized: "Turn Off Bridge"), kind: .secondary, expands: true) {
            Task { await turnOff() }
        }
        .disabled(state.busy)
    }

    private var settingsButton: some View {
        NibButton(String(localized: "Open Bridge Settings"), symbol: .settings, kind: .secondary, expands: true) {
            state.detailsPresented = false
            BridgeNavigation.openSettings(app, navigator: nil)
        }
    }

    private func turnOff() async {
        state.busy = true
        defer { state.busy = false }
        do {
            try await BridgeCalls.setEnabled(app, enabled: false)
            state.detailsPresented = false
            await monitor.refresh()
        } catch {
            state.error = NibError.wrap(error).message
        }
    }
}
