import UIKit

/// A library screen supplies the destination under an external file drop. The
/// import feature owns provider loading; it must not import the library UI module.
@MainActor
public protocol LibraryImportDestinationProviding: AnyObject {
    /// A library or folder ref in window coordinates; nil when this screen is
    /// not currently an import destination (for example while showing Trash).
    func libraryImportDestination(at point: CGPoint) -> NodeRef?
}
