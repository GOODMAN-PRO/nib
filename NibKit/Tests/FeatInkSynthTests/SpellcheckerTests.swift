import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import FeatInkSynth

/// A dictionary of a few English words: everything else is misspelled; "teh" has guesses.
@MainActor
private final class FakeChecker: SpellingChecker {
    var known: Set<String> = ["the", "answer", "ten", "tea", "wrote", "well", "known", "student", "notes", "is"]
    var guessTable: [String: [String]] = ["teh": ["the", "ten", "tea"], "anser": ["answer"]]
    private(set) var checks = 0

    func language(for bcp47: String) -> String? { bcp47.lowercased().hasPrefix("en") ? "en_US" : nil }

    func isMisspelled(_ word: String, language: String) -> Bool {
        checks += 1
        return !known.contains(Spellchecker.withoutPossessive(word).lowercased())
    }

    func guesses(for word: String, language: String) -> [String] { guessTable[word.lowercased()] ?? [] }
}

/// Records what spellcheck asks of the window's floating host.
@MainActor
private final class FakeFloatingHost: FloatingHosting {
    private(set) var presented: [String] = []
    private(set) var anchors: [String: CGRect] = [:]
    private(set) var toasts: [String] = []

    func present(_ id: String, content: AnyView) { if !presented.contains(id) { presented.append(id) } }
    func dismiss(_ id: String) { presented.removeAll { $0 == id } }
    func isPresenting(_ id: String) -> Bool { presented.contains(id) }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        anchors[id] = rect
        return true
    }
    func removeAnchor(_ id: String) { anchors[id] = nil }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) { toasts.append(message) }
}

/// A library folder of per-device prefs files merged per key by revision, the way the Library Store keeps synced
/// settings (ARCHITECTURE §4.3): each device writes only its own file, holding the merged state it knows.
private final class PrefsFolder {
    var files: [String: [String: DevicePrefs.Entry]] = [:]
}

private final class DevicePrefs: SyncedSettingsBackend {
    struct Entry {
        var rev: Rev
        var value: JSONValue
    }

    let device: String
    let clock: HLCClock
    let folder: PrefsFolder
    private(set) var known: [String: Entry] = [:]

    init(device: String, clock: HLCClock, folder: PrefsFolder) {
        self.device = device
        self.clock = clock
        self.folder = folder
    }

    func value(_ name: String) -> JSONValue? {
        guard let e = known[name], e.value != .null else { return nil }
        return e.value
    }

    func setValue(_ name: String, _ value: JSONValue?) {
        if let current = known[name] { clock.observe(current.rev) }
        known[name] = Entry(rev: clock.tick(), value: value ?? .null)
        folder.files[device] = known
    }

    func names() -> [String] { known.filter { $0.value.value != .null }.keys.sorted() }

    /// Reads every device's file (a sync pass) and merges it in, the higher revision winning per key.
    func sync() {
        for (_, file) in folder.files {
            for (name, entry) in file {
                if let current = known[name], current.rev >= entry.rev { continue }
                known[name] = entry
                clock.observe(entry.rev)
            }
        }
        folder.files[device] = known
    }
}

@MainActor
final class SpellcheckerTests: XCTestCase {
    private var page2: String { NodeRef.page(Fixtures.docID, Fixtures.page2).description }

    private func ref(_ id: ElementID, page: PageID = Fixtures.page2) -> String {
        NodeRef.item(Fixtures.docID, page, id).description
    }

    /// A harness with both halves of the module, a fake checker and spellcheck on in the fixture notebook.
    private func makeHarness(checker: FakeChecker? = nil, spellcheck: Bool = true) async throws -> Harness {
        let h = Harness(features: [FeatInkSynthFeature.self, FeatSpellcheckFeature.self])
        SpellcheckEngine.shared(h.app).checker = checker ?? FakeChecker()
        if spellcheck {
            try await h.run(CommandIDs.docSetWritingAids, ["doc": "doc:FIXTUREDOC01", "spellcheck": true])
        }
        return h
    }

