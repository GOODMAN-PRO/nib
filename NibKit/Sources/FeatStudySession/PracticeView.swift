import SwiftUI
import UIKit
import AVFoundation
import PencilKit
import ImageIO
import NibContracts
import NibDesign

@MainActor
protocol StudySpeaking: AnyObject {
    func speak(_ text: String, language: String) throws
    func stop()
}

enum StudyVoiceLanguages {
    static func resolve(_ language: String, installed: [String]) -> String? {
        func canonical(_ code: String) -> String { code.replacingOccurrences(of: "_", with: "-").lowercased() }
        let requested = canonical(language)
        if let exact = installed.first(where: { canonical($0) == requested }) { return exact }
        let mapped: String?
        if requested.hasPrefix("zh-hans") { mapped = "zh-cn" }
        else if requested.hasPrefix("zh-hant") { mapped = "zh-tw" }
        else if requested == "yue" || requested.hasPrefix("yue-") { mapped = "zh-hk" }
        else if requested == "vi-vt" { mapped = "vi-vn" }
        else { mapped = nil }
        if let mapped, let match = installed.first(where: { canonical($0) == mapped }) { return match }
        let code = requested.split(separator: "-").first
        return installed.first { canonical($0).split(separator: "-").first == code }
    }
}

@MainActor
final class StudySpeech: StudySpeaking {
    static let installedLanguages = Array(Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))).sorted()
    private var synthesizer: AVSpeechSynthesizer?
    func speak(_ text: String, language: String) throws {
        guard !NibApp.isHostlessTest else { throw NibError(.unavailable, "Speech is unavailable in hostless tests.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NibError(.unavailable, String(localized: "This side has no text to read aloud."))
        }
        guard let resolved = StudyVoiceLanguages.resolve(language, installed: Self.installedLanguages),
              let voice = AVSpeechSynthesisVoice(language: resolved) else {
            throw NibError(.unavailable, String(localized: "A voice for this language is not installed."))
        }
        let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer?.stopSpeaking(at: .immediate) }
}

@MainActor
final class StudySessionModel: ObservableObject {
    unowned let app: NibApp
    unowned let runtime: StudyRuntime
    let doc: DocumentID
    weak var session: EditorSession?
    @Published private(set) var content: DocumentContent?
    @Published private(set) var queue: [NibID] = []
    @Published private(set) var index = 0
    @Published private(set) var flipped = false
    @Published private(set) var mode = "practice"
    @Published private(set) var reviewed: [NibID] = []
    @Published private(set) var hardest: [NibID] = []
    @Published private(set) var language = "en-US"
    @Published private(set) var started = false
    @Published var busy = false
    @Published var error: String?
    @Published var reminderError: String?
    @Published private(set) var instantFlip = false
    @Published private(set) var scratchPresented = false
    var speaker: StudySpeaking = StudySpeech()
    var voiceLanguages: [String] = []
    private(set) var liveCards: [StudyCard] = []
    private(set) var cardsByID: [NibID: StudyCard] = [:]
    private let pictures = NSCache<NSString, UIImage>()
    var onEnd: (() -> Void)?

    init(app: NibApp, doc: DocumentID, session: EditorSession?, runtime: StudyRuntime) {
        self.app = app; self.doc = doc; self.session = session; self.runtime = runtime
        self.reminderError = runtime.reminderErrors[doc]
        // Installed voice discovery requires the speech service, which a hostless harness cannot provide.
        if !NibApp.isHostlessTest { voiceLanguages = StudySpeech.installedLanguages }
        pictures.totalCostLimit = 24 << 20
    }
    var docRef: String { NodeRef.document(doc).description }
    var current: StudyCard? {
        guard queue.indices.contains(index) else { return nil }
        return cardsByID[queue[index]]
    }
    var theme: StudyTheme { content.map { StudyPreferences.theme($0.meta) } ?? StudyTheme() }
    var cardPaper: NibPaper { NibPaper(rawValue: theme.card) ?? .white }
    var cardFill: Color { colour(theme.card) ?? NibPaper.white.color }
    var cardIsDark: Bool {
        if let paper = NibPaper(rawValue: theme.card) { return paper.isDark }
        guard let rgba = RGBA(hex: theme.card) else { return false }
        return (Double(rgba.r) * 0.2126 + Double(rgba.g) * 0.7152 + Double(rgba.b) * 0.0722) / 255 < 0.5
    }
    var desk: Color { theme.background.flatMap(colour) ?? NibColor.desk }
    private func colour(_ name: String) -> Color? {
        if let paper = NibPaper(rawValue: name) { return paper.color }
        return RGBA(hex: name).map { Color(uiColor: $0.uiColor) }
    }
    var paused: Bool { content.map { StudyPreferences.paused($0.meta) } ?? true }
    var readOnly: Bool { app.isReadOnly(doc) || session?.readOnly == true }
    var nextReview: Double? { Scheduler.nextReview(liveCards, now: runtime.now()) }

