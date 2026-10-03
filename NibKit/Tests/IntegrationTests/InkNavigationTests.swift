import XCTest
import UIKit
import NibContracts
import NibTesting
import FeatPen
import FeatWindows
import NibRender
@testable import FeatCanvas
@testable import NibStore

/// Real ink, window commands, canvas and package persistence; only the UIKit scene
/// navigator is headless. It recreates its editor exactly as the app shell does.
@MainActor
final class InkNavigationIntegrationTests: XCTestCase {
    private final class Navigator: SceneNavigator {
        let app: NibApp
        let session: EditorSession
        var openDocuments: [DocumentID] = []
        var activeDocument: DocumentID?
        var rootViewController: UIViewController? { canvas }
        var canvas: CanvasViewController?

        init(_ h: Harness) { app = h.app; session = h.session }
        func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
            canvas?.closeCanvas()
            activeDocument = doc
            if !openDocuments.contains(doc) { openDocuments.append(doc) }
            session.document = doc
            session.page = page ?? (try? app.workspace.content(doc))?.livePages.first?.id
            canvas = app.ui.editors.get(DocumentKind.notebook.rawValue)?.make(doc, session, app) as? CanvasViewController
            canvas?.loadViewIfNeeded()
            canvas?.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
            canvas?.view.setNeedsLayout()
            canvas?.view.layoutIfNeeded()
            canvas?.viewDidLayoutSubviews()
            if let page { canvas?.reveal(page: page, rect: nil, animated: false) }
        }
        func showLibrary(folder: FolderID?) {
            session.document = nil
            canvas?.closeCanvas()
            canvas = nil
        }
        func closeDocument(_ doc: DocumentID) { showLibrary(folder: nil) }
        func showSettings(page: String?) {}
        func presentModal(_ controller: UIViewController) {}
    }

    func testCommittedInkSurvivesLibraryAndFreshStoreWithSamePageAndZoom() async throws {
        let h = Harness(features: [NibRenderFeature.self, FeatCanvasFeature.self, FeatPenFeature.self, FeatWindowsFeature.self])
        defer { try? FileManager.default.removeItem(at: h.persistence.root) }
        let walDirectory = h.persistence.root.appendingPathComponent("navigation-wal", isDirectory: true)
        func freshStore() -> PackagePersistence {
            PackagePersistence(device: h.app.deviceHex, locator: h.app.services.packages,
                events: h.app.events, gate: ReadOnlyGate(), walDirectory: walDirectory)
        }
        let store = freshStore()
        let fixture = try XCTUnwrap(Fixtures.documents().first { $0.content.meta.id == Fixtures.docID })
        let package = try XCTUnwrap(h.app.services.packages.url(Fixtures.docID))
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        store.didChange(Fixtures.docID, head: fixture.content, pages: fixture.items)
        store.flush(Fixtures.docID)
        h.app.workspace.persistence = store
        h.session.document = nil
        let navigator = Navigator(h)
        h.app.ui.activeNavigator = navigator
        _ = h.app.ui.sceneHooks?.restorationActivity(navigator)
        await FeatWindowsFeature.start(h.app)
        try await h.run(CommandIDs.docOpen, ["doc": Scenarios.doc, "page": Scenarios.page])
        try await h.run(CommandIDs.viewZoom, ["scale": 1.75])
        XCTAssertEqual(h.session.page, Fixtures.page2)
        XCTAssertEqual(h.session.zoom, 1.75, accuracy: 0.001)
        let initialCount = try Scenarios.items(h).count
        let committed = expectation(description: "The production canvas commits through ink.addStrokes")
        navigator.canvas?.host.commitStroke(Scenarios.stroke(), page: Fixtures.page2) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            committed.fulfill()
        }
        await fulfillment(of: [committed], timeout: 5)
        let expected = try Scenarios.items(h)
        XCTAssertEqual(expected.count, initialCount + 1)
        try await h.run(CommandIDs.windowShowLibrary)
        XCTAssertNil(h.session.document)
        XCTAssertNil(navigator.canvas)
        // Drop both workspace and store caches: a reopened in-memory document alone
        // cannot prove that the ink actually reached its .nibnote package.
        h.app.workspace.close(Fixtures.docID)
        h.app.workspace.persistence = freshStore()
        try await h.run(CommandIDs.docOpen, ["doc": Scenarios.doc])
        try await Scenarios.wait("restored page and zoom") {
            h.session.page == Fixtures.page2 && abs(h.session.zoom - 1.75) < 0.001
        }
        XCTAssertEqual(try Scenarios.items(h), expected)
        XCTAssertEqual(navigator.canvas?.host.zoomScale ?? 0, 1.75, accuracy: 0.001)
        XCTAssertEqual(h.session.page, Fixtures.page2)
        navigator.showLibrary(folder: nil)
    }
}