    /// Handwritten-looking words on page 2, one stroke each, left to right on one line.
    private func seedWords(_ h: Harness, _ ids: [String]) async throws -> [Item] {
        let items = ids.enumerated().map { k, id -> Item in
            let x0 = Float(80 + k * 120)
            let points = (0..<16).map { i in StrokePoint(x: x0 + Float(i) * 5, y: 200 + Float(i % 4) * 5, t: Float(i) * 0.01) }
            return Item(id: NibID(id), kind: .stroke, stroke: Stroke(style: .defaultPen, points: points))
        }
        return try await h.insert(items, page: Fixtures.page2)
    }

    /// What the recogniser reads for the seeded strokes: one line, one word per stroke.
    private func reading(_ texts: [String], _ strokes: [Item], alternatives: [String] = [],
                         confidence: Double = 1) -> TextRecognition {
        let box = strokes.map { $0.bounds }.reduce(strokes[0].bounds) { $0.union($1) }
        var line = TextRecognition(text: texts.joined(separator: " "), alternatives: alternatives, bbox: box,
                                   itemIDs: strokes.map { $0.id }, source: "ink", confidence: confidence)
        line.words = zip(texts, strokes).map { TextRecognitionWord(text: $0, bbox: $1.bounds, itemIDs: [$1.id]) }
        return line
    }

    // MARK: Words and suggestions (pure rules)

    func testTokensKeepApostrophesAndHyphensAndDropSurroundingPunctuation() {
        XCTAssertEqual(Spellchecker.token("(teh,"), SpellToken(prefix: "(", core: "teh", suffix: ","))
        XCTAssertEqual(Spellchecker.token("don’t."), SpellToken(prefix: "", core: "don't", suffix: "."))
        XCTAssertEqual(Spellchecker.token("well-known"), SpellToken(prefix: "", core: "well-known", suffix: ""))
        XCTAssertEqual(Spellchecker.token("“Hello”"), SpellToken(prefix: "“", core: "Hello", suffix: "”"))
        for notAWord in ["3rd", "x2", "a+b", "e.g.", "nib.app", "a", "DNA", "SUVAT", "---", "", "two words"] {
            XCTAssertNil(Spellchecker.token(notAWord), notAWord)
        }
        XCTAssertNotNil(Spellchecker.token("PHOTOSYNTHESIS"), "long capitals are words, not acronyms")
    }

    func testAlternativeReadingsAreMatchedToTheirWordAndUnsureLinesAreSkipped() {
        let a = RecognizedWord(text: "teh", bbox: Rect(x: 0, y: 0, width: 30, height: 20), itemIDs: ["A"])
        let b = RecognizedWord(text: "anser", bbox: Rect(x: 40, y: 0, width: 50, height: 20), itemIDs: ["B"])
        let line = RecognizedLine(text: "teh anser", bbox: Rect(x: 0, y: 0, width: 90, height: 20),
                                  alternatives: ["the answer", "tell", "teh answer"], confidence: 0.5, words: [a, b])
        let words = Spellchecker.words(from: [line])
        XCTAssertEqual(words.map { $0.alternatives }, [["the"], ["answer"]], "same-length readings only, no repeats")
        var unsure = line
        unsure.confidence = 0.1
        XCTAssertEqual(Spellchecker.words(from: [unsure]), [], "drawings read as text are not checked")
        var strokeless = line
        strokeless.words[0].itemIDs = []
        XCTAssertEqual(Spellchecker.words(from: [strokeless]).map { $0.text }, ["anser"])
    }

    func testSuggestionsPutOtherReadingsFirstMatchCaseAndKeepPunctuation() {
        let checker = FakeChecker()
        let m = Misspelling(written: "Teh,", word: "Teh", prefix: "", suffix: ",", bbox: .zero, itemIDs: ["A"],
                            alternatives: ["tea"], layer: 0)
        let suggestions = Spellchecker.suggestions(for: m, language: "en_US", dictionary: [], checker: checker)
        XCTAssertEqual(suggestions, ["Tea", "The", "Ten"])
        XCTAssertEqual(Spellchecker.replacement(suggestions[1], for: m), "The,")
        XCTAssertEqual(Spellchecker.matchingCase("there", of: "TEHRE"), "THERE")
        XCTAssertEqual(Spellchecker.matchingCase("the", of: "teh"), "the")
    }

