import Foundation
import NibContracts

// The commands of handwriting spellcheck (F104). Everything the spelling popover, the document's More menu and the
// underlines do goes through these, so plugins, the AI and the bridge can do the same.

// MARK: - dictionary.add

/// Adds a word to the personal dictionary: one synced setting per word, so additions on two devices merge.
struct DictionaryAdd: NibCommand {
    struct Params: Codable {
        var word: String
    }

    struct Output: Codable {
        /// The word as stored (lower case: the dictionary ignores case).
        var word: String
        /// False when it was already there.
        var added: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "dictionary.add", title: "Add to Dictionary",
        summary: "Add a word to the personal dictionary (synced, case-insensitive) so handwriting spellcheck stops underlining it.",
        params: .obj(["word": .str("one word; surrounding punctuation and case are ignored")], required: ["word"]),
        examples: [["word": "Nibnote"]],
        effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let word = try PersonalDictionary.normalise(p.word)
        let settings = ctx.services.settings
        let key = NibSettings.dictionaryWord(word)
        let had = settings.get(key)
        if !had { settings.set(key, true) }
        SpellcheckEngine.existing(ctx.app)?.dictionaryDidChange()
        return Output(word: word, added: !had)
    }
}

// MARK: - dictionary.remove

/// Removes a word from the personal dictionary (stored as a removal, so the other devices drop it too).
struct DictionaryRemove: NibCommand {
    struct Params: Codable {
        var word: String
    }

    struct Output: Codable {
        var word: String
        /// False when it was not in the dictionary.
        var removed: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "dictionary.remove", title: "Remove from Dictionary",
        summary: "Remove a word from the personal dictionary (on every device); spellcheck underlines it again if misspelled.",
        params: .obj(["word": .str("the word, as dictionary.list shows it (case is ignored)")], required: ["word"]),
        examples: [["word": "Nibnote"]],
        effect: .session, target: .app, destructive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let word = try PersonalDictionary.normalise(p.word)
        let settings = ctx.services.settings
        let name = NibSettings.dictionaryWord(word).name
        let had = PersonalDictionary.contains(word, settings)
        if settings.json(name) != nil { settings.setJSON(name, nil) }
        SpellcheckEngine.existing(ctx.app)?.dictionaryDidChange()
        return Output(word: word, removed: had)
    }
}

// MARK: - dictionary.list

/// The personal dictionary, alphabetically, a page at a time.
struct DictionaryList: NibCommand {
    struct Params: Codable {
        var prefix: String?
        var limit: Int?
        var cursor: String?
    }

    struct Output: Codable {
        var words: [String]
        /// Words in the dictionary (matching `prefix`).
        var count: Int
        var truncated: Bool
        /// Pass back unchanged for the next page.
        var cursor: String?
    }

    static let defaultLimit = 500
    static let maximumLimit = 2000

    static let descriptor = CommandDescriptor(
        id: "dictionary.list", title: "Personal Dictionary",
        summary: "List personal dictionary words (lower case, sorted) → {words, count, truncated, cursor?}; optional prefix filter and paging.",
        params: .obj([
            "prefix": .str("only words starting with this (case is ignored)"),
            "limit": .int("words per page (default 500)", min: 1, max: maximumLimit),
            "cursor": .str("the cursor of the previous page")
        ]),
        examples: [[:], ["prefix": "nib", "limit": 50]],
        effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let limit = p.limit ?? defaultLimit
        guard (1...maximumLimit).contains(limit) else {
            throw NibError.invalid("limit must be 1–\(maximumLimit)", path: "$.limit")
        }
        var words = PersonalDictionary.words(ctx.services.settings)
        if let prefix = p.prefix.map(Spellchecker.dictionaryKey), !prefix.isEmpty {
            words = words.filter { $0.hasPrefix(prefix) }
        }
        var start = 0
        if let cursor = p.cursor, !cursor.isEmpty {
            guard let offset = Int(cursor), offset >= 0 else {
                throw NibError(.invalidParams, "unknown cursor", path: "$.cursor",
                               hint: "pass the cursor of the previous dictionary.list result unchanged")
            }
            start = min(offset, words.count)
        }
        let end = min(start + limit, words.count)
        let truncated = end < words.count
        return Output(words: Array(words[start..<end]), count: words.count, truncated: truncated,
                      cursor: truncated ? String(end) : nil)
    }
}

