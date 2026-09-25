import SwiftUI
import UIKit
import NibContracts
import NibDesign

// MARK: - Crop editing (pure)

/// The eight rigid handles of the rectangle crop (DESIGN.md §10.15: precision handles never deform).
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    func point(in r: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? r.minX : (movesRight ? r.maxX : r.midX),
                y: movesTop ? r.minY : (movesBottom ? r.maxY : r.midY))
    }
}

/// Crop rects in normalised image coordinates (0…1, top-left origin).
enum CropEditing {
    /// Smallest crop the handles allow, as a fraction of the image.
    static let minimumSize = 0.05

    /// Moves one handle (nil = the whole rect) by a normalised delta from `start`, staying inside the image.
    static func drag(_ start: Rect, handle: CropHandle?, dx: Double, dy: Double) -> Rect {
        guard let handle = handle else {
            let x = min(max(start.x + dx, 0), 1 - start.width), y = min(max(start.y + dy, 0), 1 - start.height)
            return Rect(x: x, y: y, width: start.width, height: start.height)
        }
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if handle.movesLeft { minX = min(max(minX + dx, 0), maxX - minimumSize) }
        if handle.movesRight { maxX = max(min(maxX + dx, 1), minX + minimumSize) }
        if handle.movesTop { minY = min(max(minY + dy, 0), maxY - minimumSize) }
        if handle.movesBottom { maxY = max(min(maxY + dy, 1), minY + minimumSize) }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The largest centred crop whose pixel aspect is `ratio` (width / height) on an image of `imageAspect`.
    static func aspect(_ ratio: Double, imageAspect: Double) -> Rect {
        let normalised = ratio / max(imageAspect, 1e-9)
        if normalised >= 1 {
            let h = 1 / normalised
            return Rect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        return Rect(x: (1 - normalised) / 2, y: 0, width: normalised, height: 1)
    }

    /// Grows or shrinks about the centre (the VoiceOver adjustable action), staying inside the image.
    static func scaled(_ r: Rect, by factor: Double) -> Rect {
        let w = min(max(r.width * factor, minimumSize), 1), h = min(max(r.height * factor, minimumSize), 1)
        let x = min(max(r.midX - w / 2, 0), 1 - w), y = min(max(r.midY - h / 2, 0), 1 - h)
        return Rect(x: x, y: y, width: w, height: h)
    }
}

enum CropMode: CaseIterable {
    case rectangle, freehand

    var title: String {
        switch self {
        case .rectangle: return String(localized: "Rectangle")
        case .freehand: return String(localized: "Freehand")
        }
    }
}

/// Shape presets: the action equivalents of dragging the handles.
enum CropAspect: CaseIterable {
    case full, square, fourThree, threeFour, sixteenNine

    var title: String {
        switch self {
        case .full: return String(localized: "Whole Image")
        case .square: return String(localized: "Square")
        case .fourThree: return String(localized: "4:3")
        case .threeFour: return String(localized: "3:4")
        case .sixteenNine: return String(localized: "16:9")
        }
    }

    var ratio: Double? {
        switch self {
        case .full: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

// MARK: - Crop sheet

/// Crop Image: an opaque sheet (no liquid on an editing surface) with the whole image as the page shows it (mirrored
/// like the item), a rectangle with eight rigid 12 pt handles in 44 pt targets, or a freehand lasso. Everything here
/// is in display space; the presenter converts to image space.
struct ImageCropSheet: View {
    let image: UIImage
    let onCancel: () -> Void
    let onCrop: (CropRequest) -> Void

    @State private var mode: CropMode
    @State private var rect: Rect
    @State private var outline: [Point]
    @State private var drawing: [Point] = []
    @State private var dragStart: Rect?
    @State private var aspect: CropAspect?

    init(image: UIImage, rect: Rect, mask: [Point]?, onCancel: @escaping () -> Void,
         onCrop: @escaping (CropRequest) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onCrop = onCrop
        _mode = State(initialValue: mask == nil ? .rectangle : .freehand)
        _rect = State(initialValue: rect)
        _outline = State(initialValue: mask ?? [])
    }

    private var imageAspect: Double { Double(image.size.width / max(image.size.height, 1)) }
    private var canCrop: Bool { mode == .rectangle || outline.count >= 3 }

    var body: some View {
        VStack(spacing: NibSpacing.m) {
            NibSheetHeader(String(localized: "Crop Image"), primaryTitle: String(localized: "Crop"),
                           isPrimaryEnabled: canCrop, onCancel: onCancel, onPrimary: commit)
            NibSegmentedControl(selection: $mode, options: CropMode.allCases) { $0.title }
                .padding(.horizontal, NibSpacing.xl)
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .accessibilityHidden(true)
                    if mode == .rectangle {
                        rectangleOverlay(size)
                    } else {
                        freehandOverlay(size)
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.horizontal, NibSpacing.xxl)
            footer
        }
        .padding(.bottom, NibSpacing.l)
        .background(NibColor.backgroundSecondary)
    }

    private func fitted(in space: CGSize) -> CGSize {
        let w = max(space.width, 1), h = max(space.height, 1)
        let a = CGFloat(imageAspect)
        return w / h > a ? CGSize(width: h * a, height: h) : CGSize(width: w, height: w / a)
    }

    private func rectangleOverlay(_ size: CGSize) -> some View {
        let r = CGRect(x: rect.x * Double(size.width), y: rect.y * Double(size.height),
                       width: rect.width * Double(size.width), height: rect.height * Double(size.height))
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(NibColor.scrim, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Path(r)
                .stroke(NibColor.accent, lineWidth: 2)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(nil, size))
            ForEach(CropHandle.allCases, id: \.self) { handle in
                Circle()
                    .fill(NibColor.background)
                    .overlay(Circle().stroke(NibColor.accent, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .frame(width: NibMetrics.hitTarget, height: NibMetrics.hitTarget)
                    .contentShape(Rectangle())
                    .hoverEffect(.highlight)
                    .position(handle.point(in: r))
                    .gesture(drag(handle, size))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Crop area"))
        .accessibilityValue(String(localized: "\(Int((rect.width * 100).rounded())) per cent wide, \(Int((rect.height * 100).rounded())) per cent tall"))
        .accessibilityHint(String(localized: "Swipe up or down to grow or shrink the crop."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rect = CropEditing.scaled(rect, by: 1.1)
            case .decrement: rect = CropEditing.scaled(rect, by: 0.9)
            @unknown default: break
            }
            aspect = nil
        }
    }

    private func drag(_ handle: CropHandle?, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = rect }
                rect = CropEditing.drag(start, handle: handle, dx: Double(g.translation.width / max(size.width, 1)),
                                        dy: Double(g.translation.height / max(size.height, 1)))
                aspect = nil
            }
            .onEnded { _ in dragStart = nil }
    }

    private func freehandOverlay(_ size: CGSize) -> some View {
        let source = drawing.isEmpty ? outline : drawing
        let pts = source.map { CGPoint(x: $0.x * Double(size.width), y: $0.y * Double(size.height)) }
        let closed = drawing.isEmpty && outline.count >= 3
        return ZStack(alignment: .topLeading) {
            if closed {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addLines(pts)
                    p.closeSubpath()
                }
                .fill(NibColor.scrim, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            }
            if pts.count > 1 {
                Path { p in
                    p.addLines(pts)
                    if closed { p.closeSubpath() }
                }
                .stroke(NibColor.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        drawing.append(Point(min(max(Double(g.location.x / max(size.width, 1)), 0), 1),
                                             min(max(Double(g.location.y / max(size.height, 1)), 0), 1)))
                    }
                    .onEnded { _ in
                        if drawing.count >= 3 { outline = drawing }
                        drawing = []
                    })
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Freehand crop area"))
        .accessibilityHint(String(localized: "Draw around the part to keep. With VoiceOver, choose Rectangle and a shape below."))
    }

    private var footer: some View {
        VStack(spacing: NibSpacing.s) {
            if mode == .rectangle {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NibSpacing.s) {
                        ForEach(CropAspect.allCases, id: \.self) { a in
                            NibChip(a.title, style: .filter(isSelected: aspect == a), action: { apply(a) })
                        }
                    }
                    .padding(.horizontal, NibSpacing.xl)
                }
            } else {
                Text(String(localized: "Draw around the part of the image to keep."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NibSpacing.xl)
            }
            NibButton(String(localized: "Reset Crop"), kind: .plain, size: .compact) {
                rect = ImageGeometry.unit
                outline = []
                aspect = .full
            }
        }
    }

    private func apply(_ a: CropAspect) {
        rect = a.ratio.map { CropEditing.aspect($0, imageAspect: imageAspect) } ?? ImageGeometry.unit
        aspect = a
    }

    private func commit() {
        switch mode {
        case .rectangle: onCrop(.rect(rect))
        case .freehand: onCrop(.mask(outline))
        }
    }
}

/// Presents the crop sheet for `image.crop` called by the user without rect or mask (the object menu's Crop).
@MainActor
enum ImageCropPresenter {
    static func ask(doc: DocumentID, page: PageID, id: ElementID, ctx: CommandContext) async throws -> CropRequest? {
        let item = try ctx.workspace.item(doc, page: page, id: id)
        guard let image = item.image else {
            throw NibError(.invalidParams, "item \(id.raw) is a \(item.kind.rawValue), not an image", path: "$.ref")
        }
        guard !NibApp.isHostlessTest else { throw NibError.unavailable("the crop sheet (hostless test)") }
        let data = try ImageAssets.store(ctx).data(image.asset, doc: doc)
        let flip = ImageFlip(item)
        guard let whole = ImageRendition.cgImage(ImageItem(frame: image.frame, asset: image.asset), flip: flip, data: data,
                                                 maxPixel: 1600) else {
            throw NibError(.internalError, "could not decode the image")
        }
        let presenter = try ImagePresenter.top(ctx.activeSession)
        let result = await present(UIImage(cgImage: whole), rect: flip.mirror(image.crop ?? ImageGeometry.unit),
                                   mask: image.mask.map { flip.mirror($0) }, from: presenter)
        switch result {
        case .rect(let r)?: return .rect(flip.mirror(r))
        case .mask(let m)?: return .mask(flip.mirror(m))
        case nil: return nil
        }
    }

    private static func present(_ image: UIImage, rect: Rect, mask: [Point]?,
                                from presenter: UIViewController) async -> CropRequest? {
        await withCheckedContinuation { continuation in
            let box = WeakController()
            var done = false
            let finish: (CropRequest?) -> Void = { result in
                guard !done else { return }
                done = true
                box.controller?.dismiss(animated: true)
                continuation.resume(returning: result)
            }
            let sheet = ImageCropSheet(image: image, rect: rect, mask: mask, onCancel: { finish(nil) },
                                       onCrop: { finish($0) })
            let controller = UIHostingController(rootView: sheet)
            controller.modalPresentationStyle = .formSheet
            controller.isModalInPresentation = true                // Cancel or Crop always answers the command
            controller.preferredContentSize = CGSize(width: 640, height: 760)
            box.controller = controller
            presenter.present(controller, animated: true)
        }
    }
}

// MARK: - Image inspector (Style for selected images)

/// The inspector the object menu's Style opens for images: Crop, Flip, Replace, Save to Photos, Image Playground.
struct ImageInspector: View {
    let app: NibApp
    let session: EditorSession
    let doc: DocumentID
    let page: PageID
    let items: [Item]

    private var refs: [String] {
        items.filter { $0.kind == .image }.map { NodeRef.item(doc, page, $0.id).description }
    }

    var body: some View {
        let refs = self.refs
        let single = refs.count == 1 ? refs.first : nil
        let editable = !session.readOnly
        NibInspectorSection(refs.count > 1 ? String(localized: "\(refs.count) Images") : String(localized: "Image")) {
            VStack(spacing: 0) {
                if let ref = single, editable {
                    row(String(localized: "Crop"), icon: ImageIcons.crop) {
                        [(command: "image.crop", params: ["ref": .string(ref)])]
                    }
                }
                if editable {
                    row(String(localized: "Flip Horizontally"), icon: ImageIcons.flipHorizontal) {
                        refs.map { (command: "image.flip", params: ["ref": .string($0), "axis": "horizontal"]) }
                    }
                    row(String(localized: "Flip Vertically"), icon: ImageIcons.flipVertical) {
                        refs.map { (command: "image.flip", params: ["ref": .string($0), "axis": "vertical"]) }
                    }
                }
                if let ref = single {
                    if editable {
                        row(String(localized: "Replace Image"), icon: ImageIcons.replace) {
                            [(command: "image.pick", params: ["source": "photos", "ref": .string(ref)])]
                        }
                    }
                    row(String(localized: "Save to Photos"), icon: ImageIcons.saveToPhotos) {
                        [(command: "image.saveToPhotos", params: ["ref": .string(ref)])]
                    }
                }
                if editable && ImagePlaygroundBridge.isAvailable {
                    row(String(localized: "Image Playground"), icon: ImageIcons.playground) {
                        [(command: "image.pick", params: ["source": "playground", "refs": .array(refs.map { .string($0) })])]
                    }
                }
            }
        }
    }

    private func row(_ title: String, icon: String,
                     calls: @escaping () -> [(command: String, params: JSONValue)]) -> some View {
        Button {
            ImageUI.run(app, calls(), session: session)
        } label: {
            NibInspectorRow(title, symbol: NibSymbol(systemName: icon) ?? .image)
                .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
    }
}
