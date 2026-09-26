import XCTest
import UIKit
import NibContracts
import NibTesting
@testable import FeatTextDoc

/// F102: slash menu, Turn Into, block handles and inline formatting of text documents.
@MainActor
final class SlashMenuTests: XCTestCase {
    private let doc = Fixtures.textDocID
    private let heading = "block:FIXTUREDOC02/FIXTUREBLK01"
    private let paragraph = "block:FIXTUREDOC02/FIXTUREBLK02"

    private func harness() -> Harness {
        Harness(features: [FeatTextDocFeature.self, FeatTextDocEditingFeature.self])
    }

    /// F048's table kind, as the tables feature registers it.
    private func registerTable(_ h: Harness) {
        h.app.content.blockKinds.register(BlockKindDescriptor(
            id: "tables.table", title: "Table", icon: "tablecells", kind: .table, owner: "tables", order: 330,
            params: ["kind": "table"], aliases: ["grid", "table"]))
    }

    /// A plugin's `blocks` contribution (F078 maps it to a custom kind with the plugin's insert command).
    private func registerPluginKinds(_ h: Harness) {
        h.app.content.blockKinds.register(BlockKindDescriptor(
            id: "dev.nib.charts.chart", title: "Chart", icon: "chart.bar", kind: .custom, owner: "dev.nib.charts",
            order: 900, customType: "dev.nib.charts.chart", command: "dev.nib.charts.insert", aliases: ["graph"]))
        // A custom kind with neither a command nor a payload cannot be inserted: the menu leaves it out.
        h.app.content.blockKinds.register(BlockKindDescriptor(
            id: "dev.nib.broken.box", title: "Broken Box", icon: "", kind: .custom, owner: "dev.nib.broken",
            order: 950, customType: "dev.nib.broken.box"))
    }

    private func live(_ h: Harness) throws -> [TextBlock] { try h.app.workspace.content(doc).liveBlocks }

    private func block(_ h: Harness, _ id: String) throws -> TextBlock {
        try XCTUnwrap(live(h).first { $0.id.raw == id }, "block \(id)")
    }

    /// Records every block.* command (and plugin commands) the bus runs, with its params.
    private final class Recorder {
        var calls: [(command: String, params: JSONValue)] = []
        var commands: [String] { calls.map { $0.command } }
    }

    private func record(_ h: Harness) -> Recorder {
        let recorder = Recorder()
        h.app.bus.hooks.register(CommandHookDescriptor.guarding(
            id: "test.record", owner: "test", commands: ["block.*", "dev.nib.charts.*"]) { command, params, _ in
            recorder.calls.append((command, params))
            return nil
        })
        return recorder
    }

    // MARK: Registration

