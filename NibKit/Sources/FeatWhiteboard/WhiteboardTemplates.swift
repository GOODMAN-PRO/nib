import SwiftUI
import Combine
import NibContracts
import NibDesign

// MARK: - Built-in whiteboard frameworks (D-031, S-087)

/// The eight built-in frameworks. Each is a clipboard-format fragment (`BoardTemplateDescriptor.spec.fragment`), so
/// `board.insertTemplate` places it in one transaction with every item written once, at an exact centre. Plugins and
/// content packs add their own descriptors (fragments or `diagram.create` specs) to the same registry.
enum WhiteboardTemplates {
    static let brainstorm = "whiteboard.brainstorm"
    static let kanban = "whiteboard.kanban"
    static let swot = "whiteboard.swot"
    static let retro = "whiteboard.retro"
    static let mindMap = "whiteboard.mindMap"
    static let timeline = "whiteboard.timeline"
    static let meeting = "whiteboard.meeting"
    static let flowchart = "whiteboard.flowchart"

    struct Built {
        let id: String
        let title: String
        let icon: String
        let items: [Item]
    }

    @MainActor
    static func register(_ app: NibApp, owner: String) {
        for (index, template) in all().enumerated() {
            app.content.boardTemplates.register(BoardTemplateDescriptor(
                id: template.id, title: template.title, icon: template.icon, order: 100 + index * 10, owner: owner,
                spec: ["fragment": fragment(template.items)]))
        }
    }

    static func all() -> [Built] {
        [
            Built(id: brainstorm, title: String(localized: "Brainstorm"), icon: "lightbulb", items: brainstormItems()),
            Built(id: kanban, title: String(localized: "Kanban"), icon: "rectangle.split.3x1", items: kanbanItems()),
            Built(id: swot, title: String(localized: "SWOT Analysis"), icon: "square.grid.2x2", items: swotItems()),
            Built(id: retro, title: String(localized: "Retrospective"), icon: "arrow.triangle.2.circlepath",
                  items: retroItems()),
            Built(id: mindMap, title: String(localized: "Mind Map"), icon: NibSymbol.connectors.name, items: mindMapItems()),
            Built(id: timeline, title: String(localized: "Timeline"), icon: "calendar.day.timeline.left",
                  items: timelineItems()),
            Built(id: meeting, title: String(localized: "Meeting Notes"), icon: "person.3", items: meetingItems()),
            Built(id: flowchart, title: String(localized: "Flowchart"), icon: "arrow.triangle.branch", items: flowchartItems())
        ]
    }

    /// The fragment JSON a template carries (the clipboard format, F014).
    static func fragment(_ items: [Item]) -> JSONValue {
        let bounds = TemplatePlacement.union(items) ?? .zero
        let encoded = (try? JSONValue.from(items)) ?? .array([])
        return ["format": "nib-fragment/1", "items": encoded, "assets": [:],
                "bounds": [.number(bounds.x), .number(bounds.y), .number(bounds.width), .number(bounds.height)]]
    }

    // MARK: Colours (inks and highlighters: template content is page content, so it takes the page palette)

    static let ink = RGBA(NibInk.carbon)
    static let muted = RGBA(NibInk.graphite)
    static let accent = RGBA(NibInk.cobalt)
    static let lemon = RGBA(NibHighlighter.lemon)
    static let apricot = RGBA(NibHighlighter.apricot)
    static let mint = RGBA(NibHighlighter.mint)
    static let sky = RGBA(NibHighlighter.sky)
    static let lilac = RGBA(NibHighlighter.lilac)
    static let blush = RGBA(NibHighlighter.blush)
    static let lane = RGBA(NibInk.graphite, alpha: 0.08)

    // MARK: Frameworks (page points; placement re-centres them)

