import XCTest
import NibContracts
import NibTesting
@testable import FeatPages

@MainActor
final class PageLocalizationTests: XCTestCase {
    func testFrenchPageAddCarriesTranslatedTitleIntoHistoryAndUndo() async throws {
        try await checkPageAdd(language: "fr", add: "Ajouter une page", undo: "Annuler %@",
                               expectedUndo: "Annuler Ajouter une page")
    }

    func testEnglishPageAddKeepsHistoryAndUndoTitles() async throws {
        try await checkPageAdd(language: "en", add: "Add Page", undo: "Undo %@", expectedUndo: "Undo Add Page")
    }

    private func checkPageAdd(language: String, add: String, undo: String, expectedUndo: String) async throws {
        // These are the app catalogue's translations. A temporary language bundle avoids global
        // AppleLanguages changes and needs no resource/build-file changes in another owner's lane.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let languageURL = root.appendingPathComponent(language + ".lproj")
        try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let strings = "\"Add Page\" = \"\(add)\";\n\"Undo %@\" = \"\(undo)\";\n"
        try strings.write(to: languageURL.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: languageURL))
        let locale = Locale(identifier: language)
        let h = Harness(features: [FeatPagesFeature.self])
        let entry = try XCTUnwrap(h.app.commands.entry(CommandIDs.pageAdd))
        let descriptor = PageAdd.localizedDescriptor(bundle: bundle, locale: locale)
        XCTAssertEqual(descriptor.title, add)
        // Run the real registered page.add handler, with the same descriptor factory configured for French.
        h.app.commands.register(descriptor, handler: entry.handler)
        _ = try await h.run(CommandIDs.pageAdd, ["position": "end"])
        let rows = try await h.run(CommandIDs.historyList, ["doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(rows["entries"]?.arrayValue?.first?["label"]?.stringValue, add)
        let label = try XCTUnwrap(h.app.bus.history.undoLabel(Fixtures.docID))
        XCTAssertEqual(label, add)
        // Resolve the localized Undo template against the actual stored step (the Undo UI contract).
        // The literal history label must already be translated; interpolation does not translate it.
        let title = String(localized: "Undo \(label)", bundle: bundle, locale: locale)
        XCTAssertEqual(title, expectedUndo)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(h.app.bus.history.redoLabel(Fixtures.docID), add)
    }
}
