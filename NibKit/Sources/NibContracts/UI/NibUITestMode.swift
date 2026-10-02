import Foundation

/// Opt-in launch configuration shared by the real app and its UI renderers. Never enables hostless-test fakes.
public enum NibUITestMode {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-NibUITestFixture")
    /// One fresh directory per process; the library, catalogue and fixture settings cannot reach the user's library.
    public static let rootURL: URL? = isEnabled
        ? FileManager.default.temporaryDirectory.appendingPathComponent("NibUITests-" + UUID().uuidString, isDirectory: true)
        : nil
}