    func testCloseDictionaryWordsAreSuggested() {
        let near = Spellchecker.nearDictionaryWords("Nibnoet", dictionary: ["nibnote", "zettel", "nib"])
        XCTAssertEqual(near, ["nibnote"], "a swap is one edit")
        XCTAssertEqual(Spellchecker.editDistance(Array("kitten"), Array("sitting"), limit: 5), 3)
        XCTAssertEqual(Spellchecker.nearDictionaryWords("abc", dictionary: ["abd"]), [], "too short to guess")
    }

    func testDocumentLanguagesMapToTheCheckersLanguages() {
        let available = ["en_US", "en_GB", "fr_FR", "de", "pt_BR", "zh_Hant"]
        XCTAssertEqual(Spellchecker.resolveLanguage("en-GB", available: available), "en_GB")
        XCTAssertEqual(Spellchecker.resolveLanguage("en-AU", available: available), "en_GB", "first region of the language")
        XCTAssertEqual(Spellchecker.resolveLanguage("de-AT", available: available), "de")
        XCTAssertEqual(Spellchecker.resolveLanguage("fr", available: available), "fr_FR")
        XCTAssertEqual(Spellchecker.resolveLanguage("zh-Hant-TW", available: available), "zh_Hant")
        XCTAssertNil(Spellchecker.resolveLanguage("ja-JP", available: available))
    }

    func testTapTargetsGrowToAComfortableSize() {
        let small = Misspelling(written: "teh", word: "teh", prefix: "", suffix: "", bbox: Rect(x: 100, y: 100, width: 20, height: 10),
                                itemIDs: ["A"], alternatives: [], layer: 0)
        XCTAssertEqual(Spellchecker.hit(Point(92, 124), ref: nil, in: [small], minimumSize: 44), small)
        XCTAssertNil(Spellchecker.hit(Point(160, 104), ref: nil, in: [small], minimumSize: 44))
        XCTAssertEqual(Spellchecker.hit(Point(400, 400), ref: "A", in: [small], minimumSize: 44), small,
                       "a tap on one of the word's strokes counts")
    }

    func testTheUnderlineIsAWaveUnderTheWord() {
        let rect = CGRect(x: 10, y: 20, width: 60, height: 18)
        let line = SpellcheckGeometry.underline(for: rect)
        XCTAssertGreaterThan(line.y, rect.maxY)
        let box = SpellcheckGeometry.squiggle(from: line.x0, to: line.x1, y: line.y).boundingBoxOfPath
        XCTAssertEqual(box.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertLessThanOrEqual(box.height, 4 * SpellcheckGeometry.amplitude + 0.01)
        XCTAssertGreaterThan(box.minY, rect.maxY, "never over the ink")
    }

    func testTheSystemCheckerFindsAMisspelling() throws {
        let checker = SystemSpellingChecker()
        guard let language = checker.language(for: "en-US") else { throw XCTSkip("no English dictionary on this system") }
        XCTAssertTrue(checker.isMisspelled("teh", language: language))
        XCTAssertFalse(checker.isMisspelled("the", language: language))
        XCTAssertTrue(checker.guesses(for: "teh", language: language).map { $0.lowercased() }.contains("the"))
        let m = Misspelling(written: "teh", word: "teh", prefix: "", suffix: "", bbox: .zero, itemIDs: ["A"],
                            alternatives: [], layer: 0)
        XCTAssertTrue(Spellchecker.suggestions(for: m, language: language, dictionary: [], checker: checker).contains("the"))
        XCTAssertFalse(Spellchecker.isMisspelled("teh", language: language, dictionary: ["teh"], checker: checker),
                       "the personal dictionary wins over the system's")
    }

    // MARK: The engine with a fake recogniser (acceptance)

    func testAMisspellingIsFoundWithAFakeRecogniser() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001", "WORDANS00001", "WORDNOT00001"])
        let recognizer = FakeRecognizer([reading(["teh", "answer", "notes."], strokes, alternatives: ["the answer notes."])])
        h.app.services.recognizer = recognizer
        let engine = SpellcheckEngine.shared(h.app)
        XCTAssertTrue(engine.needsCheck(Fixtures.docID, Fixtures.page2))

        let result = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(result.misspellings.map { $0.word }, ["teh"])
        XCTAssertEqual(result.misspellings.first?.itemIDs, [strokes[0].id])
        XCTAssertEqual(result.misspellings.first?.bbox, strokes[0].bounds)
        XCTAssertEqual(result.language, "en_US")
        XCTAssertTrue(result.isFresh)
        XCTAssertEqual(engine.suggestions(for: result.misspellings[0], documentLanguage: "en-US").first, "the",
                       "the recogniser's other reading comes first")
        XCTAssertEqual(recognizer.strokeCalls, 1)

        _ = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(recognizer.strokeCalls, 1, "an unchanged page is not recognised again")
        XCTAssertFalse(engine.needsCheck(Fixtures.docID, Fixtures.page2))
    }

