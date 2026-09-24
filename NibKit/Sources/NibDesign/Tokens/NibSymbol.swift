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
}

public extension Image {
    init(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}

public extension UIImage {
    convenience init?(nib symbol: NibSymbol) { self.init(systemName: symbol.name) }
}
