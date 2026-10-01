import Foundation
import UIKit
import PDFKit
import NibContracts
import NibDesign

struct PresentPrint: NibCommand {
    struct Params: Codable {
        var doc: String?
        var pages: [String]?
        var range: String?
        var exclude: String?
        var options: JSONValue?
        var ready: Bool?
        var instant: Bool?
    }
    static let descriptor = CommandDescriptor(
        id: "print.present", title: String(localized: "Print"),
        summary: "Open AirPrint page options; ready=true prints selected pages after applying 1-based ranges and exclusions, preserving mixed page proportions.",
        params: .obj(["doc": .ref, "pages": .arr(.ref), "range": .str("1-based ranges, e.g. 1-3, 5, 8-"),
                      "exclude": .str("1-based pages to omit"), "options": .anything("PDF export options"),
                      "ready": .bool("submit the print draft"), "instant": .bool("keyboard presentation")]),
        examples: [["doc": "doc:FIXTUREDOC01"], ["doc": "doc:FIXTUREDOC01", "pages": ["page:FIXTUREDOC01/FIXTUREPG001"]]],
        effect: .read, userPresence: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> JSONValue {
        let doc = try ctx.documentOrSession(p.doc)
        if p.ready != true, !ctx.dryRun, ctx.services.lock?.isLocked(doc) == true {
            try await ExportPresentation.presenter(ctx).showLocked(doc: doc, retry: Self.descriptor.id,
                                                                  params: JSONValue.from(p), ctx: ctx)
            return ["presented": true, "locked": true]
        }
        let selection = try await ExportSelection.load(docs: [NodeRef.document(doc).description], pages: p.pages, ctx: ctx)
        guard let pdf = selection.formats.first(where: { $0.fileExtension.lowercased() == "pdf" }) else {
            throw NibError.unsupported(String(localized: "Printing this document kind"))
        }
        if ctx.dryRun { return ["wouldPresent": true] }
        let presenter = try ExportPresentation.presenter(ctx)
        var draft = ExportDraft(selection: selection)
        draft.format = pdf.id
        draft.printRange = p.range ?? ""
        draft.printExclusions = p.exclude ?? ""
        if let options = p.options {
            guard options.objectValue != nil else { throw NibError.invalid("options must be an object", path: "$.options") }
            draft.options = options
        }
        guard p.ready == true else {
            try await presenter.show(selection: selection, draft: draft, printing: true, instant: p.instant ?? false, ctx: ctx)
            return ["presented": true]
        }
        var params: JSONValue = ["docs": .array([.string(NodeRef.document(doc).description)]), "format": .string(pdf.id)]
        if !selection.documents[0].pages.isEmpty {
            let refs = try PrintPageSelection.resolve(pages: p.pages, range: p.range ?? "", exclusions: p.exclude ?? "", document: selection.documents[0])
            params.set("pages", .array(refs.map(JSONValue.string)))
        } else if p.pages != nil || !(p.range ?? "").isEmpty || !(p.exclude ?? "").isEmpty {
            throw NibError.invalid("This document has no numbered pages to select.", path: "$.range")
        }
        // The final PDF owns the page filter. Strip pageRange so an exporter cannot apply a second filter.
        var options = draft.options.objectValue ?? [:]
        options["pageRange"] = nil
        options["mode"] = "flattened"
        params.set("options", .object(options))
        try selection.requireUnlocked(ctx)
        let result = try await ctx.execute(CommandIDs.exportRun, params)
        try selection.requireUnlocked(ctx)
        let files = try await ExportFiles.materialize(result, ctx: ctx)
        defer { files.remove() }
        guard files.urls.count == 1 else { throw NibError(.internalError, "Printing requires a single PDF.") }
        try selection.requireUnlocked(ctx)
        let completed = try await presenter.printPDF(files.urls[0], title: selection.title, ctx: ctx)
        return ["completed": .bool(completed)]
    }
}

enum PrintPageSelection {
    /// Ranges use original document positions, even when a selected subset is supplied. Exclusions then win.
    static func resolve(pages: [String]?, range: String, exclusions: String, document: ExportDocument) throws -> [String] {
        let all = document.pages.map(\.ref)
        var selected = Set(pages ?? all)
        guard !selected.isEmpty, selected.isSubset(of: Set(all)) else { throw NibError.invalid("Select available pages to print.", path: "$.pages") }
        if !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let included = try indices(range, count: all.count, path: "$.range")
            selected.formIntersection(included.map { all[$0] })
        }
        if !exclusions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let excluded = try indices(exclusions, count: all.count, path: "$.exclude")
            selected.subtract(excluded.map { all[$0] })
        }
        let result = all.filter { selected.contains($0) }
        guard !result.isEmpty else { throw NibError.invalid("The page range and exclusions leave nothing to print.", path: "$.range") }
        return result
    }
    static func indices(_ text: String, count: Int, path: String) throws -> Set<Int> {
        var output = Set<Int>()
        func invalid() -> NibError { NibError(.invalidParams, "Invalid page range: \(text)", path: path, hint: "use 1-based page numbers such as 1-3, 5, 8-") }
        let normalized = text.replacingOccurrences(of: "–", with: "-")
        for component in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let token = component.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard !token.isEmpty, (1...2).contains(parts.count), let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  start >= 1, start <= count else { throw invalid() }
            let end: Int
            if parts.count == 1 { end = start }
            else if parts[1].trimmingCharacters(in: .whitespaces).isEmpty { end = count }
            else if let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) { end = value }
            else { throw invalid() }
            guard end >= start, end <= count else { throw invalid() }
            output.formUnion((start...end).map { $0 - 1 })
        }
        return output
    }
}