// MARK: - doc.setWritingAids

/// Turns handwriting spellcheck and Math Assist on or off for one notebook or whiteboard (`DocumentMeta.spellcheck`,
/// `.mathAssist`; new documents start from `NibSettings.spellcheckNewDocuments` / `.mathAssistSuggestions`).
/// Undoable. Session default (§6.1): a user call may omit `doc` for the invoking window's document.
struct DocSetWritingAids: NibCommand {
    struct Params: Codable {
        /// Required in the schema; the user principal may omit it.
        var doc: String?
        var spellcheck: Bool?
        var mathAssist: Bool?
    }

    struct Output: Codable {
        var doc: String
        var spellcheck: Bool
        var mathAssist: Bool
        /// False when both were already as asked (nothing was written).
        var changed: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "doc.setWritingAids", title: "Writing Aids",
        summary: "Turn handwriting spellcheck and/or Math Assist on or off for a notebook or whiteboard (undoable) → {doc, spellcheck, mathAssist, changed}.",
        params: .obj([
            "doc": .ref,
            "spellcheck": .bool("underline misspelled handwriting"),
            "mathAssist": .bool("offer answers for handwritten equations ending in '='")
        ], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "spellcheck": true],
                   ["doc": "doc:FIXTUREDOC04", "spellcheck": true, "mathAssist": true]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        guard p.spellcheck != nil || p.mathAssist != nil else {
            throw NibError(.invalidParams, "nothing to change", path: "$.spellcheck",
                           hint: "pass spellcheck and/or mathAssist (true or false)")
        }
        let meta = try ctx.workspace.content(doc).meta
        guard SpellcheckEngine.supports(meta.kind) else {
            throw NibError(.invalidParams, "writing aids work on notebooks and whiteboards, not on a \(meta.kind.rawValue)",
                           path: "$.doc", hint: "typed text in text documents and study sets uses the system spellchecker")
        }
        if ctx.isReadOnly(doc) {
            throw NibError(.unsupported, "document \(doc.raw) is read-only", path: "$.doc",
                           hint: "the document was saved by a newer version of Nib or its files cannot be written")
        }
        let spellcheck = p.spellcheck ?? meta.spellcheck
        let mathAssist = p.mathAssist ?? meta.mathAssist
        let changed = spellcheck != meta.spellcheck || mathAssist != meta.mathAssist
        if changed {
            try ctx.mutate(label(spellcheck: p.spellcheck, mathAssist: p.mathAssist)) { tx in
                var m = try tx.content(doc).meta
                m.spellcheck = spellcheck
                m.mathAssist = mathAssist
                try tx.putMeta(m)
            }
        }
        return Output(doc: NodeRef.document(doc).description, spellcheck: spellcheck, mathAssist: mathAssist,
                      changed: changed)
    }

    /// The undo step's name ("Turn On Spellcheck").
    static func label(spellcheck: Bool?, mathAssist: Bool?) -> String {
        switch (spellcheck, mathAssist) {
        case (let s?, nil): return s ? "Turn On Spellcheck" : "Turn Off Spellcheck"
        case (nil, let m?): return m ? "Turn On Math Assist" : "Turn Off Math Assist"
        default: return "Change Writing Aids"
        }
    }
}

// MARK: - spellcheck.tapAt

/// The tap handler of underlined words (`content.tapHandlers`, order 350: after links, before selection). A tap on
/// a misspelled word shows its suggestions in a popover budded from the word (user taps); every caller gets them
/// back, with the texts to pass to `handwriting.replaceWord`.
struct SpellcheckTapAt: NibCommand {
    struct Params: Codable {
        var page: String?
        var point: [Double]
        var ref: String?
        var gesture: String?
    }

