import Foundation

/// Well-known command ids that features call across module boundaries (owners: ARCHITECTURE.md §6).
/// Calling a command by id is the ONLY way one feature uses another feature's behaviour.
public enum CommandIDs {
    // Contracts (always present)
    public static let undo = "edit.undo"
    public static let redo = "edit.redo"
    public static let historyList = "history.list"
    public static let revertGroup = "history.revertGroup"
    public static let commandsList = "commands.list"
    public static let commandsDescribe = "commands.describe"
    public static let batch = "commands.batch"
    public static let toolSelect = "tool.select"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let settingsList = "settings.list"
    public static let settingsDescribe = "settings.describe"

    // Query / render / recognition
    public static let queryContext = "query.context"
    public static let queryGet = "query.get"
    public static let queryFind = "query.find"
    public static let queryTree = "query.tree"
    /// Owner: F004 (NibRender). {page, scale?, region?, marks?, layers?, background?} →
    /// {asset: "tmp:<name>", pxPerPt, region, marks?}; long edge capped at 1568 px.
    public static let renderPage = "render.page"
    public static let recognizePageText = "recognize.pageText"
    public static let recognizeItems = "recognize.items"
    public static let searchText = "search.text"

    // Ink, items, selection
    public static let inkAddStrokes = "ink.addStrokes"
    public static let inkErase = "ink.erase"
    public static let inkScribbleErase = "ink.scribbleErase"
    public static let inkWriteText = "ink.writeText"
    public static let inkSetPoints = "ink.setPoints"
    public static let itemCreate = "item.create"
    public static let itemUpdate = "item.update"
    public static let itemDelete = "item.delete"
    public static let itemTransform = "item.transform"
    public static let itemMoveToPage = "item.moveToPage"
    public static let selectionSet = "selection.set"
    public static let selectionFromPolygon = "selection.fromPolygon"
    public static let clipboardCopy = "clipboard.copy"
    public static let clipboardPaste = "clipboard.paste"
    public static let shapeRecognize = "shape.recognize"
    public static let shapeCreate = "shape.create"
    public static let diagramCreate = "diagram.create"
    public static let textCreateBox = "text.createBox"
    public static let assetPut = "asset.put"
    /// Stores bytes as a temporary asset ("tmp:<name>", 1 h) that url-taking commands accept.
    public static let assetUpload = "asset.upload"
    /// Owner: F006. Transient DisplayList overlays per page ({page, id, display, ttl?}); plugins: nib.canvas.decorate.
    public static let canvasDecorate = "canvas.decorate"

    // Pages, documents, library, view
    public static let pageAdd = "page.add"
    public static let pageSetTemplate = "page.setTemplate"
    public static let docCreate = "doc.create"
    /// Owner: F018. {doc, page?, mode?: replace|newTab|newWindow} — opens in the active window unless told otherwise.
    public static let docOpen = "doc.open"
    public static let viewGoToPage = "view.goToPage"
    public static let panelOpen = "panel.open"
    public static let importFiles = "import.files"
    public static let exportRun = "export.run"
    public static let appOpenURL = "app.openURL"
    public static let appQuickAction = "app.quickAction"

    // Finger taps, double-taps and long-presses are routed through `app.content.tapHandlers`
    // (TapHandlerDescriptor, lowest order first; built-ins: tape.tapAt 100, comment.tapAt 200, link.tapAt 300,
    // selection.tapAt 400), then to the active tool. There is no fixed tap-chain constant.

    // Extensibility
    public static let pluginInstall = "plugin.install"
    public static let aiAsk = "ai.ask"
}
