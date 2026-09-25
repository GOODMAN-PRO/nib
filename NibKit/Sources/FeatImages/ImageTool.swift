import SwiftUI
import UIKit
import Photos
import PhotosUI
import AVFoundation
import VisionKit
import UniformTypeIdentifiers
import NibContracts
import NibDesign

// MARK: - The canvas tool

/// Canvas tool "image" (key I, taps only, non-sticky): a tap on the page opens the Insert Image menu at that spot
/// (recent photos, Photos, Camera, Scan Document, Files, Image Playground, Paste; images can also be dropped on it).
/// The image lands centred where the tap was, then the previous tool comes back.
@MainActor
final class ImageTool: CanvasTool {
    static let toolID = "image"
    let id = ImageTool.toolID
    let inputMode: CanvasInputMode = .taps
    let isSticky = false

    func tap(_ sample: CanvasSample, host: CanvasHost) {
        guard !host.session.readOnly else { return }
        ImageMenuController.present(from: host, page: sample.page, point: sample.location)
    }

    func deactivate(_ host: CanvasHost) {
        ImageMenuController.dismissCurrent()
    }
}

/// Where a menu choice inserts: the tapped spot, or (from the palette's popover) the visible centre of the page.
struct ImageMenuTarget {
    var doc: DocumentID
    var page: PageID
    var point: Point?

    var pageRef: String { NodeRef.page(doc, page).description }

    @MainActor
    static func current(_ session: EditorSession) -> ImageMenuTarget? {
        guard let doc = session.document, let page = session.page else { return nil }
        return ImageMenuTarget(doc: doc, page: page, point: nil)
    }
}

// MARK: - Running commands from image UI

@MainActor
enum ImageUI {
    /// Runs commands as the user in one undo group, like `NibApp.perform` (failures reach the shell's toast). When items
    /// were created, the non-sticky image tool hands back to the previous tool and the new items are selected.
    static func run(_ app: NibApp, _ calls: [(command: String, params: JSONValue)], session: EditorSession?) {
        guard !calls.isEmpty else { return }
        Task { @MainActor in
            let group = NibID.make().raw
            var created: [String] = []
            for call in calls {
                do {
                    let r = try await app.bus.execute(Invocation(command: call.command, params: call.params, principal: .user,
                                                                 session: session, group: group))
                    created += ImagePick.refs(in: r.value).filter { $0.hasPrefix("item:") }
                } catch {
                    NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                    userInfo: ["command": call.command, "error": NibError.wrap(error)])
                    return
                }
            }
            guard !created.isEmpty, let session = session else { return }
            if session.tool == ImageTool.toolID, let previous = session.previousTool, previous != ImageTool.toolID {
                _ = try? await app.bus.execute(CommandIDs.toolSelect, ["tool": .string(previous)], session: session)
            }
            _ = try? await app.bus.execute(CommandIDs.selectionSet, ["refs": .array(created.map { .string($0) })],
                                           session: session)
        }
    }

    /// image.insert calls for bytes the menu already holds (recent photos, paste, drop): each is stored as a
    /// temporary asset and passed as a tmp: url, centred on the target and cascaded.
    static func insertCalls(_ images: [Data], target: ImageMenuTarget, app: NibApp,
                            session: EditorSession?) -> [(command: String, params: JSONValue)] {
        guard let store = app.services.assets,
              let page = try? app.workspace.content(target.doc).page(target.page) else { return [] }
        let base = target.point ?? ImagePlacement.centre(of: page, doc: target.doc, session: session)
        var calls: [(command: String, params: JSONValue)] = []
        for (i, data) in images.enumerated() {
            guard let info = ImageDecoder.info(data), let tmp = try? store.putTemporary(data, ext: info.fileExtension) else { continue }
            let offset = Double(i) * ImagePlacement.cascade
            let f = ImagePlacement.frame(size: ImagePlacement.size(pixels: info.pixelSize, page: page.size),
                                         centre: Point(base.x + offset, base.y + offset), page: page.size)
            let frame: JSONValue = .array([.number(f.x), .number(f.y), .number(f.w), .number(f.h)])
            let params: JSONValue = ["page": .string(target.pageRef), "url": .string("tmp:" + tmp.name), "frame": frame]
            calls.append((command: "image.insert", params: params))
        }
        return calls
    }
}

// MARK: - The Insert Image menu (a Deep menu, not a grid: DESIGN.md §14.3)

