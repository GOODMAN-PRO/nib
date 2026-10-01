import Foundation
import SwiftUI
import NibContracts
import NibDesign

// MARK: - Rules (pure)

/// When following ends by itself: the follower moved away from where the leader put them.
enum FollowRules {
    /// The last view this device was moved to while following, and (once it settled) what this window then showed.
    struct Applied: Equatable {
        var page: PageID
        var rect: Rect?
        var at: TimeInterval
        /// The follower's own visible rect once the move settled: screens differ, so a follower on an iPhone never
        /// shows exactly the leader's iPad rect, and it is compared with itself.
        var settled: Rect?
    }

    /// Whether this window's view (`page`, `rect`) is the user's own move away from `applied`. The first change after
    /// the settle time records the settled rect (`applied` is updated) and is not a move.
    static func isUserMove(page: PageID?, rect: Rect?, applied: inout Applied?, now: TimeInterval,
                           settle: TimeInterval) -> Bool {
        guard var a = applied, now - a.at >= settle, let page = page else { return false }
        if page != a.page { return true }
        guard let r = rect else { return false }
        guard let base = a.settled else {
            a.settled = r
            applied = a
            return false
        }
        return moved(r, from: base)
    }

    /// A scroll by more than a quarter of the view, or a zoom by more than 25 %.
    static func moved(_ r: Rect, from base: Rect) -> Bool {
        let scale = max(base.width, base.height, 1)
        let distance = hypot(r.midX - base.midX, r.midY - base.midY) / scale
        let zoom = max(r.width / max(base.width, 0.001), base.width / max(r.width, 0.001))
        return distance > 0.25 || zoom > 1.25
    }

    /// Whether moving to (`page`, `rect`) would change what this window shows (a leader's repeat is not re-applied).
    static func needsMove(to page: PageID, rect: Rect?, currentPage: PageID?, currentRect: Rect?,
                          applied: Applied?) -> Bool {
        if currentPage != page { return true }
        guard let target = rect else { return false }
        if let a = applied, a.page == page, let previous = a.rect, !moved(target, from: previous) { return false }
        guard let current = currentRect else { return true }
        return moved(target, from: current)
    }
}

// MARK: - Follow and Follow Me

/// Follow a collaborator (S-078: this window shows what they look at, until you stop or move away) and Follow Me
/// (S-113: everyone follows you). Driven by `collab.follow` / `collab.followMe` and by the others' presence.
@MainActor
final class FollowController {
    private unowned let hub: PresenceHub
    /// Who this device follows.
    private(set) var following: String?
    /// Set when following because they turned on Follow Me.
    private(set) var leader: String?
    /// This device's Follow Me.
    private(set) var isLeading = false
    private(set) var applied: FollowRules.Applied?
    /// The window that follows (nil = whichever window shows the shared document).
    private weak var window: EditorSession?
    /// The shared document had no window when following started, so it was opened once.
    private var openedForFollowing = false

    init(hub: PresenceHub) {
        self.hub = hub
    }

    /// Follows `pid` in `window` (nil stops). Following someone of your own choice ends a Follow Me link.
    func follow(_ pid: String?, window: EditorSession? = nil) {
        if let pid = pid {
            following = pid
            if leader != pid { leader = nil }
            if isLeading {
                isLeading = false
                _ = hub.broadcaster.sendNow(.followMe(on: false), to: nil)
            }
            self.window = window
            applied = nil
            openedForFollowing = false
            catchUp(pid)
        } else {
            following = nil
            leader = nil
            applied = nil
            self.window = nil
        }
        hub.followChanged()
    }

    /// Turns this device's Follow Me on or off and tells everyone; a leader follows nobody.
    @discardableResult
    func setLeading(_ on: Bool) -> Bool {
        isLeading = on
        if on {
            following = nil
            leader = nil
            applied = nil
        }
        let sent = hub.broadcaster.sendNow(.followMe(on: on), to: nil)
        if on { hub.sendViewport(force: true) }
        hub.followChanged()
        return sent
    }

    /// Rejoining preserves a manual follow, but drops stale automatic leadership without broadcasting it.
    func rejoined() {
        isLeading = false
        if leader != nil { follow(nil) }
    }

    /// Host leadership wins a tie; otherwise the lower participant id wins on every device.
    private func wins(_ candidate: CollabParticipant, over id: String) -> Bool {
        let incumbentIsHost = hub.hooks?.participants.first { $0.id == id }?.isHost ?? false
        if candidate.isHost != incumbentIsHost { return candidate.isHost }
        return candidate.id < id
    }