    struct Output: Codable {
        var handled: Bool
        /// The misspelled word as checked ("teh") and as written ("teh,").
        var word: String?
        var written: String?
        var suggestions: [String]?
        /// `suggestions` with the word's punctuation: the `text` for handwriting.replaceWord.
        var replacements: [String]?
        /// The word's strokes: the `refs` for handwriting.replaceWord.
        var refs: [String]?
        var bbox: Rect?

        static let unhandled = Output(handled: false)

        init(handled: Bool, word: String? = nil, written: String? = nil, suggestions: [String]? = nil,
             replacements: [String]? = nil, refs: [String]? = nil, bbox: Rect? = nil) {
            self.handled = handled
            self.word = word
            self.written = written
            self.suggestions = suggestions
            self.replacements = replacements
            self.refs = refs
            self.bbox = bbox
        }
    }

    static let descriptor = CommandDescriptor(
        id: "spellcheck.tapAt", title: "Spelling Suggestions",
        summary: "Tap handler: suggestions for the misspelled handwritten word at a point → {handled, word, suggestions, replacements, refs} (apply with handwriting.replaceWord).",
        params: .obj([
            "page": .ref,
            "point": .point,
            "ref": .ref,
            "gesture": .str("canvas gesture (only tap is handled)", choices: CanvasGesture.allCases.map { $0.rawValue })
        ], required: ["page", "point"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "point": [110, 122]]],
        effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let (doc, page) = try ctx.pageOrSession(p.page)
        guard p.point.count == 2, p.point.allSatisfy({ $0.isFinite }) else {
            throw NibError.invalid("point must be [x, y] in page points", path: "$.point")
        }
        let gesture = CanvasGesture(rawValue: p.gesture ?? CanvasGesture.tap.rawValue) ?? .tap
        guard gesture == .tap, let app = ctx.app else { return .unhandled }
        let meta = try ctx.workspace.content(doc).meta
        let session = ctx.session ?? ctx.activeSession
        let windowReadOnly = session.map { $0.document == doc && $0.readOnly } ?? false
        guard meta.spellcheck, SpellcheckEngine.supports(meta.kind), !windowReadOnly, !ctx.isReadOnly(doc) else {
            return .unhandled
        }
        let engine = SpellcheckEngine.shared(app)
        var spelling = engine.displayed(doc, page)
        if !ctx.principal.isUser, !engine.isFresh(doc, page) {
            // The AI, plugins and the bridge see no underlines: check the page for them now.
            spelling = try await engine.check(doc, page) { refs in
                try await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(refs.map { JSONValue.string($0) })])
            }
        }
        guard let result = spelling else { return .unhandled }
        let hidden = session?.document == doc ? (session?.hiddenLayers ?? []) : []
        let shown = result.misspellings.filter { !hidden.contains($0.layer) }
        let zoom = max(session?.zoom ?? 1, 0.05)
        var tapped: ElementID?
        if let r = p.ref, case let .item(d, pg, id)? = NodeRef(r), d == doc, pg == page { tapped = id }
        guard let m = Spellchecker.hit(Point(p.point[0], p.point[1]), ref: tapped, in: shown,
                                       minimumSize: SpellcheckGeometry.minimumTarget / zoom) else {
            return .unhandled
        }
        let suggestions = engine.suggestions(for: m, documentLanguage: result.documentLanguage)
        if ctx.principal.isUser, let session = session, session.document == doc {
            SpellcheckUI.attachment(for: session)?.presentSuggestions(for: m, page: page, suggestions: suggestions,
                                                                     documentLanguage: result.documentLanguage)
        }
        return Output(handled: true, word: m.word, written: m.written, suggestions: suggestions,
                      replacements: suggestions.map { Spellchecker.replacement($0, for: m) },
                      refs: m.itemIDs.map { NodeRef.item(doc, page, $0).description }, bbox: m.bbox)
    }
}
