import SwiftUI
import UIKit

/// Every SF Symbol Nib uses (DESIGN.md §8). Features write `Image(nib: .pen)`, never `Image(systemName:)`.
public struct NibSymbol: Hashable, Sendable {
    public let name: String

    init(_ name: String) { self.name = name }

    private static let banned: Set<String> = ["sparkles", "sparkle", "wand.and.stars", "wand.and.stars.inverse",
                                              "wand.and.rays", "wand.and.rays.inverse", "sparkles.rectangle.stack",
                                              "sparkle.magnifyingglass"]

    /// A plugin's declared symbol. Empty, banned (AI sparkles, magic wands), misspelt or newer-than-this-OS names
    /// become the plugin glyph, so a plugin tool is never an empty, unlabelled button.
    public static func plugin(_ name: String) -> NibSymbol {
        (name.isEmpty || banned.contains(name) || UIImage(systemName: name) == nil) ? .puzzle : NibSymbol(name)
    }

    /// A native descriptor's `icon: String` (CONTRACTS.md): nil when the name is banned or not on this OS.
    public init?(systemName name: String) {
        guard !name.isEmpty, !Self.banned.contains(name), UIImage(systemName: name) != nil else { return nil }
        self.name = name
    }

    // Tools
    public static let pen = NibSymbol("pencil.tip")
    public static let pencil = NibSymbol("pencil")
    public static let highlighter = NibSymbol("highlighter")
    public static let eraser = NibSymbol("eraser")
    public static let eraserFilter = NibSymbol("eraser.line.dashed")
    public static let lasso = NibSymbol("lasso")
    public static let lassoRectangle = NibSymbol("rectangle.dashed")
    public static let shapes = NibSymbol("square.on.circle")
    public static let connectors = NibSymbol("point.3.connected.trianglepath.dotted")
    public static let tape = NibSymbol("rectangle.dashed")
    public static let text = NibSymbol("textformat")
    public static let pageTyping = NibSymbol("character.cursor.ibeam")
    public static let image = NibSymbol("photo")
    public static let camera = NibSymbol("camera")
    public static let scan = NibSymbol("doc.viewfinder")
    public static let elements = NibSymbol("star.square.on.square")
    public static let sticky = NibSymbol("note.text")
    public static let comment = NibSymbol("text.bubble")
    public static let laser = NibSymbol("laser.burst")
    public static let zoomWindow = NibSymbol("plus.magnifyingglass")
    public static let ruler = NibSymbol("ruler")
    public static let fingerDrawing = NibSymbol("hand.draw")
    /// The palette's More slot: buds a grid of the tools that are not on the palette.
    public static let more = NibSymbol("ellipsis")
    public static let moreCircle = NibSymbol("ellipsis.circle")

    // Actions and navigation
    public static let back = NibSymbol("chevron.backward")
    public static let forward = NibSymbol("chevron.forward")
    public static let chevronDown = NibSymbol("chevron.down")
    public static let undo = NibSymbol("arrow.uturn.backward")
    public static let redo = NibSymbol("arrow.uturn.forward")
    public static let search = NibSymbol("magnifyingglass")
    public static let clearText = NibSymbol("xmark.circle.fill")
    public static let bookmark = NibSymbol("bookmark")
    public static let bookmarkFill = NibSymbol("bookmark.fill")
    public static let share = NibSymbol("square.and.arrow.up")
    public static let importFile = NibSymbol("square.and.arrow.down")
    public static let pages = NibSymbol("square.grid.2x2")
    public static let outline = NibSymbol("list.bullet.indent")
    public static let addPage = NibSymbol("doc.badge.plus")
    public static let assistant = NibSymbol("drop")
    public static let assistantOpen = NibSymbol("drop.fill")
    public static let record = NibSymbol("waveform")
    public static let microphone = NibSymbol("mic")
    public static let stop = NibSymbol("stop.fill")
    public static let play = NibSymbol("play.fill")
    public static let pause = NibSymbol("pause.fill")
    public static let present = NibSymbol("play.rectangle")
    public static let externalDisplay = NibSymbol("rectangle.on.rectangle")
    public static let checkmark = NibSymbol("checkmark")
    public static let checkCircle = NibSymbol("checkmark.circle")
    public static let checkCircleFill = NibSymbol("checkmark.circle.fill")
    public static let circle = NibSymbol("circle")
    public static let xmark = NibSymbol("xmark")
    public static let plus = NibSymbol("plus")
    public static let minus = NibSymbol("minus")
    public static let citation = NibSymbol("doc.text.magnifyingglass")
    /// Drawn on a 32 pt `fill3` disc (`NibIconButton` size `.send`), never an accent disc.
    public static let send = NibSymbol("arrow.up")
    public static let stopGenerating = NibSymbol("stop.fill")
    public static let key = NibSymbol("key")
    public static let bridge = NibSymbol("point.3.filled.connected.trianglepath.dotted")
    public static let eye = NibSymbol("eye")
    public static let eyeSlash = NibSymbol("eye.slash")
    public static let warningTriangle = NibSymbol("exclamationmark.triangle")
    public static let retry = NibSymbol("arrow.clockwise")
    public static let lock = NibSymbol("lock")
    public static let faceID = NibSymbol("faceid")
    public static let command = NibSymbol("command")
    public static let keyboard = NibSymbol("keyboard")
    public static let dictate = NibSymbol("mic")
    public static let attach = NibSymbol("plus")