    /// Someone turned Follow Me on or off. Resolve competing leaders before moving anyone's view.
    func remoteFollowMe(on: Bool, from pid: String) {
        if on {
            guard let candidate = hub.state.others.first(where: { $0.id == pid }), candidate.canEdit else { return }
            if isLeading, let me = hub.state.me {
                guard wins(candidate, over: me) else {
                    // The other device may have enabled Follow Me just after receiving ours. Reassert the winning
                    // state so both devices converge even when deliveries do not overlap.
                    _ = hub.broadcaster.sendNow(.followMe(on: true), to: pid)
                    return
                }
                isLeading = false
                _ = hub.broadcaster.sendNow(.followMe(on: false), to: nil)
            } else if let current = leader, current != pid, !wins(candidate, over: current) {
                return
            }
            leader = pid
            following = pid
            applied = nil
            window = nil
            openedForFollowing = false
            catchUp(pid)
        } else if leader == pid {
            leader = nil
            if following == pid {
                following = nil
                applied = nil
            }
        } else {
            return
        }
        hub.followChanged()
    }

    /// A viewport arrived from `pid`: this window follows it when following them.
    func remoteViewport(from pid: String) {
        guard following == pid, let v = hub.presence.people[pid]?.viewport else { return }
        apply(page: v.page, rect: v.rect)
    }

    /// This window's view changed: stop following when the user moved away from the leader's view.
    func localViewChanged(_ session: EditorSession) {
        guard let pid = following, session === targetSession() else { return }
        var a = applied
        let moved = FollowRules.isUserMove(page: session.page, rect: session.visibleRect, applied: &a, now: hub.now(),
                                           settle: hub.timing.followSettle)
        applied = a
        guard moved else { return }
        let name = hub.state.others.first { $0.id == pid }?.name ?? ""
        follow(nil)
        hub.announce(String(localized: "Stopped following \(name)"))
    }

    /// People left: stop following someone who is gone.
    func rosterChanged(active: Set<String>) {
        var changed = false
        if let f = following, !active.contains(f) {
            following = nil
            applied = nil
            changed = true
        }
        if let l = leader, !active.contains(l) {
            leader = nil
            changed = true
        }
        if changed { hub.followChanged() }
    }

    func reset() {
        following = nil
        leader = nil
        isLeading = false
        applied = nil
        window = nil
        openedForFollowing = false
    }

    /// The window that follows: the one following was started from while it shows the shared document, else the
    /// one the hub shares its view from.
    func targetSession() -> EditorSession? {
        if let w = window, w.document == hub.sharedDoc { return w }
        return hub.presenceSession()
    }

    // MARK: Moving the view

    /// Starts following with what is known of `pid`: their last viewport, else the page the roster says they are on.
    private func catchUp(_ pid: String) {
        if let v = hub.presence.people[pid]?.viewport {
            apply(page: v.page, rect: v.rect)
        } else if let page = hub.rosterPage(pid) {
            apply(page: page, rect: nil)
        }
    }

    private func apply(page: PageID, rect: Rect?) {
        guard let doc = hub.sharedDoc else { return }
        guard let session = targetSession() else {
            // No window shows the document (following from the library): open it there once.
            guard !openedForFollowing else { return }
            openedForFollowing = true
            applied = FollowRules.Applied(page: page, rect: rect, at: hub.now(), settled: nil)
            hub.openShared(doc, page: page)
            return
        }
        let move = FollowRules.needsMove(to: page, rect: rect, currentPage: session.page,
                                         currentRect: session.visibleRect, applied: applied)
        // Recorded before moving: the move itself reports a page change, which must not count as the user's. A view
        // that already matches still becomes the reference the user's own moves are measured from.
        if move || applied == nil { applied = FollowRules.Applied(page: page, rect: rect, at: hub.now(), settled: nil) }
        if move { hub.reveal(page: page, rect: rect, in: session) }
    }
}

// MARK: - Follow HUD

/// "Following Sam · Stop" (a Clear HUD, DESIGN.md §14.14), or "Everyone follows you · Stop" while Follow Me is on.
struct FollowHUD: View {
    @ObservedObject var hub: PresenceHub
    let context: ChromeContext

    var body: some View {
        let state = hub.state
        if let p = state.followed {
            HStack(spacing: NibSpacing.xxs) {
                NibBadge(.presence(initials: p.initials, colorIndex: p.colorIndex))
                    .padding(.leading, NibSpacing.xs)
                    .accessibilityHidden(true)
                NibHUDText(String(localized: "Following \(p.name)"))
                stop(String(localized: "Stop Following \(p.name)")) {
                    hub.run(CommandIDs.collabFollow, [:], session: context.session)
                }
            }
            .frame(height: NibMetrics.hudHeight)
            .nibChromeTypeCap()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Following \(p.name)"))
        } else if state.leading {
            HStack(spacing: NibSpacing.xxs) {
                NibStatusDot(.connected)
                    .padding(.leading, NibSpacing.m)
                NibHUDText(String(localized: "Everyone follows you"))
                stop(String(localized: "Stop Follow Me")) {
                    hub.run(CommandIDs.collabFollowMe, ["on": false], session: context.session)
                }
            }
            .frame(height: NibMetrics.hudHeight)
            .nibChromeTypeCap()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Follow Me is on"))
        }
    }

    /// "Stop": HUD type in `label` (legible on Clear), a 44 pt target.
    private func stop(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(String(localized: "Stop"))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
                .padding(.horizontal, NibSpacing.m)
                .frame(minWidth: NibMetrics.hitTarget, minHeight: NibMetrics.hitTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(NibPressStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}
