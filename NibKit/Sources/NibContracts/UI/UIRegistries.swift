import SwiftUI
import UIKit

// MARK: - Toolbar

public enum ToolbarGroup: String, Codable, CaseIterable {
    /// Fixed first slot (Lasso).
    case lasso
    /// Writing tools (pen, pencil, highlighter, eraser, tape, shapes…).
    case tools
    /// Accessories (audio, ruler, zoom window, timer, laser…).
    case accessories
    /// Document nav bar, left side (library, sidebar, search, AI, read-only).
    case navLeading
    /// Document nav bar, right side (add page, share/export, more).
    case navTrailing
}

/// Every toolbar button is either a canvas tool (activated via `tool.select`) or a command. No other actions exist.
public struct ToolbarItemDescriptor: Registrable {
    public var id: String
    public var title: String
    /// SF Symbol name.
    public var icon: String
    public var group: ToolbarGroup
    public var order: Int
    public var owner: String
    public var toolID: String?
    public var command: String?
    public var params: JSONValue
    public var shortcut: KeyShortcut?
    /// Can be hidden in Toolbar Customization (Lasso cannot).
    public var hideable: Bool
    public var docKinds: Set<DocumentKind>
    /// Contextual options bar shown while this tool is active (presets, colors, sizes).
    public var activeToolMenu: (@MainActor (EditorSession) -> AnyView)?
    /// Settings popover shown when the already-selected tool is tapped again.
    public var settings: (@MainActor (EditorSession) -> AnyView)?

    public init(id: String, title: String, icon: String, group: ToolbarGroup, order: Int, owner: String,
                toolID: String? = nil, command: String? = nil, params: JSONValue = [:], shortcut: KeyShortcut? = nil,
                hideable: Bool = true, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                activeToolMenu: (@MainActor (EditorSession) -> AnyView)? = nil,
                settings: (@MainActor (EditorSession) -> AnyView)? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.group = group
        self.order = order
        self.owner = owner
        self.toolID = toolID
        self.command = command
        self.params = params
        self.shortcut = shortcut
        self.hideable = hideable
        self.docKinds = docKinds
        self.activeToolMenu = activeToolMenu
        self.settings = settings
    }
}

// MARK: - Menus

public enum MenuLocation: String, Codable, CaseIterable {
    /// Quick-action icon row / full list above a selection.
    case objectMenu
    /// Long-press on empty page area.
    case pageLongPress
    /// Document "More (…)" menu.
    case documentMore
    /// Tap on the document title.
    case documentTitle
    /// Add Page (+) menu.
    case addPage
    /// Share & Export menu.
    case shareExport
    /// Per-item menu in the library.
    case libraryItem
    /// New (+) creation menu in the library.
    case libraryNew
    /// Actions for a multi-selection in the library.
    case librarySelection
    /// App menu (avatar / gear in the library).
    case appMenu
    /// Page thumbnail menu in the sidebar.
    case sidebarPage
    /// Actions for selected thumbnails.
    case sidebarSelection
    /// Selected typed text (text boxes, blocks).
    case textSelection
    /// Audio clip row.
    case audioClip
    /// Text-document block handle menu.
    case block
    /// Study-set card menu.
    case card
    /// Whiteboard board (Boards sidebar) menu.
    case board
    /// Outline entry menu.
    case outlineEntry
    /// Comment thread menu.
    case comment
    /// Transcript line menu.
    case transcriptSegment
    /// Document tab menu.
    case tab
}

public struct MenuContext {
    public var app: NibApp
    public var session: EditorSession?
    public var doc: DocumentID?
    public var page: PageID?
    /// Long-press location in page coordinates.
    public var point: Point?
    public var selection: Selection
    public var itemKinds: Set<ItemKind>
    /// Library selection (items, folders) or sidebar selection (pages).
    public var nodes: [NibID]
    /// The ref the menu is for (block, card, board page, outline entry, comment item, audio clip, tab document);
    /// transcript lines use "audio:D/A" plus `index`.
    public var ref: String?
    public var index: Int?

    public init(app: NibApp, session: EditorSession? = nil, doc: DocumentID? = nil, page: PageID? = nil, point: Point? = nil,
                selection: Selection = Selection(), itemKinds: Set<ItemKind> = [], nodes: [NibID] = [],
                ref: String? = nil, index: Int? = nil) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.point = point
        self.selection = selection
        self.itemKinds = itemKinds
        self.nodes = nodes
        self.ref = ref
        self.index = index
    }
}