extension ImagePickSource {
    var title: String {
        switch self {
        case .photos: return String(localized: "Photos")
        case .camera: return String(localized: "Camera")
        case .scan: return String(localized: "Scan Document")
        case .files: return String(localized: "Files")
        case .paste: return String(localized: "Paste")
        case .playground: return String(localized: "Image Playground")
        }
    }

    var hint: String {
        switch self {
        case .photos: return String(localized: "Choose photos from your library")
        case .camera: return String(localized: "Take a photo and insert it")
        case .scan: return String(localized: "Scan paper with the camera and insert the pages as images")
        case .files: return String(localized: "Choose image files")
        case .paste: return String(localized: "Insert the copied image")
        case .playground: return String(localized: "Create an image with Apple Intelligence")
        }
    }

    var symbol: NibSymbol {
        switch self {
        case .photos: return .image
        case .camera: return .camera
        case .scan: return .scan
        case .files: return .folder
        case .paste: return NibSymbol(systemName: ImageIcons.paste) ?? .importFile
        case .playground: return NibSymbol(systemName: ImageIcons.playground) ?? .image
        }
    }

    /// The rows this device can offer.
    @MainActor
    static var menuRows: [ImagePickSource] {
        var rows: [ImagePickSource] = [.photos]
        if UIImagePickerController.isSourceTypeAvailable(.camera) { rows.append(.camera) }
        if VNDocumentCameraViewController.isSupported { rows.append(.scan) }
        rows.append(.files)
        if ImagePlaygroundBridge.isAvailable { rows.append(.playground) }
        return rows
    }
}

/// SF Symbol names this feature adds to NibSymbol's set (menu and toolbar descriptors take strings).
enum ImageIcons {
    static let tool = "photo"
    static let crop = "crop"
    static let flipHorizontal = "arrow.left.and.right.righttriangle.left.righttriangle.right"
    static let flipVertical = "arrow.up.and.down.righttriangle.up.righttriangle.down"
    static let replace = "arrow.2.squarepath"
    static let saveToPhotos = "square.and.arrow.down"
    static let playground = "apple.image.playground"
    static let paste = "doc.on.clipboard"
    static let camera = "camera"
}

/// The menu body: recent photos, the picker rows and Paste; the whole menu accepts dropped images. Hosted in a popover
/// at the tapped spot (the tool) or in the palette's own popover (tapping the selected image tool).
struct ImageSourceMenu: View {
    let app: NibApp
    let session: EditorSession
    let target: () -> ImageMenuTarget?
    /// Closes the menu, then runs the continuation (a picker cannot present while the menu is going away).
    let close: (@escaping () -> Void) -> Void

    @StateObject private var recent = RecentPhotos()
    @State private var dropTargeted = false
    @State private var hasPasteboardImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            RecentPhotosSection(recent: recent, insert: insertRecent)
            VStack(spacing: 0) {
                ForEach(ImagePickSource.menuRows, id: \.self) { source in
                    Button {
                        choose(source)
                    } label: {
                        NibInspectorRow(source.title, symbol: source.symbol)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                    .accessibilityHint(source.hint)
                }
            }
            if hasPasteboardImage {
                PasteButton(supportedContentTypes: [.image]) { providers in
                    Task { @MainActor in insert(providers) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
            }
        }
        .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in insert(providers) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: NibRadius.proposal, style: .continuous)
                    .strokeBorder(NibColor.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            hasPasteboardImage = UIPasteboard.general.hasImages
        }
        .onAppear {
            hasPasteboardImage = UIPasteboard.general.hasImages
            recent.load()
        }
    }

    private func choose(_ source: ImagePickSource) {
        guard let t = target() else { return }
        var params: [String: JSONValue] = ["source": .string(source.rawValue), "page": .string(t.pageRef)]
        if let p = t.point { params["point"] = .array([.number(p.x), .number(p.y)]) }
        let app = self.app, session = self.session
        close { ImageUI.run(app, [(command: "image.pick", params: .object(params))], session: session) }
    }

    private func insert(_ providers: [NSItemProvider]) {
        guard let t = target() else { return }
        let app = self.app, session = self.session, close = self.close
        Task { @MainActor in
            let images = await ImageProviders.load(providers)
            guard !images.isEmpty else { return }
            close { ImageUI.run(app, ImageUI.insertCalls(images, target: t, app: app, session: session), session: session) }
        }
    }

