import SwiftUI
import UIKit
import Combine
import PencilKit
import NibContracts
import NibDesign

/// The glyph of a session kind (NibDesign v2 `.timer` / `.stopwatch`).
enum TimeKeeperGlyph {
    static func of(_ kind: TimerKind) -> NibSymbol { kind == .timer ? NibSymbol.timer : NibSymbol.stopwatch }
}

/// Keyboard equivalents of the shell's key commands (FeatTimeKeeperFeature), shown as `KeyHint`s on the controls.
enum TimeKeeperKeys {
    static let pause = KeyboardShortcut("k", modifiers: [.command, .shift])
    static let lap = KeyboardShortcut("k", modifiers: [.command, .option])
}

/// A countdown's progress: NibProgressBar, `critical` (destructive) for the last five seconds.
struct TimeKeeperProgress: View {
    let value: Double
    let critical: Bool

    var body: some View {
        NibProgressBar(value: value, style: critical ? .critical : .standard)
            .animation(NibMotion.colorChange, value: critical)
            .accessibilityHidden(true)              // the clock beside it carries the value
    }
}

// MARK: - Panel

/// The Time Keeper panel (a floating Deep panel from the document chrome; a sheet in compact windows). Idle: Timer or
/// Stopwatch, the duration typed or handwritten, presets, your saved modes and a name. Running: the clock, controls
/// and laps. Always: the session history.
struct TimeKeeperPanel: View {
    @ObservedObject var keeper: TimeKeeper
    let context: PanelContext

    enum Reading: Equatable {
        case idle, reading, recognised(String), failed, unavailable
    }

    @State private var kind: TimerKind = .timer
    @State private var durationText = ""
    @State private var name = ""
    @State private var modeName = ""
    @State private var writing = false
    @State private var padHasInk = false
    @State private var padClear = 0
    @State private var reading: Reading = .idle
    /// Bumped by every read, so an older recognition that finishes late never overwrites a newer one.
    @State private var readGeneration = 0
    @State private var pendingDelete: TimerPreset?

