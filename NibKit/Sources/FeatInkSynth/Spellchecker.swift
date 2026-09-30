import Foundation
import UIKit
import os
import NibContracts

// Handwriting spellcheck (F104: T-043, S-032, S-033). Recognised words (`recognize.items`, else the recogniser
// directly) are checked with `UITextChecker` in the document's language, minus the personal dictionary (one synced
// setting per word, `NibSettings.dictionaryWord`). This file holds the pure rules (`Spellchecker`), the system
// checker behind a small protocol (so tests use a fake), and the per-app engine that caches results per page and
// keeps them current as ink, the document's language or the dictionary change.

// MARK: - Model

/// One recognised line as `recognize.items` returns it (page coordinates).
struct RecognizedLine: Equatable {
    var text: String
    var bbox: Rect
    var alternatives: [String]
    var confidence: Double
    var words: [RecognizedWord]
}

/// One recognised handwritten word: its text as read, where it is, the strokes it came from and what the other
/// readings of its line had in its place.
struct RecognizedWord: Equatable {
    var text: String
    var bbox: Rect
    var itemIDs: [ElementID]
    /// The same word in the line's alternative readings (only when an alternative has as many words).
    var alternatives: [String] = []
    /// Lowest layer of its strokes (words on hidden layers are not underlined).
    var layer: Int = 0
}

/// A recognised word split into what is checked and the punctuation around it ("(teh," → "(", "teh", ",").
struct SpellToken: Equatable {
    var prefix: String
    var core: String
    var suffix: String
}

/// A handwritten word that is not in the dictionary.
struct Misspelling: Equatable {
    /// The word as recognised, punctuation included ("teh,").
    var written: String
    /// The part that was checked ("teh").
    var word: String
    var prefix: String
    var suffix: String
    var bbox: Rect
    var itemIDs: [ElementID]
    var alternatives: [String]
    var layer: Int

    /// Stable identity on its page (the strokes it covers).
    var key: String { itemIDs.map { $0.raw }.sorted().joined(separator: ",") }
}

/// The spellcheck state of one page.
struct PageSpelling: Equatable {
    var doc: DocumentID
    var page: PageID
    /// BCP-47 language of the document (what recognition and the dictionary lookup used).
    var documentLanguage: String
    /// The checker's language for it; nil when the system has no dictionary for that language.
    var language: String?
    var misspellings: [Misspelling]
    /// False while the page changed since it was checked (the underlines still show the last result).
    var isFresh: Bool
}

// MARK: - The checker

/// What spellcheck needs from a dictionary. `SystemSpellingChecker` is `UITextChecker`; tests inject a fake.
@MainActor
protocol SpellingChecker: AnyObject {
    /// The checker's language for a BCP-47 tag ("en-GB" → "en_GB"), nil when it has none.
    func language(for bcp47: String) -> String?
    func isMisspelled(_ word: String, language: String) -> Bool
    func guesses(for word: String, language: String) -> [String]
}

/// `UITextChecker` with a small per-word cache (checking a page re-checks the same words after every edit).
@MainActor
final class SystemSpellingChecker: SpellingChecker {
    private let checker = UITextChecker()
    private var verdicts: [String: Bool] = [:]
    private var available: [String]?
    static let cacheLimit = 8000

    func language(for bcp47: String) -> String? {
        if available == nil { available = UITextChecker.availableLanguages }
        return Spellchecker.resolveLanguage(bcp47, available: available ?? [])
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        let key = language + "|" + word
        if let known = verdicts[key] { return known }
        let length = (word as NSString).length
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: length), startingAt: 0,
                                                  wrap: false, language: language)
        let result = range.location != NSNotFound
        if verdicts.count >= SystemSpellingChecker.cacheLimit { verdicts.removeAll(keepingCapacity: true) }
        verdicts[key] = result
        return result
    }

    func guesses(for word: String, language: String) -> [String] {
        let length = (word as NSString).length
        return checker.guesses(forWordRange: NSRange(location: 0, length: length), in: word, language: language) ?? []
    }
}

// MARK: - Rules

