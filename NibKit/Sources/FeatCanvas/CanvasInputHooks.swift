import UIKit
import NibContracts

/// The seam between the canvas (F006) and its input half (F101, `FeatCanvasInputFeature`, same module). The canvas
/// never references the input half's types: F101 fills these hooks in its `register`, so each half compiles and runs
/// on its own (ARCHITECTURE §3, split features). Without F101 the canvas scrolls, zooms, renders, hosts attachments
/// and tools, and offers double-tap zoom; it just captures no ink.
///
/// What the input half gets from `CanvasHostImpl` (all main actor):
/// - `scrollView` (the `canvasView`), `wetInkContainer` (above the pages, below attachments, scroll-content
///   coordinates: put the wet-ink `PKCanvasView`s here), `fixedOverlayView`, `overlayLayer`;
/// - `activeTool` (made from `ui.canvasTools` for `session.tool`, activated and deactivated by the canvas),
///   `attachments` (registry order, for hit-testing claimed touches), `isReadOnly` / `isInkEnabled`;
/// - `topmostItem(at:page:)` (the `ref` a tap handler gets), `visibleLayers`, `pageFrame` / `pageTransform` /
///   `pagePoint`, `zoomScale`;
/// - `beginInking(page:strokeBounds:)` / `updateInking(page:strokeBounds:)` / `endInking()`: the window's
///   `EditorSession.inking` signal (contracts-v2, G12), from page coordinates;
/// - `commitStroke(_:page:completion:)` (stroke processors, then `ink.addStrokes`) and `afterNextRender(page:_:)`:
///   remove a wet stroke only in the completion's `afterNextRender`, so nothing flickers;
/// - `doubleTapZoomRecognizer` and `zoomToggle(at:)`: once F101 routes finger double-taps (attachments, then
///   `content.tapHandlers`, then the tool), it disables the recogniser and calls `zoomToggle(at:)` for a double-tap
///   nothing claimed.
enum CanvasInputHooks {
    /// Installs the input half on a canvas that just loaded its view (wet ink, touch pipeline, palm rejection, gesture
    /// routing, Pencil interactions). Set by F101's `register`; nil when the input half is not built or disabled.
    static var install: ((CanvasHostImpl) -> Void)?
}

/// What the canvas tells its input half. F101 sets `CanvasHostImpl.inputController` inside `CanvasInputHooks.install`;
/// every method has a default, so the input half implements only what it needs.
@MainActor
protocol CanvasInputController: AnyObject {
    /// Scroll, zoom, page layout or a commit changed where pages are (reposition the wet canvas, keep its zoom).
    func canvasDidChange(_ host: CanvasHostImpl)
    /// A zoom (pinch or programmatic) ended at a new scale.
    func canvasDidEndZooming(_ host: CanvasHostImpl)
    /// The current page (`session.page`) changed.
    func canvasActivePageDidChange(_ host: CanvasHostImpl)
    /// `activeTool` changed (activation already happened).
    func canvasActiveToolDidChange(_ host: CanvasHostImpl)
    /// Read-only mode or the document's writability changed: `isInkEnabled` has the new value.
    func canvasReadOnlyDidChange(_ host: CanvasHostImpl)
    /// `CanvasHost.cancelWetStroke()`: drop the in-progress or just-finished wet stroke (idempotent).
    func canvasCancelWetStroke(_ host: CanvasHostImpl)
    /// The canvas is closing: tear down (the controller is released right after).
    func canvasWillClose(_ host: CanvasHostImpl)
}

@MainActor
extension CanvasInputController {
    func canvasDidChange(_ host: CanvasHostImpl) {}
    func canvasDidEndZooming(_ host: CanvasHostImpl) {}
    func canvasActivePageDidChange(_ host: CanvasHostImpl) {}
    func canvasActiveToolDidChange(_ host: CanvasHostImpl) {}
    func canvasReadOnlyDidChange(_ host: CanvasHostImpl) {}
    func canvasCancelWetStroke(_ host: CanvasHostImpl) {}
    func canvasWillClose(_ host: CanvasHostImpl) {}
}
