import AppIntents
import os
import SwiftUI
import UIKit
import WidgetKit

// Nib's widget extension (F096, D-018, P-069). Everything in it is optional: the app never depends on it, CI also ships
// Nib-unsigned-noextensions.ipa without it (free Apple IDs with few App IDs), and it can be removed from project.yml
// without code changes. It links no NibKit module, so it talks to the app only through nib:// links and, when the
// sideloading tool provides an App Group, the favourites.json file the app writes there (F074).
//
//   QuickNote     Home Screen small, Lock Screen and StandBy; opens nib://quicknote
//   Search        Home Screen small, Lock Screen and StandBy; opens nib://search
//   Favourites    offered only when an App Group container exists; each favourite opens nib://open/<doc>
//   Control       iOS 18 Control Center, Lock Screen and Action button; opens nib://quicknote

@main
struct NibWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickNoteWidget()
        SearchWidget()
        FavouritesWidget()
        if #available(iOS 18.0, *) {
            QuickNoteControl()
        }
    }
}

// MARK: - Kinds and links

/// Widget and control kinds. They are persisted by the system with every placed widget, so they never change.
enum NibWidgetKind {
    static let quickNote = "app.nib.widget.quicknote"
    static let search = "app.nib.widget.search"
    static let favourites = "app.nib.widget.favourites"
    static let quickNoteControl = "app.nib.control.quicknote"
}

/// The deep links the widgets open (ARCHITECTURE.md §12). The app routes them through `app.openURL` (F074), so a widget
/// tap runs the same commands as the matching action inside Nib.
enum NibWidgetLinks {
    static let scheme = "nib"
    // Literal links: always valid URLs.
    static let quickNote = URL(string: "nib://quicknote")!
    static let search = URL(string: "nib://search")!

    /// nib://open/<doc>, or nil when `id` is not a Nib id (1-64 characters of A-Z, a-z, 0-9, _ and -).
    static func open(document id: String) -> URL? {
        guard isDocumentID(id) else { return nil }
        return URL(string: "nib://open/" + id)
    }

    /// The link a favourite opens: the file's own `url` when it is a nib://open link to a valid document id (it may name
    /// a page), otherwise one built from `id`.
    static func favouriteLink(id: String, url: String?) -> URL? {
        if let url, let parsed = URL(string: url), parsed.scheme?.lowercased() == scheme, parsed.host == "open" {
            let segments = parsed.pathComponents.filter { $0 != "/" }
            if (1...2).contains(segments.count), segments.allSatisfy(isDocumentID) { return parsed }
        }
        return open(document: id)
    }

    private static let idScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func isDocumentID(_ id: String) -> Bool {
        guard (1...64).contains(id.unicodeScalars.count) else { return false }
        return id.unicodeScalars.allSatisfy { idScalars.contains($0) }
    }
}

// MARK: - App Group

/// The App Group container, when the sideloading tool provides one. Mirrors `AppGroup.containerURL` (NibContracts),
/// which this extension cannot link: AltStore and SideStore register groups even for free Apple IDs and list the
/// rewritten ids in Info.plist `ALTAppGroups`; `NibAppGroups` lists the ids the build asked for. The host app's
/// Info.plist is read too, because a tool may rewrite only the app's.
enum WidgetAppGroup {
    static var containerURL: URL? {
        for id in groupIDs {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        return nil
    }

    static var groupIDs: [String] {
        var infos: [[String: Any]] = [Bundle.main.infoDictionary ?? [:]]
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if host.pathExtension == "app", let info = Bundle(url: host)?.infoDictionary { infos.append(info) }
        return orderedGroupIDs(infos)
    }

    /// `ALTAppGroups` before `NibAppGroups`, each Info.plist in turn, without repeats or empty ids.
    static func orderedGroupIDs(_ infos: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for key in ["ALTAppGroups", "NibAppGroups"] {
            for info in infos {
                for id in (info[key] as? [String]) ?? [] {
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, seen.insert(trimmed).inserted { ids.append(trimmed) }
                }
            }
        }
        return ids
    }
}

// MARK: - Design tokens (mirrored)

/// The NibDesign tokens the widgets use, mirrored because NibWidgets links no NibKit module. Values are DESIGN.md's:
/// §3.2 Pool accent, §3.6 White and Slate paper with their rules, §3.1 neutrals (Apple's semantic colours).
/// Colours are picked from the widget's colour scheme rather than a dynamic UIColor, which WidgetKit's renderer does
/// not always resolve per appearance.
struct WidgetPalette {
    var scheme: ColorScheme
    var contrast: ColorSchemeContrast = .standard

