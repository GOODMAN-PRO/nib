import Foundation
import MultipeerConnectivity
import os
import NibContracts

/// `CollabTransport` over MultipeerConnectivity (Bonjour service "nib-collab", declared in Info.plist
/// `NSBonjourServices` as `_nib-collab._tcp` / `_nib-collab._udp`). Local network or peer-to-peer Wi-Fi and Bluetooth,
/// no server, at most `kMCSessionMaximumNumberOfPeers` (8) devices per session including the host.
///
/// - The host advertises a *discovery hash* of the join code (never the code itself) and accepts an invitation only
///   when its context carries the *join proof* (a second hash of the code), so nearby devices that merely see the
///   advertisement cannot connect. Admission into the live session is still the host's decision (`collab.approve`,
///   CollabSession); this layer only moves bytes.
/// - A joiner browses for the discovery hash, invites the first match and waits until it is connected.
/// - Sessions require encryption. Every MultipeerConnectivity callback arrives on a private queue and is handed to the
///   main actor in order.
/// - iOS drops the session about 30 s after the app is backgrounded; CollabService re-joins with the same code when
///   the app returns (ARCHITECTURE.md §10).
@MainActor
final class MultipeerTransport: CollabTransport {
    static let serviceType = "nib-collab"
    /// Devices per Multipeer session, the host included (8).
    static let cap = kMCSessionMaximumNumberOfPeers
    /// How long `join` looks for the host before giving up.
    static let joinTimeout: TimeInterval = 20

    let id = "multipeer"
    private(set) var displayName = ""
    let maxPeers = MultipeerTransport.cap
    var onMessage: ((CollabPeer, Data) -> Void)?
    var onPeersChanged: (([CollabPeer]) -> Void)?

    private let link = MultipeerLink()
    private var localPeer: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var code: String?
    /// Transport peers by the Multipeer id they connected with (the display name is a random token, so it is unique).
    private var known: [MCPeerID: CollabPeer] = [:]
    private var joinTarget: MCPeerID?
    private var joinWaiter: CheckedContinuation<Void, Error>?
    private var joinTimer: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nib", category: "collab")

    init() {
        link.handler = { [weak self] event in self?.handle(event) }
    }

    var peers: [CollabPeer] {
        guard let s = session else { return [] }
        return s.connectedPeers.map { known[$0] ?? CollabPeer(id: $0.displayName, name: "") }
    }

    // MARK: CollabTransport

