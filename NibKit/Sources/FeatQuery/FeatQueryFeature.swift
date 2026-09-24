import NibContracts

/// F003 — the universal read API (query.*), the raw node/item edit escape hatch (node.*, item.create/update) and
/// document assets (asset.*), used by the AI, plugins and the bridge (ARCHITECTURE §7). Parity: N-001, N-002, N-003.
public enum FeatQueryFeature: NibFeature {
    public static let id = "query"

    public static func register(_ app: NibApp) {
        app.commands.register(QueryContext.self)
        app.commands.register(QueryTree.self)
        app.commands.register(QueryGet.self)
        app.commands.register(QueryFind.self)
        app.commands.register(NodeInsert.self)
        app.commands.register(NodeSet.self)
        app.commands.register(NodeRemove.self)
        app.commands.register(NodeMove.self)
        app.commands.register(ItemCreate.self)
        app.commands.register(ItemUpdate.self)
        app.commands.register(AssetPut.self)
        app.commands.register(AssetGet.self)
        app.commands.register(AssetUpload.self)
    }
}
