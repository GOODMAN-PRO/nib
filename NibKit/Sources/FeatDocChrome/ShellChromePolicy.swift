import UIKit
import NibContracts

/// Shared with the app shell so its presentation decisions are covered by package tests.
@MainActor
public enum ShellChromePolicy {
    public static func makeTabBar(openDocuments: [DocumentID], make: () -> UIView?) -> UIView? {
        guard !openDocuments.isEmpty else { return nil }
        return make()
    }
}
