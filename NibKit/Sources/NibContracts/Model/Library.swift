import Foundation

public struct FolderStyle: Codable, Hashable {
    public var color: RGBA?
    /// SF Symbol name or a single emoji.
    public var icon: String?
    public var favorite: Bool

    public init(color: RGBA? = nil, icon: String? = nil, favorite: Bool = false) {
        self.color = color
        self.icon = icon
        self.favorite = favorite
    }
}

public enum LibraryNodeKind: String, Codable, CaseIterable { case folder, document }

/// Sync state shown on library thumbnails.
public enum SyncBadge: String, Codable, CaseIterable { case synced, syncing, downloading, error, localOnly }

/// A folder or document as listed by the library catalog (derived, rebuilt from disk).
public struct LibraryNode: Codable, Hashable, Identifiable {
    /// Document id, or the folder id stored in the folder's `.nibfolder.<dev>.json` files.
    public var id: NibID
    public var kind: LibraryNodeKind
    /// Package / folder name without extension.
    public var title: String
    /// Library-relative path, "/"-separated.
    public var path: String
    /// Parent folder; nil = library root.
    public var parent: FolderID?
    public var documentKind: DocumentKind?
    /// Unix seconds.
    public var modified: Double
    public var created: Double
    public var favorite: Bool
    public var locked: Bool
    public var pageCount: Int?
    public var style: FolderStyle?
    public var sync: SyncBadge
    public var trashedAt: Double?

    public init(id: NibID, kind: LibraryNodeKind, title: String, path: String, parent: FolderID? = nil,
                documentKind: DocumentKind? = nil, modified: Double = 0, created: Double = 0, favorite: Bool = false,
                locked: Bool = false, pageCount: Int? = nil, style: FolderStyle? = nil, sync: SyncBadge = .localOnly,
                trashedAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.parent = parent
        self.documentKind = documentKind
        self.modified = modified
        self.created = created
        self.favorite = favorite
        self.locked = locked
        self.pageCount = pageCount
        self.style = style
        self.sync = sync
        self.trashedAt = trashedAt
    }
}
