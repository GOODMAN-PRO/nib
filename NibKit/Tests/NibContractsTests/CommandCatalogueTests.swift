import XCTest
import NibContracts

/// contracts-v2.1: every command id in the ARCHITECTURE.md §6.5 catalogue has a `CommandIDs` constant, and `PanelIDs`
/// matches the well-known panel ids that ARCHITECTURE.md §13 lists. The tables below name every constant, so a missing
/// one fails to compile; the doc checks read docs/ARCHITECTURE.md from the repository checkout this file lives in.
final class CommandCatalogueTests: XCTestCase {
    /// Every `CommandIDs` constant with the id it holds, in §6.5 catalogue order.
    static let commandIDs: [(String, String)] = [
        ("edit.undo", CommandIDs.undo),
        ("edit.redo", CommandIDs.redo),
        ("history.list", CommandIDs.historyList),
        ("history.revertGroup", CommandIDs.revertGroup),
        ("commands.list", CommandIDs.commandsList),
        ("commands.describe", CommandIDs.commandsDescribe),
        ("commands.batch", CommandIDs.batch),
        ("tool.select", CommandIDs.toolSelect),
        ("settings.get", CommandIDs.settingsGet),
        ("settings.set", CommandIDs.settingsSet),
        ("settings.list", CommandIDs.settingsList),
        ("settings.describe", CommandIDs.settingsDescribe),
        ("window.showLibrary", CommandIDs.windowShowLibrary),

        ("a11y.describePage", CommandIDs.a11yDescribePage),

        ("ai.ask", CommandIDs.aiAsk),
        ("ai.chat.list", CommandIDs.aiChatList),
        ("ai.chat.rename", CommandIDs.aiChatRename),
        ("ai.chat.delete", CommandIDs.aiChatDelete),
        ("ai.chat.feedback", CommandIDs.aiChatFeedback),
        ("ai.provider.list", CommandIDs.aiProviderList),
        ("ai.provider.save", CommandIDs.aiProviderSave),
        ("ai.provider.activate", CommandIDs.aiProviderActivate),
        ("ai.provider.delete", CommandIDs.aiProviderDelete),
        ("ai.provider.test", CommandIDs.aiProviderTest),
        ("ai.quiz", CommandIDs.aiQuiz),

        ("answerZone.create", CommandIDs.answerZoneCreate),
        ("answerZone.score", CommandIDs.answerZoneScore),
        ("answerZone.setHints", CommandIDs.answerZoneSetHints),
        ("answerZone.revealHint", CommandIDs.answerZoneRevealHint),

        ("app.openURL", CommandIDs.appOpenURL),
        ("app.quickAction", CommandIDs.appQuickAction),
        ("app.deleteAllData", CommandIDs.appDeleteAllData),

        ("asset.put", CommandIDs.assetPut),
        ("asset.get", CommandIDs.assetGet),
        ("asset.upload", CommandIDs.assetUpload),

        ("audio.record", CommandIDs.audioRecord),
        ("audio.play", CommandIDs.audioPlay),
        ("audio.pause", CommandIDs.audioPause),
        ("audio.seek", CommandIDs.audioSeek),
        ("audio.setPlayback", CommandIDs.audioSetPlayback),
        ("audio.rename", CommandIDs.audioRename),
        ("audio.delete", CommandIDs.audioDelete),
        ("audio.export", CommandIDs.audioExport),
        ("audio.quickRecord", CommandIDs.audioQuickRecord),

        ("backup.now", CommandIDs.backupNow),
        ("backup.manual", CommandIDs.backupManual),
        ("backup.configure", CommandIDs.backupConfigure),
        ("backup.chooseFolder", CommandIDs.backupChooseFolder),
        ("backup.status", CommandIDs.backupStatus),
        ("backup.clearQueue", CommandIDs.backupClearQueue),

        ("block.insert", CommandIDs.blockInsert),
        ("block.update", CommandIDs.blockUpdate),
        ("block.delete", CommandIDs.blockDelete),
        ("block.move", CommandIDs.blockMove),
        ("block.comment", CommandIDs.blockComment),
        ("block.editComment", CommandIDs.blockEditComment),
        ("block.deleteComment", CommandIDs.blockDeleteComment),
        ("block.resolveComment", CommandIDs.blockResolveComment),

        ("board.add", CommandIDs.boardAdd),
        ("board.rename", CommandIDs.boardRename),
        ("board.insertTemplate", CommandIDs.boardInsertTemplate),

        ("bridge.setEnabled", CommandIDs.bridgeSetEnabled),
        ("bridge.status", CommandIDs.bridgeStatus),

        ("calendar.events", CommandIDs.calendarEvents),
        ("calendar.createNote", CommandIDs.calendarCreateNote),
        ("calendar.openNote", CommandIDs.calendarOpenNote),

        ("canvas.decorate", CommandIDs.canvasDecorate),
        ("canvas.clearDecorations", CommandIDs.canvasClearDecorations),

        ("card.add", CommandIDs.cardAdd),
        ("card.update", CommandIDs.cardUpdate),
        ("card.delete", CommandIDs.cardDelete),
        ("card.move", CommandIDs.cardMove),
        ("card.moveTo", CommandIDs.cardMoveTo),

        ("clipboard.copy", CommandIDs.clipboardCopy),
        ("clipboard.cut", CommandIDs.clipboardCut),
        ("clipboard.paste", CommandIDs.clipboardPaste),
        ("clipboard.copyText", CommandIDs.clipboardCopyText),

        ("collab.host", CommandIDs.collabHost),
        ("collab.join", CommandIDs.collabJoin),
        ("collab.leave", CommandIDs.collabLeave),
        ("collab.participants", CommandIDs.collabParticipants),
        ("collab.approve", CommandIDs.collabApprove),
        ("collab.setRole", CommandIDs.collabSetRole),
        ("collab.revoke", CommandIDs.collabRevoke),
        ("collab.follow", CommandIDs.collabFollow),
        ("collab.followMe", CommandIDs.collabFollowMe),
        ("collab.markSeen", CommandIDs.collabMarkSeen),

        ("comment.add", CommandIDs.commentAdd),
        ("comment.reply", CommandIDs.commentReply),
        ("comment.edit", CommandIDs.commentEdit),
        ("comment.deleteMessage", CommandIDs.commentDeleteMessage),
        ("comment.resolve", CommandIDs.commentResolve),
        ("comment.tapAt", CommandIDs.commentTapAt),

        ("connector.create", CommandIDs.connectorCreate),
        ("connector.setPath", CommandIDs.connectorSetPath),

        ("diagnostics.export", CommandIDs.diagnosticsExport),
        ("diagnostics.setFeatureEnabled", CommandIDs.diagnosticsSetFeatureEnabled),

        ("diagram.addConnected", CommandIDs.diagramAddConnected),
        ("diagram.create", CommandIDs.diagramCreate),

        ("dictionary.add", CommandIDs.dictionaryAdd),
        ("dictionary.remove", CommandIDs.dictionaryRemove),
        ("dictionary.list", CommandIDs.dictionaryList),

        ("doc.create", CommandIDs.docCreate),
        ("doc.setFavorite", CommandIDs.docSetFavorite),
        ("doc.merge", CommandIDs.docMerge),
        ("doc.setScrollDirection", CommandIDs.docSetScrollDirection),
        ("doc.open", CommandIDs.docOpen),
        ("doc.quickNote", CommandIDs.docQuickNote),
        ("doc.convertToWhiteboard", CommandIDs.docConvertToWhiteboard),
        ("doc.setLanguage", CommandIDs.docSetLanguage),
        ("doc.setWritingAids", CommandIDs.docSetWritingAids),
        ("doc.setLocked", CommandIDs.docSetLocked),
        ("doc.unlock", CommandIDs.docUnlock),
        ("doc.suggestTitle", CommandIDs.docSuggestTitle),

        ("element.create", CommandIDs.elementCreate),
        ("element.insert", CommandIDs.elementInsert),
        ("element.collection.create", CommandIDs.elementCollectionCreate),
        ("element.collection.update", CommandIDs.elementCollectionUpdate),
        ("element.collection.delete", CommandIDs.elementCollectionDelete),
        ("element.collection.list", CommandIDs.elementCollectionList),
        ("element.list", CommandIDs.elementList),
        ("element.rename", CommandIDs.elementRename),
        ("element.delete", CommandIDs.elementDelete),
        ("element.import", CommandIDs.elementImport),
        ("element.export", CommandIDs.elementExport),

        ("export.run", CommandIDs.exportRun),
        ("export.present", CommandIDs.exportPresent),
        ("export.saveToSource", CommandIDs.exportSaveToSource),

        ("folder.create", CommandIDs.folderCreate),
        ("folder.setStyle", CommandIDs.folderSetStyle),

        ("gallery.list", CommandIDs.galleryList),

        ("gif.search", CommandIDs.gifSearch),

        ("handwriting.toText", CommandIDs.handwritingToText),
        ("handwriting.toTextPages", CommandIDs.handwritingToTextPages),
        ("handwriting.words", CommandIDs.handwritingWords),
        ("handwriting.reflow", CommandIDs.handwritingReflow),
        ("handwriting.straighten", CommandIDs.handwritingStraighten),
        ("handwriting.align", CommandIDs.handwritingAlign),
        ("handwriting.insertSpace", CommandIDs.handwritingInsertSpace),
        ("handwriting.replaceWord", CommandIDs.handwritingReplaceWord),
        ("handwriting.restyle", CommandIDs.handwritingRestyle),

        ("image.insert", CommandIDs.imageInsert),
        ("image.crop", CommandIDs.imageCrop),
        ("image.flip", CommandIDs.imageFlip),
        ("image.replace", CommandIDs.imageReplace),
        ("image.saveToPhotos", CommandIDs.imageSaveToPhotos),
        ("image.pick", CommandIDs.imagePick),

        ("import.files", CommandIDs.importFiles),
        ("import.pick", CommandIDs.importPick),

        ("index.rebuild", CommandIDs.indexRebuild),

        ("ink.addStrokes", CommandIDs.inkAddStrokes),
        ("ink.setStyle", CommandIDs.inkSetStyle),
        ("ink.setPoints", CommandIDs.inkSetPoints),
        ("ink.erase", CommandIDs.inkErase),
        ("ink.scribbleErase", CommandIDs.inkScribbleErase),
        ("ink.writeText", CommandIDs.inkWriteText),

        ("item.create", CommandIDs.itemCreate),
        ("item.update", CommandIDs.itemUpdate),
        ("item.transform", CommandIDs.itemTransform),
        ("item.moveToPage", CommandIDs.itemMoveToPage),
        ("item.delete", CommandIDs.itemDelete),
        ("item.arrange", CommandIDs.itemArrange),
        ("item.recolor", CommandIDs.itemRecolor),
        ("item.setLocked", CommandIDs.itemSetLocked),
        ("item.duplicate", CommandIDs.itemDuplicate),

        ("laser.setMode", CommandIDs.laserSetMode),
        ("laser.point", CommandIDs.laserPoint),

        ("layer.setActive", CommandIDs.layerSetActive),
        ("layer.setVisible", CommandIDs.layerSetVisible),
        ("layer.rename", CommandIDs.layerRename),
        ("layer.moveItems", CommandIDs.layerMoveItems),
        ("layer.exportOptions", CommandIDs.layerExportOptions),

        ("lesson.create", CommandIDs.lessonCreate),
        ("lesson.setState", CommandIDs.lessonSetState),
        ("lesson.importRoster", CommandIDs.lessonImportRoster),
        ("lesson.collect", CommandIDs.lessonCollect),
        ("lesson.cluster", CommandIDs.lessonCluster),
        ("lesson.setClusters", CommandIDs.lessonSetClusters),

        ("library.list", CommandIDs.libraryList),
        ("library.rename", CommandIDs.libraryRename),
        ("library.move", CommandIDs.libraryMove),
        ("library.duplicate", CommandIDs.libraryDuplicate),
        ("library.trash", CommandIDs.libraryTrash),
        ("library.setView", CommandIDs.librarySetView),
        ("library.reorder", CommandIDs.libraryReorder),
        ("library.chooseFolder", CommandIDs.libraryChooseFolder),
        ("library.relocate", CommandIDs.libraryRelocate),
        ("library.locations", CommandIDs.libraryLocations),
        ("library.switch", CommandIDs.librarySwitch),
        ("library.repair", CommandIDs.libraryRepair),

        ("link.set", CommandIDs.linkSet),
        ("link.remove", CommandIDs.linkRemove),
        ("link.follow", CommandIDs.linkFollow),
        ("link.back", CommandIDs.linkBack),
        ("link.autodetect", CommandIDs.linkAutodetect),
        ("link.tapAt", CommandIDs.linkTapAt),

        ("lock.setup", CommandIDs.lockSetup),

        ("math.recognize", CommandIDs.mathRecognize),
        ("math.convert", CommandIDs.mathConvert),
        ("math.setLatex", CommandIDs.mathSetLatex),
        ("math.copy", CommandIDs.mathCopy),
        ("math.evaluate", CommandIDs.mathEvaluate),
        ("math.assist", CommandIDs.mathAssist),
        ("math.graph.create", CommandIDs.mathGraphCreate),
        ("math.graph.setViewport", CommandIDs.mathGraphSetViewport),
        ("math.solve", CommandIDs.mathSolve),

        ("mathassist.tapAt", CommandIDs.mathassistTapAt),

        ("meeting.summarize", CommandIDs.meetingSummarize),
        ("meeting.generateNotes", CommandIDs.meetingGenerateNotes),

        ("menu.showAt", CommandIDs.menuShowAt),

        ("node.insert", CommandIDs.nodeInsert),
        ("node.set", CommandIDs.nodeSet),
        ("node.remove", CommandIDs.nodeRemove),
        ("node.move", CommandIDs.nodeMove),

        ("outline.add", CommandIDs.outlineAdd),
        ("outline.rename", CommandIDs.outlineRename),
        ("outline.move", CommandIDs.outlineMove),
        ("outline.delete", CommandIDs.outlineDelete),
        ("outline.sortByPage", CommandIDs.outlineSortByPage),
        ("outline.list", CommandIDs.outlineList),
        ("outline.generate", CommandIDs.outlineGenerate),

        ("page.setTemplate", CommandIDs.pageSetTemplate),
        ("page.setBackground", CommandIDs.pageSetBackground),
        ("page.clear", CommandIDs.pageClear),
        ("page.deleteItems", CommandIDs.pageDeleteItems),
        ("page.add", CommandIDs.pageAdd),
        ("page.duplicate", CommandIDs.pageDuplicate),
        ("page.copy", CommandIDs.pageCopy),
        ("page.paste", CommandIDs.pagePaste),
        ("page.moveTo", CommandIDs.pageMoveTo),
        ("page.reorder", CommandIDs.pageReorder),
        ("page.rotate", CommandIDs.pageRotate),
        ("page.trash", CommandIDs.pageTrash),
        ("page.restore", CommandIDs.pageRestore),
        ("page.purge", CommandIDs.pagePurge),
        ("page.setBookmarked", CommandIDs.pageSetBookmarked),

        ("panel.open", CommandIDs.panelOpen),
        ("panel.close", CommandIDs.panelClose),

        ("pdf.text", CommandIDs.pdfText),
        ("pdf.links", CommandIDs.pdfLinks),
        ("pdf.markSelection", CommandIDs.pdfMarkSelection),
        ("pdf.copyText", CommandIDs.pdfCopyText),
        ("pdf.tapAt", CommandIDs.pdfTapAt),

        ("pencil.gesture", CommandIDs.pencilGesture),
        ("pencil.palette", CommandIDs.pencilPalette),
        ("pencil.actions", CommandIDs.pencilActions),

        ("plugin.list", CommandIDs.pluginList),
        ("plugin.enable", CommandIDs.pluginEnable),
        ("plugin.reload", CommandIDs.pluginReload),
        ("plugin.logs", CommandIDs.pluginLogs),
        ("plugin.sdkTypes", CommandIDs.pluginSdkTypes),
        ("plugin.docs", CommandIDs.pluginDocs),
        ("plugin.install", CommandIDs.pluginInstall),
        ("plugin.uninstall", CommandIDs.pluginUninstall),
        ("plugin.review", CommandIDs.pluginReview),

        ("present.setMode", CommandIDs.presentSetMode),

        ("preset.select", CommandIDs.presetSelect),
        ("preset.setSwatch", CommandIDs.presetSetSwatch),
        ("preset.addSwatch", CommandIDs.presetAddSwatch),
        ("preset.removeSwatch", CommandIDs.presetRemoveSwatch),
        ("preset.moveSwatch", CommandIDs.presetMoveSwatch),
        ("preset.setWidth", CommandIDs.presetSetWidth),
        ("preset.reset", CommandIDs.presetReset),

        ("print.present", CommandIDs.printPresent),

        ("query.context", CommandIDs.queryContext),
        ("query.tree", CommandIDs.queryTree),
        ("query.get", CommandIDs.queryGet),
        ("query.find", CommandIDs.queryFind),

        ("recognize.pageText", CommandIDs.recognizePageText),
        ("recognize.items", CommandIDs.recognizeItems),

        ("relay.configure", CommandIDs.relayConfigure),

        ("render.page", CommandIDs.renderPage),

        ("replay.setMode", CommandIDs.replaySetMode),
        ("replay.seekToItem", CommandIDs.replaySeekToItem),
        ("replay.tapAt", CommandIDs.replayTapAt),

        ("ruler.set", CommandIDs.rulerSet),

        ("scan.documents", CommandIDs.scanDocuments),
        ("scan.qr", CommandIDs.scanQr),

        ("search.text", CommandIDs.searchText),
        ("search.open", CommandIDs.searchOpen),
        ("search.step", CommandIDs.searchStep),

        ("selection.set", CommandIDs.selectionSet),
        ("selection.clear", CommandIDs.selectionClear),
        ("selection.fromPolygon", CommandIDs.selectionFromPolygon),
        ("selection.fromRect", CommandIDs.selectionFromRect),
        ("selection.fromLoop", CommandIDs.selectionFromLoop),
        ("selection.selectAll", CommandIDs.selectionSelectAll),
        ("selection.tapAt", CommandIDs.selectionTapAt),
        ("selection.screenshot", CommandIDs.selectionScreenshot),

        ("settings.open", CommandIDs.settingsOpen),

        ("shape.recognize", CommandIDs.shapeRecognize),
        ("shape.create", CommandIDs.shapeCreate),
        ("shape.setStyle", CommandIDs.shapeSetStyle),
        ("shape.setKind", CommandIDs.shapeSetKind),
        ("shape.setPoints", CommandIDs.shapeSetPoints),
        ("shape.tapAt", CommandIDs.shapeTapAt),

        ("sidebar.toggle", CommandIDs.sidebarToggle),

        ("spellcheck.tapAt", CommandIDs.spellcheckTapAt),

        ("sticky.create", CommandIDs.stickyCreate),
        ("sticky.setCollapsed", CommandIDs.stickySetCollapsed),
        ("sticky.resolve", CommandIDs.stickyResolve),
        ("sticky.setColor", CommandIDs.stickySetColor),
        ("sticky.tapAt", CommandIDs.stickyTapAt),

        ("stopwatch.start", CommandIDs.stopwatchStart),
        ("stopwatch.lap", CommandIDs.stopwatchLap),

        ("study.grade", CommandIDs.studyGrade),
        ("study.resetProgress", CommandIDs.studyResetProgress),
        ("study.setReminders", CommandIDs.studySetReminders),
        ("study.setTheme", CommandIDs.studySetTheme),
        ("study.importText", CommandIDs.studyImportText),
        ("study.exportCSV", CommandIDs.studyExportCSV),

        ("sync.now", CommandIDs.syncNow),

        ("tab.close", CommandIDs.tabClose),
        ("tab.closeOthers", CommandIDs.tabCloseOthers),
        ("tab.select", CommandIDs.tabSelect),

        ("table.edit", CommandIDs.tableEdit),
        ("table.exportCSV", CommandIDs.tableExportCSV),

        ("tape.tapAt", CommandIDs.tapeTapAt),
        ("tape.setRevealed", CommandIDs.tapeSetRevealed),
        ("tape.removeAll", CommandIDs.tapeRemoveAll),
        ("tape.importPattern", CommandIDs.tapeImportPattern),
        ("tape.patterns", CommandIDs.tapePatterns),
        ("tape.deletePattern", CommandIDs.tapeDeletePattern),
        ("tape.clearHistory", CommandIDs.tapeClearHistory),

        ("template.list", CommandIDs.templateList),
        ("template.choose", CommandIDs.templateChoose),
        ("template.import", CommandIDs.templateImport),
        ("template.listCustom", CommandIDs.templateListCustom),
        ("template.group.create", CommandIDs.templateGroupCreate),
        ("template.group.rename", CommandIDs.templateGroupRename),
        ("template.group.delete", CommandIDs.templateGroupDelete),
        ("template.delete", CommandIDs.templateDelete),
        ("template.setHidden", CommandIDs.templateSetHidden),
        ("template.fromPage", CommandIDs.templateFromPage),

        ("text.createBox", CommandIDs.textCreateBox),
        ("text.setText", CommandIDs.textSetText),
        ("text.format", CommandIDs.textFormat),
        ("text.setParagraph", CommandIDs.textSetParagraph),
        ("text.setBoxStyle", CommandIDs.textSetBoxStyle),
        ("text.saveDefaultStyle", CommandIDs.textSaveDefaultStyle),
        ("text.tapAt", CommandIDs.textTapAt),
        ("text.startPageText", CommandIDs.textStartPageText),

        ("timer.start", CommandIDs.timerStart),
        ("timer.control", CommandIDs.timerControl),
        ("timer.history", CommandIDs.timerHistory),
        ("timer.saveMode", CommandIDs.timerSaveMode),
        ("timer.deleteMode", CommandIDs.timerDeleteMode),

        ("toolbar.setLayout", CommandIDs.toolbarSetLayout),
        ("toolbar.reset", CommandIDs.toolbarReset),
        ("toolbar.setVisible", CommandIDs.toolbarSetVisible),
        ("toolbar.layouts", CommandIDs.toolbarLayouts),
        ("toolbar.saveLayout", CommandIDs.toolbarSaveLayout),
        ("toolbar.applyLayout", CommandIDs.toolbarApplyLayout),
        ("toolbar.deleteLayout", CommandIDs.toolbarDeleteLayout),
        ("toolbar.dock", CommandIDs.toolbarDock),

        ("transcript.get", CommandIDs.transcriptGet),
        ("transcript.regenerate", CommandIDs.transcriptRegenerate),
        ("transcript.editSegment", CommandIDs.transcriptEditSegment),
        ("transcript.insert", CommandIDs.transcriptInsert),

        ("trash.list", CommandIDs.trashList),
        ("trash.recover", CommandIDs.trashRecover),
        ("trash.deletePermanently", CommandIDs.trashDeletePermanently),
        ("trash.empty", CommandIDs.trashEmpty),

        ("view.goToPage", CommandIDs.viewGoToPage),
        ("view.zoom", CommandIDs.viewZoom),
        ("view.scrollBy", CommandIDs.viewScrollBy),
        ("view.reveal", CommandIDs.viewReveal),
        ("view.setReadOnly", CommandIDs.viewSetReadOnly),

        ("webdav.syncNow", CommandIDs.webdavSyncNow),
        ("webdav.configure", CommandIDs.webdavConfigure),
        ("webdav.put", CommandIDs.webdavPut),
        ("webdav.status", CommandIDs.webdavStatus),

        ("window.open", CommandIDs.windowOpen),

        ("zoom.toggle", CommandIDs.zoomToggle),
        ("zoom.setBox", CommandIDs.zoomSetBox),
        ("zoom.newLine", CommandIDs.zoomNewLine),
        ("zoom.setReturnHeight", CommandIDs.zoomSetReturnHeight),
    ]

