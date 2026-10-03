import Foundation

/// Opt-in launch configuration shared by the real app and its UI renderers. Never enables hostless-test fakes.
public enum NibUITestMode {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-NibUITestFixture")
    public static let scenario = NibUITestScenario.parse(ProcessInfo.processInfo.arguments)
    /// One fresh directory per process; the library, catalogue and fixture settings cannot reach the user's library.
    public static let rootURL: URL? = isEnabled
        ? FileManager.default.temporaryDirectory.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        : nil

    /// Called before features open their stores. Each simulator/app installation has its own temporary container;
    /// a terminated fixture process cannot clean up after itself, so the next launch reclaims its packages.
    public static func prepareStorage() throws {
        guard let rootURL else { return }
        try NibUITestStorage.prepare(root: rootURL, in: FileManager.default.temporaryDirectory)
    }
}

public enum NibUITestStorage {
    /// Only direct, UUID-named fixture directories belong to us. Never traverse symlinks or clean another app's
    /// container, production library, result bundles, or unrelated temporary files. Errors remain real failures.
    public static func prepare(root: URL, in temporaryDirectory: URL) throws {
        let fm = FileManager.default
        let parent = temporaryDirectory.standardizedFileURL
        let current = root.standardizedFileURL
        func isFixtureName(_ name: String) -> Bool {
            let prefix = "NibUITests-"
            return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        guard current.deletingLastPathComponent() == parent, isFixtureName(current.lastPathComponent) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var currentExists = false
        for entry in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys)) {
            guard isFixtureName(entry.lastPathComponent) else { continue }
            let values = try entry.resourceValues(forKeys: keys)
            if entry.standardizedFileURL == current {
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileWriteFileExists)
                }
                currentExists = true
            } else if values.isDirectory == true && values.isSymbolicLink != true {
                try fm.removeItem(at: entry)
            }
        }
        if !currentExists { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
    }
}

/// Extra prerequisites are explicit so ordinary canvas tests retain their four-page notebook and one board.
public enum NibUITestScenario: String, CaseIterable {
    case standard, failedRender, largeDocument, unseenBoards

    public static func parse(_ arguments: [String]) -> Self {
        guard arguments.contains("-NibUITestFixture"),
              let index = arguments.firstIndex(of: "-NibUITestScenario"),
              arguments.indices.contains(index + 1) else { return .standard }
        return Self(rawValue: arguments[index + 1]) ?? .standard
    }

    public var notebookPageCount: Int { self == .largeDocument ? 300 : 4 }

    /// A local first board and two changed, offscreen boards. Keeping the changed boards offscreen avoids the
    /// production dwell-to-mark-seen behaviour consuming the prerequisite before the user opens Select mode.
    public static func unseenBoardContent(localDevice: UInt32) -> DocumentContent {
        let remote = Rev(wallMs: 1, counter: 0, device: localDevice ^ 1)
        let pages = FractionalIndex.balanced(count: 3).enumerated().map { index, order in
            var page = PageRecord(order: order, size: nil, title: "Board \(index + 1)")
            page.rev = index == 0 ? .zero : remote
            return page
        }
        return DocumentContent(meta: DocumentMeta(kind: .whiteboard), pages: pages)
    }
}
