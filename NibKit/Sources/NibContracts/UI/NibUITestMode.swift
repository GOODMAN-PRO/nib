import Foundation

/// Opt-in launch configuration shared by the real app and its UI renderers. Never enables hostless-test fakes.
public enum NibUITestMode {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-NibUITestFixture")
    public static let scenario = NibUITestScenario.parse(ProcessInfo.processInfo.arguments)
    /// One fresh directory per process; the library, catalogue and fixture settings cannot reach the user's library.
    public static let rootURL: URL? = isEnabled
        ? FileManager.default.temporaryDirectory.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        : nil
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