    func accept(_ content: DocumentContent) {
        let oldID = current?.id
        self.content = content
        liveCards = content.liveCards
        cardsByID = Dictionary(uniqueKeysWithValues: liveCards.map { ($0.id, $0) })
        if !started { language = StudyVoiceLanguages.resolve(content.meta.language, installed: voiceLanguages) ?? content.meta.language }
        if started {
            queue.removeAll { cardsByID[$0] == nil }
            if mode == "practice" { index = oldID.flatMap { queue.firstIndex(of: $0) } ?? min(index, queue.count) }
            else { moveToDueCard() }
        }
        if oldID != current?.id {
            flipped = false
            instantFlip = true
            speaker.stop()
        }
    }

    func act(_ action: String, mode: String?, language: String?, instant: Bool) throws {
        switch action {
        case "start":
            guard mode == nil || mode == "practice" || mode == "smartLearn" else {
                throw NibError.invalid("Choose practice or smartLearn.", path: "$.mode")
            }
            guard let content else { throw NibError.notFound("study set") }
            self.mode = mode ?? "practice"
            queue = (self.mode == "smartLearn" ? Scheduler.due(liveCards, now: runtime.now()) : liveCards).map(\.id)
            index = 0; reviewed = []; hardest = []; instantFlip = true; flipped = false; started = true
            self.language = StudyVoiceLanguages.resolve(content.meta.language, installed: voiceLanguages) ?? content.meta.language
            speaker.stop()
        case "flip":
            guard current != nil else { return }
            instantFlip = instant
            var transaction = Transaction()
            transaction.disablesAnimations = instant
            withTransaction(transaction) { flipped.toggle() }
            speaker.stop()
        case "previous", "next":
            guard self.mode == "practice", !queue.isEmpty else { return }
            instantFlip = instant
            index = min(max(index + (action == "next" ? 1 : -1), 0), queue.count - 1)
            flipped = false; speaker.stop()
        case "language":
            guard let language, voiceLanguages.contains(language) else {
                throw NibError(.invalidParams, "Use an installed language code.", path: "$.language", hint: "pass a BCP-47 locale such as en-GB or th-TH")
            }
            self.language = language; speaker.stop()
        case "speak":
            guard let card = current else { return }
            let face = flipped ? card.back : card.front
            try speaker.speak(face.text?.plainText ?? "", language: self.language)
        case "scratch":
            guard app.ui.panels.get("studyeditor.scratch") != nil else {
                throw NibError(.unavailable, String(localized: "Scratch paper is unavailable in this host."))
            }
            speaker.stop(); scratchPresented = true
        case "closeScratch": scratchPresented = false
        case "stopSpeech": speaker.stop()
        case "end":
            speaker.stop(); started = false; onEnd?()
        default: throw NibError.invalid("Unknown study session action.", path: "$.action")
        }
    }

    func recordGrade(_ id: NibID, rating: StudyRating) {
        guard started, queue.contains(id) else { return }
        if mode == "practice" {
            guard current?.id == id else { return }
        } else if reviewed.contains(id) { return }
        if !reviewed.contains(id) { reviewed.append(id) }
        if (rating == .again || rating == .hard), !hardest.contains(id) { hardest.append(id) }
        instantFlip = true
        flipped = false; speaker.stop()
        if mode == "practice" { index += 1 } else { moveToDueCard() }
    }

    private func moveToDueCard() {
        index = queue.firstIndex { id in
            !reviewed.contains(id) && cardsByID[id].map { Scheduler.dueDate($0) <= runtime.now() } == true
        } ?? queue.count
    }

