import UIKit

public enum CanvasInputMode {
    /// The canvas captures ink with PencilKit (wet ink) and hands the finished stroke to the tool.
    case pencilKit
    /// The tool receives raw samples and draws its own preview into `CanvasHost.overlayLayer`.
    case samples
    /// Taps only (text, sticky, image placement…).
    case taps
}

public struct CanvasSample {
    public var page: PageID
    /// Page coordinates.
    public var location: Point
    public var force: Double
    public var azimuth: Double
    public var altitude: Double
    /// Apple Pencil Pro barrel roll (radians), 0 when unavailable.
    public var roll: Double
    public var timestamp: TimeInterval
    public var isPencil: Bool
    public var isPredicted: Bool
    public var modifiers: KeyModifiers

    public init(page: PageID, location: Point, force: Double = 0.5, azimuth: Double = 0, altitude: Double = .pi / 2,
                roll: Double = 0, timestamp: TimeInterval = 0, isPencil: Bool = true, isPredicted: Bool = false,
                modifiers: KeyModifiers = []) {
        self.page = page
        self.location = location
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.timestamp = timestamp
        self.isPencil = isPencil
        self.isPredicted = isPredicted
        self.modifiers = modifiers
    }
}

/// What the canvas (Canvas feature) offers to tools, gesture handlers and the Pencil handler.
@MainActor
public protocol CanvasHost: AnyObject {
    var app: NibApp { get }
    var session: EditorSession { get }
    var documentID: DocumentID { get }
    /// Current zoom (view points per page point).
    var zoomScale: Double { get }
    /// The scrolling canvas view (for presenting menus, loupes, pencil palettes). Named `canvasView` so a
    /// UIViewController (whose `view` is `UIView!`) can conform.
    var canvasView: UIView { get }
    /// Transient drawing layer of the ACTIVE TOOL in `canvasView` coordinates (previews, lasso path). Cleared by tools.
    /// Anything persistent (selection handles, underlines, presence cursors, minimap…) is a `CanvasAttachment`.
    var overlayLayer: CALayer { get }
    func viewPoint(_ p: Point, page: PageID) -> CGPoint
    /// Page under a view point, with the point in page coordinates.
    func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)?
    /// Page frame in `view` coordinates, nil when not laid out.
    func pageFrame(_ page: PageID) -> CGRect?
    /// Temporarily hide items (drag previews); pass [] to show again.
    func setHidden(_ ids: Set<ElementID>, page: PageID)
    func invalidate(page: PageID, rect: Rect?)
    /// Commits a finished stroke through `ink.addStrokes` (applies stroke processors first).
    func commitStroke(_ stroke: Stroke, page: PageID)
    /// Cancels the in-progress PencilKit stroke (Draw-and-Hold takes over).
    func cancelWetStroke()
    /// Keeps a live view (animated GIF, video, plugin view) positioned over an item's frame; nil removes it.
    func attachLiveView(_ view: UIView?, item: ElementID, page: PageID)
}

/// A canvas tool. Registered via `UIRegistries.canvasTools`; activated by `tool.select`.
@MainActor
public protocol CanvasTool: AnyObject {
    var id: String { get }
    var inputMode: CanvasInputMode { get }
    /// Sticky tools stay active; non-sticky tools return to the previous tool after one use.
    var isSticky: Bool { get }
    /// `.pencilKit` tools: the ink to capture with.
    func inkStyle(_ host: CanvasHost) -> InkStyle?
    func activate(_ host: CanvasHost)
    func deactivate(_ host: CanvasHost)
    /// `.pencilKit`: a stroke finished (processors not yet applied). Default commits it.
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost)
    /// `.pencilKit`: the pen was held still at the end of a stroke. Return true to consume it: the wet stroke is
    /// cancelled and the rest of that touch arrives through `touchesMoved` / `touchesEnded` (Draw-and-Hold).
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)
    func tap(_ sample: CanvasSample, host: CanvasHost)
    /// Touch held still for 0.5 s on the page (after attachments and `content.tapHandlers` declined it).
    func longPress(_ sample: CanvasSample, host: CanvasHost)
    func hover(_ sample: CanvasSample?, host: CanvasHost)
}

@MainActor
public extension CanvasTool {
    var isSticky: Bool { true }
    func inkStyle(_ host: CanvasHost) -> InkStyle? { nil }
    func activate(_ host: CanvasHost) {}
    func deactivate(_ host: CanvasHost) {}
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) { host.commitStroke(stroke, page: page) }
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
    func tap(_ sample: CanvasSample, host: CanvasHost) {}
    func longPress(_ sample: CanvasSample, host: CanvasHost) {}
    func hover(_ sample: CanvasSample?, host: CanvasHost) {}
}

/// Something that lives on the canvas independently of the active tool: selection handles (F012), shape control
/// points (F031), connector bends and quick-diagram dots (F032), spellcheck underlines (F104), Math Assist glow
/// (F106), presence cursors (F108), minimap (F044), ruler (F039), zoom box (F038), plugin decorations
/// (`canvas.decorate`), answer-zone widgets (F099). Registered through `ui.canvasAttachments`; the canvas creates
/// one instance per canvas host and gives it its own layer/view.
@MainActor
public protocol CanvasAttachment: AnyObject {
    /// Add sublayers/subviews to `host.canvasView` here; called once per canvas (document opened).
    func attach(to host: CanvasHost)
    func detach(from host: CanvasHost)
    /// Scroll, zoom, page layout, selection or a commit changed: reposition what you draw.
    func canvasDidChange(_ host: CanvasHost)
    /// True = this attachment takes the touch that starts at `viewPoint` (asked before tap handlers and the active
    /// tool, in registry order); the touch's samples then go to the touch methods below.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)
}

@MainActor
public extension CanvasAttachment {
    func detach(from host: CanvasHost) {}
    func canvasDidChange(_ host: CanvasHost) {}
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
}

public struct CanvasAttachmentDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var docKinds: Set<DocumentKind>
    public var make: @MainActor (CanvasHost) -> CanvasAttachment

    public init(id: String, owner: String, order: Int = 0, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                make: @escaping @MainActor (CanvasHost) -> CanvasAttachment) {
        self.id = id
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.make = make
    }
}

/// Apple Pencil hardware events forwarded by the canvas (Pencil Hardware feature).
@MainActor
public protocol PencilEventHandler: AnyObject {
    func pencilDoubleTap(session: EditorSession, host: CanvasHost)
    func pencilSqueeze(began: Bool, location: CGPoint?, session: EditorSession, host: CanvasHost)
    func pencilHover(_ sample: CanvasSample?, session: EditorSession, host: CanvasHost)
}

/// Implemented by every document editor view controller (canvas, text document, study set).
@MainActor
public protocol DocumentEditing: AnyObject {
    var documentID: DocumentID { get }
    var session: EditorSession { get }
    /// nil for editors without a page canvas.
    var canvasHost: CanvasHost? { get }
    func reveal(page: PageID, rect: Rect?, animated: Bool)
    func reloadAll()
}
