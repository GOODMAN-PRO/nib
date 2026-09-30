import Foundation
import NibContracts

struct ReplaySetMode: NibCommand {
    struct Params: Codable {
        var mode: ReplayMode
        var enabled: Bool?
        var followAlong: Bool?
        var fullScreen: Bool?
    }
    struct Output: Codable {
        var mode: ReplayMode
        var enabled: Bool
        var followAlong: Bool
        var fullScreen: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.replaySetMode, title: "Replay Mode",
        summary: "Choose spotlight, reveal or static note replay; optionally follow pages, enter full screen or disable replay in this window.",
        params: .obj(["mode": .str(choices: ReplayMode.allCases.map(\.rawValue)), "enabled": .bool(),
                      "followAlong": .bool(), "fullScreen": .bool()], required: ["mode"]),
        examples: [["mode": "spotlight"], ["mode": "reveal", "followAlong": true]], effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (controller, session) = try ReplayCommandContext.require(ctx)
        if !ctx.dryRun {
            if let fullScreen = p.fullScreen { try await controller.setFullScreen(fullScreen, for: session, query: { try await ctx.execute($0, $1) }) }
            controller.configure(session, mode: p.mode, enabled: p.enabled, followAlong: p.followAlong)
            controller.start()
            await controller.refresh()
            ctx.ui?.setNeedsChromeUpdate(session)
        }
        let options = controller.options(for: session)
        return Output(mode: ctx.dryRun ? p.mode : options.mode, enabled: p.enabled ?? options.enabled,
                      followAlong: p.followAlong ?? options.followAlong, fullScreen: p.fullScreen ?? options.fullScreen)
    }
}

struct ReplaySeekToItem: NibCommand {
    struct Params: Codable { var ref: String }
    struct Output: Codable { var clip: String; var t: Double }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.replaySeekToItem, title: "Replay Handwriting",
        summary: "Play the recording linked to a stroke from one second before its first sample; linkage uses t0 in this document's clip intervals.",
        params: .obj(["ref": .ref], required: ["ref"]),
        examples: [["ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"]], effect: .session, extraScopes: [.documentRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let app = ctx.app, case let .item(doc, _, _)? = NodeRef(p.ref) else {
            throw NibError.invalid("Expected a handwriting item ref", path: "$.ref")
        }
        let query: ReplayReader.Query = { try await ctx.execute($0, $1) }
        guard let ink = try await ReplayReader.ink(p.ref, app: app, query: query) else {
            throw NibError(.unsupported, "Only handwriting can seek a recording", hint: "Choose a stroke item using query.find")
        }
        let status = try await ctx.execute(CommandIDs.audioSetPlayback, [:]).decode(ReplayPlayback.self)
        let clips = try await ReplayReader.clips(doc, app: app, query: query)
        guard let clip = ReplayLink.clip(for: ink.t0, in: clips, preferred: status.clip, doc: doc) else {
            throw NibError(.notFound, "No recording is linked to this handwriting", hint: "Choose handwriting written while a clip was recorded")
        }
        let ref = NodeRef.audio(doc, clip.id).description
        let t = ReplayLink.seekTime(ink.t0, clip: clip)
        if !ctx.dryRun {
            _ = try await ctx.execute(CommandIDs.audioPlay, ["clip": .string(ref), "t": .number(t)])
            ReplayController.of(ctx.services)?.start()
            await ReplayController.of(ctx.services)?.refresh()
        }
        return Output(clip: ref, t: t)
    }
}

struct ReplayTapAt: NibCommand {
    struct Params: Codable { var page: String; var point: [Double]; var ref: String?; var gesture: CanvasGesture? }
    struct Output: Codable { var handled: Bool }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.replayTapAt, title: "Seek Replay at Handwriting",
        summary: "Handle a handwriting tap only while note replay is active, seeking one second before the stroke in the currently loaded clip.",
        params: .obj(["page": .ref, "point": .point, "ref": .ref,
                      "gesture": .str(choices: CanvasGesture.allCases.map(\.rawValue))], required: ["page", "point"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [80, 122],
                    "ref": "item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01", "gesture": "tap"]], effect: .session, extraScopes: [.documentRead])

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard p.point.count == 2, p.point.allSatisfy(\.isFinite), case let .page(doc, page)? = NodeRef(p.page) else {
            throw NibError.invalid("Expected a page ref and two finite page coordinates", path: "$.point")
        }
        guard p.gesture == nil || p.gesture == .tap, let session = ctx.activeSession,
              session.document == doc, session.replay != nil, let app = ctx.app else { return Output(handled: false) }
        let query: ReplayReader.Query = { try await ctx.execute($0, $1) }
        let status = try await ctx.execute(CommandIDs.audioSetPlayback, [:]).decode(ReplayPlayback.self)
        guard let clipRef = status.clip, NodeRef(clipRef)?.documentID == doc else { return Output(handled: false) }
        let clip = try await ReplayReader.clip(clipRef, app: app, query: query)
        let ink: ReplayInk?
        if let ref = p.ref {
            guard case let .item(d, pg, _)? = NodeRef(ref), d == doc, pg == page else { return Output(handled: false) }
            ink = try await ReplayReader.ink(ref, app: app, query: query)
        } else {
            // Canvas normally supplies its exact topmost hit. Direct API callers may omit ref.
            let point = Point(p.point[0], p.point[1])
            ink = try await ReplayReader.inks(doc, app: app, query: query)
                .last { $0.page == page && $0.bounds.contains(point) }
        }
        guard let ink, ReplayLink.contains(ink.t0, clip: clip) else { return Output(handled: false) }
        if !ctx.dryRun {
            _ = try await ctx.execute(CommandIDs.audioSeek, ["t": .number(ReplayLink.seekTime(ink.t0, clip: clip))])
            await ReplayController.of(ctx.services)?.refresh()
        }
        return Output(handled: true)
    }
}

@MainActor
private enum ReplayCommandContext {
    static func require(_ ctx: CommandContext) throws -> (ReplayController, EditorSession) {
        guard let controller = ReplayController.of(ctx.services), let session = ctx.activeSession else {
            throw NibError(.unavailable, "Open a note to configure replay", hint: "Call doc.open, then replay.setMode")
        }
        return (controller, session)
    }
}