    private func insertRecent(_ asset: PHAsset) {
        guard let t = target() else { return }
        let app = self.app, session = self.session, close = self.close, recent = self.recent
        Task { @MainActor in
            guard let data = await recent.data(for: asset) else { return }
            close { ImageUI.run(app, ImageUI.insertCalls([data], target: t, app: app, session: session), session: session) }
        }
    }
}

// MARK: - Recent photos strip

@MainActor
final class RecentPhotos: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var status: PHAuthorizationStatus = .notDetermined
    let manager = PHCachingImageManager()

    func load() {
        guard !NibApp.isHostlessTest else { return }
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 24
        var list: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    /// Asked only when the person taps "Show Recent Photos" (PHPicker itself needs no permission).
    func requestAccess() {
        Task { @MainActor in
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            load()
        }
    }

    /// The original bytes (HEIC stays HEIC, PNG keeps transparency, GIF keeps its frames), iCloud originals included.
    func data(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

struct RecentPhotosSection: View {
    @ObservedObject var recent: RecentPhotos
    let insert: (PHAsset) -> Void

    var body: some View {
        switch recent.status {
        case .authorized, .limited:
            if !recent.assets.isEmpty {
                NibInspectorSection(String(localized: "Recent Photos")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: NibSpacing.s) {
                            ForEach(recent.assets, id: \.localIdentifier) { asset in
                                RecentPhotoCell(asset: asset, manager: recent.manager) { insert(asset) }
                            }
                        }
                    }
                    .frame(height: NibSpacing.x6)
                }
            }
        case .notDetermined:
            NibButton(String(localized: "Show Recent Photos"), symbol: .image, kind: .plain, size: .compact) {
                recent.requestAccess()
            }
        default:
            EmptyView()
        }
    }
}

struct RecentPhotoCell: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let action: () -> Void
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            ZStack {
                NibColor.fill3
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: NibSpacing.x6, height: NibSpacing.x6)
            .clipShape(RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
        .accessibilityLabel(label)
        .accessibilityHint(String(localized: "Inserts this photo"))
        .onAppear { requestThumbnail() }
    }

    private var label: String {
        guard let date = asset.creationDate else { return String(localized: "Photo") }
        return String(localized: "Photo, \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func requestThumbnail() {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        let side = NibSpacing.x6 * displayScale
        manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                             options: options) { image, _ in
            DispatchQueue.main.async { thumbnail = image }
        }
    }
}

// MARK: - Popover host for the tool

/// The Insert Image menu as a popover at the tapped spot (iPad), a medium-detent sheet on iPhone. ⎋ closes it.
@MainActor
final class ImageMenuController: UIViewController {
    private static weak var current: ImageMenuController?
    private let hosting: UIHostingController<AnyView>

    init(content: AnyView) {
        hosting = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = .preferredContentSize
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = container.preferredContentSize
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeMenu))]
    }

    @objc private func closeMenu() { dismiss(animated: true) }

    static func present(from host: CanvasHost, page: PageID, point: Point) {
        dismissCurrent()
        guard var presenter = ImagePresenter.owner(of: host.canvasView) else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let app = host.app, session = host.session
        let target = ImageMenuTarget(doc: host.documentID, page: page, point: point)
        let box = WeakController()
        let menu = ImageSourceMenu(app: app, session: session, target: { target }, close: { then in
            guard let controller = box.controller, controller.presentingViewController != nil else { return then() }
            controller.dismiss(animated: true, completion: then)
        })
        let controller = ImageMenuController(content: AnyView(NibPopoverPanel(title: String(localized: "Insert Image")) { menu }))
        box.controller = controller
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.canvasView
            let v = host.viewPoint(point, page: page)
            popover.sourceRect = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            popover.permittedArrowDirections = .any
            let sheet = popover.adaptiveSheetPresentationController
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        current = controller
        presenter.present(controller, animated: true)
    }

    static func dismissCurrent() {
        guard let c = current, c.presentingViewController != nil, !c.isBeingDismissed else { return }
        c.dismiss(animated: true)
    }
}

final class WeakController {
    weak var controller: UIViewController?
}

// MARK: - Presenting system pickers