/// A menu entry always runs a command (so plugins, AI and the bridge can do the same thing).
public struct MenuItemDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String?
    public var location: MenuLocation
    public var order: Int
    public var owner: String
    public var command: String
    public var params: @MainActor (MenuContext) -> JSONValue
    public var isVisible: @MainActor (MenuContext) -> Bool
    public var destructive: Bool
    /// Shown as an icon in the object menu's quick row.
    public var quick: Bool
    /// Sub-menu title this entry is grouped under (nil = top level).
    public var submenu: String?

    public init(id: String, title: String, icon: String? = nil, location: MenuLocation, order: Int, owner: String,
                command: String,
                params: @escaping @MainActor (MenuContext) -> JSONValue = { _ in [:] },
                isVisible: @escaping @MainActor (MenuContext) -> Bool = { _ in true },
                destructive: Bool = false, quick: Bool = false, submenu: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.location = location
        self.order = order
        self.owner = owner
        self.command = command
        self.params = params
        self.isVisible = isVisible
        self.destructive = destructive
        self.quick = quick
        self.submenu = submenu
    }
}

// MARK: - Panels, settings pages, inspectors

public enum PanelPlacement: String, Codable, CaseIterable {
    /// A tab in the document sidebar (Pages, Outline, Audio, Boards, Search, Layers…).
    case sidebarTab
    /// Draggable floating panel (AI chat, timer, plugin panels).
    case floating
    case sheet
    /// Library sidebar section (Documents, Favorites, Shared, Trash, Gallery…).
    case libraryTab
    case fullScreen
}

public struct PanelContext {
    public var app: NibApp
    public var session: EditorSession?
    public var navigator: SceneNavigator?
    public var dismiss: @MainActor () -> Void

    public init(app: NibApp, session: EditorSession?, navigator: SceneNavigator?, dismiss: @escaping @MainActor () -> Void) {
        self.app = app
        self.session = session
        self.navigator = navigator
        self.dismiss = dismiss
    }
}

public struct PanelDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var placement: PanelPlacement
    public var order: Int
    public var owner: String
    /// nil = any (library tabs ignore it).
    public var docKinds: Set<DocumentKind>?
    public var makeView: @MainActor (PanelContext) -> AnyView

    public init(id: String, title: String, icon: String, placement: PanelPlacement, order: Int, owner: String,
                docKinds: Set<DocumentKind>? = nil, makeView: @escaping @MainActor (PanelContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.placement = placement
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.makeView = makeView
    }
}

public enum SettingsSection: String, Codable, CaseIterable {
    case general, editing, stylus, writing, ai, sync, plugins, bridge, advanced, about
}

public struct SettingsPageDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var section: SettingsSection
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (NibApp) -> AnyView

    public init(id: String, title: String, icon: String, section: SettingsSection, order: Int, owner: String,
                makeView: @escaping @MainActor (NibApp) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

public struct InspectorContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var page: PageID
    public var items: [Item]

    public init(app: NibApp, session: EditorSession, doc: DocumentID, page: PageID, items: [Item]) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.items = items
    }
}