    func testConformance() async {
        let problems = await CommandConformance.check(features: [FeatTextDocFeature.self, FeatTextDocEditingFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersShortcutsAsTextDocumentKeyCommandsAndNoCommands() {
        let h = harness()
        XCTAssertEqual(FeatTextDocEditingFeature.id, "textdocedit")
        XCTAssertTrue(h.app.commands.all().filter { $0.owner == "textdocedit" }.isEmpty,
                      "the editing half owns no command: it runs block.* and plugin block commands")
        let mine = h.app.content.keyCommands.all.filter { $0.owner == "textdocedit" }
        XCTAssertEqual(mine.count, TextDocShortcut.allCases.count)
        for d in mine {
            XCTAssertEqual(d.docKinds, [.textDocument], d.id)
            XCTAssertEqual(d.command, CommandIDs.batch, d.id)
            XCTAssertEqual(d.params["calls"], .array([]), "\(d.id): static params are an empty batch")
            XCTAssertNotNil(d.sessionParams, d.id)
            XCTAssertEqual(d.scope, .canvas, d.id)
            XCTAssertFalse(d.title.isEmpty, d.id)
            XCTAssertNotNil(h.app.commands.descriptor(d.command), d.id)
        }
        func shortcut(_ s: TextDocShortcut) -> KeyShortcut? { h.app.content.keyCommands.get(s.id)?.shortcut }
        XCTAssertEqual(shortcut(.turnInto), KeyShortcut("t", [.command]))
        XCTAssertEqual(shortcut(.inlineCode), KeyShortcut("e", [.command]))
        XCTAssertEqual(shortcut(.highlight), KeyShortcut("h", [.command, .shift]))
        XCTAssertEqual(shortcut(.bold), KeyShortcut("b", [.command]))
        XCTAssertEqual(shortcut(.italic), KeyShortcut("i", [.command]))
        XCTAssertEqual(shortcut(.underline), KeyShortcut("u", [.command]))
        XCTAssertEqual(shortcut(.strikethrough), KeyShortcut("x", [.command, .shift]))
        // No shortcut is registered twice (F047's ⇧⌘T included).
        let all = h.app.content.keyCommands.all.map { "\($0.shortcut.key.lowercased())/\($0.shortcut.modifiers.rawValue)" }
        XCTAssertEqual(all.count, Set(all).count, "duplicate shortcut")
        XCTAssertEqual(TextDocShortcut.heading1.display, "\u{2303}\u{2318}1")
        XCTAssertEqual(TextDocShortcut.toggleDone.display, "\u{21E7}\u{2318}\u{21A9}")
        XCTAssertEqual(TextDocShortcut(descriptorID: "textdocedit.key.bold"), .bold)
        XCTAssertNil(TextDocShortcut(descriptorID: "keyboard.bold"))

        for hook in ["editor", "cell", "selection", "slash", "keys", "blockMenu", "style"] {
            let id = "textdocedit." + hook
            let found = TextDocHooks.editorObservers.contains { $0.id == id } || TextDocHooks.cellDecorators.contains { $0.id == id }
                || TextDocHooks.selectionObservers.contains { $0.id == id } || TextDocHooks.textInterceptors.contains { $0.id == id }
                || TextDocHooks.keyCommandSets.contains { $0.id == id } || TextDocHooks.blockMenuProviders.contains { $0.id == id }
                || TextDocHooks.editMenuProviders.contains { $0.id == id }
            XCTAssertTrue(found, id)
        }
    }

    func testShortcutParamsComeFromTheWindowAndAreEmptyWithoutAFocusedBlock() {
        let h = harness()
        // No text document editor in this window: an empty batch.
        let d = try? XCTUnwrap(h.app.content.keyCommands.get(TextDocShortcut.bold.id))
        XCTAssertEqual(d?.resolvedParams(for: h.session)["calls"], .array([]))
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.loadViewIfNeeded()
        XCTAssertEqual(TextDocShortcut.sessionParams(.moveDown, h.session)["calls"], .array([]),
                       "nothing is focused, so nothing moves")
        let controller = TextDocEditingController.controller(for: editor)
        XCTAssertTrue(controller === TextDocEditingController.controller(for: editor), "one controller per editor")
        XCTAssertTrue(controller.calls(for: .deleteBlock).isEmpty)
    }

    // MARK: Acceptance: slash-menu filtering and aliases

    func testSlashMenuFiltersBuiltInTableAndPluginKindsByTitleAndAlias() {
        let h = harness()
        registerTable(h)
        registerPluginKinds(h)
        let registry = h.app.content.blockKinds.all
        func titles(_ q: String) -> [String] { SlashMenuFilter.matches(q, in: registry).map { $0.title } }

        let all = titles("")
        XCTAssertEqual(all.count, 14, "12 built-ins, the table and the plugin chart: \(all)")
        XCTAssertEqual(all.first, "Text")
        XCTAssertFalse(all.contains("Broken Box"), "a custom kind without a command or payload is not offered")
        XCTAssertEqual(titles("h1").first, "Heading 1")
        XCTAssertEqual(titles("head"), ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(titles("list"), ["Bulleted List", "Numbered List", "To-do List"], "the exact alias first")
        XCTAssertEqual(titles("#"), ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(titles("##").first, "Heading 2")
        XCTAssertEqual(titles("graph").first, "Chart", "a plugin kind by its alias")
        XCTAssertEqual(titles("chart").first, "Chart")
        XCTAssertEqual(titles("grid"), ["Table"])
        XCTAssertEqual(titles("tâble").first, "Table", "diacritics fold")
        XCTAssertEqual(titles("HEADING 2").first, "Heading 2", "case folds")
        XCTAssertEqual(titles("heading2").first, "Heading 2", "the kind's own name")
        XCTAssertEqual(titles("to").first, "To-do List")
        XCTAssertEqual(Array(titles("t").prefix(3)), ["Text", "To-do List", "Table"], "title prefixes keep registry order")
        XCTAssertEqual(titles("num list").first, "Numbered List", "every word of a multi-word query")
        XCTAssertEqual(titles("---"), ["Divider"])
        XCTAssertEqual(titles("[]"), ["To-do List"])
        XCTAssertTrue(titles("xyz").isEmpty)

        let chart = try? XCTUnwrap(registry.first { $0.id == "dev.nib.charts.chart" })
        XCTAssertEqual(chart.map { BlockKindChoice.make($0).isPlugin }, true)
        let broken = registry.first { $0.id == "dev.nib.broken.box" }
        let unknown = BlockKindDescriptor(id: "x", title: "x", icon: "no.such.symbol.name", kind: .custom, owner: "x")
        XCTAssertEqual(broken.map { BlockKindChoice.symbol($0).name }, BlockKindChoice.symbol(unknown).name,
                       "an empty or unknown icon falls back to the plugin glyph")
        let text = try? XCTUnwrap(registry.first { $0.kind == .paragraph })
        XCTAssertEqual(text.map { BlockKindChoice.symbol($0).name }, "text.alignleft")
    }

    func testSlashQueryOpensAtLineStartsAndClosesOnProse() {
        XCTAssertTrue(SlashQuery.opensMenu(in: "" as NSString, at: 0))
        XCTAssertTrue(SlashQuery.opensMenu(in: "Hello " as NSString, at: 6))
        XCTAssertTrue(SlashQuery.opensMenu(in: "a\nb" as NSString, at: 2))
        XCTAssertFalse(SlashQuery.opensMenu(in: "and" as NSString, at: 3), "a slash inside a word is prose (and/or)")
        let text = "Hello /hea" as NSString
        XCTAssertEqual(SlashQuery.query(in: text, slash: 6, selection: NSRange(location: 10, length: 0)), "hea")
        XCTAssertEqual(SlashQuery.query(in: text, slash: 6, selection: NSRange(location: 7, length: 0)), "")
        XCTAssertNil(SlashQuery.query(in: text, slash: 6, selection: NSRange(location: 6, length: 0)), "caret before the slash")
        XCTAssertNil(SlashQuery.query(in: text, slash: 5, selection: NSRange(location: 10, length: 0)), "the slash went")
        XCTAssertNil(SlashQuery.query(in: "/ x" as NSString, slash: 0, selection: NSRange(location: 3, length: 0)))
        XCTAssertNil(SlashQuery.query(in: "/a  b" as NSString, slash: 0, selection: NSRange(location: 5, length: 0)))
        XCTAssertNil(SlashQuery.query(in: "/ab" as NSString, slash: 0, selection: NSRange(location: 1, length: 2)))
        XCTAssertEqual(SlashQuery.query(in: "/heading 1" as NSString, slash: 0, selection: NSRange(location: 10, length: 0)),
                       "heading 1")
        let long = ("/" + String(repeating: "a", count: SlashQuery.maxLength + 1)) as NSString
        XCTAssertNil(SlashQuery.query(in: long, slash: 0, selection: NSRange(location: long.length, length: 0)))
    }

    func testMenuStateWrapsTheHighlight() {
        let state = BlockKindMenuState(title: "Blocks", emptyText: "None")
        state.moveHighlight(by: -1)
        XCTAssertEqual(state.highlighted, 0, "no choices, no move")
        state.choices = ["a", "b", "c"].map {
            BlockKindChoice.make(BlockKindDescriptor(id: $0, title: $0, icon: "textformat", kind: .paragraph, owner: "test"))
        }
        state.moveHighlight(by: -1)
        XCTAssertEqual(state.highlighted, 2)
        state.moveHighlight(by: 1)
        XCTAssertEqual(state.highlighted, 0)
        var picked: [Int] = []
        state.onPick = { picked.append($0) }
        state.pick(5)
        state.pick(1)
        XCTAssertEqual(picked, [1], "out-of-range picks are ignored")
    }

    // MARK: What a slash pick does

    func testSlashPickOnAnEmptyLineTurnsItIntoTheKindInOneUndoStep() async throws {
        let h = harness()
        let heading1 = try XCTUnwrap(h.app.content.blockKinds.all.first { $0.kind == .heading1 })
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "after": .string(paragraph), "kind": "paragraph",
                                         "text": "/h1", "id": "SLASHLINE01"])
        let before = try h.snapshot(doc)
        let depth = h.undoDepth(doc)
        let line = try block(h, "SLASHLINE01")
        let plan = SlashPlanner.calls(for: heading1, block: line, remaining: .empty, doc: doc, newID: "UNUSED00001")
        XCTAssertEqual(plan.calls.map { $0.command }, ["block.update", "block.update"], "the query leaves, the kind changes")
        XCTAssertEqual(plan.focus, NibID("SLASHLINE01"))
        try await h.run(CommandIDs.batch, ["calls": .array(plan.calls.map { $0.json })])
        let turned = try block(h, "SLASHLINE01")
        XCTAssertEqual(turned.kind, .heading1)
        XCTAssertTrue(turned.text.isEmpty)
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "one undo step")
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), before, "undo brings the /h1 line back")
    }

