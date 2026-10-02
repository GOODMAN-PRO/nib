import Foundation
import NibContracts

/// Uses the same command-driven seed path as onboarding's SampleNotebook, with real package persistence.
@MainActor
enum UITestFixture {
    static var isReady = false
    static var failure: String?

    static func defaults() -> UserDefaults {
        guard NibUITestMode.isEnabled else { return .standard }
        let name = "app.nib.uitest"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // A suite otherwise also searches the app domain. Remove that fallback to isolate production preferences.
        if let bundle = Bundle.main.bundleIdentifier { defaults.removeSuite(named: bundle) }
        return defaults
    }

    static func configure(_ app: NibApp) {
        guard NibUITestMode.isEnabled else { return }
        app.settings.setJSON("onboarding.done", true)
        app.settings.set(NibSettings.stylusMode, .anyInput)
        app.settings.set(NibSettings.liquidMode, "off")
    }

    static func seed(_ app: NibApp) async throws {
        guard NibUITestMode.isEnabled else { return }
        @discardableResult
        func run(_ command: String, _ params: JSONValue) async throws -> JSONValue {
            try await app.bus.execute(command, params)
        }
        func create(_ kind: String, _ title: String, pages: Int = 1, folder: String? = nil) async throws -> JSONValue {
            var params: [String: JSONValue] = ["kind": .string(kind), "title": .string(title)]
            if kind == "notebook" {
                params["pages"] = .number(Double(pages))
                params["cover"] = false
            }
            if let folder { params["folder"] = .string(folder) }
            return try await run("doc.create", .object(params))
        }
        func page(_ result: JSONValue) throws -> JSONValue {
            guard let first = result["pages"]?.arrayValue?.first else {
                throw NibError.invalid("Fixture document has no page")
            }
            return first
        }
        let folder = try await run("folder.create", ["title": "Semester Notes"])
        _ = try await create("notebook", "Lecture notes", folder: folder["ref"]?.stringValue)
        let physics = try await create("notebook", "Physics — Motion", pages: 4)
        let paper = try page(physics)
        try await run("text.createBox", ["page": paper, "frame": [72, 64, 350, 48], "text": "Motion and forces"])
        try await run("shape.create", ["page": paper, "shape": "rectangle", "frame": [100, 200, 160, 90]])
        try await run("sticky.create", ["page": paper, "at": [400, 120], "text": "Remember F = ma"])
        try await run("ink.addStrokes", ["page": paper, "strokes": [["fmt": "xy", "pts": [72, 140, 112, 145, 152, 138, 192, 143]]]])
        let board = try await create("whiteboard", "Concept map")
        let boardPage = try page(board)
        try await run("shape.create", ["page": boardPage, "shape": "ellipse", "frame": [0, 0, 200, 120], "text": "Motion"])
        try await run("sticky.create", ["page": boardPage, "at": [260, 40], "text": "Acceleration"])
        try await run("text.createBox", ["page": boardPage, "at": [40, 180], "text": "Velocity changes over time"])
        let text = try await create("textDocument", "Lab report")
        try await run("block.insert", ["doc": text["ref"] ?? .null, "kind": "paragraph", "text": "Measure distance and time, then calculate velocity."])
        let study = try await create("studySet", "Motion flashcards")
        for (front, back) in [("Velocity", "Displacement per unit time"), ("Acceleration", "Change in velocity per unit time"), ("Force", "Mass times acceleration")] {
            try await run("card.add", ["doc": study["ref"] ?? .null, "front": .string(front), "back": .string(back)])
        }
        let listing = try await run("library.list", [:])
        guard listing["nodes"]?.arrayValue?.contains(where: { $0["title"]?.stringValue == "Physics — Motion" }) == true else {
            throw NibError.invalid("Fixture is missing from library.list: " + listing.jsonString())
        }
        for doc in app.workspace.loadedDocuments { app.bus.history.clear(doc) }
    }
}