    func send(_ command: String, _ params: JSONValue) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await app.bus.execute(Invocation(command: command, params: params, session: session))
                error = nil
                if command != StudySessionAction.id { try await reload() }
            } catch { self.error = NibError.wrap(error).message }
        }
    }
    func action(_ action: String, instant: Bool = false, language: String? = nil) {
        var params: [String: JSONValue] = ["doc": .string(docRef), "action": .string(action), "instant": .bool(instant)]
        if let language { params["language"] = .string(language) }
        send(StudySessionAction.id, .object(params))
    }
    func end(close: () -> Void) {
        // Closing remains available while a grade or OS permission request is in flight.
        onEnd = nil
        app.perform(StudySessionAction.id, ["doc": .string(docRef), "action": "end"], session: session)
        close()
    }
    func grade(_ rating: StudyRating) {
        guard let card = current, flipped, !readOnly else { return }
        send(CommandIDs.studyGrade, ["card": .string(NodeRef.card(doc, card.id).description),
                                    "knewIt": .bool(rating.knewIt), "rating": .string(rating.rawValue)])
    }
    func reload() async throws {
        accept(try app.workspace.content(doc))
    }
    func begin(_ mode: String) async {
        do {
            try await reload()
            _ = try await app.bus.execute(Invocation(command: StudySessionAction.id,
                params: ["doc": .string(docRef), "action": "start", "mode": .string(mode)], session: session))
        } catch { self.error = NibError.wrap(error).message }
    }
    func interval(_ rating: StudyRating) -> String {
        let s = Scheduler.grade(current?.srs, rating: rating, now: runtime.now())
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = s.interval < 1 ? [.minute, .hour] : [.day, .hour]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: s.interval * Scheduler.day) ?? ""
    }
    func picture(_ face: CardFace, card: StudyCard, back: Bool) -> UIImage? {
        let key = (card.id.raw + card.rev.description + (back ? "/back" : "/front")) as NSString
        if let image = pictures.object(forKey: key) { return image }
        var image: UIImage?
        if face.kind == .image, let asset = face.asset, let data = try? app.services.assets?.data(asset, doc: doc) {
            // Downsample large imports before decoding to protect memory on older iPads.
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: NibMetrics.studyCardSize.width * 2,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { image = UIImage(cgImage: cg) }
        } else if face.kind == .ink {
            let size = face.size ?? PageSize(Double(NibMetrics.studyCardSize.width), Double(NibMetrics.studyCardSize.height))
            let scale = min(2, NibMetrics.studyCardSize.width * 2 / CGFloat(max(size.width, size.height, 1)))
            image = PKBridge.drawing(face.ink ?? []).image(from: CGRect(x: 0, y: 0, width: size.width, height: size.height), scale: scale)
        }
        if let image {
            pictures.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        }
        return image
    }
}

struct PracticeView: View {
    @ObservedObject var model: StudySessionModel
    let close: () -> Void
    var body: some View { StudySessionView(model: model, smartLearn: false, close: close) }
}

enum StudyCardLayout {
    /// Fit the paper's aspect ratio into the space left after the HUD and grading controls have laid out.
    static func fittingSize(in available: CGSize) -> CGSize {
        let paper = NibMetrics.studyCardSize
        let scale = min(1, max(0, available.width) / paper.width, max(0, available.height) / paper.height)
        return CGSize(width: paper.width * scale, height: paper.height * scale)
    }
}

struct StudySessionView: View {
    @ObservedObject var model: StudySessionModel
    let smartLearn: Bool
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = CGSize.zero
    @State private var swiping = false
    @State private var resetConfirmed = false
    @State private var optionsPresented = false

    var body: some View {
        sessionLayout
        .task {
            model.onEnd = close
            let mode = smartLearn ? "smartLearn" : "practice"
            if !model.started || model.mode != mode { await model.begin(mode) }
        }
        .sheet(isPresented: Binding(get: { model.scratchPresented }, set: { if !$0 { model.action("closeScratch") } })) {
            if let descriptor = model.app.ui.panels.get("studyeditor.scratch") {
                descriptor.makeView(PanelContext(app: model.app, session: model.session,
                    navigator: model.app.ui.activeNavigator, dismiss: { model.action("closeScratch") }))
            }
        }
        .onDisappear {
            model.onEnd = nil
            if !model.scratchPresented && !optionsPresented {
                model.app.perform(StudySessionAction.id, ["doc": .string(model.docRef), "action": "end"], session: model.session)
            }
        }
    }