    /// Every `PanelIDs` constant with the id it holds (`studyLearn` is the superseded alias of `studySmartLearn`).
    static let panelIDs: [(String, String)] = [
        ("aichat.panel", PanelIDs.assistant),
        ("organize.trash", PanelIDs.trash),
        ("organize.favourites", PanelIDs.favourites),
        ("templateui.manage", PanelIDs.templates),
        ("syncui.panel", PanelIDs.cloudBackup),
        ("about.panel", PanelIDs.about),
        ("pluginmanager.gallery", PanelIDs.gallery),
        ("studysession.practice", PanelIDs.studyPractice),
        ("studysession.smartLearn", PanelIDs.studySmartLearn),
        ("studysession.smartLearn", PanelIDs.studyLearn),
        ("pages.movePages", PanelIDs.movePages),
    ]

    func testEveryCommandConstantHoldsItsID() {
        for (id, constant) in Self.commandIDs {
            XCTAssertEqual(constant, id)
        }
        XCTAssertEqual(Set(Self.commandIDs.map { $0.0 }).count, Self.commandIDs.count, "an id is listed twice")
    }

    func testEveryCatalogueIDHasACommandConstant() throws {
        let catalogue = try Self.catalogueIDs()
        XCTAssertGreaterThan(catalogue.count, 300, "the §6.5 parser found too few rows")
        let constants = Set(Self.commandIDs.map { $0.0 })
        let missing = catalogue.filter { !constants.contains($0) }
        XCTAssertEqual(missing, [], "§6.5 ids without a CommandIDs constant (add each to CommandIDs.swift and here)")
        let listed = Set(catalogue)
        let stale = Self.commandIDs.map { $0.0 }.filter { !listed.contains($0) }
        XCTAssertEqual(stale, [], "CommandIDs constants whose id is not in the §6.5 catalogue")
    }