    func host(code: String, displayName: String) async throws {
        try Self.checkAvailable()
        leave()
        let me = makePeer(displayName)
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = link
        session = s
        self.code = code
        let info = ["c": CollabCode.discoveryHash(code), "v": String(CollabMessage.protocolVersion),
                    "n": String(displayName.prefix(32))]
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.serviceType)
        a.delegate = link
        advertiser = a
        a.startAdvertisingPeer()
    }

    func join(code: String, displayName: String) async throws {
        try Self.checkAvailable()
        leave()
        let me = makePeer(displayName)
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = link
        session = s
        self.code = code
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        b.delegate = link
        browser = b
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            joinWaiter = continuation
            b.startBrowsingForPeers()
            joinTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(MultipeerTransport.joinTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishJoin(NibError(.notFound, String(localized: "No live session with that code is nearby."),
                                          hint: "check the code; both devices need Wi-Fi or Bluetooth on and Nib open"))
            }
        }
    }

    func send(_ data: Data, to peers: [CollabPeer]?) throws {
        guard let s = session else { throw NibError.unavailable("collaboration session") }
        let targets = s.connectedPeers.filter { p in peers.map { list in list.contains { $0.id == p.displayName } } ?? true }
        guard !targets.isEmpty else { return }
        do {
            try s.send(data, toPeers: targets, with: .reliable)
        } catch {
            throw NibError(.unavailable, String(localized: "Couldn't reach the other devices: \(error.localizedDescription)"))
        }
    }

    func leave() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        session?.delegate = nil
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        code = nil
        known = [:]
        joinTarget = nil
        finishJoin(NibError(.userDenied, String(localized: "Stopped looking for the live session.")))
    }

    // MARK: Internals

    /// Multipeer needs the app (Info.plist Bonjour services, local network permission); package tests use
    /// NibTesting's `InMemoryCollabTransport` instead.
    private static func checkAvailable() throws {
        if NibApp.isHostlessTest { throw NibError.unavailable("Multipeer collaboration in tests") }
    }

    private func makePeer(_ name: String) -> MCPeerID {
        displayName = name
        // A random token as the Multipeer display name: unique, and it never shows anyone's name in Bonjour.
        let me = MCPeerID(displayName: NibID.make().raw)
        localPeer = me
        return me
    }

    private func finishJoin(_ error: Error?) {
        joinTimer?.cancel()
        joinTimer = nil
        guard let waiter = joinWaiter else { return }
        joinWaiter = nil
        browser?.stopBrowsingForPeers()
        if let error = error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    private func handle(_ event: MultipeerLink.Event) {
        switch event {
        case let .state(s, peer, state):
            guard s === session else { return }
            switch state {
            case .connected:
                if known[peer] == nil { known[peer] = CollabPeer(id: peer.displayName, name: "") }
                if peer == joinTarget { finishJoin(nil) }
            case .notConnected:
                if peer == joinTarget, joinWaiter != nil {
                    finishJoin(NibError(.unavailable, String(localized: "The host's device didn't accept the connection."),
                                        hint: "check the code; the session may be full"))
                }
            case .connecting:
                return
            @unknown default:
                return
            }
            onPeersChanged?(peers)
        case let .data(s, data, peer):
            guard s === session else { return }
            onMessage?(known[peer] ?? CollabPeer(id: peer.displayName, name: ""), data)
        case let .invitation(a, peer, context, respond):
            guard a === advertiser, let s = session, let code = code else {
                respond(false, nil)
                return
            }
            let invite = context.flatMap { try? JSONDecoder().decode(Invite.self, from: $0) }
            guard let i = invite, i.proof == CollabCode.joinProof(code), s.connectedPeers.count < maxPeers - 1 else {
                respond(false, nil)
                return
            }
            known[peer] = CollabPeer(id: peer.displayName, name: String(i.name.prefix(64)))
            respond(true, s)
        case let .found(b, peer, info):
            guard b === browser, joinTarget == nil, let s = session, let code = code,
                  info?["c"] == CollabCode.discoveryHash(code) else { return }
            joinTarget = peer
            known[peer] = CollabPeer(id: peer.displayName, name: info?["n"] ?? "")
            let context = try? JSONEncoder().encode(Invite(proof: CollabCode.joinProof(code), name: displayName))
            b.invitePeer(peer, to: s, withContext: context, timeout: 15)
        case let .lost(b, peer):
            guard b === browser, peer == joinTarget, joinWaiter != nil else { return }
            joinTarget = nil
        case let .failed(error):
            log.error("multipeer: \(error.localizedDescription, privacy: .public)")
            finishJoin(NibError(.unavailable, String(localized: "Nearby sharing isn't available: \(error.localizedDescription)"),
                                hint: "allow Local Network access for Nib in Settings › Privacy & Security"))
        }
    }

    /// What a joiner sends with its invitation: proof that it knows the code, and the name the host shows.
    struct Invite: Codable {
        var proof: String
        var name: String
    }
}

/// The MultipeerConnectivity delegate. Its callbacks arrive on private queues; each becomes one `Event` delivered on
/// the main queue in arrival order (FIFO), where `MultipeerTransport` handles it.
final class MultipeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    enum Event {
        case state(MCSession, MCPeerID, MCSessionState)
        case data(MCSession, Data, MCPeerID)
        case invitation(MCNearbyServiceAdvertiser, MCPeerID, Data?, (Bool, MCSession?) -> Void)
        case found(MCNearbyServiceBrowser, MCPeerID, [String: String]?)
        case lost(MCNearbyServiceBrowser, MCPeerID)
        case failed(Error)
    }

    var handler: (@MainActor (Event) -> Void)?

    private func deliver(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.handler?(event) }
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        deliver(.state(session, peerID, state))
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        deliver(.data(session, data, peerID))
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        if let url = localURL { try? FileManager.default.removeItem(at: url) }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        deliver(.invitation(advertiser, peerID, context, invitationHandler))
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        deliver(.failed(error))
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        deliver(.found(browser, peerID, info))
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        deliver(.lost(browser, peerID))
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        deliver(.failed(error))
    }
}