    func testAPersonalDictionaryWordIsSkipped() async throws {
        let checker = FakeChecker()
        let h = try await makeHarness(checker: checker)
        let strokes = try await seedWords(h, ["WORDNIB00001", "WORDTEH00001"])
        let recognizer = FakeRecognizer([reading(["Nibnote's", "teh"], strokes)])
        h.app.services.recognizer = recognizer
        let engine = SpellcheckEngine.shared(h.app)
        let first = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(first.misspellings.map { $0.word }, ["Nibnote's", "teh"])

        let added = try await h.run(CommandIDs.dictionaryAdd, ["word": " Nibnote, "])
        XCTAssertEqual(added["word"]?.stringValue, "nibnote")
        XCTAssertEqual(added["added"]?.boolValue, true)
        let filtered = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(filtered.misspellings.map { $0.word }, ["teh"],
                       "dictionary words are skipped, whatever their case or possessive")
        XCTAssertEqual(recognizer.strokeCalls, 1, "a dictionary change re-filters without recognising again")

        try await h.run(CommandIDs.dictionaryRemove, ["word": "NIBNOTE"])
        XCTAssertEqual(engine.displayed(Fixtures.docID, Fixtures.page2)?.misspellings.map { $0.word }, ["Nibnote's", "teh"])
    }

    func testEditingAWordDropsItsUnderlineUntilThePageIsReadAgain() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001", "WORDANS00001"])
        h.app.services.recognizer = FakeRecognizer([reading(["teh", "anser"], strokes)])
        let engine = SpellcheckEngine.shared(h.app)
        let checked = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(checked.misspellings.count, 2)