    /// `NibColor.accent` (Pool): #0066E0 light, #3D8BFF dark.
    var accent: Color { scheme == .dark ? Self.rgb(0x3D8BFF) : Self.rgb(0x0066E0) }
    /// `NibColor.onAccent`.
    var onAccent: Color { .white }
    /// `NibColor.background`.
    var background: Color { Color(uiColor: .systemBackground) }
    /// `NibColor.fill4` (search field, composer, proposal block); `fill3` under Increase Contrast.
    var fill: Color {
        contrast == .increased ? Color(uiColor: .tertiarySystemFill) : Color(uiColor: .quaternarySystemFill)
    }
    /// White paper, or Slate (Nib's dark paper) in dark mode.
    var paper: Color { scheme == .dark ? Self.rgb(0x1E1F22) : Self.rgb(0xFFFFFF) }
    /// The paper's rule colour; the separator under Increase Contrast.
    var paperRule: Color {
        if contrast == .increased { return Color(uiColor: .separator) }
        return scheme == .dark ? Self.rgb(0x34373D) : Self.rgb(0xCFDBE8)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// `NibSpacing` (4 pt base) and the fixed metrics the widgets need.
enum WidgetMetrics {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let xl: CGFloat = 20
    /// Hit targets and the QuickNote disc (DESIGN.md §5: 44 pt, always).
    static let target: CGFloat = 44
    /// The most a 44 pt target grows with Dynamic Type (`NibMetrics.barHeightMax`).
    static let targetMax: CGFloat = 52
    /// Ruled narrow template pitch (DESIGN.md §3.6: 20 pt) and the rule weight (0.5 pt).
    static let rulePitch: CGFloat = 20
    static let ruleWidth: CGFloat = 0.5
}

/// The SF Symbols the widgets use: the NibSymbol names for the same places (DESIGN.md §8).
enum WidgetSymbol {
    static let quickNote = "square.and.pencil"
    static let search = "magnifyingglass"
    static let favourites = "star.fill"
    static let favouritesEmpty = "star"
    static let notebook = "book.closed"
    static let whiteboard = "scribble.variable"
    static let textDocument = "doc.text"
    static let studySet = "rectangle.stack"
    static let document = "doc"
    static let unavailable = "star.slash"
}

let widgetLog = Logger(subsystem: "app.nib", category: "widgets")

// MARK: - Static timelines

/// QuickNote and Search show no data: one entry, never refreshed.
struct StaticEntry: TimelineEntry {
    let date: Date
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry {
        StaticEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
        completion(StaticEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: Date())], policy: .never))
    }
}

// MARK: - Control Center (iOS 18)

/// Opens Nib on a new QuickNote from Control Center, the Lock Screen or the Action button. The intent lives in this
/// extension (the control's process); it asks the system to open Nib and hands it nib://quicknote, which the app routes
/// like any other QuickNote link. It is hidden from Shortcuts, where the app's own Create QuickNote intent (F074) is.
@available(iOS 18.0, *)
struct OpenQuickNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New QuickNote"
    static var description = IntentDescription("Opens Nib on a new QuickNote.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(NibWidgetLinks.quickNote))
    }
}

@available(iOS 18.0, *)
struct QuickNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: NibWidgetKind.quickNoteControl) {
            ControlWidgetButton(action: OpenQuickNoteIntent()) {
                Label("QuickNote", systemImage: WidgetSymbol.quickNote)
            }
        }
        .displayName("QuickNote")
        .description("Opens Nib on a new QuickNote.")
    }
}
