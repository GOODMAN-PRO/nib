import SwiftUI
import NibContracts
import NibDesign

@MainActor
enum AnyMovePicker {
    static func make(_ context: PanelContext) -> AnyView {
        guard let session = context.session else {
            return AnyView(NibEmptyState(symbol: .warningTriangle, title: String(localized: "A library window is required")))
        }
        return AnyView(MovePicker(model: LibraryModels.get(context.app).model(session), context: context))
    }
}

enum MoveDestinations {
    static func available(_ folders: [LibraryRow], moving refs: Set<String>) -> [LibraryRow] {
        let map = Dictionary(folders.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return folders.filter { folder in
            var ref: String? = folder.ref, seen = Set<String>()
            while let current = ref {
                if refs.contains(current) || !seen.insert(current).inserted { return false }
                ref = map[current]?.parent
            }
            return true
        }
    }
}

struct MovePicker: View {
    @ObservedObject var model: LibraryViewModel
    let context: PanelContext
    @State private var folders: [LibraryRow] = []
    @State private var busy = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var newTitle = ""
    private var state: JSONValue { model.modal?.id == "libraryui.move" ? model.modal?.params ?? context.params : context.params }
    private var refs: [String] { state["refs"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    private var destination: String { state["destination"]?.stringValue ?? state["folder"]?.stringValue ?? "lib" }
    private var search: String { state["search"]?.stringValue ?? "" }
    private var sort: LibrarySort { LibrarySort(rawValue: state["sort"]?.stringValue ?? "") ?? .name }
    private var recursive: Bool { state["recursive"]?.boolValue ?? false }
    private var visible: [LibraryRow] {
        let candidates = MoveDestinations.available(folders, moving: Set(refs))
        let children = search.isEmpty && !recursive ? candidates.filter { ($0.parent ?? "lib") == destination } : candidates
        return LibrarySorting.rows(children, sort: sort, filter: .folders, search: search)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            NibSearchField(text: $searchText, prompt: String(localized: "Find a folder"))
            HStack {
                NibButton(String(localized: "Library Root"), symbol: .library, kind: .plain) { update(["destination": "lib"]) }
                Menu {
                    ForEach(LibrarySort.allCases.filter { $0 != .manual }, id: \.self) { sort in
                        Button(sort.title) { update(["sort": .string(sort.rawValue)]) }
                    }
                } label: { Text(sort.title).font(NibFont.button).foregroundStyle(NibColor.label).frame(minHeight: NibMetrics.hitTarget) }
                Spacer()
                NibToggle(String(localized: "All folders"), isOn: Binding(get: { recursive }, set: { update(["recursive": .bool($0)]) }))
            }
            Text(destination == "lib" ? String(localized: "Documents") : folders.first { $0.ref == destination }?.path ?? String(localized: "Folder"))
                .font(NibFont.title3).foregroundStyle(NibColor.label)
            ScrollView {
                LazyVStack(spacing: NibSpacing.xs) {
                    ForEach(visible) { row in
                        NibButton(row.name, symbol: .folder, kind: .plain) { update(["destination": .string(row.ref), "search": ""]) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let error { NibBanner(error) }
            HStack {
                TextField(String(localized: "New folder name"), text: $newTitle).font(NibFont.body).frame(minHeight: NibMetrics.hitTarget)
                    .onSubmit { Task { await createFolder() } }
                    .accessibilityIdentifier("cmd.folder.create")
                NibButton(String(localized: "Create Folder"), symbol: .plus) { Task { await createFolder() } }
                    .accessibilityIdentifier("cmd.folder.create")
                    .disabled(busy || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                NibButton(String(localized: "Cancel"), kind: .plain) { context.dismiss() }
                .accessibilityIdentifier("cmd.panel.close")
                Spacer()
                NibButton(String(localized: "Move Here"), kind: .primary) { Task { await move() } }
                    .accessibilityIdentifier("cmd.library.move").disabled(busy || refs.isEmpty)
            }
        }
        .padding(NibSpacing.xxl).background(NibColor.background).task { searchText = search; newTitle = state["newTitle"]?.stringValue ?? ""; await load() }
        .onChange(of: search) { _, value in if value != searchText { searchText = value } }
        .task(id: searchText) {
            guard searchText != search else { return }
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
            update(["search": .string(searchText)])
        }
    }
    private func update(_ patch: JSONValue) { model.setView(["panel": "libraryui.move", "params": state.merging(patch)]) }
    private func load() async {
        do { folders = try await model.queryRows(folder: nil, recursive: true, foldersOnly: true) }
        catch { self.error = NibError.wrap(error).message }
    }
    private func createFolder() async {
        busy = true; defer { busy = false }
        do {
            let result = try await MovePickerActions.createFolder(title: newTitle, destination: destination, model: model)
            await load()
            update(["destination": result["ref"] ?? "lib", "newTitle": ""])
            newTitle = ""; error = nil
        } catch { self.error = NibError.wrap(error).message }
    }
    private func move() async {
        busy = true; defer { busy = false }
        do {
            try await MovePickerActions.move(refs: refs, destination: destination, model: model)
            context.dismiss()
        } catch { self.error = NibError.wrap(error).message }
    }
}

@MainActor
enum MovePickerActions {
    static func createFolder(title: String, destination: String, model: LibraryViewModel) async throws -> JSONValue {
        var params: JSONValue = ["title": .string(title)]
        if destination != "lib" { params = params.merging(["parent": .string(destination)]) }
        return try await model.app.bus.execute(CommandIDs.folderCreate, params, session: model.session)
    }
    static func move(refs: [String], destination: String, model: LibraryViewModel) async throws {
        var params: JSONValue = ["refs": .array(refs.map(JSONValue.string))]
        if destination != "lib" { params = params.merging(["folder": .string(destination)]) }
        _ = try await model.app.bus.execute(CommandIDs.libraryMove, params, session: model.session)
    }
}
