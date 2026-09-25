import Foundation
import UIKit
import WebKit
import NibContracts

/// Word and PowerPoint files and web pages become PDFs, which the PDF importer (F024) then imports: the document is
/// laid out by WebKit (Office files through its built-in viewer), paginated with `UIPrintPageRenderer` and written
/// as a PDF. Layout may shift from the original. Web pages keep their live address (`.webloc`), so styles and
/// images load; the page title names the document (Safari's own PDF, shared through NibShare, imports as a PDF).
@MainActor
enum OfficeConverter {
    static let officeID = "import.office"
    static let webID = "import.webpage"
    static let officeExtensions = ["doc", "docx", "ppt", "pptx"]
    static let presentationExtensions: Set<String> = ["ppt", "pptx"]
    static let webExtensions = ["html", "htm", WebLocation.fileExtension]

    static func officeDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: officeID, title: String(localized: "Word and PowerPoint"), fileExtensions: officeExtensions,
                           utTypes: ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
                                     "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation"],
                           order: 100, owner: owner) { url, target, ctx in
            let landscape = OfficeConverter.presentationExtensions.contains(url.pathExtension.lowercased())
            return try await OfficeConverter.convertAndImport(.file(url), title: url.deletingPathExtension().lastPathComponent,
                                                              layout: .office(landscape: landscape), target: target, ctx: ctx)
        }
    }

    static func webDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: webID, title: String(localized: "Web pages"), fileExtensions: webExtensions,
                           utTypes: ["public.html", "com.apple.web-internet-location"],
                           order: 100, owner: owner) { url, target, ctx in
            let title = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension.lowercased() == WebLocation.fileExtension else {
                return try await OfficeConverter.convertAndImport(.file(url), title: title, layout: .webPage,
                                                                  target: target, ctx: ctx)
            }
            guard let page = WebLocation.read(url) else {
                throw NibError(.unsupported, "\(url.lastPathComponent) holds no web address")
            }
            return try await OfficeConverter.convertAndImport(.remote(page), title: title, layout: .webPage,
                                                              target: target, ctx: ctx)
        }
    }

    /// Lays `source` out in an off-screen web view, writes a paginated PDF named after the page (or `title`) and hands
    /// it to the registered PDF importer with the same target.
    static func convertAndImport(_ source: WebSource, title: String, layout: PDFLayout, target: ImportTarget,
                                 ctx: CommandContext) async throws -> [DocumentID] {
        guard let app = ImportHost.app(for: ctx) else { throw NibError.unavailable("import") }
        guard let pdfImporter = app.content.importer(forExtension: "pdf") else {
            throw NibError(.unavailable, "PDF import is not available, so Word, PowerPoint and web pages can't be converted",
                           hint: "enable the PDF feature and import again")
        }
        guard !NibApp.isHostlessTest, let window = ImportUI.hostWindow(app) else {
            throw NibError(.unavailable, "converting documents needs an open Nib window",
                           hint: "open Nib on the device and import again")
        }
        let dir = ImportLocations.scratch.appendingPathComponent("convert-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paper = layout.paper(base: ctx.services.settings.get(NibSettings.defaultPageSize))
        let renderer = WebPDFRenderer(host: window, width: paper.width)
        defer { renderer.tearDown() }
        try await renderer.load(source, settle: layout.settleSeconds)
        var name = title
        if layout == .webPage, let pageTitle = renderer.pageTitle, !pageTitle.isEmpty { name = pageTitle }
        let pdf = dir.appendingPathComponent(ImportNaming.sanitize(name) + ".pdf")
        try await renderer.writePDF(paper: paper, margin: layout.margin, to: pdf)
        return try await pdfImporter.handler(pdf, target, ctx)
    }
}

/// What the web view loads.
enum WebSource: Equatable {
    case file(URL)
    case remote(URL)
}

/// Paper and margins of a converted PDF. Pure.
enum PDFLayout: Equatable {
    case office(landscape: Bool)
    case webPage

    /// The default page size, portrait for documents and web pages, landscape for presentations.
    func paper(base: PageSize) -> CGSize {
        let short = min(base.width, base.height)
        let long = max(base.width, base.height)
        if case .office(landscape: true) = self { return CGSize(width: long, height: short) }
        return CGSize(width: short, height: long)
    }

    /// Office files carry their own page margins; web pages get the usual print margin.
    var margin: CGFloat {
        switch self {
        case .office: return 18
        case .webPage: return 36
        }
    }

    /// Time for late layout (web fonts, lazy images, the Office viewer) after the load finishes.
    var settleSeconds: Double {
        switch self {
        case .office: return 1.0
        case .webPage: return 0.8
        }
    }
}

/// `.webloc` files (a property list with the "URL" key): what NibShare and downloads of web pages write, so a page
/// is imported from its live address. Pure and thread-safe.
enum WebLocation {
    static let fileExtension = "webloc"

    static func write(_ url: URL, title: String, in dir: URL) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                                      format: .xml, options: 0)
        let file = ImportNaming.unique(ImportNaming.sanitize(title) + "." + fileExtension, in: dir)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The http(s) address in a `.webloc` file; nil for anything else.
    static func read(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any], let string = dict["URL"] as? String,
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

/// A print renderer with a fixed paper size (UIKit's own is read-only).
final class PaperRenderer: UIPrintPageRenderer {
    private let paper: CGRect
    private let printable: CGRect

    init(paper: CGSize, margin: CGFloat) {
        let rect = CGRect(origin: .zero, size: paper)
        self.paper = rect
        self.printable = rect.insetBy(dx: margin, dy: margin)
        super.init()
    }

    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { printable }
}

/// An off-screen web view that loads a document or page and writes it as a paginated PDF. Main actor only.
@MainActor
final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    init(host: UIView, width: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Off screen, but inside a window so WebKit lays it out and paints for printing.
        webView = WKWebView(frame: CGRect(x: -20_000, y: 0, width: width, height: width * 1.4),
                            configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        host.insertSubview(webView, at: 0)
    }

    var pageTitle: String? { webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func load(_ source: WebSource, settle: Double, timeout: Double = 60) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            switch source {
            case .file(let url):
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            case .remote(let url):
                webView.load(URLRequest(url: url))
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishLoading(NibError(.timeout, "the page took longer than \(Int(timeout)) s to load",
                                             hint: "check the connection and import again"))
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
    }

    /// Paginates with the web view's print formatter; a layout the formatter cannot paginate becomes one tall page.
    func writePDF(paper: CGSize, margin: CGFloat, to url: URL) async throws {
        let renderer = PaperRenderer(paper: paper, margin: margin)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let count = renderer.numberOfPages
        guard count > 0 else {
            try await writeSinglePage(to: url)
            return
        }
        guard UIGraphicsBeginPDFContextToFile(url.path, renderer.paperRect, nil) else {
            throw NibError(.internalError, "could not create the converted PDF")
        }
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        for index in 0..<count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
            // ponytail: printing has to run on the main thread; yielding per page keeps the window responsive.
            await Task.yield()
        }
        UIGraphicsEndPDFContext()
    }

    private func writeSinglePage(to url: URL) async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in continuation.resume(with: result) }
        }
        try data.write(to: url, options: .atomic)
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        finishLoading(NibError(.internalError, "the conversion was stopped"))
    }

    private func finishLoading(_ error: Error?) {
        guard let continuation = loading else { return }
        loading = nil
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(NibError(.unavailable, "the page couldn't be loaded: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(NibError(.unavailable, "the page couldn't be loaded: \(error.localizedDescription)",
                               hint: "check the address and the connection, then import again"))
    }
}