/// The pure rules of handwriting spellcheck: what counts as a word, what is misspelled, what to suggest and where a
/// tap lands.
enum Spellchecker {
    /// Lines Vision is this unsure of are usually drawings, arrows or maths: they are not checked.
    static let minimumLineConfidence = 0.25
    /// Suggestions shown for one word.
    static let suggestionLimit = 5
    /// Longest personal-dictionary word (a setting key per word).
    static let maximumWordLength = 64

    // MARK: Words

    /// Curly apostrophes and quotes as their straight forms, so "don’t" and "don't" are one word.
    static func normaliseApostrophes(_ s: String) -> String {
        var out = s
        for curly in ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{FF07}"] { out = out.replacingOccurrences(of: curly, with: "'") }
        return out
    }

    /// The checkable part of a recognised word, or nil for things that are not words: numbers ("3rd", "x2"),
    /// formulas and links ("a+b", "e.g", "nib.app"), single letters and short all-capital acronyms ("DNA", "SUVAT").
    static func token(_ raw: String) -> SpellToken? {
        let text = normaliseApostrophes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNumber }) else { return nil }
        let chars = Array(text)
        var start = 0
        var end = chars.count
        while start < end, !chars[start].isLetter { start += 1 }
        while end > start, !chars[end - 1].isLetter { end -= 1 }
        guard start < end else { return nil }
        let core = String(chars[start..<end])
        guard core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }
        let letters = core.filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }
        if letters.count <= 5, letters.allSatisfy({ $0.isUppercase }) { return nil }
        return SpellToken(prefix: String(chars[0..<start]), core: core, suffix: String(chars[end...]))
    }

    /// How a word is stored in the personal dictionary (and compared with it): straight apostrophes, lower case.
    static func dictionaryKey(_ word: String) -> String {
        normaliseApostrophes(word).lowercased()
    }

    /// "student's" → "student", "students'" → "students".
    static func withoutPossessive(_ word: String) -> String {
        if word.count > 2, word.lowercased().hasSuffix("'s") { return String(word.dropLast(2)) }
        if word.count > 1, word.hasSuffix("'") { return String(word.dropLast()) }
        return word
    }

    /// True when the dictionary has the word (or its possessive-free form).
    static func inDictionary(_ word: String, _ dictionary: Set<String>) -> Bool {
        guard !dictionary.isEmpty else { return false }
        return dictionary.contains(dictionaryKey(word)) || dictionary.contains(dictionaryKey(withoutPossessive(word)))
    }

    /// A token is misspelled when the checker rejects one of its hyphen-separated parts that the personal dictionary
    /// does not have.
    @MainActor
    static func isMisspelled(_ core: String, language: String, dictionary: Set<String>, checker: SpellingChecker) -> Bool {
        if inDictionary(core, dictionary) { return false }
        for part in core.split(separator: "-").map(String.init) where !part.isEmpty {
            if inDictionary(part, dictionary) { continue }
            let bare = withoutPossessive(part)
            guard bare.filter({ $0.isLetter }).count >= 2 else { continue }
            if checker.isMisspelled(part, language: language) { return true }
        }
        return false
    }

    /// Words of recognised lines, each with its alternative readings. Unsure lines and words without strokes are
    /// left out.
    static func words(from lines: [RecognizedLine]) -> [RecognizedWord] {
        var out: [RecognizedWord] = []
        for line in lines where line.confidence >= minimumLineConfidence {
            let alternativeWords = line.alternatives
                .map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                .filter { $0.count == line.words.count }
            for (i, word) in line.words.enumerated() where !word.itemIDs.isEmpty {
                var w = word
                var seen = Set([dictionaryKey(word.text)])
                w.alternatives = alternativeWords.compactMap { alt -> String? in
                    let a = alt[i]
                    return seen.insert(dictionaryKey(a)).inserted ? a : nil
                }
                out.append(w)
            }
        }
        return out
    }

    /// The misspelled words, in reading order.
    @MainActor
    static func misspellings(in words: [RecognizedWord], language: String, dictionary: Set<String>,
                             checker: SpellingChecker) -> [Misspelling] {
        words.compactMap { w -> Misspelling? in
            guard let t = token(w.text),
                  isMisspelled(t.core, language: language, dictionary: dictionary, checker: checker) else { return nil }
            return Misspelling(written: w.text, word: t.core, prefix: t.prefix, suffix: t.suffix, bbox: w.bbox,
                               itemIDs: w.itemIDs, alternatives: w.alternatives, layer: w.layer)
        }
    }

    /// Corrections for a misspelled word, best first: the recogniser's other readings that are spelled correctly
    /// (the ink may simply have been misread), close personal-dictionary words, then the checker's guesses. Matches
    /// the word's capitalisation.
    @MainActor
    static func suggestions(for m: Misspelling, language: String, dictionary: Set<String>, checker: SpellingChecker,
                            limit: Int = suggestionLimit) -> [String] {
        var out: [String] = []
        var seen = Set([dictionaryKey(m.word)])
        func add(_ s: String) {
            let w = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, out.count < limit, seen.insert(dictionaryKey(w)).inserted else { return }
            out.append(matchingCase(w, of: m.word))
        }
        for alt in m.alternatives {
            if let t = token(alt), !isMisspelled(t.core, language: language, dictionary: dictionary, checker: checker) {
                add(t.core)
            }
        }
        for word in nearDictionaryWords(m.word, dictionary: dictionary) { add(word) }
        for guess in checker.guesses(for: m.word, language: language) { add(guess) }
        return out
    }

    /// Personal-dictionary words one or two edits away, closest first ("Nibnoet" → "nibnote").
    static func nearDictionaryWords(_ word: String, dictionary: Set<String>, limit: Int = 2) -> [String] {
        let key = Array(dictionaryKey(word))
        guard key.count >= 4, !dictionary.isEmpty else { return [] }
        let maximum = key.count >= 8 ? 2 : 1
        var found: [(word: String, distance: Int)] = []
        for entry in dictionary {
            let e = Array(entry)
            guard abs(e.count - key.count) <= maximum else { continue }
            let d = editDistance(key, e, limit: maximum)
            if d > 0 && d <= maximum { found.append((entry, d)) }
        }
        return found.sorted { ($0.distance, $0.word) < ($1.distance, $1.word) }.prefix(limit).map { $0.word }
    }

    /// Optimal-string-alignment distance (adjacent swaps count once), cut off above `limit`.
    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, previous2[j - 2] + 1) }
                current[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            previous2 = previous
            previous = current
        }
        return previous[b.count]
    }

    /// "the" written as "Teh" suggests "The"; "TEHRE" suggests "THERE".
    static func matchingCase(_ suggestion: String, of word: String) -> String {
        let letters = word.filter { $0.isLetter }
        guard let first = letters.first else { return suggestion }
        if letters.count > 1, letters.allSatisfy({ $0.isUppercase }) { return suggestion.uppercased() }
        if first.isUppercase, let s = suggestion.first, s.isLowercase {
            return String(s).uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }

    /// What `handwriting.replaceWord` writes for a suggestion: the punctuation that was around the word stays.
    static func replacement(_ suggestion: String, for m: Misspelling) -> String {
        m.prefix + suggestion + m.suffix
    }

    // MARK: Languages

    /// The checker language for a BCP-47 tag: an exact match ("en-GB" → "en_GB"), else the language alone ("en"),
    /// else the first region of that language the system has; nil when it has none.
    static func resolveLanguage(_ bcp47: String, available: [String]) -> String? {
        let tag = bcp47.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_")
        guard !tag.isEmpty else { return nil }
        if let exact = available.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return exact }
        let parts = tag.split(separator: "_").map(String.init)
        let language = parts[0].lowercased()
        // "zh_Hant_TW" style: language plus script.
        if parts.count > 2, let scripted = available.first(where: {
            $0.caseInsensitiveCompare(parts[0] + "_" + parts[1]) == .orderedSame }) {
            return scripted
        }
        if let bare = available.first(where: { $0.lowercased() == language }) { return bare }
        return available.filter { $0.lowercased().hasPrefix(language + "_") }.sorted().first
    }

    /// "English (United Kingdom)" for "en-GB", in the user's language.
    static func languageName(_ bcp47: String) -> String {
        Locale.current.localizedString(forIdentifier: bcp47) ?? bcp47
    }

    // MARK: Hit testing

    /// The misspelling a tap at `point` (page points) means: one whose box, grown to a comfortable target and down
    /// over its underline, holds the point (the closest centre wins), else the one covering the tapped stroke.
    static func hit(_ point: Point, ref: ElementID?, in misspellings: [Misspelling], minimumSize: Double) -> Misspelling? {
        let targets = misspellings.filter { target($0.bbox, minimumSize: minimumSize).contains(point) }
        if let best = targets.min(by: { $0.bbox.center.distance(to: point) < $1.bbox.center.distance(to: point) }) {
            return best
        }
        guard let ref = ref else { return nil }
        return misspellings.first { $0.itemIDs.contains(ref) }
    }

    /// A word's tap target: its box grown by a fifth of its height (more below, where the underline is), and to at
    /// least `minimumSize` in each direction.
    static func target(_ bbox: Rect, minimumSize: Double) -> Rect {
        let pad = max(2, bbox.height * 0.2)
        var r = Rect(x: bbox.x - pad, y: bbox.y - pad, width: bbox.width + 2 * pad, height: bbox.height + 3 * pad)
        if r.width < minimumSize {
            r.x -= (minimumSize - r.width) / 2
            r.width = minimumSize
        }
        if r.height < minimumSize {
            r.y -= (minimumSize - r.height) / 2
            r.height = minimumSize
        }
        return r
    }

    // MARK: Recognition results

    private struct ItemsOutput: Decodable {
        struct Word: Decodable {
            var text: String
            var bbox: Rect
            var refs: [String]?
        }
        struct Line: Decodable {
            var text: String
            var bbox: Rect
            var alternatives: [String]?
            var confidence: Double?
            var words: [Word]?
        }
        var lines: [Line]
    }

    /// Lines of a `recognize.items` result ({text, lines:[{text, bbox, alternatives, confidence, words:[{text, bbox,
    /// refs}]}]}).
    static func lines(fromRecognizeItems value: JSONValue) throws -> [RecognizedLine] {
        let out = try value.decode(ItemsOutput.self)
        return out.lines.map { line in
            let words = (line.words ?? []).map { w -> RecognizedWord in
                let ids = (w.refs ?? []).compactMap { ref -> ElementID? in
                    if case let .item(_, _, id)? = NodeRef(ref) { return id }
                    return nil
                }
                return RecognizedWord(text: w.text, bbox: w.bbox, itemIDs: ids)
            }
            return RecognizedLine(text: line.text, bbox: line.bbox, alternatives: line.alternatives ?? [],
                                  confidence: line.confidence ?? 1, words: words)
        }
    }

    /// Lines straight from a `TextRecognizer` (when `recognize.items` is not installed). A line without word boxes
    /// is split by character count, and each part takes the strokes over it.
    static func lines(from results: [TextRecognition], strokes: [Item]) -> [RecognizedLine] {
        let bounds = Dictionary(strokes.map { ($0.id, $0.bounds) }, uniquingKeysWith: { a, _ in a })
        return results.map { r -> RecognizedLine in
            let words: [RecognizedWord]
            if let given = r.words, !given.isEmpty {
                words = given.map { RecognizedWord(text: $0.text, bbox: $0.bbox, itemIDs: $0.itemIDs) }
            } else {
                words = approximateWords(r, bounds: bounds)
            }
            return RecognizedLine(text: r.text, bbox: r.bbox, alternatives: r.alternatives, confidence: r.confidence,
                                  words: words)
        }
    }

    static func approximateWords(_ line: TextRecognition, bounds: [ElementID: Rect]) -> [RecognizedWord] {
        let parts = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty, line.bbox.width > 0 else { return [] }
        let units = Double(parts.reduce(0) { $0 + $1.count } + parts.count - 1)
        var x = line.bbox.minX
        var out: [RecognizedWord] = []
        for part in parts {
            let w = line.bbox.width * Double(part.count) / units
            let box = Rect(x: x, y: line.bbox.y, width: w, height: line.bbox.height)
            let ids = line.itemIDs.filter { id in
                guard let b = bounds[id] else { return false }
                return b.midX >= box.minX && b.midX <= box.maxX
            }
            out.append(RecognizedWord(text: part, bbox: box, itemIDs: ids))
            x += w + line.bbox.width / units
        }
        return out
    }
}

