import XCTest
import UIKit
import Combine
import NibContracts
import NibTesting
@testable import FeatPresentation

/// A page source with a scripted current page; records renders and snapshots. With `holdsRenders`, every render
/// waits until the test calls `resumeRender()` (a change can then land while it is in flight).
@MainActor
final class FakePageSource: PresentationPageSource {
    var current: PresentedPage?
    var onChange: (() -> Void)?
    var onLaser: ((LaserEvent) -> Void)?
    private(set) var renders: [(page: PageID, region: Rect, scale: Double)] = []
    private(set) var snapshots = 0
    let mirrorImage = FakeRenderer.blank(CGSize(width: 4, height: 3))
    var holdsRenders = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(page: PresentedPage?) {
        current = page
    }

    var pendingRenders: Int { held.count }

    func resumeRender() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func render(doc: DocumentID, page: PageID, region: Rect, scale: Double, hiddenLayers: Set<Int>) async throws -> CGImage {
        renders.append((page, region, scale))
        if holdsRenders {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in held.append(continuation) }
        }
        return FakeRenderer.blank(CGSize(width: 2, height: 2))
    }

    func snapshot(maxPixelWidth: CGFloat) -> CGImage? {
        snapshots += 1
        return mirrorImage
    }

    func stop() {}
}

/// Adds a 100 × 30 text box to a page (at x, y; default 10, 10): a real commit for the live source to notice (test only).
struct TouchPage: NibCommand {
    struct Params: Codable {
        var page: String
        var x: Double?
        var y: Double?
    }