    private var header: some View {
        NibPanelHeader(title: smartLearn ? String(localized: "Smart Learn") : String(localized: "Practice"),
                       symbol: .studySets, onClose: {
                           model.end(close: close)
                       }) {
            HStack(spacing: NibSpacing.xs) {
                if !smartLearn, model.current != nil {
                    NibIconButton(.back, label: String(localized: "Previous Card"), size: .panel,
                                  shortcut: KeyboardShortcut(.leftArrow, modifiers: [])) {
                        model.action("previous", instant: true)
                    }.disabled(model.busy || model.index == 0)
                    NibIconButton(.forward, label: String(localized: "Next Card"), size: .panel,
                                  shortcut: KeyboardShortcut(.rightArrow, modifiers: [])) {
                        model.action("next", instant: true)
                    }.disabled(model.busy || model.index + 1 >= model.queue.count)
                }
                NibIconButton(.more, label: String(localized: "Study options"), size: .panel) {
                    optionsPresented = true
                }
                .popover(isPresented: $optionsPresented) {
                    VStack(spacing: 0) {
                        NibPanelHeader(title: String(localized: "Study options"), symbol: .studySets,
                                       onClose: { optionsPresented = false })
                        ScrollView { controls.padding(NibSpacing.l) }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(idealWidth: NibMetrics.studyCardSize.width,
                           idealHeight: NibMetrics.popoverMaxHeight)
                    .background(NibColor.background)
                    .foregroundStyle(NibColor.label)
                }
            }
        }
    }

    private var sessionLayout: some View {
        NibDropletContainer {
            VStack(spacing: 0) {
                header
                if let card = model.current {
                    VStack(spacing: NibSpacing.l) {
                        if let error = model.error { NibBanner(error) }
                        progress.fixedSize(horizontal: false, vertical: true)
                        GeometryReader { geometry in
                            cardView(card, size: StudyCardLayout.fittingSize(in: geometry.size))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .disabled(swiping)
                        grading.fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, NibSpacing.l)
                    .padding(.bottom, NibSpacing.l)
                } else {
                    ScrollView {
                        VStack(spacing: NibSpacing.xxl) {
                            if let error = model.error { NibBanner(error) }
                            if !model.started, model.error == nil {
                                ProgressView().accessibilityLabel(String(localized: "Loading study cards"))
                            } else if model.started {
                                StudySummaryView(model: model, smartLearn: smartLearn, close: close)
                            }
                        }
                        .padding(NibSpacing.l)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.desk.ignoresSafeArea())
        .foregroundStyle(NibColor.label)
    }

    /// The actual screen composition without session lifecycle callbacks, for layout snapshots.
    var snapshotContent: some View { sessionLayout }

    private var progress: some View {
        VStack(spacing: NibSpacing.s) {
            Text(String(localized: "\(min(model.index + 1, model.queue.count)) of \(model.queue.count)"))
                .font(NibFont.hud)
            NibProgressBar(value: progressValue)
                .accessibilityLabel(String(localized: "Study progress"))
        }
        .frame(maxWidth: NibMetrics.studyCardSize.width)
    }
    private var progressValue: Double {
        Double(smartLearn ? model.reviewed.count : model.index + 1) / Double(max(model.queue.count, 1))
    }

    private func cardView(_ card: StudyCard, size: CGSize) -> some View {
        NibFlashcard(isFlipped: model.flipped, fill: model.cardFill) {
            StudyFaceView(model: model, card: card, face: card.front, back: false)
        } back: {
            StudyFaceView(model: model, card: card, face: card.back, back: true)
        }
        .frame(width: size.width, height: size.height)
        .offset(drag)
        .rotationEffect(.degrees(reduceMotion ? 0 : min(6, max(-6, Double(drag.width / max(size.width, 1)) * 6))))
        .transaction { if model.instantFlip { $0.disablesAnimations = true } }
        .contentShape(RoundedRectangle(cornerRadius: NibRadius.studyCard))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: NibRadius.studyCard))
        .hoverEffect(.highlight)
        .onTapGesture { model.action("flip") }
        .gesture(DragGesture(minimumDistance: NibSpacing.l).onChanged { value in
            guard !model.busy, !swiping else { return }
            if !reduceMotion { drag = value.translation }
        }.onEnded { value in
            guard !model.busy, !swiping else { drag = .zero; return }
            let travel = value.predictedEndTranslation.width
            if abs(travel) > size.width / 4 {
                if model.flipped, !model.readOnly {
                    if reduceMotion { model.grade(travel > 0 ? .good : .again); drag = .zero }
                    else {
                        swiping = true
                        withAnimation(NibMotion.sheet.animation, completionCriteria: .logicallyComplete) {
                            drag = CGSize(width: travel > 0 ? max(travel, size.width) : min(travel, -size.width), height: value.predictedEndTranslation.height)
                        } completion: {
                            if model.current?.id == card.id { model.grade(travel > 0 ? .good : .again) }
                            swiping = false
                            var transaction = Transaction(); transaction.disablesAnimations = true
                            withTransaction(transaction) { drag = .zero }
                        }
                    }
                } else if !smartLearn { model.action(travel < 0 ? "next" : "previous", instant: true) }
            }
            if !(model.flipped && !model.readOnly && !reduceMotion && abs(travel) > size.width / 4) {
                withAnimation(NibMotion.slot.animation) { drag = .zero }
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.flipped ? String(localized: "Answer side") : String(localized: "Question side"))
        .accessibilityAction(named: String(localized: "Flip Card")) { model.action("flip", instant: true) }
        .accessibilityAction(named: String(localized: "Previous Card")) { if !smartLearn { model.action("previous", instant: true) } }
        .accessibilityAction(named: String(localized: "Next Card")) { if !smartLearn { model.action("next", instant: true) } }
        .accessibilityAction(named: String(localized: "Still Learning")) { model.grade(.again) }
        .accessibilityAction(named: String(localized: "Knew It")) { model.grade(.good) }
    }

    private var flip: some View {
        NibButton(String(localized: "Flip Card"), kind: .plain,
                  shortcut: KeyboardShortcut(.space, modifiers: [])) { model.action("flip", instant: true) }.disabled(model.busy)
    }

    private var grading: some View {
        VStack(spacing: NibSpacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.l) { ForEach(StudyRating.allCases, id: \.self) { gradeButton($0) } }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NibSpacing.l) {
                    ForEach(StudyRating.allCases, id: \.self) { gradeButton($0) }
                }
            }
            if model.readOnly { Text(String(localized: "This study set is read-only.")) }
        }
        .frame(maxWidth: .infinity)
    }
    private func gradeButton(_ rating: StudyRating) -> some View {
        let key = String((StudyRating.allCases.firstIndex(of: rating) ?? 0) + 1)
        return NibDropletButton(id: "studysession.grade." + rating.rawValue,
            title: rating.title, detail: model.interval(rating), kind: .clear,
            shortcut: KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])) { model.grade(rating) }
            .disabled(model.busy || !model.flipped || model.readOnly)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            if model.current != nil { flip }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.m) { speech; language; scratch }
                VStack(alignment: .leading, spacing: NibSpacing.s) { speech; language; scratch }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: NibSpacing.l) {
                    paperPicker(card: true)
                    paperPicker(card: false)
                    NibToggle(String(localized: "Review reminders"), isOn: Binding(get: { !model.paused }, set: { enabled in
                        if enabled {
                            model.send(StudyRequestReminders.id, ["doc": .string(model.docRef)])
                        } else {
                            model.send(CommandIDs.studySetReminders, ["doc": .string(model.docRef), "paused": true])
                        }
                    })).disabled(model.readOnly || model.busy)
                    if !model.paused, let message = model.reminderError { NibBanner(message) }
                    if resetConfirmed {
                        Text(String(localized: "Clear the review history for every card? You can undo this change."))
                        HStack {
                            NibButton(String(localized: "Reset Progress"), kind: .destructivePlain) {
                                model.send(CommandIDs.studyResetProgress, ["doc": .string(model.docRef)])
                                resetConfirmed = false
                            }
                            .accessibilityIdentifier("cmd." + CommandIDs.studyResetProgress)
                            NibButton(String(localized: "Keep Progress"), kind: .plain) { resetConfirmed = false }
                        }
                    } else {
                        NibButton(String(localized: "Reset Progress"), kind: .destructivePlain) { resetConfirmed = true }
                    }
                }.padding(.top, NibSpacing.l).disabled(model.readOnly || model.busy)
            } label: {
                Text(String(localized: "Appearance and reminders"))
                    .frame(minHeight: NibMetrics.hitTarget)
            }
        }
        .font(NibFont.body)
        .frame(maxWidth: NibMetrics.studyCardSize.width)
    }
    private var speech: some View {
        NibButton(String(localized: "Read Aloud"), symbol: .speak, kind: .plain) { model.action("speak") }
            .disabled(model.busy || (model.flipped ? model.current?.back.text : model.current?.front.text)?.plainText.isEmpty != false)
    }
    private var language: some View {
        Picker(String(localized: "Voice language"), selection: Binding(get: { model.language }, set: { model.action("language", language: $0) })) {
            ForEach(model.voiceLanguages, id: \.self) { code in
                Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
            }
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget).disabled(model.busy)
    }
    private var scratch: some View {
        NibButton(String(localized: "Open Scratchpad"), symbol: .quickNote, kind: .plain) {
            optionsPresented = false
            model.action("scratch")
        }.disabled(model.busy || model.app.ui.panels.get("studyeditor.scratch") == nil)
    }
    private func paperPicker(card: Bool) -> some View {
        let selected = card ? model.theme.card : model.theme.background ?? "desk"
        return VStack(alignment: .leading, spacing: NibSpacing.s) {
            Text(card ? String(localized: "Card colour") : String(localized: "Background colour"))
                .font(NibFont.headline)
            ScrollView(.horizontal) {
                HStack(spacing: NibSpacing.m) {
                    if !card {
                        paperTile(name: String(localized: "Desk"), colour: NibColor.desk, value: "desk", selected: selected, card: false)
                    }
                    if NibPaper(rawValue: selected) == nil && selected != "desk" {
                        paperTile(name: String(localized: "Custom colour"), colour: card ? model.cardFill : model.desk,
                                  value: selected, selected: selected, card: card)
                    }
                    ForEach(NibPaper.allCases, id: \.self) { paper in
                        paperTile(name: paper.name, colour: paper.color, value: paper.rawValue, selected: selected, card: card)
                    }
                }.padding(NibSpacing.xs)
            }
        }
    }
    private func paperTile(name: String, colour: Color, value: String, selected: String, card: Bool) -> some View {
        NibPaperTile(name: name, isSelected: selected == value, size: NibMetrics.coverStripSize, action: {
            model.send(CommandIDs.studySetTheme, ["doc": .string(model.docRef), card ? "card" : "background": .string(value)])
        }) {
            colour
        }
    }

}