    private var seconds: Int? { DurationParser.seconds(from: durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NibPanelHeader(title: String(localized: "Time Keeper"), symbol: NibSymbol.timer) { context.dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: NibSpacing.xl) {
                    if keeper.engine.isActive {
                        TimeKeeperRunningSection(keeper: keeper, barAvailable: keeper.showsBar(in: context.session),
                                                 run: { command, params in run(command, params) })
                    } else {
                        setup
                    }
                    // A value, compared before its body is built: the clock above ticks every second, the history
                    // changes only when a session ends.
                    TimeKeeperHistorySection(records: keeper.history).equatable()
                }
                .padding(NibSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            keeper.panelOpen = true
            keeper.refreshStored()
        }
        .onDisappear { keeper.panelOpen = false }
        .onChange(of: name) { _, value in
            let clean = TimeKeeperPanel.oneLine(value, limit: 60)
            if clean != value { name = clean }
        }
        .onChange(of: modeName) { _, value in
            let clean = TimeKeeperPanel.oneLine(value, limit: 40)
            if clean != value { modeName = clean }
        }
        .confirmationDialog(String(localized: "Delete this mode?"), isPresented: deleteIsPresented,
                            titleVisibility: .visible, presenting: pendingDelete) { mode in
            Button(String(localized: "Delete Mode"), role: .destructive) {
                run("timer.deleteMode", ["name": .string(mode.name)])
            }
        } message: { mode in
            Text(String(localized: "\(mode.name) will be removed from your modes on every device."))
        }
    }

    /// Names are one line (the fields grow vertically, so Return would otherwise add a line break).
    static func oneLine(_ text: String, limit: Int) -> String {
        String(text.map { $0.isNewline ? " " : $0 }.prefix(limit))
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func run(_ command: String, _ params: JSONValue = [:]) {
        keeper.perform(command, params, session: context.session)
    }

    // MARK: Setup

    @ViewBuilder private var setup: some View {
        NibSegmentedControl(selection: $kind, options: TimerKind.allCases) { $0.title }
            .accessibilityLabel(String(localized: "Timer or stopwatch"))
        if kind == .timer {
            durationSection
            presetsSection
            modesSection
            NibInspectorSection(String(localized: "Name")) {
                NibField(text: $name, prompt: String(localized: "Optional, such as Essay plan"))
                    .accessibilityLabel(String(localized: "Timer name"))
            }
            NibButton(String(localized: "Start Timer"), symbol: .play, kind: .primary, expands: true) { startTimer() }
                .disabled(seconds == nil)
        } else {
            Text(String(localized: "Counts up from zero. Record laps while it runs."))
                .font(NibFont.callout)
                .foregroundStyle(NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NibButton(String(localized: "Start Stopwatch"), symbol: .play, kind: .primary, expands: true) {
                run("stopwatch.start")
                dismissIfBarShows()
            }
        }
    }

    private var durationSection: some View {
        NibInspectorSection(String(localized: "Duration"), value: seconds.map { TimerFormat.clock(Double($0)) }) {
            HStack(alignment: .top, spacing: NibSpacing.s) {
                if writing {
                    handwritingPad
                } else {
                    NibField(text: $durationText, prompt: String(localized: "25, 1:30 or 1h 15m"))
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel(String(localized: "Duration"))
                }
                NibIconButton(writing ? NibSymbol.keyboard : NibSymbol.pen,
                              label: writing ? String(localized: "Type the Duration") : String(localized: "Write the Duration"),
                              size: .panel) {
                    writing.toggle()
                    reading = .idle
                    readGeneration += 1
                }
            }
            Text(durationHint)
                .font(NibFont.footnote)
                .foregroundStyle(reading == .failed || reading == .unavailable ? NibColor.warning : NibColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var durationHint: String {
        switch reading {
        case .reading:
            return String(localized: "Reading your handwriting…")
        case .failed:
            return String(localized: "Couldn't read a duration. Write it again, such as 25 or 1:30.")
        case .unavailable:
            return String(localized: "Handwriting recognition isn't available. Type the duration instead.")
        case .recognised(let text):
            return String(localized: "Read as \(text)")
        case .idle:
            if durationText.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Minutes by default. Use 1:30 for minutes and seconds.")
            }
            return seconds.map { TimerFormat.spoken(Double($0)) }
                ?? String(localized: "Use a duration such as 25, 1:30 or 1h 15m, up to 24 hours.")
        }
    }

    /// A small writing area: PencilKit captures the ink, the recogniser (the service behind `recognize.items`) reads it.
    private var handwritingPad: some View {
        let shape = RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)
        return ZStack {
            DurationPad(clearToken: padClear, onInk: { padHasInk = $0 }, onStrokes: { recognise($0) })
            if !padHasInk {
                Text(String(localized: "Write a duration"))
                    .font(NibFont.callout)
                    .foregroundStyle(NibColor.labelTertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 2 * NibMetrics.hitTarget + NibSpacing.s)
        .background(NibColor.fill4, in: shape)
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            if padHasInk {
                NibIconButton(.xmark, label: String(localized: "Clear Handwriting"), size: .panel) {
                    padClear += 1
                    padHasInk = false
                    reading = .idle
                    readGeneration += 1
                    durationText = ""
                }
            }
        }
    }

    private func recognise(_ strokes: [PKStroke]) {
        readGeneration += 1
        let generation = readGeneration
        guard let recognizer = context.app.services.recognizer else {
            reading = .unavailable
            return
        }
        let style = InkStyle(tool: .pen, pen: .ball, width: 2)
        let items = strokes.map { Item.makeStroke(PKBridge.stroke(from: $0, style: style)) }
        let language = context.app.settings.get(NibSettings.defaultLanguage)
        reading = .reading
        Task { @MainActor in
            let lines = try? await recognizer.recognize(strokes: items, language: language)
            guard generation == readGeneration else { return }
            if let best = TimerRecognition.bestDuration(lines ?? []) {
                durationText = best.text
                reading = .recognised(best.text)
            } else {
                reading = .failed
            }
        }
    }

    private var presetsSection: some View {
        NibInspectorSection(String(localized: "Presets")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: NibSpacing.x6 + NibSpacing.s), spacing: NibSpacing.s)],
                      alignment: .leading, spacing: NibSpacing.s) {
                ForEach(TimerPreset.builtIn, id: \.self) { s in
                    NibChip(TimerFormat.short(s), style: .filter(isSelected: seconds == s), action: {
                        durationText = TimerFormat.clock(Double(s))
                        writing = false
                        reading = .idle
                    })
                    .accessibilityAddTraits(seconds == s ? .isSelected : [])
                }
            }
        }
    }

    private var modesSection: some View {
        NibInspectorSection(String(localized: "Your Modes")) {
            if keeper.modes.isEmpty {
                Text(String(localized: "Save a duration you use often, such as a 50-minute study block."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(keeper.modes) { mode in
                HStack(spacing: NibSpacing.s) {
                    Button {
                        durationText = TimerFormat.clock(Double(mode.seconds))
                        name = mode.name
                        writing = false
                        reading = .idle
                    } label: {
                        NibInspectorRow(mode.name, subtitle: TimerFormat.short(mode.seconds), symbol: NibSymbol.timer)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                    .accessibilityHint(String(localized: "Fills in this duration and name"))
                    NibIconButton(.trash, label: String(localized: "Delete \(mode.name)"), size: .panel) {
                        pendingDelete = mode
                    }
                }
            }
            HStack(spacing: NibSpacing.s) {
                NibField(text: $modeName, prompt: String(localized: "Mode name"))
                    .accessibilityLabel(String(localized: "New mode name"))
                NibButton(String(localized: "Save Mode"), size: .compact) { saveMode() }
                    .disabled(seconds == nil || modeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func startTimer() {
        guard let s = seconds else { return }
        var params: [String: JSONValue] = ["seconds": .number(Double(s))]
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { params["label"] = .string(label) }
        run("timer.start", .object(params))
        let k = keeper
        k.notifier.requestAuthorizationIfNeeded { k.rescheduleNotification() }
        dismissIfBarShows()
    }

    /// On a canvas the bar takes over from the panel; other documents keep the panel as the running view.
    private func dismissIfBarShows() {
        if keeper.showsBar(in: context.session) { context.dismiss() }
    }

    private func saveMode() {
        guard let s = seconds else { return }
        let mode = modeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mode.isEmpty else { return }
        run("timer.saveMode", ["name": .string(mode), "seconds": .number(Double(s))])
        modeName = ""
    }
}

/// The session history: the five newest, or all of them after "Show All" (built lazily, as the list is never pruned).
/// It takes the records as a value and does not observe the Time Keeper, and is used `.equatable()`: the panel's
/// once-a-second clock never rebuilds it.
struct TimeKeeperHistorySection: View, Equatable {
    static let collapsedCount = 5

    let records: [TimerRecord]
    @State private var showsAll = false
    @State private var expanded: Set<String> = []

    static func == (a: TimeKeeperHistorySection, b: TimeKeeperHistorySection) -> Bool { a.records == b.records }

    var body: some View {
        NibInspectorSection(String(localized: "History"), action: toggleAction) {
            if records.isEmpty {
                Text(String(localized: "Finished timers and stopwatches appear here."))
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            LazyVStack(alignment: .leading, spacing: NibSpacing.s) {
                ForEach(showsAll ? records : Array(records.prefix(Self.collapsedCount))) { record in
                    TimeKeeperHistoryRow(record: record, expanded: expanded.contains(record.id)) {
                        if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
                    }
                }
            }
        }
    }

    private var toggleAction: NibAction? {
        guard records.count > Self.collapsedCount else { return nil }
        return NibAction(showsAll ? String(localized: "Show Less") : String(localized: "Show All")) { showsAll.toggle() }
    }
}

/// The running session inside the panel: the clock, its progress, the controls and the laps.
struct TimeKeeperRunningSection: View {
    @ObservedObject var keeper: TimeKeeper
    /// The window shows a canvas, so the session has a bar to hide or show.
    let barAvailable: Bool
    let run: (String, JSONValue) -> Void
    /// Discarding throws away the run and its laps, so it asks first.
    @State private var confirmsDiscard = false

    var body: some View {
        let e = keeper.engine
        let t = keeper.now
        let critical = e.isFinalCountdown(at: t)
        VStack(alignment: .leading, spacing: NibSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: NibSpacing.s) {
                Label {
                    Text(e.label ?? e.kind.title)
                } icon: {
                    Image(nib: TimeKeeperGlyph.of(e.kind))
                }
                .font(NibFont.headline)
                .foregroundStyle(NibColor.label)
                .lineLimit(2)
                Spacer(minLength: NibSpacing.s)
                Text(e.state.title)
                    .font(NibFont.footnote)
                    .foregroundStyle(NibColor.labelSecondary)
            }
            Text(e.state == .finished ? String(localized: "Time's up") : TimerFormat.display(e, at: t))
                .font(NibFont.hudLarge)
                .foregroundStyle(critical ? NibColor.destructive : NibColor.label)
                .accessibilityLabel(TimerFormat.spokenDisplay(e, at: t))
                .accessibilityAddTraits(.updatesFrequently)
            if e.kind == .timer {
                TimeKeeperProgress(value: e.progress(at: t), critical: critical)
            }
            controls(e)
            if !e.laps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(e.laps.reversed(), id: \.index) { lap in TimeKeeperLapRow(lap: lap) }
                }
            }
        }
        .confirmationDialog(String(localized: "Discard this session?"), isPresented: $confirmsDiscard,
                            titleVisibility: .visible) {
            Button(String(localized: "Discard Session"), role: .destructive) {
                run("timer.control", ["action": "discard"])
            }
        } message: {
            Text(String(localized: "It won't be saved to your history."))
        }
    }

    @ViewBuilder private func controls(_ e: TimerEngine) -> some View {
        if e.state == .finished {
            // Side by side when they fit, stacked at large text sizes: labels never truncate.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.s) { finishedButtons(e) }
                VStack(spacing: NibSpacing.s) { finishedButtons(e) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NibSpacing.s) { runningButtons(e) }
                VStack(spacing: NibSpacing.s) { runningButtons(e) }
            }
            HStack(spacing: NibSpacing.s) {
                if barAvailable {
                    NibButton(keeper.barVisible ? String(localized: "Hide Bar") : String(localized: "Show Bar"),
                              symbol: keeper.barVisible ? NibSymbol.eyeSlash : NibSymbol.eye, kind: .plain) {
                        run("timer.control", ["action": keeper.barVisible ? "hide" : "show"])
                    }
                }
                Spacer(minLength: 0)
                NibButton(String(localized: "Discard Session"), kind: .destructive, size: .compact) {
                    confirmsDiscard = true
                }
            }
        }
    }

    @ViewBuilder private func finishedButtons(_ e: TimerEngine) -> some View {
        NibButton(String(localized: "Start Again"), symbol: .retry, expands: true) {
            var params: [String: JSONValue] = ["seconds": .number(Double(e.seconds))]
            if let label = e.label { params["label"] = .string(label) }
            run("timer.start", .object(params))
        }
        NibButton(String(localized: "Done"), symbol: .checkmark, expands: true) {
            run("timer.control", ["action": "stop"])
        }
    }

    @ViewBuilder private func runningButtons(_ e: TimerEngine) -> some View {
        NibButton(e.state == .running ? String(localized: "Pause") : String(localized: "Resume"),
                  symbol: e.state == .running ? NibSymbol.pause : NibSymbol.play, expands: true,
                  shortcut: TimeKeeperKeys.pause) {
            run("timer.control", ["action": "togglePause"])
        }
        if e.kind == .stopwatch && e.state == .running {
            NibButton(String(localized: "Lap"), symbol: NibSymbol.lap, expands: true, shortcut: TimeKeeperKeys.lap) {
                run("stopwatch.lap", [:])
            }
        }
        NibButton(String(localized: "Stop and Save"), symbol: .stop, expands: true) {
            run("timer.control", ["action": "stop"])
        }
    }
}

struct TimeKeeperLapRow: View {
    let lap: TimerLap

    var body: some View {
        HStack(spacing: NibSpacing.m) {
            Text(String(localized: "Lap \(lap.index)"))
                .font(NibFont.body)
                .foregroundStyle(NibColor.label)
            Spacer(minLength: NibSpacing.s)
            Text("+" + TimerFormat.lap(lap.split))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.labelSecondary)
            Text(TimerFormat.lap(lap.total))
                .font(NibFont.hud)
                .foregroundStyle(NibColor.label)
        }
        .frame(minHeight: NibMetrics.hitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Lap \(lap.index), \(TimerFormat.spoken(lap.split)), total \(TimerFormat.spoken(lap.total))"))
    }
}

struct TimeKeeperHistoryRow: View {
    let record: TimerRecord
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if record.laps.isEmpty {
                row
            } else {
                Button(action: toggle) { row.contentShape(Rectangle()) }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.field, style: .continuous)))
                    .accessibilityHint(expanded ? String(localized: "Hides the laps") : String(localized: "Shows the laps"))
                if expanded {
                    ForEach(record.laps, id: \.index) { lap in TimeKeeperLapRow(lap: lap) }
                }
            }
        }
    }

    private var row: some View {
        NibInspectorRow(record.label ?? record.kind.title, subtitle: subtitle, symbol: TimeKeeperGlyph.of(record.kind)) {
            if record.completed {
                Image(nib: .checkCircleFill)
                    .font(NibFont.body)
                    .foregroundStyle(NibColor.success)
                    .accessibilityLabel(String(localized: "Completed"))
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let title = record.docTitle, !title.isEmpty { parts.append(title) }
        if let duration = record.duration, !record.completed {
            parts.append(String(localized: "\(TimerFormat.clock(record.elapsed)) of \(TimerFormat.clock(duration))"))
        } else {
            parts.append(TimerFormat.clock(record.elapsed))
        }
        if !record.laps.isEmpty { parts.append(TimerFormat.laps(record.laps.count)) }
        parts.append(Date(timeIntervalSince1970: record.startedAt).formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Handwriting pad

/// PencilKit writing area for the duration. Pencil or finger; the strokes are handed over 0.7 s after the last one.
struct DurationPad: UIViewRepresentable {
    let clearToken: Int
    let onInk: (Bool) -> Void
    let onStrokes: ([PKStroke]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.monoline, color: NibUIColor.label, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        canvas.accessibilityLabel = String(localized: "Handwriting area")
        canvas.accessibilityHint = String(localized: "Write a duration such as 25 or 1:30")
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onInk = onInk
        coordinator.onStrokes = onStrokes
        if coordinator.clearToken != clearToken {
            coordinator.clearToken = clearToken
            coordinator.isClearing = true
            canvas.drawing = PKDrawing()
            coordinator.isClearing = false
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onInk: (Bool) -> Void = { _ in }
        var onStrokes: ([PKStroke]) -> Void = { _ in }
        var clearToken = 0
        var isClearing = false
        private var pending: Task<Void, Never>?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            pending?.cancel()
            guard !isClearing else { return }
            let strokes = canvasView.drawing.strokes
            onInk(!strokes.isEmpty)
            guard !strokes.isEmpty else { return }
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                self?.onStrokes(strokes)
            }
        }
    }
}

// MARK: - Bar

final class TimeKeeperBarPresentation: ObservableObject {
    /// The Pencil is down on the canvas (DESIGN.md §10.8).
    @Published var receded = false
}

/// The running session as a Clear 40 pt HUD capsule: pause or resume, the clock and name over the progress bar,
/// Lap (stopwatch), Stop and Save, Hide. Tapping the clock opens the panel with the laps and history.
struct TimeKeeperBar: View {
    static let width: CGFloat = NibMetrics.panelWidth
    /// The 40 pt HUD plus room for the 44 pt hit targets.
    static let height: CGFloat = NibMetrics.hitTarget + NibSpacing.xs

    @ObservedObject var keeper: TimeKeeper
    @ObservedObject var presentation: TimeKeeperBarPresentation

    var body: some View {
        let e = keeper.engine
        let t = keeper.now
        HStack(spacing: NibSpacing.xxs) {
            if e.state == .finished {
                NibIconButton(.retry, label: String(localized: "Start Again")) {
                    var params: [String: JSONValue] = ["seconds": .number(Double(e.seconds))]
                    if let label = e.label { params["label"] = .string(label) }
                    keeper.perform("timer.start", .object(params))
                }
            } else {
                NibIconButton(e.state == .running ? NibSymbol.pause : NibSymbol.play,
                              label: e.state == .running ? String(localized: "Pause") : String(localized: "Resume"),
                              shortcut: TimeKeeperKeys.pause) {
                    keeper.perform("timer.control", ["action": "togglePause"])
                }
            }
            summary(e, at: t)
            if e.kind == .stopwatch && e.state == .running {
                NibIconButton(NibSymbol.lap, label: String(localized: "Record Lap"), shortcut: TimeKeeperKeys.lap) {
                    keeper.perform("stopwatch.lap")
                }
            }
            NibIconButton(e.state == .finished ? NibSymbol.checkmark : NibSymbol.stop,
                          label: e.state == .finished ? String(localized: "Done") : String(localized: "Stop and Save")) {
                keeper.perform("timer.control", ["action": "stop"])
            }
            NibIconButton(.chevronDown, label: String(localized: "Hide Time Keeper")) {
                keeper.perform("timer.control", ["action": "hide"])
            }
        }
        .padding(.horizontal, NibSpacing.xs)
        .frame(height: NibMetrics.hudHeight)
        .background { material }
        .nibChromeTypeCap()
        .opacity(presentation.receded ? NibLiquid.recedeOpacity : 1)
        .animation(presentation.receded ? NibMotion.recede : NibMotion.enter, value: presentation.receded)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Time Keeper"))
    }

    /// Clear water at rest. While the Pencil is down nothing samples the backdrop (DESIGN.md §10.8): the bar is the
    /// plain Clear body, as the droplet container draws frozen droplets (at 22 % the swap does not show).
    @ViewBuilder private var material: some View {
        if presentation.receded {
            NibDropletShape().fill(NibColor.clearBody)
        } else {
            Color.clear.nibGlass(.clear)
        }
    }

    private func summary(_ e: TimerEngine, at t: Date) -> some View {
        let spoken = TimerFormat.spokenDisplay(e, at: t)
        return Button(action: openPanel) {
            VStack(alignment: .leading, spacing: NibSpacing.xs) {
                HStack(spacing: NibSpacing.s) {
                    Text(e.state == .finished ? String(localized: "Time's up") : TimerFormat.display(e, at: t))
                        .font(NibFont.hud)
                        .foregroundStyle(NibColor.label)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let label = e.label {
                        // HUD type on Clear (DESIGN.md §2.4), as NibHUD sets its secondary part.
                        Text(label)
                            .font(NibFont.hud)
                            .foregroundStyle(NibColor.label)
                            .lineLimit(1)
                    }
                }
                if e.kind == .timer {
                    TimeKeeperProgress(value: e.progress(at: t), critical: e.isFinalCountdown(at: t))
                }
            }
            .frame(maxWidth: .infinity, minHeight: NibMetrics.hitTarget, alignment: .leading)
            .padding(.horizontal, NibSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(NibPressStyle(shape: Capsule()))
        .accessibilityLabel(e.label.map { "\($0), \(spoken)" } ?? spoken)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityHint(String(localized: "Opens Time Keeper"))
    }

    private func openPanel() {
        keeper.perform("timer.control", ["action": "open"])
    }
}

/// Puts the bar over every canvas (a canvas attachment cannot reach the chrome's droplet container, so the bar is a
/// lone `nibGlass` HUD in the canvas's superview). It slides in from the bottom edge when a session starts or is
/// shown and slides back when hidden (a cross-fade under Reduce Motion, nothing when the keyboard asked or when a
/// document opens with a session already running), sits above the iPhone palette, and recedes to 22 % while the
/// Pencil is down.
@MainActor
final class TimeKeeperBarAttachment: CanvasAttachment {
    private let keeper: TimeKeeper
    private let presentation = TimeKeeperBarPresentation()
    private weak var host: CanvasHost?
    private var hosting: UIHostingController<TimeKeeperBar>?
    private var cancellables: Set<AnyCancellable> = []
    private var wantsBar = false
    /// False until the first state arrives: a bar that is already up when the canvas opens appears in place.
    private var hasState = false
    private var restore: Task<Void, Never>?

    init(keeper: TimeKeeper) {
        self.keeper = keeper
    }

    func attach(to host: CanvasHost) {
        self.host = host
        keeper.$engine.map { $0.isActive }.removeDuplicates()
            .combineLatest(keeper.$barVisible.removeDuplicates())
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setWanted(on) }
            .store(in: &cancellables)
    }

    func detach(from host: CanvasHost) {
        cancellables.removeAll()
        restore?.cancel()
        if let h = hosting {
            h.willMove(toParent: nil)
            h.view.removeFromSuperview()
            h.removeFromParent()
        }
        hosting = nil
        self.host = nil
    }

    func canvasDidChange(_ host: CanvasHost) {
        // The canvas may not have been in a view hierarchy when the state first arrived.
        if wantsBar, hosting?.view.superview == nil {
            slideIn(animated: false)
        } else {
            layout()
        }
    }

    /// Asked for every touch that starts on the canvas; the bar never takes it, but steps back while it writes.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool {
        if wantsBar { recede() }
        return false
    }

    private func setWanted(_ on: Bool) {
        let animated = hasState && !keeper.instantVisibility
        hasState = true
        wantsBar = on
        if on { slideIn(animated: animated) } else { slideOut(animated: animated) }
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled || NibMotion.forcesReduced }

    private func slideIn(animated: Bool) {
        guard let view = ensureHosting() else { return }
        layout()
        presentation.receded = false
        let wasHidden = view.isHidden
        view.isHidden = false
        guard animated else {
            view.alpha = 1
            view.transform = .identity
            return
        }
        if wasHidden {
            if reduceMotion { view.alpha = 0 } else { view.transform = offscreen(view) }
        }
        NibMotion.animateUIKit(NibMotion.sheet) {
            view.alpha = 1
            view.transform = .identity
        }
    }

    private func slideOut(animated: Bool) {
        guard let view = hosting?.view, !view.isHidden else { return }
        guard animated else {
            view.isHidden = true
            view.alpha = 1
            view.transform = .identity
            return
        }
        let fade = reduceMotion
        let target = offscreen(view)
        NibMotion.animateUIKit(NibMotion.retract, animations: {
            if fade { view.alpha = 0 } else { view.transform = target }
        }, completion: { [weak self] _ in
            guard let self, !self.wantsBar else { return }
            view.isHidden = true
            view.alpha = 1
            view.transform = .identity
        })
    }

    /// Below the bottom edge of the container.
    private func offscreen(_ view: UIView) -> CGAffineTransform {
        let bottom = view.superview?.bounds.maxY ?? view.center.y
        return CGAffineTransform(translationX: 0, y: max(bottom - view.center.y + view.bounds.height, view.bounds.height))
    }

    private func recede() {
        presentation.receded = true
        restore?.cancel()
        restore = Task { @MainActor [weak self] in
            // Until the Pencil lifts (NibHaptics.isInking is the droplet container's flag), then 450 ms (DESIGN.md §10.8).
            repeat {
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while NibHaptics.isInking && !Task.isCancelled
            try? await Task.sleep(nanoseconds: UInt64(NibMotion.recedeDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.presentation.receded = false
        }
    }

    private func ensureHosting() -> UIView? {
        guard let host, let container = host.canvasView.superview else { return nil }
        let h: UIHostingController<TimeKeeperBar>
        if let existing = hosting {
            h = existing
        } else {
            h = UIHostingController(rootView: TimeKeeperBar(keeper: keeper, presentation: presentation))
            h.view.backgroundColor = .clear
            h.safeAreaRegions = []
            h.view.isHidden = true
            hosting = h
        }
        if h.view.superview !== container {
            h.willMove(toParent: nil)
            h.view.removeFromSuperview()
            h.removeFromParent()
            if let parent = Self.viewController(of: container) {
                parent.addChild(h)
                container.addSubview(h.view)
                h.didMove(toParent: parent)
            } else {
                container.addSubview(h.view)
            }
        }
        return h.view
    }

    /// Bottom centre of the canvas, 16 pt above the safe area (above the palette on iPhone). Set through bounds and
    /// centre so a slide in progress keeps its transform.
    private func layout() {
        guard let host, let view = hosting?.view, let container = view.superview else { return }
        let canvas = host.canvasView
        let area = container.convert(canvas.bounds, from: canvas)
        let compact = area.width < NibMetrics.compactBreakpoint
        let width = max(0, min(TimeKeeperBar.width, area.width - 2 * NibMetrics.chromeInset))
        let bottom = canvas.safeAreaInsets.bottom + (compact ? NibMetrics.canvasBottomInsetCompact : NibMetrics.chromeInset)
        let size = CGSize(width: width, height: TimeKeeperBar.height)
        let centre = CGPoint(x: area.midX, y: area.maxY - bottom - size.height / 2)
        if view.bounds.size != size { view.bounds = CGRect(origin: .zero, size: size) }
        if view.center != centre { view.center = centre }
    }

    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