// MARK: - Engine

/// Spellcheck results per page, for the underlines (`SpellcheckUnderlines`), taps (`spellcheck.tapAt`) and the
/// dictionary commands. One per app (a service). Recognition runs only when asked (visible pages, a tap by the AI);
/// ink, language and dictionary changes are followed through commit observation and settings notifications, so
/// asking whether a page is current is cheap (the canvas asks on every scroll).
@MainActor
final class SpellcheckEngine {
    static let serviceKey = "spellcheck.engine"
    /// Pages whose results are kept.
    static let pageLimit = 200

    /// Runs `recognize.items {refs}` (inside a command: `ctx.execute`, so the caller's principal applies).
    typealias RecognitionRunner = @MainActor (_ refs: [String]) async throws -> JSONValue

    struct PageKey: Hashable {
        let doc: DocumentID
        let page: PageID
    }

    /// What changed: a page, a whole document (language, spellcheck switched), or everything (the dictionary).
    struct Change {
        var doc: DocumentID?
        var page: PageID?
        /// False when only freshness changed (new ink next to the words, nothing underlined moved): the underlines
        /// stay as drawn and only a check is scheduled, so writing never redraws them inside the stroke commit.
        var redraw = true
    }

    private final class PageState {
        var words: [RecognizedWord] = []
        var documentLanguage = ""
        var language: String?
        var misspellings: [Misspelling] = []
        /// Content generation the words were read at.
        var generation = 0
        /// Dictionary generation `misspellings` were filtered with.
        var dictionaryGeneration = -1
    }