    static func brainstormItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "Brainstorm"), Rect(x: 0, y: 0, width: 600, height: 44), size: 30, bold: true)
        b.box(.roundedRectangle, Rect(x: 0, y: 64, width: 864, height: 88), text: String(localized: "What are we trying to solve?"),
              size: 20, fill: nil, stroke: muted, radius: 16)
        let colours = [lemon, mint, sky, blush, apricot, lilac, lemon, mint]
        for row in 0..<2 {
            for column in 0..<4 {
                b.sticky(Rect(x: Double(column) * 224, y: 184 + Double(row) * 224, width: 192, height: 192),
                         colours[row * 4 + column], String(localized: "Idea"))
            }
        }
        return b.items
    }

    static func kanbanItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "Kanban"), Rect(x: 0, y: 0, width: 600, height: 44), size: 30, bold: true)
        let columns: [(String, RGBA, Int, String)] = [
            (String(localized: "To do"), lemon, 3, String(localized: "Task")),
            (String(localized: "In progress"), sky, 2, String(localized: "Task")),
            (String(localized: "Done"), mint, 1, String(localized: "Finished task"))
        ]
        for (i, column) in columns.enumerated() {
            let x = Double(i) * 324
            b.box(.roundedRectangle, Rect(x: x, y: 68, width: 300, height: 620), fill: lane, stroke: nil, radius: 20)
            b.text(column.0, Rect(x: x + 20, y: 88, width: 260, height: 32), size: 20, bold: true)
            for card in 0..<column.2 {
                b.sticky(Rect(x: x + 20, y: 136 + Double(card) * 148, width: 260, height: 132), column.1, column.3)
            }
        }
        return b.items
    }

    static func swotItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "SWOT analysis"), Rect(x: 0, y: 0, width: 700, height: 44), size: 30, bold: true)
        let quadrants: [(String, String, RGBA)] = [
            (String(localized: "Strengths"), String(localized: "What do we do well?"), mint),
            (String(localized: "Weaknesses"), String(localized: "Where could we improve?"), blush),
            (String(localized: "Opportunities"), String(localized: "What could we make the most of?"), sky),
            (String(localized: "Threats"), String(localized: "What could get in our way?"), apricot)
        ]
        for (i, q) in quadrants.enumerated() {
            let x = Double(i % 2) * 454, y = 68 + Double(i / 2) * 324
            b.box(.roundedRectangle, Rect(x: x, y: y, width: 430, height: 300), fill: q.2.withAlpha(0.35), stroke: nil,
                  radius: 20)
            b.text(q.0, Rect(x: x + 24, y: y + 20, width: 380, height: 32), size: 22, bold: true)
            b.text(q.1, Rect(x: x + 24, y: y + 56, width: 380, height: 24), size: 15, color: muted)
        }
        return b.items
    }

    static func retroItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "Retrospective"), Rect(x: 0, y: 0, width: 700, height: 44), size: 30, bold: true)
        let columns: [(String, String, RGBA)] = [
            (String(localized: "Went well"), String(localized: "Keep doing"), mint),
            (String(localized: "To improve"), String(localized: "Change next time"), blush),
            (String(localized: "Actions"), String(localized: "Owner and date"), sky)
        ]
        for (i, column) in columns.enumerated() {
            let x = Double(i) * 324
            b.box(.roundedRectangle, Rect(x: x, y: 68, width: 300, height: 540), fill: column.2.withAlpha(0.3), stroke: nil,
                  radius: 20)
            b.text(column.0, Rect(x: x + 20, y: 88, width: 260, height: 32), size: 20, bold: true)
            b.text(column.1, Rect(x: x + 20, y: 122, width: 260, height: 24), size: 15, color: muted)
            for card in 0..<2 {
                b.sticky(Rect(x: x + 20, y: 164 + Double(card) * 156, width: 260, height: 140), column.2, "")
            }
        }
        return b.items
    }

    static func mindMapItems() -> [Item] {
        var b = FrameworkBuilder()
        let centreBox = Rect(x: -130, y: -60, width: 260, height: 120)
        let centre = b.box(.ellipse, centreBox, text: String(localized: "Central idea"), size: 22, bold: true,
                           fill: sky.withAlpha(0.5), stroke: accent, width: 2)
        let fills = [lemon, mint, blush, lilac, apricot, sky]
        for k in 0..<6 {
            let angle = (-90 + Double(k) * 60) * .pi / 180
            let c = Point(400 * cos(angle), 250 * sin(angle))
            let branch = b.box(.roundedRectangle, Rect(x: c.x - 100, y: c.y - 36, width: 200, height: 72),
                               text: String(localized: "Idea \(k + 1)"), size: 17, fill: fills[k].withAlpha(0.6),
                               stroke: nil, radius: 36)
            // The side of each box that faces the other, judged in box proportions.
            let horizontal = abs(c.x) / centreBox.width > abs(c.y) / centreBox.height
            let from = horizontal ? (c.x > 0 ? 1 : 3) : (c.y > 0 ? 2 : 0)
            let to = horizontal ? (c.x > 0 ? 3 : 1) : (c.y > 0 ? 0 : 2)
            b.connect(centre, side: from, branch, side: to, route: .curved, arrow: false)
        }
        return b.items
    }

    static func timelineItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "Timeline"), Rect(x: 0, y: 0, width: 600, height: 44), size: 30, bold: true)
        let axis = 220.0
        b.line(from: Point(0, axis), to: Point(1200, axis), width: 3, arrow: true)
        for i in 0..<5 {
            let x = 120 + Double(i) * 240
            b.box(.ellipse, Rect(x: x - 12, y: axis - 12, width: 24, height: 24), fill: accent, stroke: nil)
            let y = i % 2 == 0 ? axis - 100 : axis + 28
            b.paragraphs([(String(localized: "Milestone \(i + 1)"), 17, true, ink, .plain),
                          (String(localized: "Date"), 15, false, muted, .plain)],
                         Rect(x: x - 100, y: y, width: 200, height: 68), align: .center)
        }
        return b.items
    }

    static func meetingItems() -> [Item] {
        var b = FrameworkBuilder()
        b.text(String(localized: "Meeting notes"), Rect(x: 0, y: 0, width: 700, height: 44), size: 30, bold: true)
        b.box(.roundedRectangle, Rect(x: 0, y: 64, width: 960, height: 56), fill: nil, stroke: muted, radius: 12, width: 1)
        b.text(String(localized: "Date:   ·   Attendees:   ·   Facilitator:"), Rect(x: 16, y: 80, width: 928, height: 24),
               size: 16, color: muted)
        let panels: [(String, [String], ListKind)] = [
            (String(localized: "Agenda"), [String(localized: "Topic"), String(localized: "Topic"), String(localized: "Topic")], .bullet),
            (String(localized: "Notes"), [""], .plain),
            (String(localized: "Action items"), [String(localized: "Task · owner"), String(localized: "Task · owner"),
                                                  String(localized: "Task · owner")], .todo)
        ]
        for (i, panel) in panels.enumerated() {
            let x = Double(i) * 328
            b.box(.roundedRectangle, Rect(x: x, y: 144, width: 304, height: 480), fill: nil, stroke: muted, radius: 20)
            b.text(panel.0, Rect(x: x + 20, y: 164, width: 264, height: 30), size: 20, bold: true)
            b.paragraphs(panel.1.map { ($0, 16.0, false, ink, panel.2) }, Rect(x: x + 20, y: 204, width: 264, height: 400))
        }
        return b.items
    }

    static func flowchartItems() -> [Item] {
        var b = FrameworkBuilder()
        let start = b.box(.roundedRectangle, Rect(x: 340, y: 0, width: 200, height: 64), text: String(localized: "Start"),
                          size: 17, bold: true, fill: mint.withAlpha(0.6), stroke: nil, radius: 32)
        let step = b.box(.rectangle, Rect(x: 320, y: 124, width: 240, height: 80), text: String(localized: "Step"), size: 17,
                         fill: sky.withAlpha(0.45), stroke: nil)
        let decision = b.box(.diamond, Rect(x: 320, y: 264, width: 240, height: 144),
                             text: String(localized: "Decision?"), size: 17, fill: lemon.withAlpha(0.6), stroke: nil)
        let next = b.box(.rectangle, Rect(x: 320, y: 468, width: 240, height: 80), text: String(localized: "Step"), size: 17,
                         fill: sky.withAlpha(0.45), stroke: nil)
        let end = b.box(.roundedRectangle, Rect(x: 340, y: 608, width: 200, height: 64), text: String(localized: "End"),
                        size: 17, bold: true, fill: blush.withAlpha(0.6), stroke: nil, radius: 32)
        let revise = b.box(.rectangle, Rect(x: 680, y: 296, width: 200, height: 80), text: String(localized: "Revise"),
                           size: 17, fill: apricot.withAlpha(0.5), stroke: nil)
        b.connect(start, side: 2, step, side: 0)
        b.connect(step, side: 2, decision, side: 0)
        b.connect(decision, side: 2, next, side: 0, label: String(localized: "Yes"))
        b.connect(next, side: 2, end, side: 0)
        b.connect(decision, side: 1, revise, side: 3, label: String(localized: "No"))
        b.connect(revise, side: 0, step, side: 1, route: .elbow)
        return b.items
    }
}

