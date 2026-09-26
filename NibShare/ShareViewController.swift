import UIKit
import UniformTypeIdentifiers

/// NibShare (optional share extension, F064): hands images, files, text and web addresses shared from other apps to
/// Nib. With an App Group it writes them into `<group>/Inbox/`, which Nib offers to import the next time it becomes
/// active. Without one it puts small payloads on the pasteboard and opens `nib://import?from=pasteboard`; larger
/// items are saved to Files (On My iPad › Nib), which Nib also scans. This target cannot link NibKit: the constants
/// in `ShareFiles.Handoff` must stay in step with `ShareHandoff` in NibKit/Sources/FeatImport/InboxScanner.swift.
final class ShareViewController: UIViewController, UIDocumentPickerDelegate {
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let primaryButton = UIButton(configuration: .filled())
    private let secondaryButton = UIButton(configuration: .plain())
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var workDirectory: URL?
    private var files: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        show(title: String(localized: "Nib"), message: String(localized: "Getting it ready…"), busy: true)
        Task { await self.deliver() }
    }

    // MARK: Flow

    private func deliver() async {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NibShare-" + UUID().uuidString,
                                                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDirectory = dir
        var loaded: [URL] = []
        for provider in providers {
            if let url = await SharedItemLoader.load(provider, into: dir) { loaded.append(url) }
        }
        files = loaded
        guard !files.isEmpty else {
            show(title: String(localized: "Nothing to import"),
                 message: String(localized: "Nib imports PDFs, images, Word and PowerPoint files, web pages and Nib documents."),
                 primary: (String(localized: "Done"), { [weak self] in self?.finish() }))
            return
        }
        if let inbox = ShareFiles.appGroupInbox() {
            do {
                try ShareFiles.move(files, into: inbox)
                show(title: String(localized: "Sent to Nib"),
                     message: String(localized: "Open Nib to choose where it goes."),
                     primary: (String(localized: "Done"), { [weak self] in self?.finish() }))
                return
            } catch {
                // An unusable group container: fall back to the hand-off below.
            }
        }
        guard ShareFiles.fitsPasteboard(files) else {
            show(title: String(localized: "Save it to Files first"),
                 message: String(localized: "This is too large to hand over directly. Save it to On My iPad › Nib; Nib offers to import it the next time you open it."),
                 primary: (String(localized: "Save to Files"), { [weak self] in self?.saveToFiles() }),
                 secondary: (String(localized: "Cancel"), { [weak self] in self?.cancel() }))
            return
        }
        do {
            try ShareFiles.putOnPasteboard(files)
        } catch {
            show(title: String(localized: "Couldn't send to Nib"), message: error.localizedDescription,
                 primary: (String(localized: "Done"), { [weak self] in self?.cancel() }))
            return
        }
        if let url = URL(string: ShareFiles.Handoff.link), openHostApp(url) {
            finish()
        } else {
            show(title: String(localized: "Ready for Nib"),
                 message: String(localized: "Open Nib to finish importing."),
                 primary: (String(localized: "Done"), { [weak self] in self?.finish() }))
        }
    }

    private func saveToFiles() {
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    private func finish() {
        cleanUp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        cleanUp()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func cleanUp() {
        if let dir = workDirectory { try? FileManager.default.removeItem(at: dir) }
        workDirectory = nil
    }

    /// Extensions cannot use `UIApplication.shared`; the extension's application object in the responder chain opens
    /// the URL (dynamic dispatch, because the method is marked unavailable to extensions).
    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: Interface (system components only: the extension has no access to NibDesign)

    private func buildInterface() {
        view.backgroundColor = .systemGroupedBackground
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        spinner.hidesWhenStopped = true
        primaryButton.addAction(UIAction { [weak self] _ in self?.primaryAction?() }, for: .primaryActionTriggered)
        secondaryButton.addAction(UIAction { [weak self] _ in self?.secondaryAction?() }, for: .primaryActionTriggered)
        for button in [primaryButton, secondaryButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, messageLabel, spinner, primaryButton, secondaryButton].forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(24, after: messageLabel)
        view.addSubview(stack)
        let guide = view.readableContentGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    private func show(title: String, message: String, busy: Bool = false,
                      primary: (String, () -> Void)? = nil, secondary: (String, () -> Void)? = nil) {
        titleLabel.text = title
        messageLabel.text = message
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.accessibilityLabel = busy ? String(localized: "Preparing") : nil
        primaryAction = primary?.1
        secondaryAction = secondary?.1
        primaryButton.configuration?.title = primary?.0
        secondaryButton.configuration?.title = secondary?.0
        primaryButton.isHidden = primary == nil
        secondaryButton.isHidden = secondary == nil
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }
}

/// Files the extension writes and hands over. Pure apart from the file system and the pasteboard; callable from any
/// thread (NSItemProvider calls back on its own queues).
enum ShareFiles {
    /// Keep in step with `ShareHandoff` (NibKit/Sources/FeatImport/InboxScanner.swift).
    enum Handoff {
        static let link = "nib://import?from=pasteboard"
        static let nameType = "app.nib.share.name"
        static let dataType = "app.nib.share.data"
        static let inboxFolder = "Inbox"
        /// Larger items go through Files: the pasteboard holds them in memory in both processes.
        static let pasteboardLimit = 10 * 1024 * 1024
    }

    /// `<group>/Inbox`, when the sideloading tool registered an App Group for Nib (ALTAppGroups / NibAppGroups).
    static func appGroupInbox() -> URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = ((info["ALTAppGroups"] as? [String]) ?? []) + ((info["NibAppGroups"] as? [String]) ?? [])
        for id in ids {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { continue }
            let inbox = container.appendingPathComponent(Handoff.inboxFolder, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)) != nil { return inbox }
        }
        return nil
    }

    /// Moves each file in under a hidden name first, so Nib never sees a half-written file.
    static func move(_ files: [URL], into inbox: URL) throws {
        let fm = FileManager.default
        for file in files {
            let hidden = inbox.appendingPathComponent("." + UUID().uuidString + ".part")
            try fm.copyItem(at: file, to: hidden)
            try fm.moveItem(at: hidden, to: unique(file.lastPathComponent, in: inbox))
        }
    }

    static func fitsPasteboard(_ files: [URL]) -> Bool {
        !files.contains(where: isDirectory) && totalSize(files) <= Handoff.pasteboardLimit
    }

    @MainActor
    static func putOnPasteboard(_ files: [URL]) throws {
        var items: [[String: Any]] = []
        for file in files {
            let data = try Data(contentsOf: file)
            items.append([Handoff.nameType: Data(file.lastPathComponent.utf8), Handoff.dataType: data])
        }
        UIPasteboard.general.setItems(items, options: [.localOnly: true,
                                                       .expirationDate: Date().addingTimeInterval(3600)])
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func totalSize(_ files: [URL]) -> Int {
        files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// A path-safe file name (no separators, no leading dots).
    static func safeName(_ name: String, fallback: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? fallback : String(s.prefix(200))
    }

    static func unique(_ name: String, in dir: URL) -> URL {
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// A `.webloc` (property list with "URL"): Nib imports the page from its live address.
    static func writeWebLocation(_ url: URL, title: String, in dir: URL) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                                      format: .xml, options: 0)
        let file = unique(safeName(title, fallback: "Web page") + ".webloc", in: dir)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Shared text as a small web page, which Nib lays out as a notebook page (plain text files would be read as
    /// study-set rows).
    static func writeText(_ text: String, title: String, in dir: URL) throws -> URL {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <style>:root { color-scheme: light; } body { font: -apple-system-body; margin: 0; }\
         p { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; }</style></head>\
        <body><p>\(escaped)</p></body></html>
        """
        let file = unique(safeName(title, fallback: "Shared text") + ".html", in: dir)
        try Data(html.utf8).write(to: file, options: .atomic)
        return file
    }
}

/// Reads one shared item into a file. Runs off the main thread (NSItemProvider calls back on its own queues).
enum SharedItemLoader {
    static func load(_ provider: NSItemProvider, into dir: URL) async -> URL? {
        if let typeID = fileTypeID(provider.registeredTypeIdentifiers),
           let url = await loadFile(provider, typeID: typeID, into: dir) {
            return url
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let link = await loadURL(provider), isWebAddress(link) {
            return try? ShareFiles.writeWebLocation(link, title: provider.suggestedName ?? link.host ?? "Web page", in: dir)
        }
        if provider.canLoadObject(ofClass: UIImage.self), let url = await loadImage(provider, into: dir) {
            return url
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let link = URL(string: text), isWebAddress(link), !text.contains(where: { $0.isWhitespace }) {
                return try? ShareFiles.writeWebLocation(link, title: link.host ?? "Web page", in: dir)
            }
            return try? ShareFiles.writeText(text, title: provider.suggestedName ?? "Shared text", in: dir)
        }
        return nil
    }

    /// The best file type on offer: documents, images, archives and folders. Web addresses and plain or rich text
    /// are handled on their own (a web page imports from its address, text as a page).
    static func fileTypeID(_ ids: [String]) -> String? {
        ids.first { id in
            guard let type = UTType(id) else { return false }
            if type.conforms(to: .url) { return false }
            if type.conforms(to: .text) && !type.conforms(to: .html) { return false }
            return type.conforms(to: .data) || type.conforms(to: .directory)
        }
    }

    static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    private static func loadFile(_ provider: NSItemProvider, typeID: String, into dir: URL) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                var name = (suggested?.isEmpty == false ? suggested : nil) ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty {
                    let ext = url.pathExtension.isEmpty ? (UTType(typeID)?.preferredFilenameExtension ?? "") : url.pathExtension
                    if !ext.isEmpty { name += "." + ext }
                }
                let dest = ShareFiles.unique(ShareFiles.safeName(name, fallback: "Shared file"), in: dir)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func loadImage(_ provider: NSItemProvider, into dir: URL) async -> URL? {
        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: (object as? UIImage)?.pngData())
            }
        }
        guard let png = data else { return nil }
        let file = ShareFiles.unique(ShareFiles.safeName(provider.suggestedName ?? "", fallback: "Image") + ".png", in: dir)
        return (try? png.write(to: file, options: .atomic)) == nil ? nil : file
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else if let url = item as? URL, url.isFileURL {
                    continuation.resume(returning: try? String(contentsOf: url, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
