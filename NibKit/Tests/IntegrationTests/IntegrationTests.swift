import XCTest

/// Cross-feature acceptance belongs here, with scenario names visible in CI's XCTest report.
@MainActor
final class IntegrationTests: XCTestCase {
    func testLibraryCaptureRecipeDismissesSearchBeforeListAndFolderStates() async throws {
        try await Scenarios.libraryCaptureStates()
    }

    func testLassoCaptureRecipeRevealsShapeAndReportsSelectionBeforeObjectMenu() async throws {
        try await Scenarios.lassoCaptureState()
    }

    func testCanvasPencilKitHandoffCommitsInkAndUndoRedo() async throws {
        try await Scenarios.canvasToInk()
    }

    func testCanvasReadOnlyRejectsInkWithoutHistory() async throws {
        try await Scenarios.canvasReadOnly()
    }

    func testAIToolCallsFormOneUndoGroupAndHistoryRevertsOnlyThatTurn() async throws {
        try await Scenarios.aiTurnAndHistory()
    }

    func testAIAskCannotMutateThroughToolCalls() async throws {
        try await Scenarios.aiAskIsReadOnly()
    }

    func testScannedPageIsSearchableAndUndoRemovesItsSearchHit() async throws {
        try await Scenarios.scanToSearch()
    }

    func testLibraryRepairRecreatesDeletedCatalogWithoutChangingPackages() async throws {
        try await Scenarios.repairCatalog()
    }

    func testTemplateFromPageUsesRealFlattenedPDFExport() async throws {
        try await Scenarios.pageToTemplate()
    }

    func testToolCatalogNibRenderReturnsResolvableItemMarksAndPNG() async throws {
        try await Scenarios.renderMarks()
    }

    func testInstalledJavaScriptExampleStorageSurvivesPluginReloadAndReinstall() async throws {
        try await Scenarios.pluginStorage()
    }
}
