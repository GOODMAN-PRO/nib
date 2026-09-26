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
    static func officeDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: ImportFormats.officeImporterID, title: String(localized: "Word and PowerPoint"),
                           fileExtensions: ImportFormats.officeExtensions,
                           utTypes: ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
                                     "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation"],
                           order: 100, owner: owner) { url, target, ctx in
            let landscape = ImportFormats.presentationExtensions.contains(url.pathExtension.lowercased())
            return try await OfficeConverter.convertAndImport(.file(url), title: target.displayName ?? ImportNaming.title(of: url),
                                                              layout: .office(landscape: landscape), target: target, ctx: ctx)
        }
    }

    static func webDescriptor(owner: String) -> ImporterDescriptor {
        ImporterDescriptor(id: ImportFormats.webImporterID, title: String(localized: "Web pages"),
                           fileExtensions: ImportFormats.webExtensions,
                           utTypes: ["public.html", "com.apple.web-internet-location"],
                           order: 100, owner: owner) { url, target, ctx in
            let title = target.displayName ?? ImportNaming.title(of: url)
            guard url.pathExtension.lowercased() == ImportFormats.webLocationExtension else {
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
        guard let pdfImporter = ctx.content.importer(forExtension: "pdf") else {
            throw NibError(.unavailable, "PDF import is not available, so Word, PowerPoint and web pages can't be converted",
                           hint: "enable the PDF feature and import again")
        }
        if case .remote(let page) = source { try authorizeWebPage(page, ctx: ctx) }
        guard !NibApp.isHostlessTest, let window = await ImportUI.navigator(ctx)?.rootViewController?.view.window else {
            throw NibError(.unavailable, "converting documents needs an open Nib window",
                           hint: "open Nib on the device and import again")
        }
        if ctx.dryRun { return target.document.map { [$0] } ?? [] }
        let dir = ImportLocations.scratch.appendingPathComponent("convert-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paper = layout.paper(base: ctx.services.settings.get(NibSettings.defaultPageSize))
        // Office files and saved pages render without scripts; a live page may need them for its layout.
        let isRemote: Bool
        if case .remote = source { isRemote = true } else { isRemote = false }
        let renderer = WebPDFRenderer(host: window, width: paper.width, javaScript: isRemote)
        defer { renderer.tearDown() }
        try await renderer.load(source, settle: layout.settleSeconds)
        var name = title
        if layout == .webPage, let pageTitle = renderer.pageTitle, !pageTitle.isEmpty { name = pageTitle }
        name = ImportNaming.sanitize(name)
        let pdf = dir.appendingPathComponent(name + ".pdf")
        try await renderer.writePDF(paper: paper, margin: layout.margin, to: pdf)
        var converted = target
        converted.displayName = name
        return try await pdfImporter.handler(pdf, converted, ctx)
    }

    /// Loading a live page reaches the network: the AI and the bridge need the `network` scope and https, and a plugin
    /// also a host its manifest lists (the same rule as `CommandContext.inputFile` downloads).
    static func authorizeWebPage(_ url: URL, ctx: CommandContext) throws {
        if ctx.principal.isUser { return }
        guard url.scheme?.lowercased() == "https" else {
            throw NibError(.permissionDenied, "only https pages can be imported by \(ctx.principal)",
                           hint: "use an https address, or upload a PDF of the page with asset.upload")
        }
        guard ctx.bus.gateway.grants(ctx.principal).contains(.network) else {
            throw NibError(.permissionDenied, "loading \(url.host ?? "a web page") needs the 'network' permission",
                           hint: "upload a PDF of the page with asset.upload and import its tmp: ref")
        }
        if case let .plugin(id) = ctx.principal,
           let manifest = ctx.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.handle(id)?.manifest {
            let host = (url.host ?? "").lowercased()
            guard (manifest.network?.hosts ?? []).contains(where: { $0.lowercased() == host }) else {
                throw NibError(.permissionDenied, "'\(host)' is not in the plugin's network.hosts",
                               hint: "add the host to manifest network.hosts")
            }
        }
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
    static func write(_ url: URL, title: String, in dir: URL) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                                      format: .xml, options: 0)
        let file = ImportNaming.unique(ImportNaming.sanitize(title) + "." + ImportFormats.webLocationExtension, in: dir)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The http(s) address in a `.webloc` file; nil for anything else.
    static func read(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return address(in: data)
    }

    static func address(in data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any], let string = dict["URL"] as? String,
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
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
    private var timeout: Task<Void, Never>?

    init(host: UIView, width: CGFloat, javaScript: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
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

    func load(_ source: WebSource, settle: Double, timeout seconds: Double = 60) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            switch source {
            case .file(let url):
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            case .remote(let url):
                webView.load(URLRequest(url: url))
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishLoading(NibError(.timeout, "the page took longer than \(Int(seconds)) s to load",
                                             hint: "check the connection and import again"))
            }
        }
        timeout?.cancel()
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
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
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        let pdf = UIGraphicsPDFRenderer(bounds: renderer.paperRect)
        do {
            try pdf.writePDF(to: url) { context in
                for index in 0..<count {
                    context.beginPage()
                    renderer.drawPage(at: index, in: context.pdfContextBounds)
                }
            }
        } catch {
            throw NibError(.internalError, "could not write the converted PDF: \(error.localizedDescription)")
        }
    }

    private func writeSinglePage(to url: URL) async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in continuation.resume(with: result) }
        }
        try data.write(to: url, options: .atomic)
    }

    func tearDown() {
        timeout?.cancel()
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