/// Style editor shown for a selection of certain item kinds (text formatting, shape style, image crop…).
public struct InspectorDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var itemKinds: Set<ItemKind>
    /// Further restricts to these `Item.drawKey`s (custom item types: "custom.<owner>.<type>"); nil = any.
    public var drawKeys: Set<String>?
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (InspectorContext) -> AnyView

    public init(id: String, title: String, icon: String, itemKinds: Set<ItemKind>, order: Int, owner: String,
                drawKeys: Set<String>? = nil, makeView: @escaping @MainActor (InspectorContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.itemKinds = itemKinds
        self.drawKeys = drawKeys
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

/// Contextual options bar for the active tool (presets, colors, sizes). Registered under the tool id; takes
/// precedence over `ToolbarItemDescriptor.activeToolMenu` so one feature can serve several tools.
public struct ToolMenuDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (EditorSession) -> AnyView

    public init(tool: String, owner: String, order: Int = 0, makeView: @escaping @MainActor (EditorSession) -> AnyView) {
        self.id = tool
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

public struct BlockViewContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var block: TextBlock
    /// Call when the view's preferred height changes.
    public var heightChanged: @MainActor (CGFloat) -> Void

    public init(app: NibApp, session: EditorSession, doc: DocumentID, block: TextBlock,
                heightChanged: @escaping @MainActor (CGFloat) -> Void) {
        self.app = app
        self.session = session
        self.doc = doc
        self.block = block
        self.heightChanged = heightChanged
    }
}

/// Renders one Text Document block kind that the text document editor does not render itself (e.g. tables).
/// Custom blocks without a view are drawn by the editor from `CustomBlock.display`.
public struct BlockViewDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (BlockViewContext) -> UIView

    public init(kind: BlockKind, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }

    /// A view for one custom block type (id "custom.<owner>.<type>").
    public init(customType: String, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = "custom." + customType
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Builds a plugin's HTML panel (Plugin Panels feature; shared via `ServiceKeys.pluginPanels`).
@MainActor
public protocol PluginPanelFactory: AnyObject {
    func makePanel(manifest: PluginManifest, folder: URL, entry: String, context: PanelContext) -> AnyView
}

// MARK: - Canvas tools and document editors

public struct CanvasToolDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var make: @MainActor () -> CanvasTool

    public init(id: String, title: String, order: Int = 0, owner: String, make: @escaping @MainActor () -> CanvasTool) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Editor for one document kind (id = DocumentKind raw value). The view controller must adopt `DocumentEditing`.
public struct DocumentEditorDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController

    public init(kind: DocumentKind, owner: String, order: Int = 0,
                make: @escaping @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }
}

// MARK: - Shell

public enum OpenMode { case replace, newTab, newWindow }

/// One per window scene (implemented by the app shell's root view controller).
@MainActor
public protocol SceneNavigator: AnyObject {
    var session: EditorSession { get }
    /// Open tabs, in order.
    var openDocuments: [DocumentID] { get }
    var activeDocument: DocumentID? { get }
    var rootViewController: UIViewController? { get }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode)
    func closeDocument(_ doc: DocumentID)
    func showLibrary(folder: FolderID?)
    func showSettings(page: String?)
    func presentModal(_ viewController: UIViewController)
}

/// Window lifecycle hooks (Tabs & Windows feature).
@MainActor
public protocol SceneHooks: AnyObject {
    func sceneDidConnect(_ scene: UIWindowScene, options: UIScene.ConnectionOptions, navigator: SceneNavigator)
    func restorationActivity(_ navigator: SceneNavigator) -> NSUserActivity?
    /// Tab strip shown above the document chrome (nil = none).
    func makeTabBar(_ navigator: SceneNavigator) -> UIView?
}

/// Screen factories filled by features. The shell falls back to minimal built-in screens when nil.
@MainActor
public final class ScreenRegistry {
    public var libraryRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Wraps an editor view controller with the document chrome (nav bar, toolbar, sidebar, panels).
    public var documentContainer: (@MainActor (UIViewController, DocumentID, NibApp, SceneNavigator) -> UIViewController)?
    public var settingsRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Returns nil when onboarding is complete.
    public var onboarding: (@MainActor (NibApp, SceneNavigator) -> UIViewController?)?
    /// The document toolbar view (Toolbar feature); embedded by the document chrome.
    public var toolbar: (@MainActor (EditorSession, NibApp) -> UIView)?

    public init() {}
}

@MainActor
public final class UIRegistries {
    public let toolbar = Registry<ToolbarItemDescriptor>()
    public let menus = Registry<MenuItemDescriptor>()
    public let panels = Registry<PanelDescriptor>()
    public let settingsPages = Registry<SettingsPageDescriptor>()
    public let inspectors = Registry<InspectorDescriptor>()
    public let canvasTools = Registry<CanvasToolDescriptor>()
    public let editors = Registry<DocumentEditorDescriptor>()
    public let toolMenus = Registry<ToolMenuDescriptor>()
    public let blockViews = Registry<BlockViewDescriptor>()
    /// Persistent canvas overlays and touch targets that are not the active tool (see `CanvasAttachment`).
    public let canvasAttachments = Registry<CanvasAttachmentDescriptor>()
    public let screens: ScreenRegistry
    public var sceneHooks: SceneHooks?
    public var pencilHandler: PencilEventHandler?
    /// Root view controller for an external display scene (Presentation feature); nil = system mirroring.
    public var externalDisplay: (@MainActor (UIWindowScene) -> UIViewController)?
    /// Awaited before a document opens (Password Lock feature); false cancels the open.
    public var openGate: (@MainActor (DocumentID) async -> Bool)?
    /// Navigator of the most recently active window.
    public weak var activeNavigator: SceneNavigator?

    public init() {
        screens = ScreenRegistry()
    }

    public func menuItems(_ location: MenuLocation, _ context: MenuContext) -> [MenuItemDescriptor] {
        menus.all.filter { $0.location == location && $0.isVisible(context) }
    }

    public func toolbarItems(for kind: DocumentKind) -> [ToolbarItemDescriptor] {
        toolbar.all.filter { $0.docKinds.contains(kind) }
    }
}