    // Library
    public static let library = NibSymbol("books.vertical")
    public static let favorites = NibSymbol("star")
    public static let starFill = NibSymbol("star.fill")
    public static let shared = NibSymbol("person.2")
    public static let recents = NibSymbol("clock")
    public static let studySets = NibSymbol("rectangle.stack")
    public static let gallery = NibSymbol("puzzlepiece.extension")
    public static let puzzle = NibSymbol("puzzlepiece.extension")
    public static let trash = NibSymbol("trash")
    public static let folder = NibSymbol("folder")
    public static let folderFill = NibSymbol("folder.fill")
    public static let notebook = NibSymbol("book.closed")
    public static let quickNote = NibSymbol("square.and.pencil")
    public static let whiteboard = NibSymbol("scribble.variable")
    public static let textDocument = NibSymbol("doc.text")
    public static let pdf = NibSymbol("doc")
    public static let sort = NibSymbol("arrow.up.arrow.down")
    public static let select = NibSymbol("checkmark.circle")
    public static let listView = NibSymbol("list.bullet")
    public static let sidebar = NibSymbol("sidebar.left")
    public static let settings = NibSymbol("gearshape")
    public static let syncDone = NibSymbol("checkmark.icloud")
    public static let syncing = NibSymbol("arrow.triangle.2.circlepath")
    public static let syncError = NibSymbol("exclamationmark.icloud")

    // Collaboration and permissions
    public static let invite = NibSymbol("person.crop.circle.badge.plus")
    public static let live = NibSymbol("dot.radiowaves.left.and.right")
    public static let permission = NibSymbol("hand.raised")
    public static let network = NibSymbol("network")
    public static let documentWrite = NibSymbol("pencil.and.outline")

    // v2 additions (DESIGN.md §8.3). Every name exists on iOS 17; `imagePlayground` is the one OS-gated glyph.

    // Tools and colour
    /// The system colour picker's eyedropper, and the tool options' "pick a colour from the page".
    public static let eyedropper = NibSymbol("eyedropper")
    /// "Custom…" colour: opens the system colour picker (also the object menu's Colour).
    public static let customColour = NibSymbol("paintpalette")
    /// Draw Shape (hold at the end of a stroke to snap it); distinct from the Shapes tool's `square.on.circle`.
    public static let drawShape = NibSymbol("pencil.and.outline")
    public static let layers = NibSymbol("square.3.layers.3d")
    public static let editHandwriting = NibSymbol("scribble")
    /// Recognised text: Live Text, "edit every word", Convert › Text previews.
    public static let recognisedText = NibSymbol("text.viewfinder")
    public static let convertToText = NibSymbol("character.textbox")
    public static let straighten = NibSymbol("level")
    public static let insertSpace = NibSymbol("arrow.up.and.down")
    public static let math = NibSymbol("x.squareroot")
    public static let graph = NibSymbol("chart.xyaxis.line")
    public static let table = NibSymbol("tablecells")
    /// Reorder handles on rows and text-document blocks (plain `labelTertiary`).
    public static let dragHandle = NibSymbol("line.3.horizontal")

    // Editing actions (object menu, keyboard bar, image options)
    public static let cut = NibSymbol("scissors")
    public static let copy = NibSymbol("doc.on.doc")
    public static let paste = NibSymbol("doc.on.clipboard")
    public static let duplicate = NibSymbol("plus.square.on.square")
    public static let link = NibSymbol("link")
    public static let arrange = NibSymbol("square.stack.3d.up")
    public static let screenshot = NibSymbol("camera.viewfinder")
    public static let crop = NibSymbol("crop")
    public static let flipHorizontal = NibSymbol("arrow.left.and.right.righttriangle.left.righttriangle.right")
    public static let flipVertical = NibSymbol("arrow.up.and.down.righttriangle.up.righttriangle.down")
    public static let replace = NibSymbol("arrow.2.squarepath")
    public static let unlock = NibSymbol("lock.open")
    public static let touchID = NibSymbol("touchid")
    public static let print = NibSymbol("printer")
    public static let saveToFiles = NibSymbol("square.and.arrow.down.on.square")
    public static let newWindow = NibSymbol("macwindow.badge.plus")
    /// A link that leaves Nib (system settings, a web page).
    public static let externalLink = NibSymbol("arrow.up.forward.app")
    public static let qrCode = NibSymbol("qrcode")
    /// Image Playground (iOS 18.1+): nil where the OS has no glyph, so the entry is hidden there.
    public static var imagePlayground: NibSymbol? { NibSymbol(systemName: "apple.image.playground") }

