import XCTest
import NibContracts
import NibTesting
@testable import NibTemplates

@MainActor
final class NibTemplatesTests: XCTestCase {
    // MARK: Helpers

    private func harness() -> Harness { Harness(features: [NibTemplatesFeature.self]) }

    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(text) }

    private func page(_ h: Harness, _ id: PageID, in doc: DocumentID = Fixtures.docID) throws -> PageRecord {
        try XCTUnwrap(h.app.workspace.content(doc).page(id))
    }

    private func assertFails(_ h: Harness, _ command: String, _ params: String, _ code: NibError.Code,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await h.run(command, json(params))
            XCTFail("\(command) \(params) should fail with \(code.rawValue)", file: file, line: line)
        } catch let e as NibError {
            XCTAssertEqual(e.code, code, e.description, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    /// Where an op actually paints (mirrors `DisplayList.draw` in NibContracts/UI/Drawing.swift), stroke width aside.
    static func extent(_ op: DisplayOp) -> Rect? {
        switch op.op {
        case .line, .polyline, .polygon:
            return Rect.bounding(op.points ?? [])
        case .dots:
            guard let r = op.rect, let s = op.spacing, let radius = op.radius else { return nil }
            let nx = (r.width / s).rounded(.down), ny = (r.height / s).rounded(.down)
            guard nx >= 1, ny >= 1 else { return nil }
            return Rect(x: r.minX + s - radius, y: r.minY + s - radius,
                        width: (nx - 1) * s + 2 * radius, height: (ny - 1) * s + 2 * radius)
        default:
            return op.rect
        }
    }

    // MARK: Feature and conformance

    func testFeatureID() { XCTAssertEqual(NibTemplatesFeature.id, "templates") }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [NibTemplatesFeature.self])
        XCTAssertEqual(problems, [])
    }

    // MARK: Templates

    func testEveryTemplateRendersInsideThePageAtA4AndStandardInBothOrientations() {
        let h = Harness(features: [NibTemplatesFeature.self], fixtures: false)
        let templates = h.app.content.templates.all.filter { $0.owner == NibTemplatesFeature.id }
        XCTAssertGreaterThanOrEqual(templates.filter { !$0.isCover }.count, 20)
        XCTAssertEqual(templates.filter { $0.isCover }.count, 8)
        let sizes: [PageSize] = [.a4, PageSize.a4.rotated, .standard, .standardLandscape]
        let scales: [Double] = [0.25, 1, 2, 3, 8, 24]
        for t in templates {
            for size in sizes {
                let bounds = Rect(x: 0, y: 0, width: size.width, height: size.height).insetBy(-0.01)
                for scale in scales {
                    let render = t.render(t.defaults, size, scale)
                    if t.id != "builtin.blank" {
                        XCTAssertFalse(render.display.ops.isEmpty, "\(t.id) draws nothing at \(size) × \(scale)")
                    }
                    for op in render.display.ops {
                        guard let e = Self.extent(op) else { continue }
                        XCTAssertTrue(bounds.contains(e), "\(t.id) at \(size) × \(scale): \(op.op) \(e) leaves the page")
                    }
                }
            }
        }
    }

    func testRulesStayHairlinesAndParamsReachTheRender() {
        let wide = PaperTemplates.ruledWide.render(["spacing": 30, "paper": "#203040"], .a4, 2)
        XCTAssertEqual(wide.paper, RGBA(0x20, 0x30, 0x40))
        let rules = wide.display.ops.first { $0.op == .hlines }
        XCTAssertEqual(rules?.spacing, 30)
        XCTAssertEqual(rules?.width, 0.5)
        // Zoomed to 16 px per point a rule is still one pixel.
        let zoomed = PaperTemplates.ruledWide.render([:], .a4, 16).display.ops.first { $0.op == .hlines }
        XCTAssertEqual(zoomed?.width ?? 0, 1.0 / 16, accuracy: 1e-12)
        // College ruled draws its 25 mm margin line in the paper's margin colour.
        let college = PaperTemplates.ruledCollege.render([:], .a4, 2).display.ops
        let marginColour = TemplatePalette.rgba(0xEDB9B3)
        let marginLine = college.first { $0.op == .line && $0.stroke == marginColour }
        XCTAssertEqual(marginLine?.points?.first?.x ?? 0, 25 * mm, accuracy: 1e-9)
    }

    func testPaperColoursAndDerivedLines() {
        XCTAssertEqual(TemplatePalette.parse(.string("Yellow")), RGBA.paperYellow)
        XCTAssertEqual(TemplatePalette.parse(.string("dark")), RGBA.paperDark)
        XCTAssertEqual(TemplatePalette.parse(.string("#123456")), RGBA(0x12, 0x34, 0x56))
        XCTAssertEqual(TemplatePalette.parse(.string("navy")), TemplatePalette.rgba(0x23324F))
        XCTAssertNil(TemplatePalette.parse(.string("blurple")))
        XCTAssertEqual(PaperStyle(["paper": "white"]).line, TemplatePalette.rgba(0xCFDBE8))
        XCTAssertEqual(PaperStyle(["paper": "white", "line": "#FF0000"]).line, RGBA(0xFF, 0, 0))
        // Any colour gets a readable rule: lifted on dark paper, darker on light paper.
        let dark = PaperStyle(["paper": "#203040"])
        XCTAssertGreaterThan(TemplatePalette.luminance(dark.line), TemplatePalette.luminance(dark.paper))
        let light = PaperStyle(["paper": "#F0E0FF"])
        XCTAssertLessThan(TemplatePalette.luminance(light.line), TemplatePalette.luminance(light.paper))
    }

    func testWhiteboardDensityCrossFadesWithZoom() throws {
        XCTAssertEqual(WhiteboardGrids.level(base: 20, scale: 2).spacing, 20, accuracy: 1e-9)
        XCTAssertEqual(WhiteboardGrids.level(base: 20, scale: 2).fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(WhiteboardGrids.level(base: 20, scale: 4).spacing, 10, accuracy: 1e-9)
        XCTAssertEqual(WhiteboardGrids.level(base: 20, scale: 1).spacing, 40, accuracy: 1e-9)
        let halfway = WhiteboardGrids.level(base: 20, scale: 2 * 2.0.squareRoot())
        XCTAssertEqual(halfway.spacing, 20, accuracy: 1e-9)
        XCTAssertEqual(halfway.fraction, 0.5, accuracy: 1e-9)

        // At a whole zoom level: the main dots and the every-4th major dots only.
        let atLevel = WhiteboardGrids.dots.render([:], .a4, 2).display.ops
        XCTAssertEqual(atLevel.map { $0.spacing }, [20, 80])
        // Halfway to the next level the finer layer is at half strength.
        let mid = WhiteboardGrids.dots.render([:], .a4, 2 * 2.0.squareRoot()).display.ops
        let fine = try XCTUnwrap(mid.first { $0.spacing == 10 })
        let fineAlpha = try XCTUnwrap(fine.fill).a
        XCTAssertEqual(Double(fineAlpha), 127.5, accuracy: 1)
        // Just below the next level the finer layer is almost opaque and becomes the main layer of that level.
        let before = WhiteboardGrids.dots.render([:], .a4, 3.999).display.ops.first { $0.spacing == 10 }
        let after = WhiteboardGrids.dots.render([:], .a4, 4).display.ops.first { $0.spacing == 10 }
        XCTAssertGreaterThan(Double(before?.fill?.a ?? 0), 250)
        XCTAssertEqual(after?.fill?.a, 255)
    }

    func testMonthlyPlannerLaysOutTheMonth() {
        XCTAssertEqual(PlannerCalendar.layout(month: 2, year: 2024, startMonday: true)?.days, 29)
        XCTAssertEqual(PlannerCalendar.layout(month: 2, year: 2024, startMonday: true)?.offset, 3)   // Thursday
        XCTAssertEqual(PlannerCalendar.layout(month: 2, year: 2024, startMonday: false)?.offset, 4)
        XCTAssertNil(PlannerCalendar.layout(month: 0, year: 2024, startMonday: true))

        func dayNumbers(_ params: [String: JSONValue]) -> [Int] {
            PlannerTemplates.monthly.render(params, .a4, 2).display.ops
                .filter { $0.op == .text }.compactMap { Int($0.text ?? "") }
        }
        XCTAssertEqual(dayNumbers(["month": 2, "year": 2024]), Array(1...29))
        XCTAssertEqual(dayNumbers(["month": 12, "year": 2026]), Array(1...31))
        XCTAssertEqual(dayNumbers(["month": 0]), [])
    }

    // MARK: Commands

    func testTemplateListFiltersAndFitsTheAIBudget() async throws {
        let h = harness()
        let all = try await h.run("template.list")
        let templates = all["templates"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(templates.filter { $0["isCover"] == .bool(false) }.count, 20)
        XCTAssertEqual(templates.filter { $0["isCover"] == .bool(true) }.count, 8)
        XCTAssertEqual(all["sizes"]?.arrayValue?.count, PageSize.presets.count)
        XCTAssertLessThan(all.jsonString().utf8.count, NibLimits.aiToolResultBytes)

        let covers = try await h.run("template.list", ["covers": true])
        XCTAssertEqual(covers["templates"]?.arrayValue?.count, 8)
        let planners = try await h.run("template.list", ["category": "planners"], as: .ai("test"))
        let plannerCategories = planners["templates"]?.arrayValue?.compactMap { $0["category"]?.stringValue } ?? []
        XCTAssertFalse(plannerCategories.isEmpty)
        XCTAssertTrue(plannerCategories.allSatisfy { $0 == "Planners" })
    }

    func testSetTemplateResizesKeepsItemsWarnsAndUndoes() async throws {
        let h = harness()
        let before = try h.snapshot()
        let r = try await h.run("page.setTemplate", json(
            #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "builtin.grid", "params": {"paper": "yellow", "spacing": 20}, "size": "A5"}"#))
        let p = try page(h, Fixtures.page1)
        XCTAssertEqual(p.size, PageSize.a5)
        XCTAssertEqual(p.background.template?.id, "builtin.grid")
        XCTAssertEqual(p.background.template?.params["paper"], .string(RGBA.paperYellow.hex))
        XCTAssertEqual(p.background.template?.params["spacing"], .number(20))
        let outside = r["outside"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertTrue(outside.contains("item:FIXTUREDOC01/FIXTUREPG001/FIXTURECUS01"))   // y 700 on a 595 pt page
        XCTAssertTrue(outside.contains("item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTY01"))   // x 400–540 on a 419 pt page
        XCTAssertFalse(outside.contains("item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"))
        XCTAssertNotNil(r["warning"]?.stringValue)
        XCTAssertEqual(r["outsideCount"]?.intValue, outside.count)
        XCTAssertEqual(r["count"]?.intValue, 1)
        XCTAssertNil(r["truncated"])
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page1).count, 10)

        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertEqual(try page(h, Fixtures.page1).size, PageSize.a5)
        // Growing a page cannot push anything outside, so nothing is checked.
        let grown = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "builtin.grid", "size": "A3"}"#))
        XCTAssertEqual(grown["outside"]?.arrayValue ?? [], [])
        XCTAssertEqual(grown["outsideCount"]?.intValue, 0)
        XCTAssertNil(grown["warning"]?.stringValue)
    }

    func testSizesAndOrientation() async throws {
        let h = harness()
        let items = try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2)
        _ = try await h.run("page.setTemplate", json(
            #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.dots", "size": "Standard", "landscape": true}"#))
        XCTAssertEqual(try page(h, Fixtures.page2).size, PageSize.standardLandscape)
        _ = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.dots", "landscape": false}"#))
        XCTAssertEqual(try page(h, Fixtures.page2).size, PageSize.standard)
        _ = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.dots", "size": [500, 300]}"#))
        XCTAssertEqual(try page(h, Fixtures.page2).size, PageSize(500, 300))
        // Page 2 is not on screen: the shrink check drops it from the item cache again; it reloads unchanged.
        XCTAssertEqual(try h.app.workspace.items(Fixtures.docID, page: Fixtures.page2), items)

        XCTAssertEqual(TemplateCommands.oriented(.a4, landscape: true), PageSize.a4.rotated)
        XCTAssertEqual(TemplateCommands.oriented(.square, landscape: true), PageSize.square)
        XCTAssertEqual(try TemplateCommands.pageSize(.string("letter")), PageSize.letter)
        XCTAssertEqual(try TemplateCommands.pageSize(.string("600x800")), PageSize(600, 800))
        XCTAssertEqual(try TemplateCommands.pageSize(["width": 400, "height": 500]), PageSize(400, 500))
        XCTAssertThrowsError(try TemplateCommands.pageSize(.string("huge")))
        XCTAssertThrowsError(try TemplateCommands.pageSize([10, 10]))
    }

    func testCoversGoOnPageOneAndAllPagesLeavesTheCoverAlone() async throws {
        let h = harness()
        await assertFails(h, "page.setTemplate", #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "cover.solid"}"#,
                          .invalidParams)

        _ = try await h.run("page.setTemplate", json(#"{"pages": ["doc:FIXTUREDOC01"], "template": "cover.kraft", "params": {"color": "navy"}}"#))
        XCTAssertEqual(try page(h, Fixtures.page1).background.template?.id, "cover.kraft")
        XCTAssertEqual(try page(h, Fixtures.page1).background.template?.params["color"], .string(TemplatePalette.rgba(0x23324F).hex))
        XCTAssertEqual(try page(h, Fixtures.page2).background.template?.id, "builtin.ruled")

        let r = try await h.run("page.setTemplate", json(#"{"pages": ["doc:FIXTUREDOC01"], "template": "builtin.grid"}"#))
        XCTAssertEqual(r["pages"]?.arrayValue?.count, 2)
        XCTAssertEqual(r["count"]?.intValue, 2)
        XCTAssertEqual(try page(h, Fixtures.page1).background.template?.id, "cover.kraft")
        XCTAssertEqual(try page(h, Fixtures.page2).background.template?.id, "builtin.grid")
        XCTAssertEqual(try page(h, Fixtures.pdfPage).background.template?.id, "builtin.grid")
        // "Add Page › Current template" follows a change applied to every page.
        XCTAssertEqual(try h.app.workspace.content(Fixtures.docID).meta.defaultTemplate?.id, "builtin.grid")

        // Turning the cover back into paper clears the document's cover flag, in the same undo step.
        _ = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "template": "builtin.ruled"}"#))
        XCTAssertFalse(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertEqual(try page(h, Fixtures.page1).background.template?.id, "cover.kraft")

        // page.setBackground with a paper template clears the flag too; a flat colour may be a custom cover and keeps it.
        _ = try await h.run("page.setBackground", json(
            #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "background": {"kind": "template", "template": {"id": "builtin.ruled"}}}"#))
        XCTAssertFalse(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        _ = try await h.run("page.setBackground", json(##"{"pages": ["page:FIXTUREDOC01/FIXTUREPG001"], "background": {"kind": "color", "color": "#FDF6DC"}}"##))
        XCTAssertTrue(try h.app.workspace.content(Fixtures.docID).meta.coverEnabled)
    }

    func testParamsCarryOverAndDatedTemplatesAreStamped() async throws {
        let h = harness()
        _ = try await h.run("page.setTemplate", json(
            #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.ruled", "params": {"paper": "dark", "spacing": 30}}"#))
        var p = try page(h, Fixtures.page2)
        XCTAssertEqual(p.zoomReturnHeight ?? 0, 30, accuracy: 1e-9)

        _ = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.plannerMonthly"}"#))
        p = try page(h, Fixtures.page2)
        let params = p.background.template?.params ?? [:]
        XCTAssertEqual(params["paper"], .string(RGBA.paperDark.hex))   // the paper colour follows the page
        XCTAssertNil(params["spacing"])
        XCTAssertNil(p.zoomReturnHeight)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let now = gregorian.dateComponents([.year, .month], from: Date())
        XCTAssertEqual(params["month"]?.intValue, now.month)
        XCTAssertEqual(params["year"]?.intValue, now.year)
        // A Buddhist device calendar (th_TH default, year 2569) still stamps the Gregorian month the planner draws.
        var stamped: [String: JSONValue] = [:]
        TemplateCommands.stampDates(&stamped, def: PlannerTemplates.monthly, now: Date(timeIntervalSince1970: 1_789_473_600),
                                    device: Calendar(identifier: .buddhist))   // 2026-09-15 12:00 UTC
        XCTAssertEqual(stamped["year"]?.intValue, 2026)
        XCTAssertEqual(stamped["month"]?.intValue, 9)

        // null resets a param to its default.
        _ = try await h.run("page.setTemplate", json(#"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.plannerMonthly", "params": {"paper": null}}"#))
        XCTAssertNil(try page(h, Fixtures.page2).background.template?.params["paper"])
    }

    func testBoardsStayInfinite() async throws {
        let h = harness()
        _ = try await h.run("page.setTemplate", json(
            #"{"pages": ["page:FIXTUREDOC04/FIXTUREBRD01"], "template": "builtin.whiteboardGrid", "params": {"paper": "dark"}}"#))
        let board = try page(h, Fixtures.boardID, in: Fixtures.whiteboardID)
        XCTAssertNil(board.size)
        XCTAssertEqual(board.background.template?.id, "builtin.whiteboardGrid")
        await assertFails(h, "page.setTemplate",
                          #"{"pages": ["page:FIXTUREDOC04/FIXTUREBRD01"], "template": "builtin.grid", "size": "A4"}"#, .invalidParams)
        await assertFails(h, "page.setTemplate",
                          #"{"pages": ["page:FIXTUREDOC04/FIXTUREBRD01"], "template": "cover.solid"}"#, .invalidParams)
    }

    func testSetBackgroundAppliesAndValidates() async throws {
        let h = harness()
        _ = try await h.run("page.setBackground", json(##"{"pages": ["doc:FIXTUREDOC01"], "background": {"kind": "color", "color": "#FDF6DC"}}"##))
        for id in [Fixtures.page1, Fixtures.page2, Fixtures.pdfPage] {
            XCTAssertEqual(try page(h, id).background, Background.ofColor(RGBA.paperYellow))
        }
        _ = try await h.run("page.setBackground", json(
            #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "pdf", "asset": "fixture-page.pdf", "template": {"id": "builtin.grid"}}}"#))
        XCTAssertEqual(try page(h, Fixtures.page2).background, Background.ofPDF(Fixtures.pdfAsset, page: 0))

        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "image", "asset": "missing.png"}}"#, .notFound)
        // Asset names are plain file names: no path into another document.
        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "image", "asset": "../FIXTUREDOC02/assets/fixture-image.png"}}"#, .invalidParams)
        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "pdf", "asset": ".hidden.pdf"}}"#, .invalidParams)
        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "pdf"}}"#, .invalidParams)
        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "template", "template": {"id": "builtin.nope"}}}"#, .notFound)
        await assertFails(h, "page.setBackground",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "background": {"kind": "template", "template": {"id": "builtin.grid", "params": {"colour": "red"}}}}"#, .invalidParams)
        await assertFails(h, "page.setTemplate",
                          #"{"pages": ["page:FIXTUREDOC01/FIXTUREPG002"], "template": "builtin.grid", "params": {"paper": "blurple"}}"#, .invalidParams)
        await assertFails(h, "page.setTemplate",
                          #"{"pages": ["page:FIXTUREDOC01/NOSUCHPAGE01"], "template": "builtin.grid"}"#, .notFound)
        await assertFails(h, "page.setTemplate", #"{"pages": ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESTK01"], "template": "builtin.grid"}"#,
                          .invalidParams)
    }
}