/// Builds a framework's items with stable local ids ("WB001"…), which placement replaces with fresh or caller ids.
struct FrameworkBuilder {
    private(set) var items: [Item] = []

    private mutating func add(_ item: Item) -> ElementID {
        var it = item
        it.id = NibID(String(format: "WB%03ld", items.count + 1))
        items.append(it)
        return it.id
    }

    private func attrs(_ size: Double, bold: Bool, color: RGBA) -> TextAttributes {
        TextAttributes(size: size, color: color, bold: bold ? true : nil)
    }

    @discardableResult
    mutating func text(_ text: String, _ r: Rect, size: Double, bold: Bool = false,
                       color: RGBA = WhiteboardTemplates.ink) -> ElementID {
        add(.makeText(TextBoxItem(frame: Frame(r), text: RichText(plain: text, attrs: attrs(size, bold: bold, color: color)))))
    }

    /// Several paragraphs in one text box (a bulleted agenda, a to-do list, a title over a date).
    @discardableResult
    mutating func paragraphs(_ lines: [(String, Double, Bool, RGBA, ListKind)], _ r: Rect,
                             align: ParagraphAlignment = .natural) -> ElementID {
        let paragraphs = lines.map { line in
            Paragraph(runs: line.0.isEmpty ? [] : [TextRun(line.0, attrs(line.1, bold: line.2, color: line.3))],
                      align: align, list: line.4)
        }
        return add(.makeText(TextBoxItem(frame: Frame(r), text: RichText(paragraphs: paragraphs))))
    }