    // Text formatting (text boxes, full-page typing, text documents)
    public static let bold = NibSymbol("bold")
    public static let italic = NibSymbol("italic")
    public static let underline = NibSymbol("underline")
    public static let strikethrough = NibSymbol("strikethrough")
    public static let textSuperscript = NibSymbol("textformat.superscript")
    public static let textSubscript = NibSymbol("textformat.subscript")
    public static let inlineCode = NibSymbol("chevron.left.forwardslash.chevron.right")
    public static let fontSize = NibSymbol("textformat.size")
    public static let alignLeft = NibSymbol("text.alignleft")
    public static let alignCentre = NibSymbol("text.aligncenter")
    public static let alignRight = NibSymbol("text.alignright")
    public static let justify = NibSymbol("text.justify")
    public static let listBulleted = NibSymbol("list.bullet")
    public static let listNumbered = NibSymbol("list.number")
    public static let checklist = NibSymbol("checklist")
    public static let indent = NibSymbol("increase.indent")
    public static let outdent = NibSymbol("decrease.indent")
    public static let lineSpacing = NibSymbol("arrow.up.and.down.text.horizontal")

    // Audio, time and replay
    /// The recording indicator (the dot in the recording HUD is a `NibStatusDot`).
    public static let recordDot = NibSymbol("record.circle")
    public static let skipBack10 = NibSymbol("gobackward.10")
    public static let skipForward10 = NibSymbol("goforward.10")
    public static let transcript = NibSymbol("captions.bubble")
    public static let speak = NibSymbol("speaker.wave.2")
    public static let timer = NibSymbol("timer")
    public static let stopwatch = NibSymbol("stopwatch")
    public static let lap = NibSymbol("flag")
    /// Undo history, replay and backups.
    public static let history = NibSymbol("clock.arrow.circlepath")

    // Settings and places
    public static let profile = NibSymbol("person.crop.circle")
    public static let language = NibSymbol("globe")
    public static let notifications = NibSymbol("bell.badge")
    public static let reminder = NibSymbol("bell")
    /// About, and info notices (`NibBanner`).
    public static let info = NibSymbol("info.circle")
    public static let advanced = NibSymbol("wrench.and.screwdriver")
    public static let templates = NibSymbol("rectangle.3.group")
    public static let minimap = NibSymbol("map")
    public static let fitToContent = NibSymbol("arrow.up.left.and.arrow.down.right")
    public static let calendar = NibSymbol("calendar")
    public static let cloud = NibSymbol("icloud")
    public static let backup = NibSymbol("externaldrive")
    public static let diagnostics = NibSymbol("stethoscope")
    public static let dictionary = NibSymbol("character.book.closed")

    /// Every token, for the gallery and the test that each name resolves on this OS.
    static let all: [NibSymbol] = [
        pen, pencil, highlighter, eraser, eraserFilter, lasso, lassoRectangle, shapes, connectors, tape, text, pageTyping,
        image, camera, scan, elements, sticky, comment, laser, zoomWindow, ruler, fingerDrawing, more, moreCircle,
        back, forward, chevronDown, undo, redo, search, clearText, bookmark, bookmarkFill, share, importFile, pages,
        outline, addPage, assistant, assistantOpen, record, microphone, stop, play, pause, present, externalDisplay,
        checkmark, checkCircle, checkCircleFill, circle, xmark, plus, minus, citation, send, stopGenerating, key, bridge,
        eye, eyeSlash, warningTriangle, retry, lock, faceID, command, keyboard, dictate, attach,
        library, favorites, starFill, shared, recents, studySets, gallery, puzzle, trash, folder, folderFill, notebook,
        quickNote, whiteboard, textDocument, pdf, sort, select, listView, sidebar, settings, syncDone, syncing, syncError,
        invite, live, permission, network, documentWrite,
        eyedropper, customColour, drawShape, layers, editHandwriting, recognisedText, convertToText, straighten,
        insertSpace, math, graph, table, dragHandle,
        cut, copy, paste, duplicate, link, arrange, screenshot, crop, flipHorizontal, flipVertical, replace, unlock,
        touchID, print, saveToFiles, newWindow, externalLink, qrCode,
        bold, italic, underline, strikethrough, textSuperscript, textSubscript, inlineCode, fontSize, alignLeft,
        alignCentre, alignRight, justify, listBulleted, listNumbered, checklist, indent, outdent, lineSpacing,
        recordDot, skipBack10, skipForward10, transcript, speak, timer, stopwatch, lap, history,
        profile, language, notifications, reminder, info, advanced, templates, minimap, fitToContent, calendar, cloud,
        backup, diagnostics, dictionary,
    ]
}

public extension Image {
    init(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}

public extension UIImage {
    convenience init?(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}