        var moved = strokes[0]
        let shifted = (strokes[0].stroke?.points ?? []).map { p -> StrokePoint in
            var q = p
            q.x += 3
            return q
        }
        moved.stroke?.points = shifted
        try await h.insert([moved], page: Fixtures.page2)
        let shown = try XCTUnwrap(engine.displayed(Fixtures.docID, Fixtures.page2))
        XCTAssertEqual(shown.misspellings.map { $0.word }, ["anser"], "the edited word's underline goes at once")
        XCTAssertFalse(shown.isFresh)
        XCTAssertTrue(engine.needsCheck(Fixtures.docID, Fixtures.page2))
    }

    func testAPageInALanguageWithoutADictionaryHasNoUnderlines() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001"])
        h.app.services.recognizer = FakeRecognizer([reading(["teh"], strokes)])
        let engine = SpellcheckEngine.shared(h.app)
        let english = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertEqual(english.misspellings.count, 1)

        let setLanguage = CommandDescriptor(id: "test.setLanguage", title: "Set Language", summary: "Test helper.",
                                            effect: .edit, exposure: .ui)
        h.app.commands.register(setLanguage) { _, ctx in
            try ctx.mutate { tx in
                var meta = try tx.content(Fixtures.docID).meta
                meta.language = "ja-JP"
                try tx.putMeta(meta)
            }
            return .null
        }
        try await h.run("test.setLanguage")
        XCTAssertFalse(engine.isFresh(Fixtures.docID, Fixtures.page2), "a new language reads the page again")
        let result = try await engine.check(Fixtures.docID, Fixtures.page2)
        XCTAssertNil(result.language)
        XCTAssertEqual(result.misspellings, [])
    }

    // MARK: spellcheck.tapAt

    func testATapOnAnUnderlinedWordReturnsItsSuggestions() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001", "WORDANS00001"])
        h.app.services.recognizer = FakeRecognizer([reading(["teh,", "answer"], strokes)])
        _ = try await SpellcheckEngine.shared(h.app).check(Fixtures.docID, Fixtures.page2)
        let word = strokes[0].bounds

        let hit = try await h.run(CommandIDs.spellcheckTapAt, ["page": .string(page2), "point": [.number(word.midX), .number(word.midY)]])
        XCTAssertEqual(hit["handled"]?.boolValue, true)
        XCTAssertEqual(hit["word"]?.stringValue, "teh")
        XCTAssertEqual(hit["written"]?.stringValue, "teh,")
        XCTAssertEqual(hit["suggestions"]?.arrayValue?.compactMap { $0.stringValue }, ["the", "ten", "tea"])
        XCTAssertEqual(hit["replacements"]?.arrayValue?.compactMap { $0.stringValue }, ["the,", "ten,", "tea,"])
        XCTAssertEqual(hit["refs"]?.arrayValue?.compactMap { $0.stringValue }, [ref(strokes[0].id)])

        let miss = try await h.run(CommandIDs.spellcheckTapAt, ["page": .string(page2), "point": [400, 700]])
        XCTAssertEqual(miss["handled"]?.boolValue, false)
        let doubleTap = try await h.run(CommandIDs.spellcheckTapAt, ["page": .string(page2), "gesture": "doubleTap",
                                                                    "point": [.number(word.midX), .number(word.midY)]])
        XCTAssertEqual(doubleTap["handled"]?.boolValue, false)

        try await h.run(CommandIDs.docSetWritingAids, ["doc": "doc:FIXTUREDOC01", "spellcheck": false])
        let off = try await h.run(CommandIDs.spellcheckTapAt, ["page": .string(page2), "point": [.number(word.midX), .number(word.midY)]])
        XCTAssertEqual(off["handled"]?.boolValue, false, "spellcheck off: taps go on to selection")
    }

    func testTheAssistantGetsSuggestionsForAPageNobodyChecked() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001"])
        let recognizer = FakeRecognizer([reading(["teh"], strokes)])
        h.app.services.recognizer = recognizer
        let word = strokes[0].bounds
        let params: JSONValue = ["page": .string(page2), "point": [.number(word.midX), .number(word.midY)]]
        let asUser = try await h.run(CommandIDs.spellcheckTapAt, params)
        XCTAssertEqual(asUser["handled"]?.boolValue, false, "a user taps what is underlined, and nothing is yet")
        let asAI = try await h.run(CommandIDs.spellcheckTapAt, params, as: .ai("chat"))
        XCTAssertEqual(asAI["handled"]?.boolValue, true)
        XCTAssertEqual(asAI["replacements"]?.arrayValue?.first?.stringValue, "the")
        XCTAssertEqual(recognizer.strokeCalls, 1)
    }

    // MARK: Personal dictionary commands

    func testDictionaryCommandsValidateAndListWords() async throws {
        let h = Harness(features: [FeatSpellcheckFeature.self])
        for word in ["Zettel", "nibnote", "Quire!", "don’t"] { try await h.run(CommandIDs.dictionaryAdd, ["word": .string(word)]) }
        let again = try await h.run(CommandIDs.dictionaryAdd, ["word": "ZETTEL"])
        XCTAssertEqual(again["added"]?.boolValue, false)
        let list = try await h.run(CommandIDs.dictionaryList)
        XCTAssertEqual(list["words"]?.arrayValue?.compactMap { $0.stringValue }, ["don't", "nibnote", "quire", "zettel"])
        XCTAssertEqual(list["count"], 4)
        XCTAssertEqual(h.app.settings.names(prefix: NibSettings.dictionaryPrefix).count, 4, "one setting per word")

        let page = try await h.run(CommandIDs.dictionaryList, ["limit": 3])
        XCTAssertEqual(page["truncated"]?.boolValue, true)
        let rest = try await h.run(CommandIDs.dictionaryList, ["limit": 3, "cursor": .string(page["cursor"]?.stringValue ?? "")])
        XCTAssertEqual(rest["words"]?.arrayValue?.compactMap { $0.stringValue }, ["zettel"])
        let filtered = try await h.run(CommandIDs.dictionaryList, ["prefix": "N"])
        XCTAssertEqual(filtered["words"]?.arrayValue?.compactMap { $0.stringValue }, ["nibnote"])

        let removed = try await h.run(CommandIDs.dictionaryRemove, ["word": "Quire"])
        XCTAssertEqual(removed["removed"]?.boolValue, true)
        let missing = try await h.run(CommandIDs.dictionaryRemove, ["word": "Quire"])
        XCTAssertEqual(missing["removed"]?.boolValue, false)

        for bad in ["", "   ", "two words", "123", String(repeating: "a", count: 65)] {
            do {
                try await h.run(CommandIDs.dictionaryAdd, ["word": .string(bad)])
                XCTFail("accepted '\(bad)'")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams, bad)
                XCTAssertEqual(e.path, "$.word")
            }
        }
    }

    func testDictionaryAddAndRemoveFromTwoDevicesMerge() async throws {
        let folder = PrefsFolder()
        let a = Harness(features: [FeatSpellcheckFeature.self], deviceID: 7)
        let b = Harness(features: [FeatSpellcheckFeature.self], deviceID: 8)
        let prefsA = DevicePrefs(device: a.app.deviceHex, clock: a.app.clock, folder: folder)
        let prefsB = DevicePrefs(device: b.app.deviceHex, clock: b.app.clock, folder: folder)
        a.app.settings.syncedBackend = prefsA
        b.app.settings.syncedBackend = prefsB
        func words(_ h: Harness) async throws -> [String] {
            try await h.run(CommandIDs.dictionaryList)["words"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        }

        // Both devices add a word while apart: neither overwrites the other.
        try await a.run(CommandIDs.dictionaryAdd, ["word": "Nibnote"])
        try await b.run(CommandIDs.dictionaryAdd, ["word": "Zettel"])
        let wa1 = try await words(a)
        XCTAssertEqual(wa1, ["nibnote"])
        prefsA.sync()
        prefsB.sync()
        let wa2 = try await words(a)
        XCTAssertEqual(wa2, ["nibnote", "zettel"])
        let wb1 = try await words(b)
        XCTAssertEqual(wb1, ["nibnote", "zettel"])
        XCTAssertEqual(folder.files.count, 2, "each device writes only its own file")

        // A removal on one device and an addition on the other, while apart: both survive the merge.
        try await b.run(CommandIDs.dictionaryRemove, ["word": "nibnote"])
        try await a.run(CommandIDs.dictionaryAdd, ["word": "Quire"])
        prefsA.sync()
        prefsB.sync()
        let wa3 = try await words(a)
        XCTAssertEqual(wa3, ["quire", "zettel"])
        let wb2 = try await words(b)
        XCTAssertEqual(wb2, ["quire", "zettel"])

        // Adding it back later wins over the older removal.
        try await a.run(CommandIDs.dictionaryAdd, ["word": "Nibnote"])
        prefsA.sync()
        prefsB.sync()
        let wb3 = try await words(b)
        XCTAssertEqual(wb3, ["nibnote", "quire", "zettel"])
    }

    // MARK: doc.setWritingAids

    func testSetWritingAidsPassesTheUndoRoundTrip() async throws {
        let h = Harness(features: [FeatSpellcheckFeature.self])
        func meta() throws -> DocumentMeta { try h.app.workspace.content(Fixtures.docID).meta }
        let before = try h.snapshot()
        let r = try await h.run(CommandIDs.docSetWritingAids, ["doc": "doc:FIXTUREDOC01", "spellcheck": true, "mathAssist": true])
        XCTAssertEqual(r["changed"]?.boolValue, true)
        XCTAssertTrue(try meta().spellcheck)
        XCTAssertTrue(try meta().mathAssist)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertTrue(try meta().spellcheck)

        let same = try await h.run(CommandIDs.docSetWritingAids, ["doc": "doc:FIXTUREDOC01", "spellcheck": true])
        XCTAssertEqual(same["changed"]?.boolValue, false)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 1, "no change, no undo step")

        let fromWindow = try await h.run(CommandIDs.docSetWritingAids, ["mathAssist": false])
        XCTAssertEqual(fromWindow["doc"]?.stringValue, "doc:FIXTUREDOC01", "the user may omit doc")
        XCTAssertFalse(try meta().mathAssist)

        for bad: JSONValue in [["doc": "doc:FIXTUREDOC01"], ["doc": "doc:FIXTUREDOC02", "spellcheck": true]] {
            do {
                try await h.run(CommandIDs.docSetWritingAids, bad)
                XCTFail("accepted \(bad.jsonString())")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
    }

    func testCommandsConformWithUndoRoundTrips() async {
        let problems = await CommandConformance.check(features: [FeatSpellcheckFeature.self], owners: [FeatSpellcheckFeature.id])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsCommandsTapHandlerUnderlinesAndMenus() throws {
        let h = Harness(features: [FeatSpellcheckFeature.self])
        let effects: [String: Effect] = [CommandIDs.dictionaryAdd: .session, CommandIDs.dictionaryRemove: .session,
                                         CommandIDs.dictionaryList: .read, CommandIDs.docSetWritingAids: .edit,
                                         CommandIDs.spellcheckTapAt: .session]
        for (id, effect) in effects {
            let d = try XCTUnwrap(h.app.commands.descriptor(id), id)
            XCTAssertEqual(d.owner, FeatSpellcheckFeature.id)
            XCTAssertEqual(d.effect, effect, id)
            XCTAssertFalse(d.examples.isEmpty, id)
        }
        XCTAssertTrue(try XCTUnwrap(h.app.commands.descriptor(CommandIDs.dictionaryRemove)).destructive)
        let tap = try XCTUnwrap(h.app.content.tapHandlers.get("spellcheck.tapAt"))
        XCTAssertEqual(tap.command, CommandIDs.spellcheckTapAt)
        XCTAssertEqual(tap.gesture, .tap)
        XCTAssertTrue(tap.order > 300 && tap.order < 400, "after links, before selection")
        XCTAssertNotNil(h.app.ui.canvasAttachments.get(SpellcheckUnderlines.id))

        let context = MenuContext(app: h.app, session: h.session, doc: Fixtures.docID)
        let items = h.app.ui.menuItems(.documentMore, context).filter { $0.owner == FeatSpellcheckFeature.id }
        XCTAssertEqual(items.map { $0.id }, ["spellcheck.menu.spellcheck", "spellcheck.menu.mathAssist"])
        XCTAssertEqual(items[0].isChecked?(context), false)
        XCTAssertEqual(items[0].params(context), ["doc": "doc:FIXTUREDOC01", "spellcheck": true])
        let textDocument = MenuContext(app: h.app, session: h.session, doc: Fixtures.textDocID)
        XCTAssertTrue(h.app.ui.menuItems(.documentMore, textDocument).filter { $0.owner == FeatSpellcheckFeature.id }.isEmpty)
    }

    // MARK: Underlines and the suggestions popover

    func testUnderlinesDrawTapBudsSuggestionsAndAReplacementClearsThem() async throws {
        let h = try await makeHarness()
        let strokes = try await seedWords(h, ["WORDTEH00001", "WORDANS00001"])
        let recognizer = FakeRecognizer([reading(["teh", "answer"], strokes)])
        h.app.services.recognizer = recognizer
        let floating = FakeFloatingHost()
        h.session.floatingHost = floating
        let host = FakeCanvasHost(h)
        let underlines = SpellcheckUnderlines()
        underlines.attach(to: host)
        defer { underlines.detach(from: host) }

        XCTAssertTrue(underlines.visiblePages().contains(Fixtures.page2))
        await underlines.checkVisiblePages()
        underlines.redraw(force: true)
        let path = try XCTUnwrap(underlines.drawnPages[Fixtures.page2], "the misspelled word is underlined")
        let wordRect = SpellcheckGeometry.viewRect(strokes[0].bounds, page: Fixtures.page2, host: host)
        XCTAssertEqual(path.boundingBoxOfPath.minX, wordRect.minX, accuracy: 0.5)
        XCTAssertGreaterThan(path.boundingBoxOfPath.minY, wordRect.maxY)
        XCTAssertEqual(underlines.accessibilityWords.count, 1)
        XCTAssertEqual(underlines.accessibilityWords.first?.accessibilityLabel, "Misspelled: teh")

        // A finger tap on the word runs the tap handler, which buds the popover from the word.
        let word = strokes[0].bounds
        let tap = try await h.run(CommandIDs.spellcheckTapAt, ["page": .string(page2), "point": [.number(word.midX), .number(word.midY)]])
        XCTAssertEqual(tap["handled"]?.boolValue, true)
        XCTAssertTrue(floating.isPresenting(SpellcheckUI.popoverID))
        XCTAssertEqual(floating.anchors[SpellcheckUI.sourceID], wordRect)
        XCTAssertTrue(underlines.isPresentingSuggestions)

        // Choosing "the" rewrites the word as ink (one undo step); its underline and the popover go.
        let replaced = try await h.run(CommandIDs.handwritingReplaceWord,
                                       ["refs": [.string(ref(strokes[0].id))], "text": .string(tap["replacements"]?.arrayValue?.first?.stringValue ?? "")])
        XCTAssertFalse(replaced["refs"]?.arrayValue?.isEmpty ?? true)
        XCTAssertNil(underlines.drawnPages[Fixtures.page2])
        XCTAssertFalse(underlines.isPresentingSuggestions)

        // Undo brings the misspelled word back, and the next check underlines it again.
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        await underlines.checkVisiblePages()
        XCTAssertNotNil(underlines.drawnPages[Fixtures.page2])

        // Read-only windows and hidden layers show no underlines.
        h.session.readOnly = true
        underlines.redraw(force: true)
        XCTAssertTrue(underlines.drawnPages.isEmpty)
        h.session.readOnly = false
        h.session.hiddenLayers = [0]
        underlines.redraw(force: true)
        XCTAssertTrue(underlines.drawnPages.isEmpty)
    }

    func testTheSuggestionsPopoverRendersInEveryVariant() {
        let state = SpellcheckPopoverState()
        state.isPresented = true
        let model = SpellcheckSuggestionsModel(word: "teh,", languageName: Spellchecker.languageName("en-GB"),
                                               suggestions: ["the", "ten", "tea"], placement: .below,
                                               replace: { _ in }, addToDictionary: {}, turnOff: {})
        let images = NibSnapshot.images(SpellcheckSuggestionsPopover(state: state, model: model),
                                        size: CGSize(width: 480, height: 480))
        XCTAssertEqual(Set(images.keys), Set(NibSnapshot.Variant.allCases))
        let empty = SpellcheckSuggestionsModel(word: "qwxz", languageName: "English", suggestions: [], placement: .above,
                                               replace: { _ in }, addToDictionary: {}, turnOff: {})
        XCTAssertNotNil(NibSnapshot.image(SpellcheckSuggestionsPopover(state: state, model: empty),
                                          size: CGSize(width: 393, height: 600), variant: .largeText))
    }
}