    @discardableResult
    mutating func box(_ kind: ShapeKind, _ r: Rect, text: String? = nil, size: Double = 17, bold: Bool = false,
                      fill: RGBA?, stroke: RGBA?, radius: Double = 12, width: Double = 1.5) -> ElementID {
        let style = ShapeItemStyle(strokeColor: stroke, strokeWidth: stroke == nil ? 0 : width, fillColor: fill,
                                   cornerRadius: radius)
        let label = text.map { RichText(plain: $0, attrs: attrs(size, bold: bold, color: WhiteboardTemplates.ink)) }
        return add(.makeShape(ShapeItem(shape: kind, frame: Frame(r), style: style, text: label)))
    }

    @discardableResult
    mutating func sticky(_ r: Rect, _ colour: RGBA, _ text: String) -> ElementID {
        add(.makeSticky(StickyItem(frame: Frame(r), color: colour, text: text.isEmpty ? .empty : RichText(plain: text))))
    }

    @discardableResult
    mutating func line(from a: Point, to b: Point, width: Double, arrow: Bool) -> ElementID {
        let style = ShapeItemStyle(strokeColor: WhiteboardTemplates.muted, strokeWidth: width, arrowEnd: arrow)
        let frame = Frame(Rect.bounding([a, b]) ?? Rect(x: a.x, y: a.y, width: 0, height: 0))
        return add(.makeShape(ShapeItem(shape: .line, frame: frame, points: [a, b], style: style)))
    }

    /// A connector anchored to the middle of a side of each item (0 top, 1 right, 2 bottom, 3 left).
    @discardableResult
    mutating func connect(_ a: ElementID, side sa: Int, _ b: ElementID, side sb: Int, route: ConnectorRoute = .straight,
                          label: String? = nil, arrow: Bool = true) -> ElementID {
        let from = items.first { $0.id == a }?.anchorPoint(side: sa, t: 0.5) ?? .zero
        let to = items.first { $0.id == b }?.anchorPoint(side: sb, t: 0.5) ?? .zero
        let style = ShapeItemStyle(strokeColor: WhiteboardTemplates.muted, strokeWidth: 2, arrowEnd: arrow)
        let connector = ConnectorItem(from: ConnectorEnd(point: from, item: a, side: sa, t: 0.5),
                                      to: ConnectorEnd(point: to, item: b, side: sb, t: 0.5), route: route, style: style,
                                      label: label.map { RichText(plain: $0, attrs: attrs(15, bold: false, color: WhiteboardTemplates.muted)) })
        return add(.makeConnector(connector))
    }
}

// MARK: - Template picker panel

