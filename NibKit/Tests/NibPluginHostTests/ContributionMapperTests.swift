import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting
@testable import NibPluginHost

@MainActor
final class ContributionMapperTests: XCTestCase {
    static let pid = "dev.test.all"

    /// A manifest that uses every contribution point once.
    static func fixture() throws -> JSONValue {
        try JSONValue.parse(#"""
        {"id": "dev.test.all", "name": "Everything", "version": "1.2.0", "api": 1, "entry": "main.js",
         "permissions": ["document:read", "document:write", "library:write", "app"],
         "contributes": {
          "commands": [
           {"id": "dev.test.all.run", "title": "Run", "summary": "Run it.", "effect": "edit",
            "params": {"type": "object", "properties": {"n": {"type": "integer", "minimum": 1, "default": 1}}}, "examples": [{"n": 2}]},
           {"id": "dev.test.all.guard", "title": "Guard", "summary": "A hook.", "effect": "read", "target": "app"},
           {"id": "dev.test.all.tool", "title": "Tool", "summary": "Tool input.", "effect": "edit"},
           {"id": "dev.test.all.edit", "title": "Edit Chart", "summary": "Edit a chart.", "effect": "edit"},
           {"id": "dev.test.all.importDeck", "title": "Import Deck", "summary": "Import a deck.", "effect": "library", "target": "library"},
           {"id": "dev.test.all.exportDeck", "title": "Export Deck", "summary": "Export a deck.", "effect": "read"},
           {"id": "dev.test.all.block", "title": "Poll", "summary": "Insert or edit a poll block.", "effect": "edit"},
           {"id": "dev.test.all.process", "title": "Smooth", "summary": "Smooth strokes.", "effect": "read"}
          ],
          "menus": [{"location": "objectMenu", "command": "dev.test.all.run", "icon": "star", "when": {"minSelection": 1, "selectionKinds": ["stroke"]}}],
          "toolbar": [{"id": "dev.test.all.button", "title": "Run", "icon": "star", "command": "dev.test.all.run"},
                      {"id": "dev.test.all.toolButton", "title": "Lasso Tool", "icon": "lasso", "tool": "dev.test.all.lasso"}],
          "tools": [{"id": "dev.test.all.lasso", "title": "Lasso Tool", "input": "stroke", "preview": "lasso", "sticky": false,
                     "command": "dev.test.all.tool"}],
          "toolOptions": [{"tool": "dev.test.all.lasso", "settings": ["size"]}],
          "panels": [{"id": "dev.test.all.panel", "title": "Stats", "icon": "chart.bar", "entry": "panels/stats.html", "placement": "sidebarTab"}],
          "templates": [
           {"id": "dev.test.all.planner", "title": "Planner", "category": "Planners", "kind": "spec", "size": {"width": 100, "height": 200},
            "params": {"accent": {"type": "color", "default": "#FF0000FF"}, "gap": {"type": "number", "default": 20}},
            "spec": {"paper": "#FFFFF0FF", "ops": [{"op": "rect", "rect": [10, 10, 50, 20], "fill": "$accent"},
                                                  {"op": "hlines", "rect": [0, 40, 100, 160], "spacing": "$gap", "stroke": "#000000FF"}]}},
           {"id": "dev.test.all.cover", "title": "Cover", "kind": "spec", "isCover": true, "spec": {"ops": []}}
          ],
          "keybindings": [{"key": "cmd+shift+r", "command": "dev.test.all.run"}],
          "settings": {"type": "object", "properties": {
            "size": {"type": "number", "minimum": 1, "maximum": 10, "default": 3, "title": "Size"},
            "mode": {"type": "string", "enum": ["fast", "exact"], "default": "fast"}}},
          "aiActions": [{"title": "Quiz me", "prompt": "Make a quiz.", "scope": "page", "mode": "ask", "icon": "questionmark.bubble"}],
          "ai": {"instructions": "Prefer dev.test.all.run for charts."},
          "importers": [{"extensions": ["DECK"], "command": "dev.test.all.importDeck", "title": "Deck"}],
          "exporters": [{"extensions": ["deck"], "command": "dev.test.all.exportDeck"}],
          "itemTypes": [{"type": "chart", "title": "Chart", "edit": "dev.test.all.edit", "textPath": "title",
                         "inspector": {"type": "object", "properties": {"title": {"type": "string"}}}}],
          "tapHandlers": [{"gesture": "longPress", "command": "dev.test.all.run", "itemTypes": ["chart"]}],
          "blocks": [{"type": "poll", "title": "Poll", "icon": "chart.bar", "height": 90, "command": "dev.test.all.block", "aliases": ["vote"]}],
          "strokeProcessors": [{"id": "dev.test.all.smooth", "command": "dev.test.all.process"}],
          "pencilActions": [{"gesture": "squeeze", "command": "dev.test.all.run", "title": "Run"}],
          "commandHooks": [{"commands": ["test.*"], "command": "dev.test.all.guard"}],
          "elements": [{"id": "dev.test.all.arrows", "title": "Arrows", "files": ["elements/arrows.json", "elements/more.json"]}],
          "tapePatterns": [{"id": "dev.test.all.stripes", "title": "Stripes", "file": "tape/stripes.png"}],
          "boardTemplates": [{"id": "dev.test.all.retro", "title": "Retro", "diagram": {"nodes": [{"id": "a", "text": "Start"}], "edges": [], "layout": "tree"}},
                             {"id": "dev.test.all.frame", "title": "Frame", "file": "boards/frame.json"}]
         }}
        """#)
    }

    static func fixtureFiles() -> [String: Data] {
        let fragment = #"{"format": "nib-fragment/1", "title": "Right arrow", "items": [], "assets": {}, "bounds": [0, 0, 10, 10]}"#
        let list = #"[{"id": "up", "title": "Up", "fragment": {"format": "nib-fragment/1", "items": []}}]"#
        return ["panels/stats.html": Data("<p>stats</p>".utf8), "elements/arrows.json": Data(fragment.utf8),
                "elements/more.json": Data(list.utf8), "tape/stripes.png": Fixtures.pngData,
                "boards/frame.json": Data(#"{"format": "nib-fragment/1", "items": []}"#.utf8)]
    }

    /// Entries owned by `owner` in every registry the host maps into.
    static func owned(_ app: NibApp, _ owner: String) -> [String: Int] {
        func n<D: Registrable>(_ r: Registry<D>) -> Int { r.all.filter { $0.owner == owner }.count }
        let ui = app.ui
        let c = app.content
        let counts: [String: Int] = [
            "commands": app.commands.all().filter { $0.owner == owner }.count,
            "menus": n(ui.menus), "toolbar": n(ui.toolbar), "canvasTools": n(ui.canvasTools), "toolMenus": n(ui.toolMenus),
            "panels": n(ui.panels), "settingsPages": n(ui.settingsPages), "inspectors": n(ui.inspectors),
            "blockViews": n(ui.blockViews), "templates": n(c.templates), "keyCommands": n(c.keyCommands),
            "aiActions": n(c.aiActions), "importers": n(c.importers), "exporters": n(c.exporters),
            "customItemTypes": n(c.customItemTypes), "tapHandlers": n(c.tapHandlers), "blockKinds": n(c.blockKinds),
            "strokeProcessors": n(c.strokeProcessors), "pencilActions": n(c.pencilActions),
            "elementCollections": n(c.elementCollections), "tapePatterns": n(c.tapePatterns),
            "boardTemplates": n(c.boardTemplates), "hooks": n(app.bus.hooks)
        ]
        return counts.filter { $0.value > 0 }
    }

    // MARK: Acceptance: every registry, then a clean unregister

    func testFixtureManifestMapsIntoEveryRegistryAndUnregistersCleanly() async throws {
        let kit = PluginTestKit()
        let pid = Self.pid
        try await kit.installAndLoad(try Self.fixture(), files: Self.fixtureFiles())
        XCTAssertEqual(kit.host.state(pid), .running)
        let app = kit.h.app

        XCTAssertEqual(Self.owned(app, pid), [
            "commands": 8, "menus": 1, "toolbar": 2, "canvasTools": 1, "toolMenus": 1, "panels": 1, "settingsPages": 1,
            "inspectors": 1, "blockViews": 1, "templates": 2, "keyCommands": 1, "aiActions": 1, "importers": 1,
            "exporters": 1, "customItemTypes": 1, "tapHandlers": 2, "blockKinds": 1, "strokeProcessors": 1,
            "pencilActions": 1, "elementCollections": 1, "tapePatterns": 1, "boardTemplates": 2, "hooks": 1
        ])

        // Commands: descriptor from the manifest, schema enforced for non-user callers.
        let run = try XCTUnwrap(app.commands.descriptor("\(pid).run"))
        XCTAssertEqual(run.effect, .edit)
        XCTAssertEqual(run.scopes, [.documentWrite])
        XCTAssertEqual(run.examples, [["n": 2]])
        XCTAssertEqual(app.commands.descriptor("\(pid).importDeck")?.scopes, [.libraryWrite])
        XCTAssertEqual(run.params.validate(["n": 0]).first?.path, "$.n")
        XCTAssertEqual(run.params.validate(["n": 3]), [])

        // Menus, toolbar, tools, options bar, panels.
        let menu = try XCTUnwrap(app.ui.menus.all.first { $0.owner == pid })
        XCTAssertEqual(menu.location, .objectMenu)
        XCTAssertEqual(menu.title, "Run")
        XCTAssertEqual(menu.command, "\(pid).run")
        let strokeSelection = MenuContext(app: app, session: kit.h.session, doc: Fixtures.docID, page: Fixtures.page1,
                                          selection: Selection(doc: Fixtures.docID, page: Fixtures.page1, items: [Fixtures.strokeID]),
                                          itemKinds: [.stroke])
        XCTAssertTrue(menu.isVisible(strokeSelection))
        XCTAssertFalse(menu.isVisible(MenuContext(app: app, session: kit.h.session, doc: Fixtures.docID, page: Fixtures.page1)))
        XCTAssertEqual(menu.params(strokeSelection)["selection"], [.string(NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.strokeID).description)])
        let button = try XCTUnwrap(app.ui.toolbar.get("\(pid).button"))
        XCTAssertEqual(button.command, "\(pid).run")
        XCTAssertEqual(button.group, .accessories)
        XCTAssertEqual(button.resolvedParams(for: kit.h.session)["page"], .string(NodeRef.page(Fixtures.docID, Fixtures.page1).description))
        let toolButton = try XCTUnwrap(app.ui.toolbar.get("\(pid).toolButton"))
        XCTAssertEqual(toolButton.toolID, "\(pid).lasso")
        XCTAssertEqual(toolButton.group, .tools)
        let tool = try XCTUnwrap(app.ui.canvasTools.get("\(pid).lasso")?.make() as? PluginCanvasTool)
        XCTAssertEqual(tool.spec.input, .stroke)
        XCTAssertEqual(tool.spec.preview, .lasso)
        XCTAssertFalse(tool.isSticky)
        XCTAssertEqual(tool.inputMode, .samples)
        XCTAssertNotNil(app.ui.toolMenus.get("\(pid).lasso"))
        let panel = try XCTUnwrap(app.ui.panels.get("\(pid).panel"))
        XCTAssertTrue(panel.providesHeader, "F081 draws the plugin panel chrome")
        XCTAssertEqual(panel.placement, .sidebarTab)

        // Templates: $param substitution into the DisplayList, scaled from the design size; covers.
        let planner = try XCTUnwrap(app.content.templates.get("\(pid).planner"))
        XCTAssertEqual(planner.category, "Planners")
        XCTAssertEqual(planner.params.map { $0.name }, ["accent", "gap"])
        XCTAssertEqual(planner.defaults["accent"], "#FF0000FF")
        let drawn = planner.render(["accent": "#00FF00FF"], PageSize(200, 400), 2)
        XCTAssertEqual(drawn.paper, RGBA(hex: "#FFFFF0FF"))
        XCTAssertEqual(drawn.display.ops.first?.fill, RGBA(0, 255, 0))
        XCTAssertEqual(drawn.display.ops.first?.rect, Rect(x: 20, y: 20, width: 100, height: 40))
        XCTAssertEqual(drawn.display.ops.last?.spacing, 40, "hline spacing follows the vertical scale")
        XCTAssertEqual(app.content.templates.get("\(pid).cover")?.isCover, true)

        // Key binding, settings, AI.
        let key = try XCTUnwrap(app.content.keyCommands.all.first { $0.owner == pid })
        XCTAssertEqual(key.shortcut, KeyShortcut("r", [.command, .shift]))
        XCTAssertEqual(key.scope, .document)
        XCTAssertEqual(app.settings.descriptor("plugin.\(pid).size")?.synced, true)
        XCTAssertEqual(app.settings.descriptor("plugin.\(pid).anything")?.owner, pid, "the plugin.<id>. prefix is declared")
        XCTAssertFalse(app.settings.descriptor("plugin.\(pid).size")!.schema.validate(.number(11)).isEmpty)
        XCTAssertEqual(app.ui.settingsPages.get("\(pid).settings")?.section, .plugins)
        let action = try XCTUnwrap(app.content.aiActions.all.first { $0.owner == pid })
        XCTAssertEqual(action.scope, .page)
        XCTAssertEqual(action.mode, .ask)
        XCTAssertEqual(kit.host.aiInstructions, ["Prefer dev.test.all.run for charts."])

        // Files, item types, taps, blocks, processors, Pencil, hooks.
        XCTAssertEqual(app.content.importer(forExtension: "deck")?.owner, pid)
        XCTAssertEqual(app.content.exporters.all.first { $0.owner == pid }?.fileExtension, "deck")
        let chart = try XCTUnwrap(app.content.customItemTypes.get("custom.\(pid).chart"))
        XCTAssertEqual(chart.textPath, "title")
        XCTAssertEqual(chart.editCommand, "\(pid).edit")
        let taps = app.content.tapHandlers.all.filter { $0.owner == pid }
        XCTAssertEqual(Set(taps.map { $0.gesture }), [.doubleTap, .longPress])
        XCTAssertTrue(taps.allSatisfy { $0.drawKeys == ["custom.\(pid).chart"] && $0.itemKinds == [.custom] })
        XCTAssertEqual(app.ui.inspectors.all.first { $0.owner == pid }?.drawKeys, ["custom.\(pid).chart"])
        let block = try XCTUnwrap(app.content.blockKinds.all.first { $0.owner == pid })
        XCTAssertEqual(block.kind, .custom)
        XCTAssertEqual(block.customType, "\(pid).poll")
        XCTAssertEqual(block.command, "\(pid).block")
        XCTAssertEqual(block.aliases, ["vote"])
        XCTAssertNotNil(app.ui.blockViews.get("custom.\(pid).poll"))
        XCTAssertTrue(app.content.strokeProcessors.get("\(pid).smooth")?.processor is PluginStrokeRunner)
        XCTAssertEqual(app.content.pencilActions.all.first { $0.owner == pid }?.gestures, ["squeeze"])
        let hook = try XCTUnwrap(app.bus.hooks.all.first { $0.owner == pid })
        XCTAssertEqual(hook.principal, .plugin(pid))
        XCTAssertEqual(hook.command, "\(pid).guard")
        XCTAssertTrue(hook.matches("test.addText"))

        // Content packs load from the plugin folder.
        let elements = try XCTUnwrap(app.content.elementCollections.get("\(pid).arrows")).load()
        XCTAssertEqual(elements.map { $0.id }, ["arrows", "up"])
        XCTAssertEqual(elements.first?.title, "Right arrow")
        XCTAssertEqual(try app.content.tapePatterns.get("\(pid).stripes")?.load(), Fixtures.pngData)
        XCTAssertEqual(app.content.boardTemplates.get("\(pid).retro")?.spec["layout"], "tree")
        XCTAssertEqual(app.content.boardTemplates.get("\(pid).frame")?.spec["fragment"]?["format"], "nib-fragment/1")

        // Unload: nothing of the plugin is left anywhere; the runtime is stopped and holds no grant.
        kit.host.unload(pid)
        XCTAssertEqual(Self.owned(app, pid), [:])
        XCTAssertEqual(kit.host.aiInstructions, [])
        XCTAssertTrue(kit.runtime.handles[pid]?.stopped == true)
        XCTAssertEqual(app.gateway.grants(.plugin(pid)), [])
        XCTAssertEqual(kit.host.state(pid), .stopped)
        XCTAssertEqual(kit.host.installed.map { $0.id }, [pid], "unloading keeps it installed")

        // And it maps again on reload.
        try await kit.host.load(pid)
        XCTAssertEqual(Self.owned(app, pid).count, 23)
    }

    func testContributionsThatClashWithAnotherOwnerAreRefused() async throws {
        let kit = PluginTestKit()
        let pid = "dev.test.clash"
        kit.h.app.ui.panels.register(PanelDescriptor(id: "\(pid).panel", title: "Other", icon: "star", placement: .floating,
                                                     order: 0, owner: "someone") { _ in AnyView(EmptyView()) })
        do {
            try await kit.installAndLoad(kit.manifest(pid, contributes: [
                "commands": [kit.command("\(pid).go")],
                "panels": [["id": .string("\(pid).panel"), "title": "Mine", "entry": "main.js"]]
            ]))
            XCTFail("the panel id is taken")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .conflict)
        }
        XCTAssertEqual(Self.owned(kit.h.app, pid), [:])
        XCTAssertEqual(kit.host.state(pid), .failed)
        XCTAssertEqual(kit.h.app.ui.panels.get("\(pid).panel")?.owner, "someone")
    }

    // MARK: Validation

    func testManifestValidationReportsEveryProblemWithAPath() throws {
        let bad = try JSONValue.parse(#"""
        {"id": "Bad_Id", "name": "", "version": "one", "api": 2, "entry": "../main.js",
         "permissions": ["document:read", "security", "camera"],
         "network": {"hosts": ["https://example.com"]},
         "contributes": {
          "commands": [{"id": "other.cmd", "title": "X", "summary": "X."},
                       {"id": "Bad_Id.hook", "title": "Hook", "summary": "Hook.", "effect": "edit"},
                       {"id": "Bad_Id.p", "title": "P", "summary": "P.", "params": {"type": "object", "properties": {"n": {"type": "integer"}}},
                        "examples": [{"n": "x"}]}],
          "menus": [{"location": "sideways", "command": "Bad_Id.missing"}],
          "toolbar": [{"id": "Bad_Id.b", "title": "B", "icon": "star", "command": "Bad_Id.hook", "tool": "Bad_Id.t"}],
          "templates": [{"id": "Bad_Id.t", "title": "T", "kind": "spec", "spec": {"ops": [{"op": "wobble"}]}}],
          "keybindings": [{"key": "cmd+", "command": "Bad_Id.hook"}],
          "commandHooks": [{"commands": ["*"], "command": "Bad_Id.hook"}],
          "ai": {"instructions": "\#(String(repeating: "x", count: 1_001))"}
         }}
        """#)
        let manifest = try bad.decode(PluginManifest.self)
        let problems = ManifestValidator.problems(manifest, folder: nil)
        let paths = Set(problems.compactMap { $0.path })
        for expected in ["$.id", "$.name", "$.version", "$.api", "$.entry", "$.permissions[1]", "$.permissions[2]",
                         "$.network.hosts[0]", "$.contributes.commands[0].id", "$.contributes.commands[2].examples[0].n",
                         "$.contributes.menus[0].location", "$.contributes.menus[0].command", "$.contributes.toolbar[0]",
                         "$.contributes.templates[0].spec.ops[0]", "$.contributes.keybindings[0].key",
                         "$.contributes.commandHooks[0].commands[0]", "$.contributes.commandHooks[0].command",
                         "$.contributes.ai.instructions"] {
            XCTAssertTrue(paths.contains(expected), "expected a problem at \(expected); got \(paths.sorted())")
        }
        XCTAssertEqual(problems.first { $0.path == "$.permissions[1]" }?.code, .permissionDenied)
        XCTAssertEqual(problems.first { $0.path == "$.api" }?.code, .unsupported)
        XCTAssertThrowsError(try ManifestValidator.validate(manifest, folder: nil)) { error in
            XCTAssertTrue((error as? NibError)?.message.contains("more problems") == true)
        }

        let good = try Self.fixture().decode(PluginManifest.self)
        XCTAssertEqual(ManifestValidator.problems(good, folder: nil).map { $0.description }, [])
        // With the folder, missing files are reported.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nib-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = Set(ManifestValidator.problems(good, folder: empty).compactMap { $0.path })
        XCTAssertTrue(missing.contains("$.entry"))
        XCTAssertTrue(missing.contains("$.contributes.panels[0].entry"))
        XCTAssertTrue(missing.contains("$.contributes.tapePatterns[0].file"))
        XCTAssertThrowsError(try PluginPaths.resolve("../x", in: empty, path: "$"))
        XCTAssertThrowsError(try PluginPaths.resolve("/etc/hosts", in: empty, path: "$"))
    }

    func testSchemaConversionKeepsTypesBoundsAndDefaults() throws {
        let schema = SchemaConverter.schema(try JSONValue.parse(#"""
        {"type": "object", "required": ["page"], "properties": {
          "page": {"type": "string", "description": "a page ref"},
          "mode": {"type": ["string", "null"], "enum": ["a", "b"], "default": "a"},
          "count": {"type": "integer", "minimum": 1.5, "maximum": 9},
          "ratio": {"type": "number", "maximum": 1},
          "tags": {"type": "array", "items": {"type": "string"}},
          "extra": {"oneOf": [{"type": "string"}, {"type": "number"}]}}}
        """#))
        XCTAssertEqual(schema.validate(["page": "page:A/B", "mode": "b", "count": 2, "ratio": 0.5, "tags": ["x"], "extra": 3]), [])
        XCTAssertEqual(schema.validate([:]).first?.path, "$.page")
        XCTAssertEqual(schema.validate(["page": "p", "mode": "c"]).first?.path, "$.mode")
        XCTAssertEqual(schema.validate(["page": "p", "count": 1]).first?.path, "$.count", "minimum 1.5 rounds up to 2")
        XCTAssertEqual(schema.validate(["page": "p", "ratio": 2]).first?.path, "$.ratio")
        XCTAssertEqual(schema.validate(["page": "p", "tags": [1]]).first?.path, "$.tags[0]")
        let json = schema.toJSON()
        XCTAssertEqual(json["properties"]?["mode"]?["description"], "Default: \"a\".")
        XCTAssertEqual(json["properties"]?["page"]?["description"], "a page ref")
        XCTAssertTrue(SchemaConverter.isObjectSchema(["properties": [:]]))
        XCTAssertFalse(SchemaConverter.isObjectSchema(["type": "string"]))
    }

    func testSpecTemplatesSubstituteAndScaleOps() throws {
        let spec = try JSONValue.parse(#"""
        {"paper": "$paper", "ops": [{"op": "text", "rect": [0, 0, 50, 10], "text": "$title", "fontSize": 10},
                                    {"op": "line", "points": [[0, 0], [100, 100]], "stroke": "$line", "width": 2}]}
        """#)
        let t = SpecTemplate(spec: spec, designSize: PageSize(100, 100), defaults: ["paper": "#000000FF", "line": "#0000FFFF", "title": "Week"])
        let r = t.render(values: ["title": "Month"], size: PageSize(200, 100))
        XCTAssertEqual(r.paper, RGBA(0, 0, 0))
        XCTAssertEqual(r.display.ops[0].text, "Month")
        XCTAssertEqual(r.display.ops[0].rect, Rect(x: 0, y: 0, width: 100, height: 10))
        XCTAssertEqual(r.display.ops[0].fontSize, 10, "fonts scale by the smaller factor")
        XCTAssertEqual(r.display.ops[1].points, [Point(0, 0), Point(200, 100)])
        XCTAssertEqual(r.display.ops[1].stroke, RGBA(0, 0, 255))
        XCTAssertEqual(SpecTemplate.substitute(["a": "$missing", "b": "$", "c": ["$x"]], ["x": 1]), ["a": "$missing", "b": "$", "c": [1]])
        let cache = TemplateRenderCache()
        XCTAssertEqual(cache.render(t, values: [:], size: PageSize(100, 100)).display, cache.render(t, values: [:], size: PageSize(100, 100)).display)
        XCTAssertEqual(SpecTemplate.paramProblems(["a": ["type": "choice"]], path: "$.p").first?.path, "$.p.a.choices")
        XCTAssertEqual(SpecTemplate.paramProblems(["a": ["type": "shape"]], path: "$.p").first?.path, "$.p.a.type")
    }

    func testPDFTemplatesBecomeDisplayLists() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 100)).pdfData { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.red.cgColor)
            cg.fill(CGRect(x: 10, y: 10, width: 50, height: 20))
            cg.setStrokeColor(UIColor.blue.cgColor)
            cg.setLineWidth(2)
            cg.move(to: CGPoint(x: 0, y: 50))
            cg.addLine(to: CGPoint(x: 200, y: 50))
            cg.strokePath()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nib-template-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let text = [TextRecognition(text: "Week of", bbox: Rect(x: 20, y: 70, width: 60, height: 12), source: "pdf")]
        let page = try XCTUnwrap(PDFTemplateConverter.convert(url, text: text))
        XCTAssertEqual(page.size, PageSize(200, 100))
        let rect = try XCTUnwrap(page.ops.first { $0.op == .rect && $0.fill != nil })
        XCTAssertEqual(rect.fill, RGBA(255, 0, 0))
        XCTAssertEqual(rect.rect?.x ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(rect.rect?.y ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(rect.rect?.width ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(rect.rect?.height ?? -1, 20, accuracy: 0.01)
        let line = try XCTUnwrap(page.ops.first { $0.op == .line })
        XCTAssertEqual(line.stroke, RGBA(0, 0, 255))
        XCTAssertEqual(line.width ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(line.points?.first?.y ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(line.points?.last?.x ?? -1, 200, accuracy: 0.01)
        XCTAssertEqual(page.ops.last?.text, "Week of")
        XCTAssertNil(PDFTemplateConverter.convert(url.deletingLastPathComponent().appendingPathComponent("none.pdf"), text: nil))
        XCTAssertEqual(PDFTemplateConverter.axisAlignedRect([Point(0, 0), Point(4, 0), Point(4, 2), Point(0, 2), Point(0, 0)]),
                       Rect(x: 0, y: 0, width: 4, height: 2))
        XCTAssertNil(PDFTemplateConverter.axisAlignedRect([Point(0, 0), Point(4, 1), Point(4, 2), Point(0, 2)]))
    }

    func testKeyBindings() {
        XCTAssertEqual(KeyBindingParser.parse("cmd+shift+f"), KeyShortcut("f", [.command, .shift]))
        XCTAssertEqual(KeyBindingParser.parse("Alt+1"), KeyShortcut("1", [.option]))
        XCTAssertEqual(KeyBindingParser.parse("ctrl+option+left"), KeyShortcut("left", [.control, .option]))
        XCTAssertEqual(KeyBindingParser.parse("cmd++"), KeyShortcut("+", [.command]))
        XCTAssertEqual(KeyBindingParser.parse("esc"), KeyShortcut("escape"))
        XCTAssertNil(KeyBindingParser.parse("shift"))
        XCTAssertNil(KeyBindingParser.parse("cmd+ab"))
        XCTAssertNil(KeyBindingParser.parse("f+cmd"))
        XCTAssertNil(KeyBindingParser.parse(""))
        XCTAssertEqual(KeyBindingParser.scope(for: KeyShortcut("m"), target: .document), .canvas)
        XCTAssertEqual(KeyBindingParser.scope(for: KeyShortcut("m", [.command]), target: .library), .global)
        XCTAssertEqual(KeyBindingParser.scope(for: KeyShortcut("m", [.shift]), target: .app), .canvas)
    }

    func testMenuWhenAndContextParams() throws {
        let w = try JSONValue.parse(#"{"selectionKinds": ["stroke", "text"], "minSelection": 2, "docKinds": ["notebook"]}"#)
            .decode(PluginWhen.self)
        XCTAssertTrue(PluginWhenEvaluator.matches(w, selectionCount: 2, itemKinds: [.stroke], docKind: .notebook))
        XCTAssertTrue(PluginWhenEvaluator.matches(w, selectionCount: 3, itemKinds: [.stroke, .text], docKind: .notebook))
        XCTAssertFalse(PluginWhenEvaluator.matches(w, selectionCount: 1, itemKinds: [.stroke], docKind: .notebook))
        XCTAssertFalse(PluginWhenEvaluator.matches(w, selectionCount: 2, itemKinds: [.stroke, .image], docKind: .notebook))
        XCTAssertFalse(PluginWhenEvaluator.matches(w, selectionCount: 2, itemKinds: [.stroke], docKind: .whiteboard))
        XCTAssertFalse(PluginWhenEvaluator.matches(w, selectionCount: 2, itemKinds: [], docKind: .notebook))

        let h = Harness()
        let ctx = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID, page: Fixtures.page1, point: Point(10, 20),
                              nodes: [Fixtures.page2], ref: "block:FIXTUREDOC02/FIXTUREBLK01", index: 3,
                              folder: Fixtures.folderID, textRange: [1, 4])
        let params = MenuParams.build(ctx, location: .sidebarSelection)
        XCTAssertEqual(params["doc"], "doc:FIXTUREDOC01")
        XCTAssertEqual(params["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(params["point"], [10, 20])
        XCTAssertEqual(params["nodes"], ["page:FIXTUREDOC01/FIXTUREPG002"])
        XCTAssertEqual(params["ref"], "block:FIXTUREDOC02/FIXTUREBLK01")
        XCTAssertEqual(params["index"], 3)
        XCTAssertEqual(params["folder"], "folder:FIXTUREFLD01")
        XCTAssertEqual(params["range"], [1, 4])
        XCTAssertNil(params["selection"])
        let library = MenuParams.build(MenuContext(app: h.app, nodes: [Fixtures.docID, Fixtures.folderID]), location: .librarySelection)
        XCTAssertEqual(library["nodes"], ["doc:FIXTUREDOC01", "folder:FIXTUREFLD01"])
        XCTAssertEqual(PluginWhenEvaluator.documentKind(ctx), .notebook)
    }

    // MARK: Canvas tools and stroke processors

    func testToolGestureParams() {
        var g = ToolGesture(page: Fixtures.page1, start: Point(10, 10))
        g.add(Point(10.2, 10.1))
        g.add(Point(30, 40))
        XCTAssertEqual(g.points, [Point(10, 10), Point(30, 40)], "samples closer than half a point are dropped")
        let stroke = g.params(for: .stroke, doc: Fixtures.docID)
        XCTAssertEqual(stroke?["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        XCTAssertEqual(stroke?["fmt"], "xy")
        XCTAssertEqual(stroke?["pts"], [10, 10, 30, 40])
        XCTAssertEqual(stroke?["bbox"], [10, 10, 20, 30])
        var r = ToolGesture(page: Fixtures.page1, start: Point(50, 60))
        r.add(Point(20, 10))
        XCTAssertEqual(r.params(for: .rect, doc: Fixtures.docID)?["rect"], [20, 10, 30, 50])
        XCTAssertNil(ToolGesture(page: Fixtures.page1, start: Point(1, 1)).params(for: .rect, doc: Fixtures.docID))
        XCTAssertEqual(ToolGesture(page: Fixtures.page1, start: Point(5, 6)).params(for: .tap, doc: Fixtures.docID)?["point"], [5, 6])
        XCTAssertEqual(PluginToolPreview.resolve("none", input: .stroke), PluginToolPreview.none)
        XCTAssertEqual(PluginToolPreview.resolve(nil, input: .stroke), .ink)
        XCTAssertEqual(PluginToolPreview.resolve("ink", input: .rect), .rect)
    }

    func testCanvasToolRunsItsCommandOnceWithAPreview() async throws {
        let kit = PluginTestKit()
        let calls = CallRecorder()
        kit.standIn("dev.test.tool.apply", effect: .edit, recorder: calls)
        let host = FakeCanvasHost(kit.h)
        kit.h.session.selectTool("pen")
        kit.h.session.selectTool("dev.test.tool.t")
        let tool = PluginCanvasTool(PluginToolSpec(id: "dev.test.tool.t", pluginID: "dev.test.tool", command: "dev.test.tool.apply",
                                                   input: .stroke, preview: .ink, sticky: false))
        tool.activate(host)
        tool.touchesBegan(CanvasSample(page: Fixtures.page1, location: Point(10, 10)), host: host)
        tool.touchesMoved([CanvasSample(page: Fixtures.page1, location: Point(20, 10)),
                           CanvasSample(page: Fixtures.page1, location: Point(99, 99), isPredicted: true)], host: host)
        XCTAssertEqual(host.overlayLayer.sublayers?.count, 1, "the host draws the preview")
        tool.touchesEnded(CanvasSample(page: Fixtures.page1, location: Point(20, 30)), host: host)
        let ran = await eventually { calls.calls.count == 1 }
        XCTAssertTrue(ran)
        XCTAssertEqual(calls.calls.first?.params["pts"], [10, 10, 20, 10, 20, 30])
        XCTAssertEqual(calls.calls.first?.principal, .user)
        let cleared = await eventually { (host.overlayLayer.sublayers ?? []).isEmpty }
        XCTAssertTrue(cleared, "the preview goes once the result rendered")
        let returned = await eventually { kit.h.session.tool == "pen" }
        XCTAssertTrue(returned, "a non-sticky tool hands back after one use")

        let tap = PluginCanvasTool(PluginToolSpec(id: "dev.test.tool.tap", pluginID: "dev.test.tool", command: "dev.test.tool.apply",
                                                  input: .tap, preview: .none, sticky: true))
        XCTAssertEqual(tap.inputMode, .taps)
        tap.tap(CanvasSample(page: Fixtures.page2, location: Point(5, 5)), host: host)
        let tapped = await eventually { calls.calls.count == 2 }
        XCTAssertTrue(tapped)
        XCTAssertEqual(calls.calls.last?.params["point"], [5, 5])
        XCTAssertEqual(calls.calls.last?.params["page"], "page:FIXTUREDOC01/FIXTUREPG002")
    }

    func testStrokeProcessorsReplaceDropOrKeepTheStrokeWithinTheirBudget() async throws {
        let kit = PluginTestKit()
        kit.host.strokeProcessorBudget = 0.1
        let commits = CallRecorder()
        kit.standIn(CommandIDs.inkAddStrokes, effect: .edit, recorder: commits)
        var mode = "shift"
        kit.standIn("dev.test.ink.first", effect: .read) { params, _ in
            switch mode {
            case "drop": return ["drop": true]
            case "fail": throw NibError(.internalError, "boom")
            default:
                var stroke = try params["stroke"]!.decode(Stroke.self)
                stroke.points = stroke.points.map { var p = $0; p.x += 100; return p }
                return ["stroke": try JSONValue.from(stroke)]
            }
        }
        kit.h.app.commands.register(CommandDescriptor(id: "dev.test.ink.slow", title: "Slow", summary: "Slow.", effect: .read,
                                                      owner: "test")) { _, _ in
            try await Task.sleep(nanoseconds: 400_000_000)
            return ["drop": true]
        }
        let first = PluginStrokeRunner(app: kit.h.app, host: kit.host, pluginID: "dev.test.ink", id: "dev.test.ink.a",
                                          command: "dev.test.ink.first", tools: [.pen])
        let slow = PluginStrokeRunner(app: kit.h.app, host: kit.host, pluginID: "dev.test.ink", id: "dev.test.ink.b",
                                         command: "dev.test.ink.slow", tools: [.pen, .pencil])
        kit.h.app.content.strokeProcessors.register(StrokeProcessorEntry(id: "dev.test.ink.a", order: PluginStrokeRunner.order,
                                                                         owner: "dev.test.ink", processor: first))
        kit.h.app.content.strokeProcessors.register(StrokeProcessorEntry(id: "dev.test.ink.b", order: PluginStrokeRunner.order + 1,
                                                                         owner: "dev.test.ink", processor: slow))
        let raw = Stroke(style: .defaultPen, points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)])

        // The first plugin processor takes the stroke out of the synchronous chain and commits the result itself;
        // the slow one misses its budget, so the first one's change is kept.
        var stroke = raw
        XCTAssertFalse(first.process(&stroke, page: Fixtures.page1, session: kit.h.session))
        XCTAssertTrue(slow.process(&stroke, page: Fixtures.page1, session: kit.h.session), "only the first plugin processor acts")
        let committed = await eventually(3) { commits.calls.count == 1 }
        XCTAssertTrue(committed)
        let params = try XCTUnwrap(commits.calls.first?.params)
        XCTAssertEqual(params["page"], "page:FIXTUREDOC01/FIXTUREPG001")
        let out = try XCTUnwrap(params["strokes"]?[0]).decode(Stroke.self)
        XCTAssertEqual(out.points.map { $0.x }, [101, 103])
        XCTAssertEqual(commits.calls.first?.principal, .user)

        // Errors keep the raw stroke.
        mode = "fail"
        stroke = raw
        XCTAssertFalse(first.process(&stroke, page: Fixtures.page1, session: kit.h.session))
        let kept = await eventually(3) { commits.calls.count == 2 }
        XCTAssertTrue(kept)
        XCTAssertEqual(try commits.calls.last?.params["strokes"]?[0]?.decode(Stroke.self).points.map { $0.x }, [1, 3])

        // {drop: true} removes it: nothing is committed.
        mode = "drop"
        stroke = raw
        XCTAssertFalse(first.process(&stroke, page: Fixtures.page1, session: kit.h.session))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commits.calls.count, 2)

        // Tools the processors do not take are left alone.
        var highlighter = Stroke(style: .defaultHighlighter, points: raw.points)
        XCTAssertTrue(first.process(&highlighter, page: Fixtures.page1, session: kit.h.session))
        XCTAssertEqual(StrokeProcessorResult(["stroke": .null]), .keep)
        XCTAssertEqual(StrokeProcessorResult(["drop": true]), .drop)
    }

    // MARK: Taps, files, inspectors

    func testItemTypeEditTapsImportersAndExporters() async throws {
        let kit = PluginTestKit()
        let pid = Self.pid
        var editParams: JSONValue?
        kit.runtime.handlers["\(pid).edit"] = { params, _ in
            editParams = params
            return ["opened": true]
        }
        var importParams: JSONValue?
        kit.runtime.handlers["\(pid).importDeck"] = { params, _ in
            importParams = params
            return ["refs": ["doc:FIXTUREDOC03", "page:FIXTUREDOC01/FIXTUREPG001", "doc:FIXTUREDOC03"]]
        }
        kit.runtime.handlers["\(pid).guard"] = { _, _ in [:] }
        kit.runtime.handlers["\(pid).exportDeck"] = { params, _ in
            ["files": [["name": "../deck", "base64": .string(Data("hello".utf8).base64EncodedString())],
                       ["name": "notes.txt", "text": .string(params["docs"]?[0]?.stringValue ?? "")]]]
        }
        try await kit.installAndLoad(try Self.fixture(), files: Self.fixtureFiles())

        // A double-tap on the chart reaches `edit` with {ref} only, and answers the tap router with handled.
        let ref = NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.customID).description
        let tapped = try await kit.h.run("\(pid).edit", ["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [1, 2],
                                                         "ref": .string(ref), "gesture": "doubleTap"])
        XCTAssertEqual(editParams, ["ref": .string(ref)])
        XCTAssertEqual(tapped["handled"], true)
        XCTAssertEqual(tapped["opened"], true)
        _ = try await kit.h.run("\(pid).edit", ["ref": .string(ref)])
        XCTAssertEqual(editParams, ["ref": .string(ref)])

        // Importer: file → temporary asset → the plugin command; the documents come back from its refs.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Biology.deck")
        try Data("deck bytes".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        kit.h.app.commands.register(CommandDescriptor(id: "test.import", title: "Import", summary: "Test.", effect: .library,
                                                      owner: "test")) { _, ctx in
            guard let importer = ctx.content.importer(forExtension: "deck") else { throw NibError.notFound("importer") }
            let docs = try await importer.handler(file, ImportTarget(folder: Fixtures.folderID, displayName: "Bio"), ctx)
            return .array(docs.map { .string($0.raw) })
        }
        let docs = try await kit.h.run("test.import")
        XCTAssertEqual(docs, ["FIXTUREDOC03", "FIXTUREDOC01"])
        XCTAssertEqual(importParams?["name"], "Bio")
        XCTAssertEqual(importParams?["target"]?["folder"], "folder:FIXTUREFLD01")
        XCTAssertEqual(importParams?["target"]?["position"], "end")
        let asset = try XCTUnwrap(importParams?["asset"]?.stringValue)
        XCTAssertTrue(asset.hasPrefix("tmp:"))
        let stored = try XCTUnwrap(kit.h.assets.temporaryURL(AssetRef(String(asset.dropFirst(4)))))
        XCTAssertEqual(try Data(contentsOf: stored), Data("deck bytes".utf8))

        // Exporter: the plugin's {files} become temporary files with safe names.
        kit.h.app.commands.register(CommandDescriptor(id: "test.export", title: "Export", summary: "Test.", effect: .read,
                                                      owner: "test")) { _, ctx in
            guard let exporter = ctx.content.exporters.all.first(where: { $0.owner == pid }) else { throw NibError.notFound("exporter") }
            let urls = try await exporter.handler(ExportRequest(documents: [Fixtures.studySetID]), ctx)
            return .array(urls.map { .string($0.lastPathComponent + "=" + ((try? String(contentsOf: $0, encoding: .utf8)) ?? "")) })
        }
        let files = try await kit.h.run("test.export")
        XCTAssertEqual(files, ["deck.deck=hello", "notes.txt=doc:FIXTUREDOC03"])

        XCTAssertEqual(FileHandlerMapping.documents(in: ["ref": "item:D1/P/I", "docs": ["doc:D2", "D1"]]), ["D1", "D2"])
        XCTAssertEqual(FileHandlerMapping.safeName("../../.hidden:name", fallback: "x"), "hiddenname")
        XCTAssertEqual(FileHandlerMapping.safeName("", fallback: "Export"), "Export")
        XCTAssertThrowsError(try FileHandlerMapping.writeFiles(["files": []], defaultName: "x", fileExtension: "deck"))
        XCTAssertEqual(FileHandlerMapping.normalize(".DECK"), "deck")
    }

    func testInspectorWritesDataThroughItemUpdate() async throws {
        let kit = PluginTestKit()
        let updates = CallRecorder()
        kit.standIn(CommandIDs.itemUpdate, effect: .edit, recorder: updates)
        let item = try kit.h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.customID)
        let context = InspectorContext(app: kit.h.app, session: kit.h.session, doc: Fixtures.docID, page: Fixtures.page1, items: [item])
        CustomItemInspector.write("title", "Sales", context)
        let wrote = await eventually { updates.calls.count == 1 }
        XCTAssertTrue(wrote)
        let call = try XCTUnwrap(updates.calls.first)
        XCTAssertEqual(call.params["ref"], .string(NodeRef.item(Fixtures.docID, Fixtures.page1, Fixtures.customID).description))
        XCTAssertEqual(call.params["patch"]?["custom"]?["data"]?["title"], "Sales")
        XCTAssertEqual(call.params["patch"]?["custom"]?["owner"], "nib.fixture", "the whole payload is written, owner and type kept")
        XCTAssertEqual(call.principal, .user)
        XCTAssertEqual(CustomItemInspector.updated(["a": 1], key: "b", value: 2), ["a": 1, "b": 2])

        let fields = SchemaField.fields(from: try JSONValue.parse(#"""
        {"type": "object", "properties": {
          "on": {"type": "boolean", "order": 1}, "mode": {"type": "string", "enum": ["a", "b"], "order": 2},
          "size": {"type": "integer", "minimum": 1, "maximum": 5}, "tint": {"type": "string", "format": "color"},
          "name": {"type": "string", "title": "Label", "default": "x"}, "extra": {"type": "object"}}}
        """#))
        XCTAssertEqual(fields.map { $0.key }, ["on", "mode", "extra", "name", "size", "tint"])
        XCTAssertEqual(fields.first { $0.key == "mode" }?.kind, .choice(["a", "b"]))
        XCTAssertEqual(fields.first { $0.key == "size" }?.kind, .number(min: 1, max: 5, integer: true))
        XCTAssertEqual(fields.first { $0.key == "tint" }?.kind, .color)
        XCTAssertEqual(fields.first { $0.key == "name" }?.title, "Label")
        XCTAssertEqual(fields.first { $0.key == "name" }?.defaultValue, "x")
        XCTAssertEqual(fields.first { $0.key == "extra" }?.kind, .json)
        XCTAssertEqual(SchemaField.fields(from: ["properties": ["a": ["type": "boolean"], "b": ["type": "string"]]], only: ["b"]).map { $0.key }, ["b"])
    }

    func testElementPacks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nib-elements-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("big-star.json")
        try Data(#"{"format": "nib-fragment/1", "items": []}"#.utf8).write(to: one)
        let many = folder.appendingPathComponent("set.json")
        try Data(#"[{"id": "a", "title": "A", "fragment": {}}, {"fragment": {}}, {"id": "a", "fragment": {}}, {"id": "no-fragment"}]"#.utf8).write(to: many)
        let entries = try ElementPack.load([one, many])
        XCTAssertEqual(entries.map { $0.id }, ["big-star", "a", "set-2"])
        XCTAssertEqual(entries.first?.title, "Big Star")
    }
}