    func testSlashPickInsertsBelowWhenTheLineHasTextAndReplacesAnEmptyLineWithAPluginBlock() async throws {
        let h = harness()
        registerPluginKinds(h)
        // The plugin's insert command, as F078 would register it: {doc, after?} in, the new block's ref out.
        h.app.commands.register(CommandDescriptor(id: "dev.nib.charts.insert", title: "Insert Chart",
                                                  summary: "Test plugin block insert.", effect: .edit, exposure: .ui)) { params, ctx in
            var insert: [String: JSONValue] = ["doc": params["doc"] ?? .null, "kind": "custom", "id": "CHARTBLOCK1",
                                               "custom": ["owner": "dev.nib.charts", "type": "chart", "height": 80]]
            if let after = params["after"] { insert["after"] = after }
            return try await ctx.execute("block.insert", .object(insert))
        }
        let registry = h.app.content.blockKinds.all
        let heading2 = try XCTUnwrap(registry.first { $0.kind == .heading2 })
        let chart = try XCTUnwrap(registry.first { $0.id == "dev.nib.charts.chart" })
        let recorder = record(h)

        // "Hello blocks /h2": the text stays, a heading goes below and takes the caret.
        try await h.run("block.update", ["ref": .string(paragraph), "text": "Hello blocks /h2"])
        var line = try block(h, "FIXTUREBLK02")
        let below = SlashPlanner.calls(for: heading2, block: line, remaining: RichText(plain: "Hello blocks "), doc: doc,
                                       newID: "NEWHEADING1")
        XCTAssertEqual(below.focus, NibID("NEWHEADING1"))
        let depth = h.undoDepth(doc)
        try await h.run(CommandIDs.batch, ["calls": .array(below.calls.map { $0.json })])
        XCTAssertEqual(try live(h).map { $0.id.raw }, ["FIXTUREBLK01", "FIXTUREBLK02", "NEWHEADING1", "FIXTUREBLK03"])
        XCTAssertEqual(try block(h, "FIXTUREBLK02").text.plainText, "Hello blocks ")
        XCTAssertEqual(try block(h, "NEWHEADING1").kind, .heading2)
        XCTAssertEqual(h.undoDepth(doc), depth + 1)

        // "/chart" alone on a line: the plugin's command inserts its block and the empty line goes.
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "after": "block:FIXTUREDOC02/NEWHEADING1",
                                         "kind": "paragraph", "text": "/chart", "id": "CHARTLINE01"])
        line = try block(h, "CHARTLINE01")
        recorder.calls.removeAll()
        let plugin = SlashPlanner.calls(for: chart, block: line, remaining: .empty, doc: doc, newID: "UNUSED00002")
        XCTAssertEqual(plugin.calls.map { $0.command }, ["block.update", "dev.nib.charts.insert", "block.delete"])
        XCTAssertNil(plugin.calls[1].params["id"], "a plugin command chooses its own id")
        XCTAssertEqual(plugin.calls[1].params["after"]?.stringValue, "block:FIXTUREDOC02/CHARTLINE01")
        XCTAssertEqual(plugin.focusResultOf, 1)
        let result = try await h.run(CommandIDs.batch, ["calls": .array(plugin.calls.map { $0.json })])
        XCTAssertEqual(result["results"]?[1]?["value"]?["ref"]?.stringValue, "block:FIXTUREDOC02/CHARTBLOCK1")
        let ids = try live(h).map { $0.id.raw }
        XCTAssertFalse(ids.contains("CHARTLINE01"), "the empty line was replaced")
        XCTAssertEqual(ids, ["FIXTUREBLK01", "FIXTUREBLK02", "NEWHEADING1", "CHARTBLOCK1", "FIXTUREBLK03"])
        XCTAssertEqual(try block(h, "CHARTBLOCK1").custom?.owner, "dev.nib.charts")
        XCTAssertEqual(recorder.commands, ["block.update", "dev.nib.charts.insert", "block.insert", "block.delete"])
    }

    func testSlashDividerOnAnEmptyLineLeavesALineBelowForTheCaret() async throws {
        let h = harness()
        let divider = try XCTUnwrap(h.app.content.blockKinds.all.first { $0.kind == .divider })
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "bullet", "text": "/---", "id": "RULELINE01"])
        let plan = SlashPlanner.calls(for: divider, block: try block(h, "RULELINE01"), remaining: .empty, doc: doc,
                                      newID: "AFTERRULE01")
        XCTAssertEqual(plan.focus, NibID("AFTERRULE01"))
        try await h.run(CommandIDs.batch, ["calls": .array(plan.calls.map { $0.json })])
        XCTAssertEqual(try block(h, "RULELINE01").kind, .divider)
        XCTAssertEqual(try block(h, "AFTERRULE01").kind, .paragraph)
        XCTAssertEqual(try live(h).suffix(2).map { $0.id.raw }, ["RULELINE01", "AFTERRULE01"])
    }

    // MARK: Markdown-style shortcuts

    func testMarkdownPrefixesTurnALineIntoTheirKind() async throws {
        XCTAssertEqual(MarkdownShortcut.rule(for: "#")?.kind, .heading1)
        XCTAssertEqual(MarkdownShortcut.rule(for: "##")?.kind, .heading2)
        XCTAssertEqual(MarkdownShortcut.rule(for: "###")?.kind, .heading3)
        XCTAssertNil(MarkdownShortcut.rule(for: "####"))
        for bullet in ["-", "*", "+"] { XCTAssertEqual(MarkdownShortcut.rule(for: bullet)?.kind, .bullet, bullet) }
        XCTAssertEqual(MarkdownShortcut.rule(for: "1.")?.kind, .numbered)
        XCTAssertEqual(MarkdownShortcut.rule(for: "42.")?.kind, .numbered)
        XCTAssertNil(MarkdownShortcut.rule(for: "1234."))
        XCTAssertNil(MarkdownShortcut.rule(for: "a."))
        XCTAssertEqual(MarkdownShortcut.rule(for: "[]"), MarkdownShortcut.Rule(kind: .todo, checked: false))
        XCTAssertEqual(MarkdownShortcut.rule(for: "[x]"), MarkdownShortcut.Rule(kind: .todo, checked: true))
        XCTAssertEqual(MarkdownShortcut.rule(for: ">")?.kind, .quote)
        XCTAssertEqual(MarkdownShortcut.rule(for: "```")?.kind, .code)
        XCTAssertEqual(MarkdownShortcut.rule(for: "---")?.kind, .divider)
        XCTAssertNil(MarkdownShortcut.rule(for: "Hello"))

        let h = harness()
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "paragraph", "text": "[x]Buy milk", "id": "MDLINE0001"])
        let line = try block(h, "MDLINE0001")
        let rule = try XCTUnwrap(MarkdownShortcut.rule(for: "[x]"))
        let plan = try XCTUnwrap(MarkdownShortcut.calls(rule, block: line, rest: RichText(plain: "Buy milk"), doc: doc,
                                                        newID: "UNUSED00003"))
        XCTAssertEqual(plan.calls.map { $0.command }, ["block.update"], "one block.update, like Turn Into")
        XCTAssertEqual(plan.focus, NibID("MDLINE0001"))
        let depth = h.undoDepth(doc)
        try await h.run(CommandIDs.batch, ["calls": .array(plan.calls.map { $0.json })])
        let todo = try block(h, "MDLINE0001")
        XCTAssertEqual(todo.kind, .todo)
        XCTAssertEqual(todo.checked, true)
        XCTAssertEqual(todo.text.plainText, "Buy milk")
        XCTAssertEqual(h.undoDepth(doc), depth + 1)

        let rule2 = try XCTUnwrap(MarkdownShortcut.rule(for: "---"))
        XCTAssertNil(MarkdownShortcut.calls(rule2, block: line, rest: RichText(plain: "text"), doc: doc, newID: "N0"),
                     "a rule needs an otherwise empty line")
        try await h.run("block.insert", ["doc": "doc:FIXTUREDOC02", "kind": "paragraph", "text": "---", "id": "MDRULE0001"])
        let rulePlan = try XCTUnwrap(MarkdownShortcut.calls(rule2, block: try block(h, "MDRULE0001"), rest: .empty,
                                                            doc: doc, newID: "MDAFTER001"))
        try await h.run(CommandIDs.batch, ["calls": .array(rulePlan.calls.map { $0.json })])
        XCTAssertEqual(try block(h, "MDRULE0001").kind, .divider)
        XCTAssertEqual(try live(h).last?.id.raw, "MDAFTER001", "a line after the rule takes the caret")
        XCTAssertEqual(rulePlan.focus, NibID("MDAFTER001"))
    }

    // MARK: Acceptance: Turn Into maps every kind pair to a block.update

    func testTurnIntoMapsEveryKindPairToOneBlockUpdate() async throws {
        let sources: [(BlockKind, JSONValue)] = BlockKind.allCases.map { kind in
            var p: [String: JSONValue] = ["doc": "doc:FIXTUREDOC02", "kind": .string(kind.rawValue), "id": "TURNSOURCE1"]
            switch kind {
            case .divider: break
            case .image: p["caption"] = "A figure"
            case .video: p["url"] = "https://example.com/lecture.mp4"; p["caption"] = "A lecture"
            case .custom: p["custom"] = ["owner": "dev.nib.test", "type": "box", "height": 40]; p["text"] = "Box"
            default: p["text"] = "Source text"
            }
            return (kind, .object(p))
        }
        var pairs = 0
        for (source, insert) in sources {
            let h = harness()
            registerTable(h)
            registerPluginKinds(h)
            let targets = TurnInto.targets(h.app.content.blockKinds.all)
            XCTAssertEqual(Set(targets.map { $0.kind }), Set(TurnInto.kinds), "every built-in kind and the table, never custom")
            try await h.run("block.insert", insert)
            let ref = "block:FIXTUREDOC02/TURNSOURCE1"
            let recorder = record(h)
            for target in targets.map({ $0.kind }) where target != source {
                let call = TurnInto.call(ref: ref, to: target)
                XCTAssertEqual(call.command, "block.update")
                XCTAssertEqual(call.params, ["ref": .string(ref), "kind": .string(target.rawValue)])
                let before = try h.snapshot(doc)
                let depth = h.undoDepth(doc)
                recorder.calls.removeAll()
                try await h.run(call.command, call.params)
                XCTAssertEqual(recorder.commands, ["block.update"], "\(source) → \(target)")
                XCTAssertEqual(try block(h, "TURNSOURCE1").kind, target, "\(source) → \(target)")
                XCTAssertEqual(h.undoDepth(doc), depth + 1, "\(source) → \(target) is one undo step")
                XCTAssertTrue(h.app.bus.undo(doc))
                XCTAssertEqual(try h.snapshot(doc), before, "\(source) → \(target) undoes")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 13 * 12 + 13, "12 other targets from each of 13 kinds, and all 13 from a custom block")
    }

    func testTurnIntoTextKeepsTheContentAcrossKinds() async throws {
        let h = harness()
        registerTable(h)
        try await h.run(TurnInto.call(ref: paragraph, to: .quote).command, TurnInto.call(ref: paragraph, to: .quote).params)
        XCTAssertEqual(try block(h, "FIXTUREBLK02").text.plainText, "Hello blocks")
        let toImage = TurnInto.call(ref: paragraph, to: .image)
        try await h.run(toImage.command, toImage.params)
        XCTAssertEqual(try block(h, "FIXTUREBLK02").caption?.plainText, "Hello blocks", "text becomes the caption")
        let table = TurnInto.call(ref: "block:FIXTUREDOC02/FIXTUREBLK03", to: .paragraph)
        try await h.run(table.command, table.params)
        XCTAssertEqual(try block(h, "FIXTUREBLK03").text.plainText, "A1\tB1\nA2\tB2")
    }

    func testBlockMenuOffersTurnIntoForRegisteredKinds() {
        let h = harness()
        let ctx = MenuContext(app: h.app, session: h.session, doc: doc, ref: paragraph)
        var items = h.app.ui.menuItems(.block, ctx).filter { $0.id.hasPrefix(TurnInto.submenuID) }
        XCTAssertEqual(items.count, 11, "12 built-ins minus the block's own kind; no table without the tables feature")
        XCTAssertFalse(items.contains { $0.id == TurnInto.submenuID + "paragraph" })
        let h1 = try? XCTUnwrap(items.first { $0.id == TurnInto.submenuID + "heading1" })
        XCTAssertEqual(h1?.command, "block.update")
        XCTAssertEqual(h1?.params(ctx), ["ref": .string(paragraph), "kind": "heading1"])
        XCTAssertEqual(h1?.submenu, "Turn Into")
        XCTAssertEqual(h1?.shortcut, KeyShortcut("1", [.command, .control]))
        registerTable(h)
        items = h.app.ui.menuItems(.block, ctx).filter { $0.id.hasPrefix(TurnInto.submenuID) }
        XCTAssertEqual(items.count, 12)
        h.session.readOnly = true
        XCTAssertTrue(h.app.ui.menuItems(.block, ctx).filter { $0.id.hasPrefix(TurnInto.submenuID) }.isEmpty)
    }

    func testTheEditorsBlockMenuHasTurnIntoAndInsertBelow() {
        let h = harness()
        registerPluginKinds(h)
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.loadViewIfNeeded()
        let blockValue = editor.block(Fixtures.paragraphBlockID)
        guard let block = blockValue else { return XCTFail("no paragraph") }
        let menu = editor.blockMenu(for: block)
        func submenus(_ m: UIMenu) -> [UIMenu] {
            m.children.compactMap { $0 as? UIMenu }.flatMap { [$0] + submenus($0) }
        }
        let all = submenus(menu)
        let turnInto = all.first { $0.title == "Turn Into" }
        XCTAssertEqual(turnInto?.children.count, 11)
        let insert = all.first { $0.title == "Insert Below" }
        XCTAssertEqual(insert?.children.count, 13, "12 built-ins and the plugin chart")
        XCTAssertTrue(insert?.children.contains { ($0 as? UIAction)?.title == "Chart" } == true)
        h.session.readOnly = true
        XCTAssertTrue(TextDocEditingController.controller(for: editor).blockMenuElements(block).isEmpty)
    }

    // MARK: Acceptance: drag reorder issues one block.move

    func testDragReorderIssuesOneBlockMove() async throws {
        let h = harness()
        let editor = TextDocViewController(doc: doc, session: h.session, app: h.app)
        editor.loadViewIfNeeded()
        let controller = TextDocEditingController.controller(for: editor)
        let recorder = record(h)
        let depth = h.undoDepth(doc)

        // Dropping the heading into the gap after the table (gap 3 of 3 blocks).
        await controller.handles.commitMove(Fixtures.headingBlockID, toGap: 3)
        XCTAssertEqual(recorder.commands, ["block.move"])
        XCTAssertEqual(recorder.calls.first?.params["ref"]?.stringValue, heading)
        XCTAssertEqual(recorder.calls.first?.params["after"]?.stringValue, "block:FIXTUREDOC02/FIXTUREBLK03")
        XCTAssertEqual(try live(h).map { $0.id.raw }, ["FIXTUREBLK02", "FIXTUREBLK03", "FIXTUREBLK01"])
        XCTAssertEqual(editor.blocks.map { $0.id.raw }, ["FIXTUREBLK02", "FIXTUREBLK03", "FIXTUREBLK01"])
        XCTAssertEqual(h.undoDepth(doc), depth + 1, "one undo step")

        // Dropping a block back where it is issues nothing.
        recorder.calls.removeAll()
        await controller.handles.commitMove(Fixtures.headingBlockID, toGap: 2)
        await controller.handles.commitMove(Fixtures.headingBlockID, toGap: 3)
        XCTAssertTrue(recorder.calls.isEmpty)

        // To the top.
        await controller.handles.commitMove(Fixtures.headingBlockID, toGap: 0)
        XCTAssertEqual(recorder.commands, ["block.move"])
        XCTAssertEqual(recorder.calls.first?.params["after"]?.stringValue, "doc:FIXTUREDOC02")
        XCTAssertEqual(try live(h).map { $0.id.raw }, ["FIXTUREBLK01", "FIXTUREBLK02", "FIXTUREBLK03"])
    }

    func testReorderPlanning() {
        let ids: [NibID] = ["A", "B", "C", "D"]
        XCTAssertEqual(BlockReorder.move(ids, moving: "A", toGap: 3, doc: "D1")?.after, "block:D1/C")
        XCTAssertEqual(BlockReorder.move(ids, moving: "C", toGap: 0, doc: "D1")?.after, "doc:D1")
        XCTAssertEqual(BlockReorder.move(ids, moving: "B", toGap: 4, doc: "D1")?.after, "block:D1/D")
        XCTAssertEqual(BlockReorder.move(ids, moving: "B", toGap: 4, doc: "D1")?.ref, "block:D1/B")
        XCTAssertNil(BlockReorder.move(ids, moving: "B", toGap: 1, doc: "D1"), "just above itself")
        XCTAssertNil(BlockReorder.move(ids, moving: "B", toGap: 2, doc: "D1"), "just below itself")
        XCTAssertNil(BlockReorder.move(ids, moving: "B", toGap: 5, doc: "D1"))
        XCTAssertNil(BlockReorder.move(ids, moving: "Z", toGap: 0, doc: "D1"))
        XCTAssertEqual(BlockReorder.neighbourGap(ids, moving: "B", up: true), 0)
        XCTAssertEqual(BlockReorder.neighbourGap(ids, moving: "B", up: false), 3)
        XCTAssertNil(BlockReorder.neighbourGap(ids, moving: "A", up: true))
        XCTAssertNil(BlockReorder.neighbourGap(ids, moving: "D", up: false))
        let frames: [(index: Int, frame: CGRect)] = [(2, CGRect(x: 0, y: 100, width: 10, height: 20)),
                                                     (3, CGRect(x: 0, y: 120, width: 10, height: 40))]
        XCTAssertEqual(BlockReorder.gap(atY: 105, frames: frames), 2)
        XCTAssertEqual(BlockReorder.gap(atY: 115, frames: frames), 3)
        XCTAssertEqual(BlockReorder.gap(atY: 150, frames: frames), 4)
        XCTAssertNil(BlockReorder.gap(atY: 150, frames: []))
        let call = BlockReorder.call(BlockMove.Params(ref: "block:D1/A", after: "doc:D1"))
        XCTAssertEqual(call, CommandCall(command: "block.move", params: ["ref": "block:D1/A", "after": "doc:D1"]))
    }

    // MARK: Inline formatting through block.update

    private var sample: RichText {
        RichText(paragraphs: [
            Paragraph(runs: [TextRun("Hello "), TextRun("bold", TextAttributes(bold: true)), TextRun(" end")]),
            Paragraph(runs: [TextRun("second line")])
        ])
    }

    func testInlineTogglesSplitRunsAndSwitchOffWhereAlreadyOn() {
        let text = sample
        let bold = InlineFormat.apply(.bold, to: text, range: NSRange(location: 0, length: 5), kind: .paragraph)
        XCTAssertEqual(bold.paragraphs[0].runs.map { $0.text }, ["Hello", " ", "bold", " end"])
        XCTAssertEqual(bold.paragraphs[0].runs[0].attrs.bold, true)
        XCTAssertNil(bold.paragraphs[0].runs[1].attrs.bold)
        XCTAssertEqual(bold.plainText, text.plainText)
        let off = InlineFormat.apply(.bold, to: text, range: NSRange(location: 6, length: 4), kind: .paragraph)
        XCTAssertEqual(off.paragraphs[0].runs, [TextRun("Hello bold end")], "all bold: switched off, runs merge")
        let partial = InlineFormat.apply(.bold, to: text, range: NSRange(location: 4, length: 4), kind: .paragraph)
        XCTAssertEqual(partial.paragraphs[0].runs.map { $0.text }, ["Hell", "o bold", " end"], "partly bold: all bold")
        let across = InlineFormat.apply(.italic, to: text, range: NSRange(location: 10, length: 11), kind: .paragraph)
        XCTAssertEqual(across.paragraphs[0].runs.last, TextRun(" end", TextAttributes(italic: true)))
        XCTAssertEqual(across.paragraphs[1].runs.map { $0.text }, ["second", " line"])
        XCTAssertEqual(across.paragraphs.count, 2, "paragraph breaks are never touched")
        XCTAssertEqual(InlineFormat.apply(.bold, to: text, range: NSRange(location: 3, length: 0), kind: .paragraph), text)
        let astral = InlineFormat.apply(.italic, to: RichText(plain: "a\u{1D11E}b"), range: NSRange(location: 1, length: 2),
                                        kind: .paragraph)
        XCTAssertEqual(astral.paragraphs[0].runs.map { $0.text }, ["a", "\u{1D11E}", "b"], "UTF-16 offsets")
    }

    func testKindsOwnTheirStylesAndBaselinesReplaceEachOther() {
        let title = RichText(plain: "Title")
        XCTAssertFalse(InlineFormat.isAvailable(.bold, kind: .heading1))
        XCTAssertTrue(InlineFormat.isActive(.bold, in: title, range: NSRange(location: 0, length: 5), kind: .heading2))
        XCTAssertEqual(InlineFormat.apply(.bold, to: title, range: NSRange(location: 0, length: 5), kind: .heading1), title)
        XCTAssertFalse(InlineFormat.isAvailable(.code, kind: .code))
        XCTAssertTrue(InlineFormat.isAvailable(.code, kind: .paragraph))
        let sup = InlineFormat.apply(.superscriptText, to: RichText(plain: "x2"), range: NSRange(location: 1, length: 1),
                                     kind: .paragraph)
        XCTAssertEqual(sup.paragraphs[0].runs[1].attrs.baseline, 1)
        let sub = InlineFormat.apply(.subscriptText, to: sup, range: NSRange(location: 1, length: 1), kind: .paragraph)
        XCTAssertEqual(sub.paragraphs[0].runs[1].attrs.baseline, -1, "subscript replaces superscript")
        XCTAssertEqual(InlineFormat.apply(.subscriptText, to: sub, range: NSRange(location: 1, length: 1), kind: .paragraph),
                       RichText(plain: "x2"))
        let code = InlineFormat.apply(.code, to: title, range: NSRange(location: 0, length: 2), kind: .paragraph)
        XCTAssertEqual(code.paragraphs[0].runs.first, TextRun("Ti", TextAttributes(code: true)))
        let struck = InlineFormat.apply(.strikethrough, to: title, range: NSRange(location: 0, length: 5), kind: .paragraph)
        XCTAssertEqual(struck.paragraphs[0].runs, [TextRun("Title", TextAttributes(strikethrough: true))])
        let under = InlineFormat.apply(.underline, to: title, range: NSRange(location: 0, length: 5), kind: .quote)
        XCTAssertTrue(InlineFormat.isActive(.underline, in: under, range: NSRange(location: 1, length: 2), kind: .quote))
    }

    func testHighlightColourAndClear() {
        let text = sample
        let lemon = InlineFormat.defaultHighlight
        XCTAssertEqual(lemon.hex, "#FFE45C80", "Lemon at the stored highlighter alpha")
        let on = InlineFormat.apply(.highlight(lemon), to: text, range: NSRange(location: 0, length: 5), kind: .paragraph)
        XCTAssertEqual(on.paragraphs[0].runs[0].attrs.highlight, lemon)
        XCTAssertEqual(InlineFormat.apply(.highlight(lemon), to: on, range: NSRange(location: 0, length: 5), kind: .paragraph),
                       text, "⇧⌘H again removes it")
        XCTAssertEqual(InlineFormat.apply(.highlight(nil), to: on, range: NSRange(location: 0, length: 25), kind: .paragraph),
                       text)
        let mint = InlineFormat.rgba(NibHighlighter.mint.hex, alpha: RGBA.highlighterAlpha)
        XCTAssertEqual(InlineFormat.highlights.map { $0.value }.count, NibHighlighter.allCases.count)
        XCTAssertTrue(InlineFormat.highlights.contains { $0.value == mint })
        let recoloured = InlineFormat.apply(.highlight(mint), to: on, range: NSRange(location: 0, length: 5), kind: .paragraph)
        XCTAssertEqual(recoloured.paragraphs[0].runs[0].attrs.highlight, mint, "another colour replaces the highlight")

        let cobalt = InlineFormat.rgba(NibInk.cobalt.hex)
        XCTAssertTrue(InlineFormat.textColours.contains { $0.value == cobalt })
        XCTAssertFalse(InlineFormat.textColours.contains { $0.value == InlineFormat.rgba(NibInk.chalk.hex) },
                       "inks that vanish in one appearance are not offered")
        let blue = InlineFormat.apply(.color(cobalt), to: text, range: NSRange(location: 6, length: 4), kind: .paragraph)
        XCTAssertEqual(blue.paragraphs[0].runs[1], TextRun("bold", TextAttributes(color: cobalt, bold: true)))
        XCTAssertTrue(InlineFormat.isActive(.color(cobalt), in: blue, range: NSRange(location: 7, length: 2), kind: .paragraph))
        let cleared = InlineFormat.apply(.clear, to: blue, range: NSRange(location: 0, length: 30), kind: .paragraph)
        XCTAssertEqual(cleared, RichText(paragraphs: [Paragraph(runs: [TextRun("Hello bold end")]),
                                                      Paragraph(runs: [TextRun("second line")])]))
        var linked = RichText(plain: "link")
        linked.paragraphs[0].runs[0].attrs = TextAttributes(bold: true, link: TextLink(url: "https://example.com"))
        let keep = InlineFormat.apply(.clear, to: linked, range: NSRange(location: 0, length: 4), kind: .paragraph)
        XCTAssertEqual(keep.paragraphs[0].runs[0].attrs, TextAttributes(link: TextLink(url: "https://example.com")),
                       "Clear keeps links")
    }

    func testTypingContinuesTheStyleBeforeTheCaret() {
        let text = sample
        XCTAssertEqual(InlineFormat.attributes(at: 8, in: text).bold, true)
        XCTAssertNil(InlineFormat.attributes(at: 6, in: text).bold, "before the bold run: plain continues")
        XCTAssertEqual(InlineFormat.attributes(at: 10, in: text).bold, true, "right after it: bold continues")
        XCTAssertNil(InlineFormat.attributes(at: 0, in: text).bold)
        XCTAssertEqual(InlineFormat.applying(.italic, to: TextAttributes(bold: true), on: true),
                       TextAttributes(bold: true, italic: true))
        XCTAssertEqual(InlineFormat.applying(.superscriptText, to: TextAttributes(baseline: -1), on: false),
                       TextAttributes(baseline: -1), "switching superscript off leaves a subscript alone")
    }

    func testFormattingABlockIsOneUndoableBlockUpdate() async throws {
        let h = harness()
        let recorder = record(h)
        let before = try h.snapshot(doc)
        let current = try block(h, "FIXTUREBLK02").text
        let style = BlockStyle.make(kind: .paragraph)
        let formatted = style.normalize(InlineFormat.apply(.bold, to: current, range: NSRange(location: 6, length: 6),
                                                           kind: .paragraph))
        let text = try JSONValue.from(formatted)
        try await h.run("block.update", ["ref": .string(paragraph), "text": text])
        XCTAssertEqual(recorder.commands, ["block.update"])
        let runs = try block(h, "FIXTUREBLK02").text.paragraphs[0].runs
        XCTAssertEqual(runs, [TextRun("Hello "), TextRun("blocks", TextAttributes(bold: true))])
        XCTAssertEqual(style.richText(from: style.attributed(formatted)), formatted, "the editor shows what is stored")
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(doc), before)
    }

    // MARK: The popover

    func testThePopoverRendersInLightDarkAndLargeText() {
        let h = harness()
        let state = BlockKindMenuState(title: "Blocks", emptyText: "No matching blocks")
        state.subtitle = "/he"
        state.choices = SlashMenuFilter.matches("he", in: h.app.content.blockKinds.all).map { BlockKindChoice.make($0) }
        XCTAssertFalse(state.choices.isEmpty)
        let panel = BlockKindMenuPanel(state: state)
        let images = NibSnapshot.images(panel, size: CGSize(width: 312, height: 480))
        XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases))
        let regular = NibSnapshot.fittingSize(panel, width: 312)
        let large = NibSnapshot.fittingSize(panel, width: 312, variant: .largeText)
        XCTAssertEqual(regular.width, 312, accuracy: 1)
        XCTAssertGreaterThanOrEqual(regular.height, CGFloat(state.choices.count) * 44, "44 pt rows")
        XCTAssertGreaterThan(large.height, regular.height, "rows grow with Dynamic Type")
        state.choices = []
        XCTAssertGreaterThanOrEqual(NibSnapshot.fittingSize(panel, width: 312).height, 44, "the empty state keeps a row")
    }

    // MARK: Popover placement

    func testPopoverSitsBelowTheSlashOrAboveWhenThereIsNoRoom() {
        let bounds = CGRect(x: 0, y: 60, width: 800, height: 600)
        let below = MenuPlacement.make(anchor: CGRect(x: 100, y: 100, width: 8, height: 20), bounds: bounds)
        XCTAssertEqual(below.top, 128)
        XCTAssertNil(below.bottom)
        XCTAssertEqual(below.x, 84, "the rows line up under the slash")
        XCTAssertEqual(below.width, 312)
        XCTAssertEqual(below.maxHeight, 516, "down to the chrome inset")
        let above = MenuPlacement.make(anchor: CGRect(x: 780, y: 600, width: 8, height: 20), bounds: bounds)
        XCTAssertNil(above.top)
        XCTAssertEqual(above.bottom, 592)
        XCTAssertEqual(above.x, 800 - 16 - 312, "kept inside the column")
        XCTAssertEqual(above.maxHeight, 516)
        let phone = MenuPlacement.make(anchor: CGRect(x: 10, y: 100, width: 8, height: 20),
                                       bounds: CGRect(x: 0, y: 0, width: 300, height: 700))
        XCTAssertEqual(phone.width, 268, "a narrow window: its width less the insets")
        XCTAssertEqual(phone.x, 16)
    }
}

