import XCTest
import UIKit
import Combine
import NibContracts
import NibTesting
@testable import FeatPresentation

/// A page source with a scripted current page; records renders and snapshots.
@MainActor
final class FakePageSource: PresentationPageSource {
    var current: PresentedPage?
    var onChange: (() -> Void)?
    var onLaser: ((LaserEvent) -> Void)?
    private(set) var renders: [(page: PageID, region: Rect, scale: Double)] = []
    private(set) var snapshots = 0
    let mirrorImage = FakeRenderer.blank(CGSize(width: 4, height: 3))

    init(page: PresentedPage?) {
        current = page
    }

    func render(doc: DocumentID, page: PageID, region: Rect, scale: Double, hiddenLayers: Set<Int>) async throws -> CGImage {
        renders.append((page, region, scale))
        return FakeRenderer.blank(CGSize(width: 2, height: 2))
    }

    func snapshot(maxPixelWidth: CGFloat) -> CGImage? {
        snapshots += 1
        return mirrorImage
    }

    func stop() {}
}

/// Adds a text box to a page: a real commit for the live source to notice (test only).
struct TouchPage: NibCommand {
    struct Params: Codable { var page: String }
    static let descriptor = CommandDescriptor(
        id: "test.touchPage", title: "Touch Page", summary: "Add a text box to a page (tests only).",
        params: .obj(["page": .ref], required: ["page"]), examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard case let .page(doc, page)? = NodeRef(p.page) else { throw NibError.invalid("expected a page ref", path: "$.page") }
        _ = try ctx.mutate { tx in
            try tx.put(Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 10, w: 100, h: 30), text: RichText(plain: "Hi"))),
                       doc: doc, page: page)
        }
        return NoResult()
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

        _ = try await h.run("present.setMode", ["mode": "presenter", "blank": true], as: .ai("chat"))
        XCTAssertEqual(controller.mode, .presenter)
        XCTAssertTrue(controller.blank)
        _ = try await h.run("present.setMode", ["mode": "presenter"])
        XCTAssertFalse(controller.blank, "choosing a mode shows the page again")

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
}
