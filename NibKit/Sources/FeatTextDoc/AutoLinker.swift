import UIKit
import NibContracts
import NibDesign

// Web links in text documents (D-115): addresses typed or pasted into a block become links once the typing around
// them settles (NSDataDetector, written with block.update), and the edit menu over linked text opens, copies or removes
// the link. Adding a link to any words is F029's Link entry in the same menu (`link.set`); without that feature this
// file offers Add Link itself, for web addresses.

// MARK: - Detection and link ranges (pure)

enum AutoLinker {
    /// Schemes auto-linking produces and the edit menu opens outside Nib.
    static let schemes: Set<String> = ["http", "https", "mailto"]

    struct Match: Equatable {
        /// UTF-16 range in the text's plain text (paragraphs joined by "\n").
        var range: NSRange
        var url: URL
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Web and mail addresses in `plain`.
    static func matches(in plain: String) -> [Match] {
        guard let detector = detector, !plain.isEmpty else { return [] }
        let whole = NSRange(location: 0, length: (plain as NSString).length)
        return detector.matches(in: plain, options: [], range: whole).compactMap { result in
            guard let url = result.url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
            return Match(range: result.range, url: url)
        }
    }

    /// `text` with every address that is not linked yet (and not inline code, and not in `skipping`) linked; nil
    /// when there is nothing to link. Existing links, including links to pages and audio, are never changed.
    static func linked(_ text: RichText, skipping: Set<String> = []) -> RichText? {
        var out = text
        var changed = false
        for m in matches(in: text.plainText) where !skipping.contains(m.url.absoluteString) {
            guard !touches(out, m.range, where: { $0.link != nil || $0.code == true }) else { continue }
            out = apply(in: m.range, to: out) { $0.link = TextLink(url: m.url.absoluteString) }
            changed = true
        }
        return changed ? out : nil
    }

    /// `text` with `link` on `range` (nil removes links there). Runs split at the range's ends; nothing else changes.
    static func setLink(_ link: TextLink?, in text: RichText, range: NSRange) -> RichText {
        apply(in: range, to: text) { $0.link = link }
    }

    /// Every linked stretch of `text`: neighbouring runs with the same link are one stretch.
    static func links(in text: RichText) -> [(range: NSRange, link: TextLink)] {
        var out: [(range: NSRange, link: TextLink)] = []
        var offset = 0
        for (pi, p) in text.paragraphs.enumerated() {
            for r in p.runs {
                let length = (r.text as NSString).length
                defer { offset += length }
                guard let link = r.attrs.link, length > 0 else { continue }
                if let last = out.last, last.link == link, NSMaxRange(last.range) == offset {
                    out[out.count - 1].range.length += length
                } else {
                    out.append((NSRange(location: offset, length: length), link))
                }
            }
            if pi < text.paragraphs.count - 1 { offset += 1 }
        }
        return out
    }

    /// The link under a caret (its ends included) or the one a selection lies in.
    static func link(at range: NSRange, in text: RichText) -> (range: NSRange, link: TextLink)? {
        links(in: text).first { l in
            let end = NSMaxRange(l.range)
            if range.length == 0 { return l.range.location <= range.location && range.location <= end }
            return l.range.location <= range.location && NSMaxRange(range) <= end
        }
    }

    /// The URL a web link opens (nil for links to pages or audio, which F029 follows).
    static func webURL(_ link: TextLink) -> URL? {
        guard let s = link.url, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              schemes.contains(scheme) else { return nil }
        return url
    }

