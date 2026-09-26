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

    // contracts-v2: more catalogue ids features call across modules (owners: ARCHITECTURE.md §6.5)
    public static let selectionClear = "selection.clear"
    public static let textSetText = "text.setText"
    public static let libraryRename = "library.rename"
    public static let clipboardCut = "clipboard.cut"
    public static let itemRecolor = "item.recolor"
    public static let itemDuplicate = "item.duplicate"
    public static let viewReveal = "view.reveal"
    public static let viewSetReadOnly = "view.setReadOnly"
    public static let panelClose = "panel.close"
    public static let audioPlay = "audio.play"
    /// Contracts (always present): shows the library in the invoking window {folder?} (session).
    public static let windowShowLibrary = "window.showLibrary"
}

/// contracts-v2: well-known panel ids, so a feature can open another feature's panel with `panel.open {id}` without
/// guessing by owner. Owners register their panels under exactly these ids.
public enum PanelIDs {
    /// AI chat panel (F085).
    public static let assistant = "aichat.panel"
    /// Library Trash tab (F020).
    public static let trash = "organize.trash"
    /// Library Favourites tab (F020).
    public static let favourites = "organize.favourites"
    /// Manage Templates (F045).
    public static let templates = "templateui.manage"
    /// Cloud & Backup (F070).
    public static let cloudBackup = "syncui.panel"
    /// About (F098).
    public static let about = "about.panel"
    /// Plugin and content Gallery library tab (F080).
    public static let gallery = "pluginmanager.gallery"
    /// Study set Practice and Smart Learn panels (F050).
    public static let studyPractice = "studysession.practice"
    public static let studyLearn = "studysession.learn"
}
