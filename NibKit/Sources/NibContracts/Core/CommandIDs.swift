import Foundation

/// Well-known command ids that features call across module boundaries (owners: ARCHITECTURE.md §6).
/// Calling a command by id is the ONLY way one feature uses another feature's behaviour.
/// Since contracts-v2.1 every id in the §6.5 catalogue has a constant here.
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

    // contracts-v2.1: a constant for every other id in the ARCHITECTURE.md §6.5 catalogue, by namespace in catalogue
    // order, with the owning feature. NibContractsTests/CommandCatalogueTests checks that every catalogue row has one.

    public static let a11yDescribePage = "a11y.describePage"  // F095

    public static let aiChatList = "ai.chat.list"  // F084
    public static let aiChatRename = "ai.chat.rename"  // F084
    public static let aiChatDelete = "ai.chat.delete"  // F084
    public static let aiChatFeedback = "ai.chat.feedback"  // F084
    public static let aiProviderList = "ai.provider.list"  // F086
    public static let aiProviderSave = "ai.provider.save"  // F086
    public static let aiProviderActivate = "ai.provider.activate"  // F086
    public static let aiProviderDelete = "ai.provider.delete"  // F086
    public static let aiProviderTest = "ai.provider.test"  // F086
    public static let aiQuiz = "ai.quiz"  // F087

    public static let answerZoneCreate = "answerZone.create"  // F099
    public static let answerZoneScore = "answerZone.score"  // F099
    public static let answerZoneSetHints = "answerZone.setHints"  // F099
    public static let answerZoneRevealHint = "answerZone.revealHint"  // F099

    public static let appDeleteAllData = "app.deleteAllData"  // F098

    public static let assetGet = "asset.get"  // F003

    public static let audioRecord = "audio.record"  // F052
    public static let audioPause = "audio.pause"  // F052
    public static let audioSeek = "audio.seek"  // F052
    public static let audioSetPlayback = "audio.setPlayback"  // F052
    public static let audioRename = "audio.rename"  // F052
    public static let audioDelete = "audio.delete"  // F052
    public static let audioExport = "audio.export"  // F052
    public static let audioQuickRecord = "audio.quickRecord"  // F052

    public static let backupNow = "backup.now"  // F068
    public static let backupManual = "backup.manual"  // F068
    public static let backupConfigure = "backup.configure"  // F068
    public static let backupChooseFolder = "backup.chooseFolder"  // F068
    public static let backupStatus = "backup.status"  // F068
    public static let backupClearQueue = "backup.clearQueue"  // F068

    public static let blockInsert = "block.insert"  // F047
    public static let blockUpdate = "block.update"  // F047
    public static let blockDelete = "block.delete"  // F047
    public static let blockMove = "block.move"  // F047
    public static let blockComment = "block.comment"  // F103
    public static let blockEditComment = "block.editComment"  // F103
    public static let blockDeleteComment = "block.deleteComment"  // F103
    public static let blockResolveComment = "block.resolveComment"  // F103

    public static let boardAdd = "board.add"  // F044
    public static let boardRename = "board.rename"  // F044
    public static let boardInsertTemplate = "board.insertTemplate"  // F044

    public static let bridgeSetEnabled = "bridge.setEnabled"  // F090
    public static let bridgeStatus = "bridge.status"  // F090

    public static let calendarEvents = "calendar.events"  // F075
    public static let calendarCreateNote = "calendar.createNote"  // F075
    public static let calendarOpenNote = "calendar.openNote"  // F075

    public static let canvasClearDecorations = "canvas.clearDecorations"  // F006

    public static let cardAdd = "card.add"  // F049
    public static let cardUpdate = "card.update"  // F049
    public static let cardDelete = "card.delete"  // F049
    public static let cardMove = "card.move"  // F049
    public static let cardMoveTo = "card.moveTo"  // F049

    public static let clipboardCopyText = "clipboard.copyText"  // F014

    public static let collabHost = "collab.host"  // F072
    public static let collabJoin = "collab.join"  // F072
    public static let collabLeave = "collab.leave"  // F072
    public static let collabParticipants = "collab.participants"  // F072
    public static let collabApprove = "collab.approve"  // F072
    public static let collabSetRole = "collab.setRole"  // F072
    public static let collabRevoke = "collab.revoke"  // F072
    public static let collabFollow = "collab.follow"  // F108
    public static let collabFollowMe = "collab.followMe"  // F108
    public static let collabMarkSeen = "collab.markSeen"  // F108

    public static let commentAdd = "comment.add"  // F037
    public static let commentReply = "comment.reply"  // F037
    public static let commentEdit = "comment.edit"  // F037
    public static let commentDeleteMessage = "comment.deleteMessage"  // F037
    public static let commentResolve = "comment.resolve"  // F037
    public static let commentTapAt = "comment.tapAt"  // F037

    public static let connectorCreate = "connector.create"  // F032
    public static let connectorSetPath = "connector.setPath"  // F032

    public static let diagnosticsExport = "diagnostics.export"  // F076
    public static let diagnosticsSetFeatureEnabled = "diagnostics.setFeatureEnabled"  // F076

    public static let diagramAddConnected = "diagram.addConnected"  // F032

    public static let dictionaryAdd = "dictionary.add"  // F104
    public static let dictionaryRemove = "dictionary.remove"  // F104
    public static let dictionaryList = "dictionary.list"  // F104

    public static let docSetFavorite = "doc.setFavorite"  // F002
    public static let docMerge = "doc.merge"  // F002
    public static let docSetScrollDirection = "doc.setScrollDirection"  // F017
    public static let docQuickNote = "doc.quickNote"  // F021
    public static let docConvertToWhiteboard = "doc.convertToWhiteboard"  // F044
    public static let docSetLanguage = "doc.setLanguage"  // F057
    public static let docSetWritingAids = "doc.setWritingAids"  // F104
    public static let docSetLocked = "doc.setLocked"  // F071
    public static let docUnlock = "doc.unlock"  // F071
    public static let docSuggestTitle = "doc.suggestTitle"  // F087

    public static let elementCreate = "element.create"  // F035
    public static let elementInsert = "element.insert"  // F035
    public static let elementCollectionCreate = "element.collection.create"  // F035
    public static let elementCollectionUpdate = "element.collection.update"  // F035
    public static let elementCollectionDelete = "element.collection.delete"  // F035
    public static let elementCollectionList = "element.collection.list"  // F035
    public static let elementList = "element.list"  // F035
    public static let elementRename = "element.rename"  // F035
    public static let elementDelete = "element.delete"  // F035
    public static let elementImport = "element.import"  // F035
    public static let elementExport = "element.export"  // F035

    public static let exportPresent = "export.present"  // F067
    public static let exportSaveToSource = "export.saveToSource"  // F067

    public static let folderCreate = "folder.create"  // F002
    public static let folderSetStyle = "folder.setStyle"  // F002

    public static let galleryList = "gallery.list"  // F080

    public static let gifSearch = "gif.search"  // F035

    public static let handwritingToText = "handwriting.toText"  // F057
    public static let handwritingToTextPages = "handwriting.toTextPages"  // F057
    public static let handwritingWords = "handwriting.words"  // F058
    public static let handwritingReflow = "handwriting.reflow"  // F058
    public static let handwritingStraighten = "handwriting.straighten"  // F058
    public static let handwritingAlign = "handwriting.align"  // F058
    public static let handwritingInsertSpace = "handwriting.insertSpace"  // F058
    public static let handwritingReplaceWord = "handwriting.replaceWord"  // F059
    public static let handwritingRestyle = "handwriting.restyle"  // F105

    public static let imageInsert = "image.insert"  // F034
    public static let imageCrop = "image.crop"  // F034
    public static let imageFlip = "image.flip"  // F034
    public static let imageReplace = "image.replace"  // F034
    public static let imageSaveToPhotos = "image.saveToPhotos"  // F034
    public static let imagePick = "image.pick"  // F034

    public static let importPick = "import.pick"  // F064

    public static let indexRebuild = "index.rebuild"  // F055

    public static let inkSetStyle = "ink.setStyle"  // F007

    public static let itemArrange = "item.arrange"  // F013
    public static let itemSetLocked = "item.setLocked"  // F013

    public static let laserSetMode = "laser.setMode"  // F040
    public static let laserPoint = "laser.point"  // F040

    public static let layerSetActive = "layer.setActive"  // F041
    public static let layerSetVisible = "layer.setVisible"  // F041
    public static let layerRename = "layer.rename"  // F041
    public static let layerMoveItems = "layer.moveItems"  // F041
    public static let layerExportOptions = "layer.exportOptions"  // F041

    public static let lessonCreate = "lesson.create"  // F109
    public static let lessonSetState = "lesson.setState"  // F109
    public static let lessonImportRoster = "lesson.importRoster"  // F109
    public static let lessonCollect = "lesson.collect"  // F110
    public static let lessonCluster = "lesson.cluster"  // F110
    public static let lessonSetClusters = "lesson.setClusters"  // F110

    public static let libraryList = "library.list"  // F002
    public static let libraryMove = "library.move"  // F002
    public static let libraryDuplicate = "library.duplicate"  // F002
    public static let libraryTrash = "library.trash"  // F002
    public static let librarySetView = "library.setView"  // F019
    public static let libraryReorder = "library.reorder"  // F019
    public static let libraryChooseFolder = "library.chooseFolder"  // F025
    public static let libraryRelocate = "library.relocate"  // F025
    public static let libraryLocations = "library.locations"  // F025
    public static let librarySwitch = "library.switch"  // F025
    public static let libraryRepair = "library.repair"  // F070

    public static let linkSet = "link.set"  // F029
    public static let linkRemove = "link.remove"  // F029
    public static let linkFollow = "link.follow"  // F029
    public static let linkBack = "link.back"  // F029
    public static let linkAutodetect = "link.autodetect"  // F029
    public static let linkTapAt = "link.tapAt"  // F029

    public static let lockSetup = "lock.setup"  // F071

    public static let mathRecognize = "math.recognize"  // F060
    public static let mathConvert = "math.convert"  // F060
    public static let mathSetLatex = "math.setLatex"  // F060
    public static let mathCopy = "math.copy"  // F060
    public static let mathEvaluate = "math.evaluate"  // F061
    public static let mathAssist = "math.assist"  // F106
    public static let mathGraphCreate = "math.graph.create"  // F107
    public static let mathGraphSetViewport = "math.graph.setViewport"  // F107
    public static let mathSolve = "math.solve"  // F088

    public static let mathassistTapAt = "mathassist.tapAt"  // F106

    public static let meetingSummarize = "meeting.summarize"  // F089
    public static let meetingGenerateNotes = "meeting.generateNotes"  // F089

    public static let menuShowAt = "menu.showAt"  // F013

    public static let nodeInsert = "node.insert"  // F003
    public static let nodeSet = "node.set"  // F003
    public static let nodeRemove = "node.remove"  // F003
    public static let nodeMove = "node.move"  // F003

    public static let outlineAdd = "outline.add"  // F046
    public static let outlineRename = "outline.rename"  // F046
    public static let outlineMove = "outline.move"  // F046
    public static let outlineDelete = "outline.delete"  // F046
    public static let outlineSortByPage = "outline.sortByPage"  // F046
    public static let outlineList = "outline.list"  // F046
    public static let outlineGenerate = "outline.generate"  // F087

    public static let pageSetBackground = "page.setBackground"  // F005
    public static let pageClear = "page.clear"  // F010
    public static let pageDeleteItems = "page.deleteItems"  // F010
    public static let pageDuplicate = "page.duplicate"  // F022
    public static let pageCopy = "page.copy"  // F022
    public static let pagePaste = "page.paste"  // F022
    public static let pageMoveTo = "page.moveTo"  // F022
    public static let pageReorder = "page.reorder"  // F022
    public static let pageRotate = "page.rotate"  // F022
    public static let pageTrash = "page.trash"  // F022
    public static let pageRestore = "page.restore"  // F022
    public static let pagePurge = "page.purge"  // F022
    public static let pageSetBookmarked = "page.setBookmarked"  // F046

    public static let pdfText = "pdf.text"  // F024
    public static let pdfLinks = "pdf.links"  // F024
    public static let pdfMarkSelection = "pdf.markSelection"  // F042
    public static let pdfCopyText = "pdf.copyText"  // F042
    public static let pdfTapAt = "pdf.tapAt"  // F042

    public static let pencilGesture = "pencil.gesture"  // F043
    public static let pencilPalette = "pencil.palette"  // F043
    public static let pencilActions = "pencil.actions"  // F043

    public static let pluginList = "plugin.list"  // F078
    public static let pluginEnable = "plugin.enable"  // F078
    public static let pluginReload = "plugin.reload"  // F078
    public static let pluginLogs = "plugin.logs"  // F078
    public static let pluginSdkTypes = "plugin.sdkTypes"  // F078
    public static let pluginDocs = "plugin.docs"  // F078
    public static let pluginUninstall = "plugin.uninstall"  // F079
    public static let pluginReview = "plugin.review"  // F079

    public static let presentSetMode = "present.setMode"  // F063

    public static let presetSelect = "preset.select"  // F008
    public static let presetSetSwatch = "preset.setSwatch"  // F008
    public static let presetAddSwatch = "preset.addSwatch"  // F008
    public static let presetRemoveSwatch = "preset.removeSwatch"  // F008
    public static let presetMoveSwatch = "preset.moveSwatch"  // F008
    public static let presetSetWidth = "preset.setWidth"  // F008
    public static let presetReset = "preset.reset"  // F008

    public static let printPresent = "print.present"  // F067

    public static let relayConfigure = "relay.configure"  // F092

    public static let replaySetMode = "replay.setMode"  // F053
    public static let replaySeekToItem = "replay.seekToItem"  // F053
    public static let replayTapAt = "replay.tapAt"  // F053

    public static let rulerSet = "ruler.set"  // F039

    public static let scanDocuments = "scan.documents"  // F065
    public static let scanQr = "scan.qr"  // F065

    public static let searchOpen = "search.open"  // F056
    public static let searchStep = "search.step"  // F056

    public static let selectionFromRect = "selection.fromRect"  // F011
    public static let selectionFromLoop = "selection.fromLoop"  // F011
    public static let selectionSelectAll = "selection.selectAll"  // F011
    public static let selectionTapAt = "selection.tapAt"  // F011
    public static let selectionScreenshot = "selection.screenshot"  // F013

    public static let settingsOpen = "settings.open"  // F027

    public static let shapeSetStyle = "shape.setStyle"  // F031
    public static let shapeSetKind = "shape.setKind"  // F031
    public static let shapeSetPoints = "shape.setPoints"  // F031
    public static let shapeTapAt = "shape.tapAt"  // F031

    public static let sidebarToggle = "sidebar.toggle"  // F017

    public static let spellcheckTapAt = "spellcheck.tapAt"  // F104

    public static let stickyCreate = "sticky.create"  // F036
    public static let stickySetCollapsed = "sticky.setCollapsed"  // F036
    public static let stickyResolve = "sticky.resolve"  // F036
    public static let stickySetColor = "sticky.setColor"  // F036
    public static let stickyTapAt = "sticky.tapAt"  // F036

    public static let stopwatchStart = "stopwatch.start"  // F062
    public static let stopwatchLap = "stopwatch.lap"  // F062

    public static let studyGrade = "study.grade"  // F050
    public static let studyResetProgress = "study.resetProgress"  // F050
    public static let studySetReminders = "study.setReminders"  // F050
    public static let studySetTheme = "study.setTheme"  // F050
    public static let studyImportText = "study.importText"  // F051
    public static let studyExportCSV = "study.exportCSV"  // F051

    public static let syncNow = "sync.now"  // F025

    public static let tabClose = "tab.close"  // F018
    public static let tabCloseOthers = "tab.closeOthers"  // F018
    public static let tabSelect = "tab.select"  // F018

    public static let tableEdit = "table.edit"  // F048
    public static let tableExportCSV = "table.exportCSV"  // F048

    public static let tapeTapAt = "tape.tapAt"  // F033
    public static let tapeSetRevealed = "tape.setRevealed"  // F033
    public static let tapeRemoveAll = "tape.removeAll"  // F033
    public static let tapeImportPattern = "tape.importPattern"  // F033
    public static let tapePatterns = "tape.patterns"  // F033
    public static let tapeDeletePattern = "tape.deletePattern"  // F033
    public static let tapeClearHistory = "tape.clearHistory"  // F033

    public static let templateList = "template.list"  // F005
    public static let templateChoose = "template.choose"  // F045
    public static let templateImport = "template.import"  // F045
    public static let templateListCustom = "template.listCustom"  // F045
    public static let templateGroupCreate = "template.group.create"  // F045
    public static let templateGroupRename = "template.group.rename"  // F045
    public static let templateGroupDelete = "template.group.delete"  // F045
    public static let templateDelete = "template.delete"  // F045
    public static let templateSetHidden = "template.setHidden"  // F045
    public static let templateFromPage = "template.fromPage"  // F045

    public static let textFormat = "text.format"  // F026
    public static let textSetParagraph = "text.setParagraph"  // F026
    public static let textSetBoxStyle = "text.setBoxStyle"  // F026
    public static let textSaveDefaultStyle = "text.saveDefaultStyle"  // F026
    public static let textTapAt = "text.tapAt"  // F026
    public static let textStartPageText = "text.startPageText"  // F028

    public static let timerStart = "timer.start"  // F062
    public static let timerControl = "timer.control"  // F062
    public static let timerHistory = "timer.history"  // F062
    public static let timerSaveMode = "timer.saveMode"  // F062
    public static let timerDeleteMode = "timer.deleteMode"  // F062

    public static let toolbarSetLayout = "toolbar.setLayout"  // F016
    public static let toolbarReset = "toolbar.reset"  // F016
    public static let toolbarSetVisible = "toolbar.setVisible"  // F016
    public static let toolbarLayouts = "toolbar.layouts"  // F016
    public static let toolbarSaveLayout = "toolbar.saveLayout"  // F016
    public static let toolbarApplyLayout = "toolbar.applyLayout"  // F016
    public static let toolbarDeleteLayout = "toolbar.deleteLayout"  // F016
    public static let toolbarDock = "toolbar.dock"  // F016

    public static let transcriptGet = "transcript.get"  // F054
    public static let transcriptRegenerate = "transcript.regenerate"  // F054
    public static let transcriptEditSegment = "transcript.editSegment"  // F054
    public static let transcriptInsert = "transcript.insert"  // F054

    public static let trashList = "trash.list"  // F002
    public static let trashRecover = "trash.recover"  // F002
    public static let trashDeletePermanently = "trash.deletePermanently"  // F002
    public static let trashEmpty = "trash.empty"  // F002

    public static let viewZoom = "view.zoom"  // F006
    public static let viewScrollBy = "view.scrollBy"  // F006

    public static let webdavSyncNow = "webdav.syncNow"  // F069
    public static let webdavConfigure = "webdav.configure"  // F069
    public static let webdavPut = "webdav.put"  // F069
    public static let webdavStatus = "webdav.status"  // F069

    public static let windowOpen = "window.open"  // F018

    public static let zoomToggle = "zoom.toggle"  // F038
    public static let zoomSetBox = "zoom.setBox"  // F038
    public static let zoomNewLine = "zoom.newLine"  // F038
    public static let zoomSetReturnHeight = "zoom.setReturnHeight"  // F038
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
    /// Study set Practice panel (F050).
    public static let studyPractice = "studysession.practice"
    /// Study set Smart Learn panel (F050). contracts-v2.1: the id F049 opens and ARCHITECTURE.md §13 lists.
    public static let studySmartLearn = "studysession.smartLearn"
    /// Superseded in contracts-v2.1 by `studySmartLearn`. contracts-v2 shipped "studysession.learn", which no feature
    /// registers; this now holds the Smart Learn id so existing callers open the right panel.
    public static let studyLearn = "studysession.smartLearn"
    /// Move Pages sheet (F022). contracts-v2.1. Open it with `panel.open {id, pages?}`: the sheet moves the page refs
    /// in `PanelContext.params["pages"]`, or the open page when there are none (F023 passes the selected thumbnails).
    public static let movePages = "pages.movePages"
}