    /// An address someone typed ("example.com", "https://…", "name@example.com") as a web or mail URL; a web
    /// address typed without a scheme gets https. Nil unless the whole input is one address.
    static func webURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }),
              let m = matches(in: s).first, m.range.location == 0, m.range.length == (s as NSString).length else { return nil }
        if m.url.scheme?.lowercased() == "http", !s.lowercased().hasPrefix("http:"),
           var parts = URLComponents(url: m.url, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            return parts.url ?? m.url
        }
        return m.url
    }

    // MARK: Runs

    /// True when some text in `range` has an attribute matching `test`.
    static func touches(_ text: RichText, _ range: NSRange, where test: (TextAttributes) -> Bool) -> Bool {
        var offset = 0
        for (pi, p) in text.paragraphs.enumerated() {
            for r in p.runs {
                let length = (r.text as NSString).length
                let lo = max(offset, range.location), hi = min(offset + length, NSMaxRange(range))
                if lo < hi, test(r.attrs) { return true }
                offset += length
            }
            if pi < text.paragraphs.count - 1 { offset += 1 }
        }
        return false
    }

    /// `text` with `change` applied to the attributes of the characters in `range` (UTF-16 units of the plain text).
    /// Runs are split at the range's ends and equal neighbours merged again.
    static func apply(in range: NSRange, to text: RichText, _ change: (inout TextAttributes) -> Void) -> RichText {
        guard range.length > 0 else { return text }
        let lo = range.location, hi = NSMaxRange(range)
        var out = text
        var offset = 0
        for pi in out.paragraphs.indices {
            let paragraph = out.paragraphs[pi]
            let start = offset
            let end = start + (paragraph.plainText as NSString).length
            offset = end + 1
            guard hi > start, lo < end else { continue }
            var runs: [TextRun] = []
            var position = start
            for r in paragraph.runs {
                let ns = r.text as NSString
                let rs = position, re = position + ns.length
                position = re
                let a = max(lo, rs), b = min(hi, re)
                guard a < b else {
                    runs.append(r)
                    continue
                }
                if a > rs { runs.append(TextRun(ns.substring(to: a - rs), r.attrs)) }
                var middle = TextRun(ns.substring(with: NSRange(location: a - rs, length: b - a)), r.attrs)
                change(&middle.attrs)
                runs.append(middle)
                if b < re { runs.append(TextRun(ns.substring(from: b - rs), r.attrs)) }
            }
            out.paragraphs[pi].runs = merged(runs)
        }
        return out
    }

    static func merged(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.attrs == r.attrs {
                out[out.count - 1].text += r.text
            } else {
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - The editor

/// Auto-links a block when its typing settles (after a space, a line break or a paste, once no key has been pressed
/// for `delay`) and when the caret leaves it; offers Open, Copy and Remove Link on linked text.
@MainActor
enum AutoLinkEditor {
    static let delay: TimeInterval = 1.2

    static func install() {
        let p = TextDocExtrasHookIDs.prefix
        // Late, and never consuming: the slash menu (F102) sees keys first.
        TextDocHooks.addTextInterceptor(p + "autolink.typing", order: 900) { change, editor in
            typed(change, in: editor)
            return false
        }
        TextDocHooks.addSelectionObserver(p + "autolink.leave", order: 900) { editor in
            focusChanged(in: editor)
        }
        TextDocHooks.addEditMenuProvider(p + "links.menu", order: 200) { block, range, isCaption, editor in
            editMenu(block: block, range: range, isCaption: isCaption, editor: editor)
        }
    }

    /// Arms (after a space, a line break or a paste) or pushes back (any other key) the block's auto-link pass.
    static func typed(_ change: TextDocTextChange, in editor: TextDocViewController) {
        guard !change.isCaption, change.block.kind != .code, BlockRules.isText(change.block.kind) else { return }
        let state = TextDocExtrasState.of(editor)
        let id = change.block.id
        let r = change.replacement
        let trigger = (r as NSString).length > 1 || r.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || r.rangeOfCharacter(from: .punctuationCharacters) != nil
        guard trigger || state.autoLinkTasks[id] != nil else { return }
        schedule(id, in: editor, after: delay)
    }

    /// When the caret leaves a block, links it right away.
    static func focusChanged(in editor: TextDocViewController) {
        let state = TextDocExtrasState.of(editor)
        let now = editor.focusedBlockID
        if let previous = state.lastFocusedBlock, previous != now {
            schedule(previous, in: editor, after: 0)
        }
        state.lastFocusedBlock = now
    }

    static func schedule(_ id: NibID, in editor: TextDocViewController, after seconds: TimeInterval) {
        let state = TextDocExtrasState.of(editor)
        state.autoLinkTasks[id]?.cancel()
        state.autoLinkTasks[id] = Task { @MainActor [weak editor] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled, let editor = editor else { return }
            TextDocExtrasState.of(editor).autoLinkTasks[id] = nil
            await link(id, in: editor)
        }
    }

    /// Links the block's addresses with one block.update, queued behind the keystrokes before it.
    static func link(_ id: NibID, in editor: TextDocViewController) async {
        await editor.flushEdits()
        guard !editor.isReadOnly, let block = editor.block(id), BlockRules.isText(block.kind), block.kind != .code else { return }
        if let tv = editor.focusedTextView, tv.blockID == id, tv.isBusy {
            // An IME composition or a Writing Tools pass is running in this block: try again when it is done.
            schedule(id, in: editor, after: delay)
            return
        }
        let skip = TextDocExtrasState.of(editor).unlinked[id] ?? []
        guard let text = AutoLinker.linked(block.text, skipping: skip) else { return }
        _ = await editor.run(BlockUpdate.self, BlockUpdate.Params(ref: editor.blockRef(id), text: text))
    }

    // MARK: Menu

    static func editMenu(block: TextBlock, range: NSRange, isCaption: Bool, editor: TextDocViewController) -> [UIMenuElement] {
        guard !isCaption, BlockRules.isText(block.kind) else { return [] }
        var out: [UIMenuElement] = []
        let id = block.id
        if let found = AutoLinker.link(at: range, in: block.text) {
            if let url = AutoLinker.webURL(found.link) {
                out.append(UIAction(title: String(localized: "Open Link"), image: UIImage(nib: .externalLink)) { _ in
                    editor.view.window?.windowScene?.open(url, options: nil, completionHandler: nil)
                })
                out.append(UIAction(title: String(localized: "Copy Link"), image: UIImage(nib: .copy)) { _ in
                    UIPasteboard.general.url = url
                })
                if !editor.isReadOnly && !hasLinkEditor(editor) {
                    out.append(UIAction(title: String(localized: "Edit Link"), image: UIImage(nib: .link)) { _ in
                        askForLink(in: editor, block: id, range: found.range, current: url.absoluteString)
                    })
                }
            }
            if !editor.isReadOnly {
                out.append(UIAction(title: String(localized: "Remove Link"), image: UIImage(nib: .xmark)) { _ in
                    removeLink(in: editor, block: id, range: found.range, link: found.link)
                })
            }
        } else if range.length > 0, !editor.isReadOnly, !hasLinkEditor(editor) {
            out.append(UIAction(title: String(localized: "Add Link"), image: UIImage(nib: .link)) { _ in
                askForLink(in: editor, block: id, range: range, current: nil)
            })
        }
        guard !out.isEmpty else { return [] }
        return [UIMenu(title: "", options: .displayInline, children: out)]
    }

    /// True when the Links feature (F029) is installed: its Link entry in the same menu adds and edits links of every
    /// kind, so this menu does not offer a second one.
    static func hasLinkEditor(_ editor: TextDocViewController) -> Bool {
        editor.app.commands.descriptor("link.set") != nil && editor.app.ui.menus.all.contains {
            $0.location == .textSelection && $0.command == "link.set"
        }
    }

    static func removeLink(in editor: TextDocViewController, block id: NibID, range: NSRange, link: TextLink) {
        guard let block = editor.block(id) else { return }
        if let s = link.url { TextDocExtrasState.of(editor).unlinked[id, default: []].insert(s) }
        let text = AutoLinker.setLink(nil, in: block.text, range: range)
        guard text != block.text else { return }
        Task { @MainActor in
            _ = await editor.run(BlockUpdate.self, BlockUpdate.Params(ref: editor.blockRef(id), text: text))
        }
    }

    static func askForLink(in editor: TextDocViewController, block id: NibID, range: NSRange, current: String?) {
        let alert = UIAlertController(title: current == nil ? String(localized: "Add Link") : String(localized: "Edit Link"),
                                      message: String(localized: "Enter a web or email address."), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .URL
            field.textContentType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.placeholder = "https://"
            field.text = current
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: current == nil ? String(localized: "Add Link") : String(localized: "Save"),
                                      style: .default) { [weak editor, weak alert] _ in
            guard let editor = editor, let input = alert?.textFields?.first?.text, let block = editor.block(id) else { return }
            guard let url = AutoLinker.webURL(from: input) else {
                TextDocCommandRunner(app: editor.app, session: editor.session, doc: editor.documentID)
                    .toast(String(localized: "That is not a web or email address."))
                return
            }
            TextDocExtrasState.of(editor).unlinked[id]?.remove(url.absoluteString)
            let text = AutoLinker.setLink(TextLink(url: url.absoluteString), in: block.text, range: range)
            Task { @MainActor in
                _ = await editor.run(BlockUpdate.self, BlockUpdate.Params(ref: editor.blockRef(id), text: text))
            }
        })
        editor.present(alert, animated: true)
    }
}
