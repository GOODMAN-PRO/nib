import Foundation
import CoreGraphics

/// Opt-in fixture decorator around the real renderer. It never supplies fake pixels or alters document data.
/// Only the app shell installs it, after seeding, for an explicitly requested UI-test scenario.
public final class NibUITestRenderer: PageRenderer {
    private let base: PageRenderer
    private let lock = NSLock()
    private var pendingFailure: (DocumentID, PageID)?
    private var failures = 0
    private var purges = 0

    public init(base: PageRenderer, failingPage: (DocumentID, PageID)? = nil) {
        self.base = base
        pendingFailure = failingPage
    }

    public var failureCount: Int { lock.withLock { failures } }
    public var cachePurgeCount: Int { lock.withLock { purges } }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        try Task.checkCancellation()
        // Previews/thumbnails/indexing must not consume the failure before the canvas requests a visible tile.
        let fail = lock.withLock { () -> Bool in
            guard request.purpose == .screen, request.region != nil,
                  let target = pendingFailure, target.0 == request.doc, target.1 == request.page else { return false }
            pendingFailure = nil
            failures += 1
            return true
        }
        if fail { throw NibError.invalid("UI fixture: transient page tile render failure") }
        return try await base.render(request)
    }

    public func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        await base.thumbnail(doc: doc, page: page, maxPixelSize: maxPixelSize)
    }

    public func invalidate(doc: DocumentID, page: PageID, rect: Rect?) {
        base.invalidate(doc: doc, page: page, rect: rect)
    }

    public func purgeCaches() {
        base.purgeCaches()
        lock.withLock { purges += 1 }
    }
}
