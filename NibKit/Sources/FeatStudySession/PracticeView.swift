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

@MainActor
final class StudySpeech: StudySpeaking {
    private var synthesizer: AVSpeechSynthesizer?
    func speak(_ text: String, language: String) throws {
        guard !NibApp.isHostlessTest else { throw NibError(.unavailable, "Speech is unavailable in hostless tests.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NibError(.unavailable, String(localized: "This side has no text to read aloud."))
        }
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
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
    private let pictures = NSCache<NSString, UIImage>()
    var onEnd: (() -> Void)?

    init(app: NibApp, doc: DocumentID, session: EditorSession?, runtime: StudyRuntime) {
        self.app = app; self.doc = doc; self.session = session; self.runtime = runtime
        self.reminderError = runtime.reminderErrors[doc]
        pictures.totalCostLimit = 24 << 20
    }
    var docRef: String { NodeRef.document(doc).description }
    var current: StudyCard? {
        guard queue.indices.contains(index) else { return nil }
        return content?.liveCards.first { $0.id == queue[index] }
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
    var nextReview: Double? { content.flatMap { Scheduler.nextReview($0.liveCards) } }

    func accept(_ content: DocumentContent) {
        self.content = content
        if !started { language = content.meta.language }
        if started {
            let live = Set(content.liveCards.map(\.id))
            let oldID = current?.id
            queue.removeAll { !live.contains($0) }
            if mode == "practice" { index = oldID.flatMap { queue.firstIndex(of: $0) } ?? min(index, max(0, queue.count - 1)) }
            else { moveToDueCard() }
        }
    }

    func act(_ action: String, mode: String?, language: String?, instant: Bool) throws {
        switch action {
        case "start":
            guard let content else { throw NibError.notFound("study set") }
            self.mode = mode ?? "practice"
            queue = (self.mode == "smartLearn" ? Scheduler.due(content.liveCards, now: runtime.now()) : content.liveCards).map(\.id)
            index = 0; reviewed = []; hardest = []; instantFlip = true; flipped = false; started = true
            self.language = content.meta.language
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
            guard let language, Locale.availableIdentifiers.contains(where: { $0.replacingOccurrences(of: "_", with: "-").lowercased() == language.lowercased() }) else {
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
        guard started, mode == "smartLearn", queue.contains(id), !reviewed.contains(id) else { return }
        reviewed.append(id)
        if rating == .again || rating == .hard { hardest.append(id) }
        instantFlip = true
        flipped = false; speaker.stop()
        moveToDueCard()
    }

    private func moveToDueCard() {
        index = queue.firstIndex { id in
            !reviewed.contains(id) && content?.liveCards.contains { $0.id == id && Scheduler.dueDate($0) <= runtime.now() } == true
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
                try await reload()
            } catch { self.error = NibError.wrap(error).message }
        }
    }
    func action(_ action: String, instant: Bool = false, language: String? = nil) {
        var params: [String: JSONValue] = ["doc": .string(docRef), "action": .string(action), "instant": .bool(instant)]
        if let language { params["language"] = .string(language) }
        send(StudySessionAction.id, .object(params))
    }
    func grade(_ rating: StudyRating) {
        guard let card = current, flipped, !readOnly else { return }
        send(CommandIDs.studyGrade, ["card": .string(NodeRef.card(doc, card.id).description),
                                    "knewIt": .bool(rating.knewIt), "rating": .string(rating.rawValue)])
    }
    func reload() async throws {
        let result = try await app.bus.execute(Invocation(command: StudyQuery.id, params: ["doc": .string(docRef)], session: session))
        accept(try result.value.decode(DocumentContent.self))
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

struct StudySessionView: View {
    @ObservedObject var model: StudySessionModel
    let smartLearn: Bool
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = CGSize.zero
    @State private var swiping = false
    @State private var resetConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { sessionContent }
            .scrollBounceBehavior(.basedOnSize)
            .disabled(swiping)
        }
        .background(model.desk)
        .foregroundStyle(NibColor.label)
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
            if !model.scratchPresented {
                model.app.perform(StudySessionAction.id, ["doc": .string(model.docRef), "action": "end"], session: model.session)
            }
        }
    }

    private var header: some View {
        NibPanelHeader(title: smartLearn ? String(localized: "Smart Learn") : String(localized: "Practice"),
                       symbol: .studySets, onClose: {
                           if model.content == nil { close() } else { model.action("end") }
                       })
    }

    var sessionContent: some View {
        VStack(spacing: NibSpacing.xxl) {
            if let error = model.error { NibBanner(error) }
            if !model.started, model.error == nil {
                ProgressView().accessibilityLabel(String(localized: "Loading study cards"))
            } else if let card = model.current {
                progress
                cardView(card)
                if smartLearn { grading } else { navigation }
                controls
            } else if model.started {
                StudySummaryView(model: model, smartLearn: smartLearn)
                controls
            }
        }
        .padding(NibSpacing.l)
        .frame(maxWidth: .infinity)
    }

    /// The same screen composition, without the system-backed scroll view or live lifecycle callbacks, for
    /// hostless layout snapshots. The actual panel always keeps its native scroll container.
    var snapshotContent: some View {
        VStack(spacing: 0) { header; sessionContent }
            .background(model.desk)
            .foregroundStyle(NibColor.label)
    }

    private var progress: some View {
        VStack(spacing: NibSpacing.s) {
            Text(String(localized: "\(min(model.index + 1, model.queue.count)) of \(model.queue.count)"))
                .font(NibFont.hud)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(NibColor.fill1)
                    Rectangle().fill(NibColor.label).frame(width: geometry.size.width * progressValue)
                }
            }
            .frame(height: NibStroke.thick)
            .accessibilityLabel(String(localized: "Study progress"))
            .accessibilityValue(Text(progressValue, format: .percent))
        }
        .frame(maxWidth: NibMetrics.studyCardSize.width)
    }
    private var progressValue: Double {
        Double(smartLearn ? model.reviewed.count : model.index + 1) / Double(max(model.queue.count, 1))
    }

    private func cardView(_ card: StudyCard) -> some View {
        NibFlashcard(isFlipped: model.flipped, fill: model.cardFill) {
            StudyFaceView(model: model, card: card, face: card.front, back: false)
        } back: {
            StudyFaceView(model: model, card: card, face: card.back, back: true)
        }
        .frame(maxWidth: NibMetrics.studyCardSize.width)
        .frame(height: typeSize.isAccessibilitySize ? nil : NibMetrics.studyCardSize.height)
        .frame(minHeight: NibMetrics.studyCardSize.height)
        .offset(drag)
        .rotationEffect(.degrees(reduceMotion ? 0 : min(6, max(-6, Double(drag.width / NibMetrics.studyCardSize.width) * 6))))
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
            if abs(travel) > NibMetrics.studyCardSize.width / 4 {
                if smartLearn, model.flipped, !model.readOnly {
                    if reduceMotion { model.grade(travel > 0 ? .good : .again); drag = .zero }
                    else {
                        swiping = true
                        withAnimation(NibMotion.sheet.animation, completionCriteria: .logicallyComplete) {
                            drag = CGSize(width: travel > 0 ? max(travel, NibMetrics.studyCardSize.width) : min(travel, -NibMetrics.studyCardSize.width), height: value.predictedEndTranslation.height)
                        } completion: {
                            if model.current?.id == card.id { model.grade(travel > 0 ? .good : .again) }
                            swiping = false
                            var transaction = Transaction(); transaction.disablesAnimations = true
                            withTransaction(transaction) { drag = .zero }
                        }
                    }
                } else if !smartLearn { model.action(travel < 0 ? "next" : "previous", instant: true) }
            }
            if !(smartLearn && model.flipped && !model.readOnly && !reduceMotion && abs(travel) > NibMetrics.studyCardSize.width / 4) {
                withAnimation(NibMotion.slot.animation) { drag = .zero }
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.flipped ? String(localized: "Answer side") : String(localized: "Question side"))
        .accessibilityAction(named: String(localized: "Flip Card")) { model.action("flip", instant: true) }
        .accessibilityAction(named: String(localized: "Previous Card")) { if !smartLearn { model.action("previous", instant: true) } }
        .accessibilityAction(named: String(localized: "Next Card")) { if !smartLearn { model.action("next", instant: true) } }
        .accessibilityAction(named: String(localized: "Still Learning")) { if smartLearn { model.grade(.again) } }
        .accessibilityAction(named: String(localized: "Knew It")) { if smartLearn { model.grade(.good) } }
    }

    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NibSpacing.l) { previous; flip; next }
            VStack(spacing: NibSpacing.s) { flip; HStack { previous; next } }
        }
    }
    private var previous: some View {
        NibButton(String(localized: "Previous Card"), symbol: .back,
                  shortcut: KeyboardShortcut(.leftArrow, modifiers: [])) { model.action("previous", instant: true) }
            .disabled(model.busy || model.index == 0)
    }
    private var next: some View {
        NibButton(String(localized: "Next Card"), symbol: .forward,
                  shortcut: KeyboardShortcut(.rightArrow, modifiers: [])) { model.action("next", instant: true) }
            .disabled(model.busy || model.index + 1 >= model.queue.count)
    }
    private var flip: some View {
        NibButton(String(localized: "Flip Card"), kind: .plain,
                  shortcut: KeyboardShortcut(.space, modifiers: [])) { model.action("flip", instant: true) }.disabled(model.busy)
    }

    private var grading: some View {
        VStack(spacing: NibSpacing.s) {
            flip
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.l) { ForEach(StudyRating.allCases, id: \.self) { gradeButton($0) } }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NibSpacing.l) {
                    ForEach(StudyRating.allCases, id: \.self) { gradeButton($0) }
                }
            }
            Text(String(localized: "Still Learning: Again or Hard. Knew It: Good or Easy."))
                .font(NibFont.footnote).foregroundStyle(NibColor.labelSecondary)
            if model.readOnly { Text(String(localized: "This study set is read-only.")) }
        }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.m) { speech; language; scratch }
                VStack(alignment: .leading, spacing: NibSpacing.s) { speech; language; scratch }
            }
            DisclosureGroup(String(localized: "Appearance and reminders")) {
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
                            NibButton(String(localized: "Keep Progress"), kind: .plain) { resetConfirmed = false }
                        }
                    } else {
                        NibButton(String(localized: "Reset Progress"), kind: .destructivePlain) { resetConfirmed = true }
                    }
                }.padding(.top, NibSpacing.l).disabled(model.readOnly || model.busy)
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
            ForEach(Array(Set([model.language, "en-GB", "en-US", "th-TH", "de-DE", "fr-FR", "es-ES", "ja-JP", "zh-CN"])).sorted(), id: \.self) { code in
                Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
            }
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget).disabled(model.busy)
    }
    private var scratch: some View {
        NibButton(String(localized: "Open Scratchpad"), symbol: .quickNote, kind: .plain) {
            model.action("scratch")
        }.disabled(model.busy || model.app.ui.panels.get("studyeditor.scratch") == nil)
    }
    private func paperPicker(card: Bool) -> some View {
        Picker(card ? String(localized: "Card colour") : String(localized: "Background colour"), selection: Binding(get: {
            card ? model.theme.card : model.theme.background ?? "desk"
        }, set: { colour in
            model.send(CommandIDs.studySetTheme, ["doc": .string(model.docRef), card ? "card" : "background": .string(colour)])
        })) {
            if !card { Text(String(localized: "Desk")).tag("desk") }
            let selected = card ? model.theme.card : model.theme.background ?? "desk"
            if NibPaper(rawValue: selected) == nil && selected != "desk" {
                Text(String(localized: "Custom colour")).tag(selected)
            }
            ForEach(NibPaper.allCases, id: \.self) { paper in Text(paper.name).tag(paper.rawValue) }
        }.pickerStyle(.menu).frame(minHeight: NibMetrics.hitTarget)
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
