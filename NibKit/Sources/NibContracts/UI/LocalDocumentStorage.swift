import Foundation

/// The app's Files container exists independently of the user's chosen library
/// location. Prepare it before scenes connect so the local document provider can
/// discover Nib even when the library lives in an external folder.
public enum LocalDocumentStorage {
    public static func prepare(documents: URL) throws {
        // Inbox is also the standard destination for documents received via Open
        // In. Never replace or clean it: those files belong to the user.
        try FileManager.default.createDirectory(
            at: documents.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: true)
    }
}