    static let descriptor = CommandDescriptor(
        id: "test.touchPage", title: "Touch Page", summary: "Add a text box to a page (tests only).",
        params: .obj(["page": .ref, "x": .num("left edge"), "y": .num("top edge")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .page(doc, page)? = NodeRef(p.page) else { throw NibError.invalid("expected a page ref", path: "$.page") }
        let frame = Frame(x: p.x ?? 10, y: p.y ?? 10, w: 100, h: 30)
        _ = try ctx.mutate { tx in
            try tx.put(Item.makeText(TextBoxItem(frame: frame, text: RichText(plain: "Hi"))), doc: doc, page: page)
        }
        return NoResult()
    }
}

/// Polls (yielding the main actor) until `condition` holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
final class FeatPresentationTests: XCTestCase {
    static let bounds = Rect(x: 0, y: 0, width: 600, height: 800)
    static let zoomed = Rect(x: 100, y: 200, width: 300, height: 200)
    static let scrolled = Rect(x: 100, y: 450, width: 300, height: 200)

    static func page(_ id: PageID = Fixtures.page1, index: Int = 0, visible: Rect? = nil) -> PresentedPage {
        PresentedPage(doc: Fixtures.docID, page: id, index: index, count: 3, bounds: bounds, visibleRect: visible)
    }

    // MARK: View model

    func testPresenterPageRendersTheVisiblePartAndFollowsScrollWithAnimation() async {
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let model = PresentationViewModel(source: source, mode: .presenter)
        var frames: [PageFrame] = []
        let watch = model.$display.sink { display in
            if case .page(let frame) = display { frames.append(frame) }
        }
        defer { watch.cancel() }

        await model.update(detailDelay: 0)
        guard case .page(let first) = model.display else { return XCTFail("expected the page, got \(model.display)") }
        XCTAssertEqual(first.doc, Fixtures.docID)
        XCTAssertEqual(first.page, Fixtures.page1)
        XCTAssertEqual(first.base.region, Self.bounds, "the base image is the whole page")
        XCTAssertEqual(first.viewport, Self.zoomed, "Presenter Page shows what the presenter sees")
        XCTAssertEqual(first.detail?.region, Self.zoomed, "a zoomed-in viewport gets its own sharp render")
        XCTAssertEqual(source.renders.map { $0.region }, [Self.bounds, Self.zoomed])
        XCTAssertEqual(frames.first?.animated, false, "the first frame jumps into place")

        frames.removeAll()
        source.current?.visibleRect = Self.scrolled
        await model.update(detailDelay: 0)
        XCTAssertEqual(frames.first?.viewport, Self.scrolled)
        XCTAssertEqual(frames.first?.animated, true, "the camera glides after the presenter scrolls")
        XCTAssertEqual(source.renders.filter { $0.region == Self.bounds }.count, 1, "the page is not re-rendered to scroll")
        XCTAssertEqual(source.renders.last?.region, Self.scrolled)
    }

    func testFullPageShowsTheWholePageAndFlipsWithoutAnimation() async {
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let model = PresentationViewModel(source: source, mode: .fullPage)
        var frames: [PageFrame] = []
        let watch = model.$display.sink { display in
            if case .page(let frame) = display { frames.append(frame) }
        }
        defer { watch.cancel() }

        await model.update(detailDelay: 0)
        XCTAssertEqual(frames.last?.viewport, Self.bounds)
        XCTAssertNil(frames.last?.detail)
        XCTAssertEqual(source.renders.map { $0.region }, [Self.bounds])

        source.current?.visibleRect = Self.scrolled
        await model.update(detailDelay: 0)
        XCTAssertEqual(frames.last?.viewport, Self.bounds, "zoom and scroll on the iPad do not move the full page")
        XCTAssertEqual(frames.last?.animated, false)

        source.current = Self.page(Fixtures.page2, index: 1, visible: Self.zoomed)
        await model.update(detailDelay: 0)
        XCTAssertEqual(frames.last?.page, Fixtures.page2, "the next page replaces the last one (flipbook)")
        XCTAssertEqual(frames.last?.index, 1)
        XCTAssertEqual(frames.last?.animated, false)
    }

    func testSwitchingModesKeepsTheSceneAndItsViewController() async {
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let model = PresentationViewModel(source: source, mode: .presenter)
        let controller = PresentationViewController(model: model)
        controller.loadViewIfNeeded()
        let root = controller.view
        let size = CGSize(width: 1920, height: 1080)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()

        await model.update(detailDelay: 0)
        XCTAssertTrue(controller.showsPage)
        XCTAssertFalse(controller.showsMirror)
        XCTAssertNotNil(controller.shownBaseImage)
        XCTAssertEqual(controller.cameraTransform, PresentationCamera.transform(showing: Self.zoomed, in: size))

        model.mode = .fullPage
        await model.update(detailDelay: 0)
        XCTAssertTrue(controller.showsPage)
        XCTAssertEqual(controller.cameraTransform, PresentationCamera.transform(showing: Self.bounds, in: size))

        model.mode = .mirror
        await model.update(detailDelay: 0)
        XCTAssertTrue(controller.showsMirror)
        XCTAssertFalse(controller.showsPage)
        XCTAssertGreaterThanOrEqual(source.snapshots, 1)

        model.blank = true
        await model.update(detailDelay: 0)
        guard case .blank = model.display else { return XCTFail("expected blank, got \(model.display)") }
        XCTAssertFalse(controller.showsMirror)
        XCTAssertFalse(controller.showsPage)

        model.blank = false
        model.mode = .presenter
        await model.update(detailDelay: 0)
        XCTAssertTrue(controller.showsPage)
        XCTAssertEqual(controller.cameraTransform, PresentationCamera.transform(showing: Self.zoomed, in: size))
        XCTAssertTrue(controller.view === root, "modes switch inside the same scene and view controller")
        XCTAssertTrue(controller.model === model)
        model.stop()
    }

    func testNoPageShowsTheEmptyDesk() async {
        let source = FakePageSource(page: nil)
        let model = PresentationViewModel(source: source, mode: .presenter)
        await model.update(detailDelay: 0)
        guard case .idle = model.display else { return XCTFail("expected idle, got \(model.display)") }
        XCTAssertTrue(source.renders.isEmpty)
    }

    func testCameraLetterboxesTheViewport() {
        let t = PresentationCamera.transform(showing: Rect(x: 100, y: 50, width: 400, height: 300),
                                             in: CGSize(width: 1600, height: 900))
        XCTAssertEqual(CGPoint(x: 100, y: 50).applying(t), CGPoint(x: 200, y: 0))
        XCTAssertEqual(CGPoint(x: 500, y: 350).applying(t), CGPoint(x: 1400, y: 900))
    }

    // MARK: Laser

    func testLaserIsDrawnOnTheCurrentPageThroughTheCamera() async {
        let source = FakePageSource(page: Self.page())
        let model = PresentationViewModel(source: source, mode: .presenter)
        await model.update(detailDelay: 0)
        let camera = PresentationCamera.transform(showing: Self.bounds, in: model.canvasSize)
        let ref = "page:\(Fixtures.docID.raw)/\(Fixtures.page1.raw)"

        let first: JSONValue = ["page": .string(ref), "point": [300, 400], "mode": "trail"]
        source.onLaser?(LaserEvent(payload: first))
        XCTAssertEqual(model.laser.dot, CGPoint(x: 300, y: 400).applying(camera))

        let second: JSONValue = ["page": .string(ref), "point": [320, 410], "mode": "trail"]
        source.onLaser?(LaserEvent(payload: second))
        XCTAssertEqual(model.laser.segments.count, 1, "a trail leaves a fading segment behind the dot")

        let lifted: JSONValue = ["page": .string(ref), "mode": "trail"]
        source.onLaser?(LaserEvent(payload: lifted))
        XCTAssertNil(model.laser.dot, "no point means the laser was lifted")

        source.onLaser?(LaserEvent(page: Fixtures.page2, point: Point(10, 10)))
        XCTAssertNil(model.laser.dot, "a laser on another page is not shown")

        model.mode = .mirror
        await model.update(detailDelay: 0)
        source.onLaser?(LaserEvent(payload: first))
        XCTAssertNil(model.laser.dot, "the mirrored window already shows the laser")
        model.stop()
    }

    func testLaserPayloadParsing() {
        let payload: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG002", "point": [1.5, 2], "mode": "dot", "color": "#FF0000"]
        let event = LaserEvent(payload: payload)
        XCTAssertEqual(event.page, Fixtures.page2)
        XCTAssertEqual(event.point, Point(1.5, 2))
        XCTAssertFalse(event.trail)
        XCTAssertEqual(event.color, RGBA(255, 0, 0))
        XCTAssertEqual(LaserEvent(payload: ["page": "FIXTUREPG001"]).page, Fixtures.page1)
        XCTAssertNil(LaserEvent(payload: nil).point)
    }

    // MARK: Command and live source

    func testSetModeCommandSwitchesModeAndBlank() async throws {
        let h = Harness(features: [FeatPresentationFeature.self])
        let controller = try XCTUnwrap(h.app.services.get(PresentationController.serviceKey, as: PresentationController.self))
        XCTAssertEqual(controller.mode, .presenter, "presenter is the default")
        XCTAssertNotNil(h.app.ui.externalDisplay, "the feature provides the external display scene")

        let out = try await h.run("present.setMode", ["mode": "fullPage"])
        XCTAssertEqual(controller.mode, .fullPage)
        XCTAssertEqual(out["mode"]?.stringValue, "fullPage")
        XCTAssertEqual(out["externalDisplay"]?.boolValue, false)

        let blanked = try await h.run("present.setMode", ["mode": "presenter", "blank": true], as: .ai("chat"))
        XCTAssertEqual(controller.mode, .presenter)
        XCTAssertFalse(controller.blank, "with no display there is nothing to black out, so the next one never starts black")
        XCTAssertEqual(blanked["blank"]?.boolValue, false)

        do {
            _ = try await h.run("present.setMode", ["mode": "slideshow"])
            XCTFail("an unknown mode must be rejected")
        } catch {
            XCTAssertEqual(NibError.wrap(error).code, .invalidParams)
        }

        _ = try await h.run(CommandIDs.settingsSet, ["name": "presentation.mode", "value": "mirror"])
        XCTAssertEqual(controller.mode, .mirror, "settings.set reaches the presentation too")
    }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatPresentationFeature.self],
                                                      owners: [FeatPresentationFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testLiveSourceFollowsTheActiveSession() async throws {
        let h = Harness(features: [FeatPresentationFeature.self])
        let renderer = FakeRenderer()
        h.app.services.renderer = renderer
        h.app.commands.register(TouchPage.self)
        h.session.visibleRect = Self.zoomed
        let source = LivePageSource(app: h.app)
        defer { source.stop() }

        let page = try XCTUnwrap(source.current)
        XCTAssertEqual(page.doc, Fixtures.docID)
        XCTAssertEqual(page.page, Fixtures.page1)
        XCTAssertEqual(page.index, 0)
        XCTAssertEqual(page.count, try h.app.workspace.content(Fixtures.docID).livePages.count)
        XCTAssertEqual(page.visibleRect, Self.zoomed)
        XCTAssertFalse(page.bounds.isEmpty)

        var changes = 0
        source.onChange = { changes += 1 }
        _ = try await h.run("test.touchPage", ["page": "page:FIXTUREDOC01/FIXTUREPG001"])
        XCTAssertGreaterThan(try XCTUnwrap(source.current).version, page.version, "a commit on the page re-renders it")
        XCTAssertGreaterThanOrEqual(changes, 1)

        _ = try await source.render(doc: page.doc, page: page.page, region: page.bounds, scale: 2, hiddenLayers: [1])
        XCTAssertEqual(renderer.requests.last?.layers, [0, 2, 3, 4], "hidden layers stay hidden on the display")

        var lasers: [LaserEvent] = []
        source.onLaser = { lasers.append($0) }
        let payload: JSONValue = ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [10, 20], "mode": "dot"]
        h.app.events.emit(NibEventType.laserMoved, payload: payload)
        XCTAssertEqual(lasers.last?.point, Point(10, 20))

        h.session.page = nil
        XCTAssertNil(source.current, "no page (library, text documents) shows nothing")
    }

    // MARK: Review fixes

    func testSetModeSwitchesTheConnectedDisplayInPlace() async throws {
        let h = Harness(features: [FeatPresentationFeature.self])
        let controller = try XCTUnwrap(h.app.services.get(PresentationController.serviceKey, as: PresentationController.self))
        let token = NSObject()
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let viewController = controller.connect(id: ObjectIdentifier(token), name: "Test TV", source: source)
        viewController.loadViewIfNeeded()
        let size = CGSize(width: 1920, height: 1080)
        viewController.view.frame = CGRect(origin: .zero, size: size)
        viewController.view.layoutIfNeeded()
        let model = viewController.model
        XCTAssertTrue(controller.connections.first?.model === model)
        await model.update(detailDelay: 0)
        XCTAssertTrue(viewController.showsPage)
        XCTAssertEqual(viewController.cameraTransform, PresentationCamera.transform(showing: Self.zoomed, in: size))

        let out = try await h.run("present.setMode", ["mode": "fullPage"])
        XCTAssertEqual(out["externalDisplay"]?.boolValue, true)
        XCTAssertEqual(out["displays"]?.arrayValue?.compactMap { $0.stringValue }, ["Test TV"])
        XCTAssertEqual(model.mode, .fullPage, "the command reaches the connected display's model")
        await model.update(detailDelay: 0)
        XCTAssertEqual(viewController.cameraTransform, PresentationCamera.transform(showing: Self.bounds, in: size))

        let blanked = try await h.run("present.setMode", ["mode": "fullPage", "blank": true], as: .ai("chat"))
        XCTAssertEqual(blanked["blank"]?.boolValue, true)
        XCTAssertTrue(model.blank)
        await model.update(detailDelay: 0)
        guard case .blank = model.display else { return XCTFail("expected blank, got \(model.display)") }
        XCTAssertFalse(viewController.showsPage)

        let read = try await h.run("present.setMode", ["mode": "fullPage"])
        XCTAssertEqual(read["blank"]?.boolValue, true, "a missing blank keeps the screen black (reading the state is safe)")
        XCTAssertTrue(controller.blank)
        XCTAssertTrue(model.blank)

        _ = try await h.run(CommandIDs.settingsSet, ["name": "presentation.mode", "value": "mirror"])
        XCTAssertEqual(model.mode, .mirror, "settings.set switches the same model")
        XCTAssertTrue(model.blank)

        _ = try await h.run("present.setMode", ["mode": "presenter", "blank": false])
        XCTAssertFalse(controller.blank)
        await model.update(detailDelay: 0)
        XCTAssertTrue(viewController.showsPage)
        XCTAssertEqual(viewController.cameraTransform, PresentationCamera.transform(showing: Self.zoomed, in: size))
        XCTAssertTrue(viewController.model === model, "modes switch inside the same view controller")
        XCTAssertEqual(controller.connections.count, 1)

        _ = try await h.run("present.setMode", ["mode": "presenter", "blank": true])
        controller.disconnect(ObjectIdentifier(token))
        XCTAssertFalse(controller.isConnected)
        XCTAssertFalse(controller.blank, "the next display does not start black")
    }

    func testPageModesAreOfferedOnlyWhereThereIsAPage() async throws {
        let h = Harness(features: [FeatPresentationFeature.self])
        let controller = try XCTUnwrap(h.app.services.get(PresentationController.serviceKey, as: PresentationController.self))
        func entries(_ doc: DocumentID) -> [String] {
            h.app.ui.menuItems(.shareExport, MenuContext(app: h.app, session: h.session, doc: doc))
                .filter { $0.owner == FeatPresentationFeature.id }.map { $0.id }.sorted()
        }
        XCTAssertEqual(entries(Fixtures.docID), [], "no display, no Presentation Mode entries")

        let token = NSObject()
        _ = controller.connect(id: ObjectIdentifier(token), name: "Test TV", source: FakePageSource(page: nil))
        defer { controller.disconnect(ObjectIdentifier(token)) }
        XCTAssertEqual(entries(Fixtures.docID),
                       ["presentation.mode.fullPage", "presentation.mode.mirror", "presentation.mode.presenter.current"])
        XCTAssertEqual(entries(Fixtures.whiteboardID).count, 3)
        XCTAssertEqual(entries(Fixtures.textDocID), ["presentation.mode.mirror"], "a text document has no page to present")
        XCTAssertEqual(entries(Fixtures.studySetID), ["presentation.mode.mirror"])

        let entry = try XCTUnwrap(h.app.ui.menus.get("presentation.mode.fullPage"))
        XCTAssertEqual(entry.params(MenuContext(app: h.app))["blank"]?.boolValue, false,
                       "choosing a mode in the menu shows a blanked screen again")
    }

    func testRenderScaleIsCappedLast() {
        let model = PresentationViewModel(source: FakePageSource(page: nil), mode: .fullPage)
        let huge = Rect(x: 0, y: 0, width: 1e6, height: 1e6)
        XCTAssertLessThanOrEqual(model.fitScale(for: huge) * 1e6, PresentationViewModel.maxPixels)
        for width in [800.0, 5_000, 82_000, 90_000, 250_000, 3e7] {
            let scale = model.fitScale(for: Rect(x: 0, y: 0, width: width, height: width / 2))
            XCTAssertGreaterThan(scale, 0, "width \(width)")
            XCTAssertLessThanOrEqual(scale * width, PresentationViewModel.maxPixels, "width \(width)")
        }
        XCTAssertEqual(model.fitScale(for: Rect(x: 0, y: 0, width: 800, height: 400)), 2.390625, "1/64 steps, rounded down")
    }

    func testACommitDuringARenderShowsThatRenderThenTheNewerOne() async {
        let source = FakePageSource(page: Self.page())
        source.holdsRenders = true
        let model = PresentationViewModel(source: source, mode: .fullPage)
        let running = Task { await model.update(detailDelay: 0) }
        await waitUntil { source.pendingRenders == 1 }

        source.current?.version = 1                        // a commit lands while version 0 renders
        model.setNeedsUpdate()
        source.resumeRender()
        await waitUntil { source.renders.count == 2 && source.pendingRenders == 1 }
        guard case .page(let shown) = model.display else {
            return XCTFail("the finished render shows at once, got \(model.display)")
        }
        XCTAssertEqual(shown.base.key.version, 0)

        source.resumeRender()
        await running.value
        guard case .page(let latest) = model.display else { return XCTFail("expected the page, got \(model.display)") }
        XCTAssertEqual(latest.base.key.version, 1, "then the newer version replaces it")
        XCTAssertEqual(source.renders.count, 2)
    }

    func testAPageFlipDuringARenderDropsThatRender() async {
        let source = FakePageSource(page: Self.page())
        source.holdsRenders = true
        let model = PresentationViewModel(source: source, mode: .fullPage)
        let running = Task { await model.update(detailDelay: 0) }
        await waitUntil { source.pendingRenders == 1 }

        source.current = Self.page(Fixtures.page2, index: 1)
        model.setNeedsUpdate()
        source.resumeRender()
        await waitUntil { source.renders.count == 2 && source.pendingRenders == 1 }
        guard case .idle = model.display else { return XCTFail("the left page never shows, got \(model.display)") }

        source.resumeRender()
        await running.value
        guard case .page(let frame) = model.display else { return XCTFail("expected the page, got \(model.display)") }
        XCTAssertEqual(frame.page, Fixtures.page2)
        XCTAssertEqual(source.renders.map { $0.page }, [Fixtures.page1, Fixtures.page2])
    }

    func testAPendingDetailRenderIsCancelledWhenTheViewportMoves() async throws {
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let model = PresentationViewModel(source: source, mode: .presenter)
        model.detailDelay = 0.3
        await model.update()                               // the base now; the zoomed detail waits 0.3 s
        XCTAssertEqual(source.renders.map { $0.region }, [Self.bounds])

        source.current?.visibleRect = Self.scrolled
        await model.update(detailDelay: 0)                 // the presenter moved on: that detail renders at once
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(source.renders.map { $0.region }, [Self.bounds, Self.scrolled], "the stale detail never renders")
        guard case .page(let frame) = model.display else { return XCTFail("expected the page, got \(model.display)") }
        XCTAssertEqual(frame.detail?.region, Self.scrolled)
        model.stop()
    }

    func testLaserStaysOnItsSpotOfThePageWhenThePresenterScrolls() async {
        let source = FakePageSource(page: Self.page(visible: Self.zoomed))
        let model = PresentationViewModel(source: source, mode: .presenter)
        await model.update(detailDelay: 0)
        source.onLaser?(LaserEvent(page: Fixtures.page1, point: Point(150, 250), trail: true))
        source.onLaser?(LaserEvent(page: Fixtures.page1, point: Point(200, 300), trail: true))
        XCTAssertEqual(model.laser.segments.count, 1)
        XCTAssertEqual(model.laser.segments.first?.from, Point(150, 250), "the trail is kept in page points")

        source.current?.visibleRect = Self.scrolled
        await model.update(detailDelay: 0)
        let camera = PresentationCamera.transform(showing: Self.scrolled, in: model.canvasSize)
        XCTAssertEqual(model.laser.camera, camera, "the laser rides the stage's camera")
        XCTAssertEqual(model.laser.dot, CGPoint(x: 200, y: 300).applying(camera))
        XCTAssertEqual(model.laser.segments.count, 1, "scrolling keeps the trail on the page")
        let drawn = LaserCamera(camera).apply(Point(200, 300))
        XCTAssertEqual(drawn.x, CGPoint(x: 200, y: 300).applying(camera).x, accuracy: 1e-9)
        XCTAssertEqual(drawn.y, CGPoint(x: 200, y: 300).applying(camera).y, accuracy: 1e-9)

        source.current = Self.page(Fixtures.page2, index: 1, visible: Self.zoomed)
        await model.update(detailDelay: 0)
        XCTAssertNil(model.laser.dot)
        XCTAssertTrue(model.laser.segments.isEmpty, "another page clears the laser")
        model.stop()
    }

    func testBoardExtentAsksForARebuildOnlyWhenItsEdgeMayShrink() {
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Item {
            Item.makeText(TextBoxItem(frame: Frame(x: x, y: y, w: w, h: h), text: RichText(plain: "x")))
        }
        let edge = box(0, 0, 100, 100)
        let inner = box(40, 40, 10, 10)
        var extent = BoardExtent(doc: Fixtures.whiteboardID, page: Fixtures.boardID, items: [edge, inner])
        XCTAssertEqual(extent.union, Rect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertTrue(extent.apply(before: inner, after: box(60, 60, 10, 10)), "an inner item moving inside changes nothing")
        let far = box(500, 500, 10, 10)
        XCTAssertTrue(extent.apply(before: nil, after: far))
        XCTAssertEqual(extent.union, Rect(x: 0, y: 0, width: 510, height: 510), "a new item grows the union")
        XCTAssertTrue(extent.apply(before: far, after: box(500, 500, 20, 20)), "an edge item growing only grows it")
        var gone = far
        gone.deleted = true
        XCTAssertFalse(extent.apply(before: box(500, 500, 20, 20), after: gone), "the edge went away: rebuild")
    }

    func testLiveBoardBoundsFollowCommitsAndUndo() async throws {
        let h = Harness(features: [FeatPresentationFeature.self])
        h.app.commands.register(TouchPage.self)
        h.session.document = Fixtures.whiteboardID
        h.session.page = Fixtures.boardID
        let source = LivePageSource(app: h.app)
        defer { source.stop() }

        let before = try XCTUnwrap(source.current)
        XCTAssertTrue(before.isBoard)
        XCTAssertEqual(before.count, 1)
        let shape = try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID).bounds
        XCTAssertEqual(before.bounds, shape.insetBy(-LivePageSource.boardMargin))

        _ = try await h.run("test.touchPage", ["page": "page:FIXTUREDOC04/FIXTUREBRD01", "x": 5000, "y": 3000])
        let added = try XCTUnwrap(h.app.workspace.items(Fixtures.whiteboardID, page: Fixtures.boardID)
            .first { $0.id != Fixtures.boardShapeID })
        XCTAssertEqual(try XCTUnwrap(source.current).bounds, shape.union(added.bounds).insetBy(-LivePageSource.boardMargin))

        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try XCTUnwrap(source.current).bounds, before.bounds, "the far item gone, the board shrinks back")
    }
}