struct StudyFaceView: View {
    @ObservedObject var model: StudySessionModel
    let card: StudyCard
    let face: CardFace
    let back: Bool
    var body: some View {
        Group {
            if face.kind == .text {
                ViewThatFits(in: .vertical) {
                    text.fixedSize(horizontal: false, vertical: true)
                    ScrollView { text }
                }
            } else if let image = model.picture(face, card: card, back: back) {
                Image(uiImage: image).resizable().scaledToFit().padding(NibSpacing.l)
                    .accessibilityLabel(face.kind == .ink ? String(localized: "Handwritten card side") : String(localized: "Image card side"))
            } else {
                Text(String(localized: "This card side is empty or its image is unavailable."))
                    .font(NibFont.callout).foregroundStyle(model.cardIsDark ? NibInk.chalk.color : NibInk.carbon.color)
                    .padding(NibSpacing.xxl)
            }
        }
    }
    private var attributedText: AttributedString {
        var result = AttributedString()
        for (index, paragraph) in (face.text?.paragraphs ?? []).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for run in paragraph.runs {
                var segment = AttributedString(run.text)
                var font = NibFont.cardFace
                if run.attrs.bold == true { font = font.bold() }
                if run.attrs.italic == true { font = font.italic() }
                segment.font = font
                if run.attrs.underline == true { segment.underlineStyle = .single }
                if run.attrs.strikethrough == true { segment.strikethroughStyle = .single }
                if let colour = run.attrs.color { segment.foregroundColor = Color(uiColor: colour.uiColor) }
                result.append(segment)
            }
        }
        return result
    }

    private var text: some View {
        Text(attributedText)
            .font(NibFont.cardFace)
            .multilineTextAlignment(.center)
            .foregroundStyle(model.cardIsDark ? NibInk.chalk.color : NibInk.carbon.color)
            .frame(maxWidth: .infinity)
            .padding(NibSpacing.xxl)
    }
}

extension StudyRating {
    var title: String {
        switch self {
        case .again: return String(localized: "Again")
        case .hard: return String(localized: "Hard")
        case .good: return String(localized: "Good")
        case .easy: return String(localized: "Easy")
        }
    }
}
