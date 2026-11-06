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
    case standard, failedRender, largeDocument, unseenBoards, tabsOverflow, timerHistory

    public static func parse(_ arguments: [String]) -> Self {
        guard arguments.contains("-NibUITestFixture"),
              let index = arguments.firstIndex(of: "-NibUITestScenario"),
              arguments.indices.contains(index + 1) else { return .standard }
        return Self(rawValue: arguments[index + 1]) ?? .standard
    }

    public var notebookPageCount: Int { self == .largeDocument ? 300 : 4 }

    /// Oldest to newest; Time Keeper displays the saved sessions in reverse order.
    public var timerHistoryNames: [String] {
        self == .timerHistory ? (1...6).map { "Chrome history \($0)" } : []
    }

    public var overflowTabTitles: [String] {
        self == .tabsOverflow ? (2...9).map { "Chrome tab \($0)" } : []
    }

    /// The fixture notebook is first. Use the same registered commands as Document Editing,
    /// library taps and tab selection; explicitly request newTab regardless of the user's default.
    public func tabSetupCommands(documents: [DocumentID]) throws -> [(command: String, params: JSONValue)] {
        guard self == .tabsOverflow else { return [] }
        guard documents.count == 9, Set(documents).count == 9 else {
            throw NibError.invalid("The tabsOverflow fixture requires nine distinct notebooks")
        }
        var commands: [(command: String, params: JSONValue)] = [
            (CommandIDs.settingsSet, ["name": "editing.showTabs", "value": true])
        ]
        commands += documents.map { doc -> (command: String, params: JSONValue) in
            (CommandIDs.docOpen, ["doc": .string(NodeRef.document(doc).description), "mode": "newTab"])
        }
        commands.append((CommandIDs.tabSelect, ["index": 0]))
        return commands
    }

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

/// Fixture mode only: the last hardware key events the app saw and what it did with them. `nib.qa.state` reports
/// them as `keyLog`, so a failed UI-test chord shows whether the key arrived, where, and which command ran.
public enum NibUITestKeyLog {
    private static let lock = NSLock()
    private static var entries: [String] = []
    private static var count = 0

    public static func note(_ entry: @autoclosure () -> String) {
        guard NibUITestMode.isEnabled else { return }
        let text = entry()
        lock.lock(); defer { lock.unlock() }
        count += 1
        entries.append(text)
        if entries.count > 24 { entries.removeFirst(entries.count - 24) }
    }

    public static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// All notes since launch, including entries evicted from the bounded recent log.
    public static var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