    private weak var app: NibApp?
    var checker: SpellingChecker
    private var pages: [PageKey: PageState] = [:]
    private var order: [PageKey] = []
    private var generations: [PageKey: Int] = [:]
    private var failed: [PageKey: Int] = [:]
    private var inFlight: [PageKey: Task<PageSpelling, Error>] = [:]
    private var dictionaryCache: Set<String>?
    private(set) var dictionaryGeneration = 0
    private var observers: [UUID: @MainActor (Change) -> Void] = [:]
    private var subscription: EventSubscription?
    private var settingsToken: NSObjectProtocol?
    private static let log = Logger(subsystem: "app.nib", category: "spellcheck")

    /// The app's engine, made on first use (never in `register`).
    static func shared(_ app: NibApp) -> SpellcheckEngine {
        if let engine = app.services.get(serviceKey, as: SpellcheckEngine.self) { return engine }
        let engine = SpellcheckEngine(app: app)
        app.services.set(engine, for: serviceKey)
        return engine
    }

    /// The engine if one was made (commands that only need to tell it about a change).
    static func existing(_ app: NibApp?) -> SpellcheckEngine? {
        app?.services.get(serviceKey, as: SpellcheckEngine.self)
    }

    init(app: NibApp, checker: SpellingChecker? = nil) {
        self.app = app
        self.checker = checker ?? SystemSpellingChecker()
        subscription = app.bus.observeCommits { [weak self] cs in self?.committed(cs) }
        settingsToken = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: app.settings,
                                                               queue: nil) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix(NibSettings.dictionaryPrefix) else { return }
            Task { @MainActor in self?.dictionaryDidChange() }
        }
    }

    deinit {
        if let token = settingsToken { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: Observing

    /// Calls `handler` after every change until the returned observation is cancelled.
    func observe(_ handler: @escaping @MainActor (Change) -> Void) -> Observation {
        let id = UUID()
        observers[id] = handler
        return Observation { [weak self] in self?.observers[id] = nil }
    }

    @MainActor
    final class Observation {
        private var onCancel: (() -> Void)?
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() {
            onCancel?()
            onCancel = nil
        }
    }

    private func notify(_ change: Change) {
        for handler in Array(observers.values) { handler(change) }
    }

    // MARK: Queries

    /// True when the document has handwriting spellcheck on (notebooks and whiteboards only).
    func isEnabled(_ doc: DocumentID) -> Bool {
        guard let meta = try? app?.workspace.content(doc).meta else { return false }
        return meta.spellcheck && SpellcheckEngine.supports(meta.kind)
    }

    static func supports(_ kind: DocumentKind) -> Bool { kind == .notebook || kind == .whiteboard }

    /// What the page shows now (possibly from before its latest edit), nil when it was never checked.
    func displayed(_ doc: DocumentID, _ page: PageID) -> PageSpelling? {
        let key = PageKey(doc: doc, page: page)
        guard let state = pages[key] else { return nil }
        if state.dictionaryGeneration != dictionaryGeneration { refilter(state) }
        return spelling(key, state)
    }

    /// True when the page was checked since its ink and its document's language last changed.
    func isFresh(_ doc: DocumentID, _ page: PageID) -> Bool {
        let key = PageKey(doc: doc, page: page)
        guard let state = pages[key] else { return false }
        return state.generation == generations[key, default: 0] && state.documentLanguage == documentLanguage(doc)
    }

    /// True when the page should be (re)checked: stale, not being checked, and it did not just fail.
    func needsCheck(_ doc: DocumentID, _ page: PageID) -> Bool {
        let key = PageKey(doc: doc, page: page)
        guard inFlight[key] == nil, !isFresh(doc, page) else { return false }
        return failed[key] != generations[key, default: 0]
    }

    /// Pages of a document that have results (the underlines only look at these, not at every page).
    func checkedPages(_ doc: DocumentID) -> [PageID] {
        order.filter { $0.doc == doc && pages[$0] != nil }.map { $0.page }
    }

    /// True while the page is being recognised (`check` then waits for that run).
    func isChecking(_ doc: DocumentID, _ page: PageID) -> Bool {
        inFlight[PageKey(doc: doc, page: page)] != nil
    }

    /// Corrections for a misspelling on a page checked in `documentLanguage`.
    func suggestions(for m: Misspelling, documentLanguage: String) -> [String] {
        guard let language = checker.language(for: documentLanguage) else { return [] }
        return Spellchecker.suggestions(for: m, language: language, dictionary: dictionary(), checker: checker)
    }

    /// The personal dictionary (lower-case words), read once per change.
    func dictionary() -> Set<String> {
        if let cached = dictionaryCache { return cached }
        guard let settings = app?.settings else { return [] }
        let words = PersonalDictionary.words(settings)
        dictionaryCache = Set(words)
        return dictionaryCache ?? []
    }

    // MARK: Checking

    /// Checks a page (recognising its handwriting when its ink changed) and returns the result. Concurrent calls
    /// for one page share one run.
    @discardableResult
    func check(_ doc: DocumentID, _ page: PageID, runner: RecognitionRunner? = nil) async throws -> PageSpelling {
        let key = PageKey(doc: doc, page: page)
        if isFresh(doc, page), let state = pages[key] {
            if state.dictionaryGeneration != dictionaryGeneration { refilter(state) }
            return spelling(key, state)
        }
        if let running = inFlight[key] { return try await running.value }
        // A failure is remembered for the ink it read, so an edit meanwhile (a stroke erased while recognition ran)
        // makes the page checkable again.
        let generation = generations[key, default: 0]
        let task = Task { @MainActor [weak self] () throws -> PageSpelling in
            guard let self = self else { throw CancellationError() }
            defer { self.inFlight[key] = nil }
            do {
                return try await self.run(key, runner: runner)
            } catch {
                self.failed[key] = generation
                throw error
            }
        }
        inFlight[key] = task
        return try await task.value
    }

    private func run(_ key: PageKey, runner: RecognitionRunner?) async throws -> PageSpelling {
        guard let app = app else { throw NibError.unavailable("the app") }
        let generation = generations[key, default: 0]
        let content = try app.workspace.content(key.doc)
        guard let record = content.page(key.page), !record.deleted else {
            throw NibError.notFound("page \(key.page.raw) in document \(key.doc.raw)")
        }
        let strokes = try SpellcheckEngine.handwriting(app.workspace.items(key.doc, page: key.page))
        let revs = Dictionary(strokes.map { ($0.id, $0.rev) }, uniquingKeysWith: { a, _ in a })
        let layers = Dictionary(strokes.map { ($0.id, $0.layer) }, uniquingKeysWith: { a, _ in a })
        let lines = strokes.isEmpty ? [] : try await recognise(strokes, key: key, language: content.meta.language,
                                                                runner: runner)
        // Ink edited while recognition ran: its words are left out until the next check reads them again.
        let now = Dictionary(((try? app.workspace.items(key.doc, page: key.page)) ?? []).map { ($0.id, $0.rev) },
                             uniquingKeysWith: { a, _ in a })
        let state = PageState()
        state.words = Spellchecker.words(from: lines).compactMap { word -> RecognizedWord? in
            guard word.itemIDs.allSatisfy({ revs[$0] != nil && now[$0] == revs[$0] }) else { return nil }
            var w = word
            w.layer = word.itemIDs.compactMap { layers[$0] }.min() ?? 0
            return w
        }
        state.generation = generation
        state.documentLanguage = content.meta.language
        refilter(state)
        store(key, state)
        failed[key] = nil
        notify(Change(doc: key.doc, page: key.page))
        return spelling(key, state)
    }

    /// Handwriting on a page: live pen and pencil strokes.
    static func handwriting(_ items: [Item]) -> [Item] {
        items.filter { item in
            guard !item.deleted, item.kind == .stroke, let s = item.stroke, !s.points.isEmpty else { return false }
            return s.style.tool == .pen || s.style.tool == .pencil
        }
    }

    private func recognise(_ strokes: [Item], key: PageKey, language: String,
                           runner: RecognitionRunner?) async throws -> [RecognizedLine] {
        guard let app = app else { return [] }
        if app.commands.entry(CommandIDs.recognizeItems) != nil {
            let refs = strokes.map { NodeRef.item(key.doc, key.page, $0.id).description }
            do {
                let value: JSONValue
                if let runner = runner {
                    value = try await runner(refs)
                } else {
                    value = try await app.bus.execute(CommandIDs.recognizeItems,
                                                      ["refs": .array(refs.map { JSONValue.string($0) })])
                }
                return try Spellchecker.lines(fromRecognizeItems: value)
            } catch let e as NibError where e.code == .unavailable {
                // The index is not ready: ask the recogniser directly below.
                SpellcheckEngine.log.debug("recognize.items unavailable, using the recogniser: \(e.message, privacy: .public)")
            }
        }
        guard let recognizer = app.services.recognizer else { throw NibError.unavailable("handwriting recognition") }
        let results = try await recognizer.recognize(strokes: strokes, language: language)
        return Spellchecker.lines(from: results, strokes: strokes)
    }

    private func refilter(_ state: PageState) {
        state.language = checker.language(for: state.documentLanguage)
        if let language = state.language {
            state.misspellings = Spellchecker.misspellings(in: state.words, language: language, dictionary: dictionary(),
                                                           checker: checker)
        } else {
            state.misspellings = []
        }
        state.dictionaryGeneration = dictionaryGeneration
    }

    private func spelling(_ key: PageKey, _ state: PageState) -> PageSpelling {
        PageSpelling(doc: key.doc, page: key.page, documentLanguage: state.documentLanguage, language: state.language,
                     misspellings: state.misspellings, isFresh: isFresh(key.doc, key.page))
    }

    private func store(_ key: PageKey, _ state: PageState) {
        if pages[key] == nil { order.append(key) }
        pages[key] = state
        while order.count > SpellcheckEngine.pageLimit {
            let old = order.removeFirst()
            pages[old] = nil
            generations[old] = nil
            failed[old] = nil
        }
    }

    private func documentLanguage(_ doc: DocumentID) -> String? {
        try? app?.workspace.content(doc).meta.language
    }

    // MARK: Changes

    /// The personal dictionary changed (this device, a command, or another device through sync): refilter every
    /// checked page without recognising anything again.
    func dictionaryDidChange() {
        dictionaryCache = nil
        dictionaryGeneration += 1
        notify(Change(doc: nil, page: nil))
    }

    private func committed(_ cs: Changeset) {
        var changedPages: [PageKey: Set<ElementID>] = [:]
        var changedDocs = Set<DocumentID>()
        var deletedPages = Set<PageKey>()
        for m in cs.mutations {
            switch m {
            case let .item(doc, page, before, after):
                let ink = after.kind == .stroke || before?.kind == .stroke
                guard ink else { continue }
                changedPages[PageKey(doc: doc, page: page), default: []].insert(after.id)
            case let .meta(doc, before, after):
                if before.language != after.language {
                    // Recognition itself depends on the language: every checked page of the document is read again.
                    for key in order where key.doc == doc { generations[key, default: 0] += 1 }
                }
                if before.language != after.language || before.spellcheck != after.spellcheck || before.kind != after.kind {
                    changedDocs.insert(doc)
                }
            case let .page(doc, _, after):
                if after.deleted {
                    let key = PageKey(doc: doc, page: after.id)
                    pages[key] = nil
                    order.removeAll { $0 == key }
                    deletedPages.insert(key)
                }
            default:
                continue
            }
        }
        for (key, ids) in changedPages where !deletedPages.contains(key) {
            generations[key, default: 0] += 1
            // Words whose strokes changed lose their underline now; the rest keep theirs until the page is read again.
            var removed = false
            if let state = pages[key] {
                let before = state.misspellings.count
                state.words.removeAll { !Set($0.itemIDs).isDisjoint(with: ids) }
                state.misspellings.removeAll { !Set($0.itemIDs).isDisjoint(with: ids) }
                removed = state.misspellings.count != before
            }
            notify(Change(doc: key.doc, page: key.page, redraw: removed))
        }
        for key in deletedPages {
            generations[key] = nil
            failed[key] = nil
            notify(Change(doc: key.doc, page: key.page))
        }
        for doc in changedDocs { notify(Change(doc: doc, page: nil)) }
    }
}

// MARK: - Personal dictionary

/// The personal dictionary is one synced setting per word ("writing.dictionary.<word>" = true; removed = null), so
/// words added on two devices merge (ARCHITECTURE §4.3).
enum PersonalDictionary {
    /// A word as the dictionary stores it, or `invalid_params`: surrounding punctuation and spaces trimmed, one word
    /// (no spaces), at most 64 characters, at least one letter.
    static func normalise(_ raw: String, path: String = "$.word") throws -> String {
        let text = Spellchecker.normaliseApostrophes(raw.precomposedStringWithCanonicalMapping)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)
            .subtracting(CharacterSet(charactersIn: "'")).union(.whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        guard !trimmed.isEmpty, trimmed.contains(where: { $0.isLetter }) else {
            throw NibError(.invalidParams, "the word is empty or has no letters", path: path,
                           hint: "pass one word, such as \"Nibnote\"")
        }
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            throw NibError(.invalidParams, "add one word at a time (no spaces)", path: path,
                           hint: "call dictionary.add once for each word")
        }
        guard trimmed.count <= Spellchecker.maximumWordLength else {
            throw NibError.invalid("the word is longer than \(Spellchecker.maximumWordLength) characters", path: path)
        }
        return Spellchecker.dictionaryKey(trimmed)
    }

    /// Every word in the dictionary, sorted.
    static func words(_ settings: SettingsStore) -> [String] {
        let prefix = NibSettings.dictionaryPrefix
        return settings.names(prefix: prefix).compactMap { name -> String? in
            guard settings.json(name)?.boolValue == true else { return nil }
            let word = String(name.dropFirst(prefix.count))
            return word.isEmpty ? nil : word
        }.sorted()
    }

    static func contains(_ word: String, _ settings: SettingsStore) -> Bool {
        settings.json(NibSettings.dictionaryWord(word).name)?.boolValue == true
    }
}