/// PDF pages may have different media boxes and rotations. AirPrint selects one available stock per job;
/// each source page is aspect-fitted to that stock without cropping or stretching.
final class MixedPageRenderer: UIPrintPageRenderer {
    let document: PDFDocument
    init(document: PDFDocument) { self.document = document; super.init() }
    override var numberOfPages: Int { document.pageCount }
    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        guard let page = document.page(at: pageIndex), let context = UIGraphicsGetCurrentContext() else { return }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(printableRect.width / bounds.width, printableRect.height / bounds.height)
        let x = printableRect.midX - bounds.width * scale / 2
        let y = printableRect.midY + bounds.height * scale / 2
        context.translateBy(x: x, y: y)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
    }
}

@MainActor
final class PrintController: NSObject, UIPrintInteractionControllerDelegate {
    let renderer: MixedPageRenderer
    init(renderer: MixedPageRenderer) { self.renderer = renderer }
    func printInteractionController(_ printInteractionController: UIPrintInteractionController,
                                    choosePaper paperList: [UIPrintPaper]) -> UIPrintPaper {
        let size = renderer.document.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: PageSize.a4.width, height: PageSize.a4.height)
        return UIPrintPaper.bestPaper(forPageSize: size, withPapersFrom: paperList)
    }
    static func present(url: URL, title: String, ctx: CommandContext) async throws -> Bool {
        let parent = try ExportPresentation.topController(ctx)
        guard UIPrintInteractionController.isPrintingAvailable else { throw NibError.unavailable("AirPrint") }
        let document = try await ExportFiles.work { () throws -> PDFDocument in
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw NibError(.internalError, "The exported PDF could not be opened for printing.") }
            return pdf
        }
        let renderer = MixedPageRenderer(document: document)
        let delegate = PrintController(renderer: renderer)
        let printer = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        if let size = document.page(at: 0)?.bounds(for: .mediaBox).size {
            info.orientation = size.width > size.height ? .landscape : .portrait
        }
        printer.printInfo = info
        printer.printPageRenderer = renderer
        printer.delegate = delegate
        defer { printer.delegate = nil; printer.printPageRenderer = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let handler: UIPrintInteractionController.CompletionHandler = { _, completed, error in
                // Retain the paper delegate until the system finishes or cancels the job.
                _ = delegate
                if let error { continuation.resume(throwing: NibError.wrap(error)) }
                else { continuation.resume(returning: completed) }
            }
            let shown: Bool
            if parent.traitCollection.userInterfaceIdiom == .pad {
                shown = printer.present(from: CGRect(x: parent.view.bounds.midX, y: parent.view.safeAreaInsets.top,
                                             width: NibMetrics.hitTarget, height: NibMetrics.hitTarget),
                                in: parent.view, animated: !UIAccessibility.isReduceMotionEnabled, completionHandler: handler)
            } else {
                shown = printer.present(animated: !UIAccessibility.isReduceMotionEnabled, completionHandler: handler)
            }
            if !shown { continuation.resume(throwing: NibError.unavailable("the print preview")) }
        }
    }
}