    func testPanelIDsMatchTheArchitecturePanelList() throws {
        for (id, constant) in Self.panelIDs {
            XCTAssertEqual(constant, id)
        }
        let listed = try Self.architecturePanelIDs()
        XCTAssertEqual(listed, Set(Self.panelIDs.map { $0.0 }), "PanelIDs differs from the ARCHITECTURE.md §13 list")
    }

    // MARK: docs/ARCHITECTURE.md

    private static func architecture() throws -> [Substring] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NibContractsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NibKit
            .deletingLastPathComponent() // repository root
        let text = try String(contentsOf: root.appendingPathComponent("docs/ARCHITECTURE.md"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The first-column id of every table row in §6.5, in document order.
    private static func catalogueIDs() throws -> [String] {
        let lines = try architecture()
        guard let start = lines.firstIndex(where: { $0.hasPrefix("### 6.5 ") }) else {
            XCTFail("ARCHITECTURE.md has no §6.5 heading")
            return []
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[start..<end].compactMap { line -> String? in
            guard line.hasPrefix("| `") else { return nil }
            let cell = line.dropFirst(3)
            guard let close = cell.firstIndex(of: "`") else { return nil }
            return String(cell[..<close])
        }
    }

    /// The backticked dotted ids after "Well-known panel ids are in `PanelIDs`" in §13.
    private static func architecturePanelIDs() throws -> Set<String> {
        let marker = "Well-known panel ids are in `PanelIDs`"
        guard let line = try architecture().first(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else {
            XCTFail("ARCHITECTURE.md no longer says: \(marker)")
            return []
        }
        let spans = line[range.upperBound...].split(separator: "`", omittingEmptySubsequences: false)
        var ids = Set<String>()
        for (index, span) in spans.enumerated() where index % 2 == 1 {
            let parts = span.split(separator: ".", omittingEmptySubsequences: false)
            let isID = parts.count == 2 && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            }
            if isID, let first = span.first, first.isLowercase { ids.insert(String(span)) }
        }
        return ids
    }
}
