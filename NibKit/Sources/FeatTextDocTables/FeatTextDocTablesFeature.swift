import UIKit
import NibContracts
import NibDesign

/// Text-document tables (F048): the `table.*` commands, the table block's view in the text-document editor
/// (`ui.blockViews`), the Table entry of the slash and Turn Into menus (`content.blockKinds`), table entries in the
/// block menu (`ui.menus` at `.block`), and the CSV exporter in Share & Export (`content.exporters`).
public enum FeatTextDocTablesFeature: NibFeature {
    public static let id = "tables"

    public static func register(_ app: NibApp) {
        app.commands.register(TableEdit.self)
        app.commands.register(TableExportCSV.self)

        app.ui.blockViews.register(BlockViewDescriptor(kind: .table, owner: id) { context in
            TableBlockView(context: context)
        })
        app.content.blockKinds.register(TableFeatureParts.blockKind(owner: id))
        app.content.exporters.register(TableExport.exporter(owner: id))
        for item in TableFeatureParts.blockMenuItems(owner: id) { app.ui.menus.register(item) }
    }
}

/// What `register` fills in, kept apart so the tests can read it.
@MainActor
enum TableFeatureParts {
    static let blockKindID = "tables.table"

    /// "Table" in the slash menu and Turn Into: a plain block.insert {kind: "table"} (3 × 3, F047's default).
    static func blockKind(owner: String) -> BlockKindDescriptor {
        BlockKindDescriptor(id: blockKindID, title: String(localized: "Table"), icon: NibSymbol.table.name, kind: .table,
                            owner: owner, order: 330, params: ["kind": .string(BlockKind.table.rawValue)],
                            aliases: ["table", "grid", "tbl", "cells", "|"])
    }

    /// Block menu entries (the block handle menu of text documents) for table blocks: add a row or a column at the
    /// end, and cell borders on or off.
    static func blockMenuItems(owner: String) -> [MenuItemDescriptor] {
        var borders = MenuItemDescriptor(
            id: "tables.block.borders", title: String(localized: "Cell Borders"), icon: NibSymbol.table.name,
            location: .block, order: 520, owner: owner, command: "table.edit",
            params: { ctx in
                let on = table(ctx)?.borders ?? true
                return ["ref": .string(ctx.ref ?? ""), "op": .string(TableEditOp.setBorders.rawValue), "borders": .bool(!on)]
            },
            isVisible: { ctx in editable(ctx) && table(ctx) != nil })
        borders.isChecked = { ctx in table(ctx)?.borders ?? true }
        return [
            MenuItemDescriptor(
                id: "tables.block.addRow", title: String(localized: "Add Row"), icon: NibSymbol.plus.name,
                location: .block, order: 500, owner: owner, command: "table.edit",
                params: { ctx in ["ref": .string(ctx.ref ?? ""), "op": .string(TableEditOp.insertRowAfter.rawValue)] },
                isVisible: { ctx in editable(ctx) && canGrow(ctx, rows: true) }),
            MenuItemDescriptor(
                id: "tables.block.addColumn", title: String(localized: "Add Column"), icon: NibSymbol.plus.name,
                location: .block, order: 510, owner: owner, command: "table.edit",
                params: { ctx in ["ref": .string(ctx.ref ?? ""), "op": .string(TableEditOp.insertColumnAfter.rawValue)] },
                isVisible: { ctx in editable(ctx) && canGrow(ctx, rows: false) }),
            borders
        ]
    }

    static func editable(_ ctx: MenuContext) -> Bool {
        guard ctx.session?.readOnly != true else { return false }
        if let ref = ctx.ref, case let .block(doc, _)? = NodeRef(ref), ctx.app.isReadOnly(doc) { return false }
        return true
    }

    /// The table of the block a block-menu context points at (nil for other kinds).
    static func table(_ ctx: MenuContext) -> TableData? {
        guard let ref = ctx.ref, case let .block(doc, id)? = NodeRef(ref),
              let block = try? ctx.app.workspace.content(doc).liveBlocks.first(where: { $0.id == id }),
              block.kind == .table else { return nil }
        return TableOps.normalized(block.table)
    }

    static func canGrow(_ ctx: MenuContext, rows: Bool) -> Bool {
        guard let t = table(ctx) else { return false }
        return rows ? t.rows.count < TableOps.maxRows : TableOps.columnCount(t) < TableOps.maxColumns
    }
}
