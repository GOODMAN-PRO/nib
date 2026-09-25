import UIKit
import NibContracts
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Apple Image Playground (Apple Intelligence devices, iOS 18.1+): creates an image to insert (the image tool's row)
/// and takes selected text, handwriting and images as its starting concepts (the object menu's "Image Playground").
/// Everywhere else `isAvailable` is false, the rows are hidden and `generate` throws `unsupported`.
@MainActor
enum ImagePlaygroundBridge {
    struct Seed {
        var texts: [String] = []
        var image: UIImage?
    }

    /// Longest text handed to Image Playground as concepts.
    static let maxText = 1000

    static var isAvailable: Bool {
        guard !NibApp.isHostlessTest else { return false }
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) { return ImagePlaygroundViewController.isAvailable }
        #endif
        return false
    }

    /// Concepts from items: typed text (text boxes, sticky notes, shape labels), recognised handwriting
    /// (`recognize.items`, skipped when recognition is not installed) and the first image as the source image.
    static func seed(for refs: [String], ctx: CommandContext) async -> Seed {
        var seed = Seed()
        var ink: [JSONValue] = []
        for ref in refs {
            guard case let .item(doc, page, id)? = NodeRef(ref), let item = try? ctx.workspace.item(doc, page: page, id: id) else {
                continue
            }
            switch item.kind {
            case .text: append(item.text?.text.plainText, to: &seed)
            case .sticky: append(item.sticky?.text.plainText, to: &seed)
            case .shape: append(item.shape?.text?.plainText, to: &seed)
            case .stroke: ink.append(.string(ref))
            case .image:
                if seed.image == nil, let image = item.image, let data = try? ctx.services.assets?.data(image.asset, doc: doc),
                   let rendition = ImageRendition.cgImage(image, flip: ImageFlip(item), data: data, maxPixel: 1024) {
                    seed.image = UIImage(cgImage: rendition)
                }
            default:
                break
            }
        }
        if !ink.isEmpty, let recognised = try? await ctx.execute(CommandIDs.recognizeItems, ["refs": .array(ink)]) {
            append(recognised["text"]?.stringValue, to: &seed)
        }
        return seed
    }

    private static func append(_ text: String?, to seed: inout Seed) {
        let used = seed.texts.reduce(0) { $0 + $1.count }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, used < maxText else { return }
        seed.texts.append(String(t.prefix(maxText - used)))
    }

    /// Presents Image Playground seeded with `seed`; returns the created image's bytes, nil when cancelled.
    static func generate(_ seed: Seed, from presenter: UIViewController) async throws -> Data? {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *), ImagePlaygroundViewController.isAvailable {
            return await PlaygroundSheetSession().run(seed, from: presenter)
        }
        #endif
        throw NibError(.unsupported, "Image Playground is not available on this device",
                       hint: "it needs an Apple Intelligence device on iOS 18.1 or later")
    }
}

#if canImport(ImagePlayground)
@available(iOS 18.1, *)
@MainActor
final class PlaygroundSheetSession: NSObject, ImagePlaygroundViewController.Delegate {
    private var continuation: CheckedContinuation<Data?, Never>?

    func run(_ seed: ImagePlaygroundBridge.Seed, from presenter: UIViewController) async -> Data? {
        let controller = ImagePlaygroundViewController()
        controller.delegate = self
        controller.concepts = PlaygroundSheetSession.concepts(seed.texts)
        controller.sourceImage = seed.image
        return await withCheckedContinuation { c in
            continuation = c
            presenter.present(controller, animated: true)
        }
    }

    /// Short phrases go in as they are; longer notes let Image Playground extract the concepts itself.
    static func concepts(_ texts: [String]) -> [ImagePlaygroundConcept] {
        let joined = texts.joined(separator: "\n")
        guard !joined.isEmpty else { return [] }
        if joined.count > 80 { return [ImagePlaygroundConcept.extracted(from: joined, title: nil)] }
        return texts.map { ImagePlaygroundConcept.text($0) }
    }

    nonisolated func imagePlaygroundViewController(_ imagePlaygroundViewController: ImagePlaygroundViewController,
                                                   didCreateImageAt imageURL: URL) {
        let data = try? Data(contentsOf: imageURL)                 // the file is temporary: read it before returning
        MainActor.assumeIsolated {
            close(imagePlaygroundViewController)
            finish(data)
        }
    }

    nonisolated func imagePlaygroundViewControllerDidCancel(_ imagePlaygroundViewController: ImagePlaygroundViewController) {
        MainActor.assumeIsolated {
            close(imagePlaygroundViewController)
            finish(nil)
        }
    }

    private func close(_ controller: UIViewController) {
        if controller.presentingViewController != nil { controller.dismiss(animated: true) }
    }

    private func finish(_ data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
#endif