@MainActor
enum ImagePresenter {
    /// The topmost view controller of the invoking window (commands present pickers and sheets from it).
    static func top(_ session: EditorSession?) throws -> UIViewController {
        let root = (session?.editor as? UIViewController)?.view.window?.rootViewController
            ?? NibApp.shared?.ui.activeNavigator?.rootViewController
        guard var top = root else { throw NibError.unavailable("an open window to show the picker in") }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    static func owner(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

@MainActor
enum ImagePickers {
    /// Shows the picker for `source` and returns the chosen images' bytes (empty when cancelled). `limit` 0 = any number.
    static func pick(_ source: ImagePickSource, limit: Int, seed: ImagePlaygroundBridge.Seed = ImagePlaygroundBridge.Seed(),
                     from presenter: UIViewController) async throws -> [Data] {
        switch source {
        case .photos:
            return await ImageProviders.load(PhotosPickerSession().run(limit: limit, from: presenter))
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { throw NibError.unsupported("a camera on this device") }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .denied || status == .restricted {
                throw NibError(.userDenied, "Nib is not allowed to use the camera",
                               hint: "allow it in Settings › Privacy & Security › Camera")
            }
            return await CameraSession().run(from: presenter).map { [$0] } ?? []
        case .scan:
            guard VNDocumentCameraViewController.isSupported else { throw NibError.unsupported("document scanning on this device") }
            return await ScanSession().run(from: presenter)
        case .files:
            return await FilesSession().run(multiple: limit != 1, from: presenter)
        case .paste:
            return await ImageProviders.load(UIPasteboard.general.itemProviders)
        case .playground:
            return try await ImagePlaygroundBridge.generate(seed, from: presenter).map { [$0] } ?? []
        }
    }
}

/// Image bytes out of item providers (PHPicker, paste, drop), preferring GIF and PNG so animation and transparency
/// survive.
enum ImageProviders {
    static func load(_ providers: [NSItemProvider]) async -> [Data] {
        var out: [Data] = []
        for provider in providers {
            if let data = await load(provider) { out.append(data) }
        }
        return out
    }

    static func load(_ provider: NSItemProvider) async -> Data? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
        guard let type = types.first(where: { $0.conforms(to: .gif) }) ?? types.first(where: { $0.conforms(to: .png) })
            ?? types.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

@MainActor
final class PhotosPickerSession: NSObject, PHPickerViewControllerDelegate {
    private var continuation: CheckedContinuation<[NSItemProvider], Never>?

    func run(limit: Int, from presenter: UIViewController) async -> [NSItemProvider] {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = limit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        return await withCheckedContinuation { c in
            continuation = c
            presenter.present(picker, animated: true)
        }
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        MainActor.assumeIsolated {
            picker.dismiss(animated: true)
            continuation?.resume(returning: results.map { $0.itemProvider })
            continuation = nil
        }
    }
}

@MainActor
final class CameraSession: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var continuation: CheckedContinuation<Data?, Never>?

    func run(from presenter: UIViewController) async -> Data? {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        return await withCheckedContinuation { c in
            continuation = c
            presenter.present(picker, animated: true)
        }
    }

    /// "Use Photo": the JPEG keeps the capture orientation in its EXIF, which every decode applies.
    nonisolated func imagePickerController(_ picker: UIImagePickerController,
                                           didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        MainActor.assumeIsolated {
            picker.dismiss(animated: true)
            finish(image?.jpegData(compressionQuality: 0.9))
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        MainActor.assumeIsolated {
            picker.dismiss(animated: true)
            finish(nil)
        }
    }

    private func finish(_ data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
final class ScanSession: NSObject, VNDocumentCameraViewControllerDelegate {
    private var continuation: CheckedContinuation<[Data], Never>?

    func run(from presenter: UIViewController) async -> [Data] {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        return await withCheckedContinuation { c in
            continuation = c
            presenter.present(scanner, animated: true)
        }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                  didFinishWith scan: VNDocumentCameraScan) {
        MainActor.assumeIsolated {
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.85) }
            controller.dismiss(animated: true)
            finish(pages)
        }
    }

    nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            finish([])
        }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            finish([])
        }
    }

    private func finish(_ pages: [Data]) {
        continuation?.resume(returning: pages)
        continuation = nil
    }
}

@MainActor
final class FilesSession: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<[Data], Never>?

    func run(multiple: Bool, from presenter: UIViewController) async -> [Data] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        return await withCheckedContinuation { c in
            continuation = c
            presenter.present(picker, animated: true)
        }
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let images = urls.compactMap { try? Data(contentsOf: $0) }
        MainActor.assumeIsolated { finish(images) }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { finish([]) }
    }

    private func finish(_ images: [Data]) {
        continuation?.resume(returning: images)
        continuation = nil
    }
}