/// "Templates" floating panel of a whiteboard: every registered framework (built-ins, plugins, content packs) as a
/// card with a schematic of its layout; tapping one runs `board.insertTemplate` on the current board, centred on what
/// the window shows.
struct BoardTemplatesPanel: View {
    let app: NibApp
    @ObservedObject var session: EditorSession
    let dismiss: () -> Void
    @State private var templates: [BoardTemplateDescriptor] = []
    @State private var inserting: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: NibSpacing.m)], spacing: NibSpacing.m) {
                ForEach(templates, id: \.id) { template in
                    Button { insert(template) } label: {
                        TemplateCard(template: template, isPlugin: template.owner != FeatWhiteboardFeature.id)
                    }
                    .buttonStyle(NibPressStyle(shape: RoundedRectangle(cornerRadius: NibRadius.tile, style: .continuous)))
                    .disabled(inserting != nil || session.page == nil)
                    .accessibilityLabel(template.title)
                    .accessibilityHint(String(localized: "Inserts the template in the middle of the board you are viewing"))
                }
            }
            .padding(NibSpacing.l)
        }
        .overlay {
            if templates.isEmpty {
                NibEmptyState(symbol: .whiteboard, title: String(localized: "No templates"),
                              message: String(localized: "Plugins and content packs can add whiteboard templates."))
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .nibRegistryDidChange)) { note in
            if (note.object as? Registry<BoardTemplateDescriptor>) === app.content.boardTemplates { reload() }
        }
    }

    private func reload() { templates = app.content.boardTemplates.all }

    private func insert(_ template: BoardTemplateDescriptor) {
        guard let doc = session.document, let page = session.page else { return }
        inserting = template.id
        Task { @MainActor in
            defer { inserting = nil }
            do {
                _ = try await app.bus.execute(Invocation(
                    command: "board.insertTemplate",
                    params: ["page": .string(NodeRef.page(doc, page).description), "template": .string(template.id)],
                    principal: .user, session: session))
                AccessibilityNotification.Announcement(String(localized: "Inserted \(template.title)")).post()
                dismiss()
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: app,
                                                userInfo: ["command": "board.insertTemplate", "error": NibError.wrap(error)])
            }
        }
    }
}

/// One template in the picker: a schematic drawn from the fragment (item boxes in their own colours, connectors as
/// lines), or the template's glyph for `diagram.create` specs, over its title.
struct TemplateCard: View {
    let template: BoardTemplateDescriptor
    let isPlugin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.s) {
            ZStack {
                NibPaper.white.color
                if let items = TemplateSchematic.items(template) {
                    TemplateSchematic(items: items).padding(NibSpacing.s)
                } else {
                    Image(nib: NibSymbol(systemName: template.icon) ?? .whiteboard)
                        .font(NibFont.glyph(.sidebar))
                        .foregroundStyle(NibColor.labelSecondary)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: NibRadius.thumbnail, style: .continuous))
            .nibElevation(.paper)
            HStack(spacing: NibSpacing.xs) {
                Text(template.title)
                    .font(NibFont.footnoteEmphasis)
                    .foregroundStyle(NibColor.label)
                    .lineLimit(2)
                if isPlugin { NibBadge(.plugin) }
            }
        }
        .padding(NibSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A miniature of a fragment: every item's bounds, scaled into the card.
struct TemplateSchematic: View {
    let items: [Item]

    static func items(_ template: BoardTemplateDescriptor) -> [Item]? {
        guard let fragment = template.spec["fragment"], let parsed = try? BoardFragment(json: fragment) else { return nil }
        return parsed.items
    }

    var body: some View {
        Canvas { context, size in
            guard let bounds = TemplatePlacement.union(items), bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(Double(size.width) / bounds.width, Double(size.height) / bounds.height)
            let dx = (Double(size.width) - bounds.width * scale) / 2, dy = (Double(size.height) - bounds.height * scale) / 2
            func map(_ r: Rect) -> CGRect {
                CGRect(x: dx + (r.x - bounds.x) * scale, y: dy + (r.y - bounds.y) * scale,
                       width: max(r.width * scale, 1), height: max(r.height * scale, 1))
            }
            for item in items {
                switch item.kind {
                case .connector:
                    guard let c = item.connector else { continue }
                    var path = Path()
                    let a = map(Rect(x: c.from.point.x, y: c.from.point.y, width: 0, height: 0)).origin
                    let b = map(Rect(x: c.to.point.x, y: c.to.point.y, width: 0, height: 0)).origin
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(NibColor.labelTertiary), lineWidth: 1)
                case .text:
                    let r = map(item.bounds)
                    context.fill(Path(CGRect(x: r.minX, y: r.midY - 1, width: r.width * 0.6, height: 2)),
                                 with: .color(NibColor.labelTertiary))
                default:
                    let shape = Path(map(item.bounds))
                    if let fill = item.sticky?.color ?? item.shape?.style.fillColor {
                        context.fill(shape, with: .color(Color(uiColor: fill.uiColor)))
                    }
                    if item.shape?.style.strokeColor != nil || item.shape?.shape == .line {
                        context.stroke(shape, with: .color(NibColor.labelTertiary), lineWidth: 0.75)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
