import Foundation

public enum ItemKind: String, Codable, CaseIterable {
    case stroke, shape, connector, text, image, sticky, math, comment, custom
}

// MARK: - Shapes and connectors

public enum ShapeKind: String, Codable, CaseIterable {
    case line, polyline, polygon, rectangle, roundedRectangle, ellipse, triangle, diamond, arc, curve, arrow
}

public struct ShapeItemStyle: Codable, Hashable {
    /// nil = no outline (fill-only shape).
    public var strokeColor: RGBA?
    public var strokeWidth: Double
    /// nil = no fill.
    public var fillColor: RGBA?
    public var cornerRadius: Double
    public var pattern: StrokePattern
    /// Shapes snapped from Draw-and-Hold keep the look of the tool that drew them.
    public var drawnWith: InkTool?
    public var arrowStart: Bool
    public var arrowEnd: Bool

    public init(strokeColor: RGBA? = .black, strokeWidth: Double = 1.5, fillColor: RGBA? = nil, cornerRadius: Double = 6,
                pattern: StrokePattern = .solid, drawnWith: InkTool? = nil, arrowStart: Bool = false, arrowEnd: Bool = false) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.pattern = pattern
        self.drawnWith = drawnWith
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
    }

    enum CodingKeys: String, CodingKey {
        case strokeColor, strokeWidth, fillColor, cornerRadius, pattern, drawnWith, arrowStart, arrowEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 1.5
        fillColor = try c.decodeIfPresent(RGBA.self, forKey: .fillColor)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 6
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? .solid
        drawnWith = try c.decodeIfPresent(InkTool.self, forKey: .drawnWith)
        arrowStart = try c.decodeIfPresent(Bool.self, forKey: .arrowStart) ?? false
        arrowEnd = try c.decodeIfPresent(Bool.self, forKey: .arrowEnd) ?? false
    }
}

public struct ShapeItem: Codable, Equatable {
    public var shape: ShapeKind
    public var frame: Frame
    /// Vertices / control points in page coordinates (line, polyline, polygon, arc, curve, arrow).
    /// Empty for box shapes, which are defined by `frame` alone.
    /// contracts-v2 (pinned): points are CONTROL points, never points the curve passes through, so the shape stays inside
    /// the points' bounds and `Item.bounds` is right.
    /// - `.curve`: Bézier control points: 2 = straight, 3 = quadratic, 4 = cubic, 5+ = clamped uniform B-spline.
    /// - `.arc`: [start, control, end]. For sweeps under 170° `control` is where the tangents at start and end meet
    ///   (a conic arc, circular when |control − start| = |control − end|); wider sweeps and parabolas are sent as a
    ///   quadratic start / control / end. Convert three through-points with `ShapeItem.quadraticControl(through:_:_:)`.
    public var points: [Point]
    public var style: ShapeItemStyle
    public var text: RichText?

    public init(shape: ShapeKind, frame: Frame, points: [Point] = [], style: ShapeItemStyle = ShapeItemStyle(), text: RichText? = nil) {
        self.shape = shape
        self.frame = frame
        self.points = points
        self.style = style
        self.text = text
    }

    /// contracts-v2: the quadratic Bézier control points [start, control, end] of the curve through `start`, `mid` (at
    /// t = 0.5) and `end`: control = 2·mid − (start + end) / 2.
    public static func quadraticControl(through start: Point, _ mid: Point, _ end: Point) -> [Point] {
        [start, Point(2 * mid.x - (start.x + end.x) / 2, 2 * mid.y - (start.y + end.y) / 2), end]
    }

    enum CodingKeys: String, CodingKey { case shape, frame, points, style, text }

    /// Lenient (AI / plugin JSON): only `shape` is required; `frame` defaults to the bounds of `points`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decode(ShapeKind.self, forKey: .shape)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
            ?? Rect.bounding(points).map { Frame($0) } ?? Frame(x: 0, y: 0, w: 0, h: 0)
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle()
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
    }
}

public struct ConnectorEnd: Codable, Hashable {
    /// Current end point in page coordinates (kept in sync with the anchored item).
    public var point: Point
    /// Anchored shape/item, if any.
    public var item: ElementID?
    /// 0 top, 1 right, 2 bottom, 3 left.
    public var side: Int?
    /// 0…1 along the side.
    public var t: Double?

    public init(point: Point, item: ElementID? = nil, side: Int? = nil, t: Double? = nil) {
        self.point = point
        self.item = item
        self.side = side
        self.t = t
    }

    enum CodingKeys: String, CodingKey { case point, item, side, t }

    /// Lenient: `point` defaults to (0, 0) (anchored ends are recomputed from `item`/`side`/`t` by the commands).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decodeIfPresent(Point.self, forKey: .point) ?? .zero
        item = try c.decodeIfPresent(ElementID.self, forKey: .item)
        side = try c.decodeIfPresent(Int.self, forKey: .side)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
    }
}

public enum ConnectorRoute: String, Codable, CaseIterable { case straight, elbow, curved }

public struct ConnectorItem: Codable, Equatable {
    public var from: ConnectorEnd
    public var to: ConnectorEnd
    public var route: ConnectorRoute
    /// User-added bend / control points.
    public var bends: [Point]
    public var style: ShapeItemStyle
    public var label: RichText?

    public init(from: ConnectorEnd, to: ConnectorEnd, route: ConnectorRoute = .straight, bends: [Point] = [],
                style: ShapeItemStyle = ShapeItemStyle(arrowEnd: true), label: RichText? = nil) {
        self.from = from
        self.to = to
        self.route = route
        self.bends = bends
        self.style = style
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case from, to, route, bends, style, label }

    /// Lenient: only `from` and `to` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(ConnectorEnd.self, forKey: .from)
        to = try c.decode(ConnectorEnd.self, forKey: .to)
        route = try c.decodeIfPresent(ConnectorRoute.self, forKey: .route) ?? .straight
        bends = try c.decodeIfPresent([Point].self, forKey: .bends) ?? []
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle(arrowEnd: true)
        label = try c.decodeIfPresent(RichText.self, forKey: .label)
    }
}

// MARK: - Boxes

public struct TextBoxStyle: Codable, Hashable {
    public var background: RGBA?
    public var borderColor: RGBA?
    public var borderWidth: Double
    public var cornerRadius: Double
    public var padding: Double
    public var shadow: Bool
    /// Grow height to fit content.
    public var autoGrow: Bool
    /// Full-page ("body") text: page-sized box at the bottom of the z-order.
    public var fullPage: Bool
    /// Default character attributes for runs that leave fields nil.
    public var defaults: TextAttributes
    /// contracts-v2: paragraph defaults of a saved or default style (applied to new paragraphs); nil = natural / none.
    public var align: ParagraphAlignment?
    public var lineSpacing: Double?

    public init(background: RGBA? = nil, borderColor: RGBA? = nil, borderWidth: Double = 0, cornerRadius: Double = 0,
                padding: Double = 4, shadow: Bool = false, autoGrow: Bool = true, fullPage: Bool = false,
                defaults: TextAttributes = TextAttributes(), align: ParagraphAlignment? = nil, lineSpacing: Double? = nil) {
        self.background = background
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.shadow = shadow
        self.autoGrow = autoGrow
        self.fullPage = fullPage
        self.defaults = defaults
        self.align = align
        self.lineSpacing = lineSpacing
    }

    enum CodingKeys: String, CodingKey {
        case background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, fullPage, defaults
        case align, lineSpacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
        borderColor = try c.decodeIfPresent(RGBA.self, forKey: .borderColor)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 4
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        autoGrow = try c.decodeIfPresent(Bool.self, forKey: .autoGrow) ?? true
        fullPage = try c.decodeIfPresent(Bool.self, forKey: .fullPage) ?? false
        defaults = try c.decodeIfPresent(TextAttributes.self, forKey: .defaults) ?? TextAttributes()
        align = (try? c.decodeIfPresent(ParagraphAlignment.self, forKey: .align)) ?? nil
        lineSpacing = (try? c.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? nil
    }
}

public struct TextBoxItem: Codable, Equatable {
    public var frame: Frame
    public var text: RichText
    public var style: TextBoxStyle

    public init(frame: Frame, text: RichText, style: TextBoxStyle = TextBoxStyle()) {
        self.frame = frame
        self.text = text
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case frame, text, style }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        style = try c.decodeIfPresent(TextBoxStyle.self, forKey: .style) ?? TextBoxStyle()
    }
}

public struct ImageItem: Codable, Equatable {
    public var frame: Frame
    public var asset: AssetRef
    /// Rectangular crop, normalized 0…1 in image space.
    public var crop: Rect?
    /// Freehand crop outline, normalized 0…1 in image space.
    public var mask: [Point]?
    /// Animated GIF: tiles show the first frame, a live view animates it while visible.
    public var animated: Bool
    public var altText: String?
    /// contracts-v2: mirrored horizontally / vertically inside the frame (after `crop`); nil = not flipped. Every
    /// drawer, live view and export honours them.
    public var flipX: Bool?
    public var flipY: Bool?

    public init(frame: Frame, asset: AssetRef, crop: Rect? = nil, mask: [Point]? = nil, animated: Bool = false, altText: String? = nil) {
        self.frame = frame
        self.asset = asset
        self.crop = crop
        self.mask = mask
        self.animated = animated
        self.altText = altText
    }

    enum CodingKeys: String, CodingKey { case frame, asset, crop, mask, animated, altText, flipX, flipY }

    /// Lenient: `frame` and `asset` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        asset = try c.decode(AssetRef.self, forKey: .asset)
        crop = try c.decodeIfPresent(Rect.self, forKey: .crop)
        mask = try c.decodeIfPresent([Point].self, forKey: .mask)
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        altText = try c.decodeIfPresent(String.self, forKey: .altText)
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX)
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY)
    }
}

public struct StickyItem: Codable, Equatable {
    public var frame: Frame
    public var color: RGBA
    public var text: RichText
    public var collapsed: Bool
    public var author: String?
    public var resolved: Bool

    public init(frame: Frame, color: RGBA = RGBA(0xFF, 0xE8, 0x7C), text: RichText = .empty, collapsed: Bool = false,
                author: String? = nil, resolved: Bool = false) {
        self.frame = frame
        self.color = color
        self.text = text
        self.collapsed = collapsed
        self.author = author
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case frame, color, text, collapsed, author, resolved }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(0xFF, 0xE8, 0x7C)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        author = try c.decodeIfPresent(String.self, forKey: .author)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

public struct MathItem: Codable, Equatable {
    public var frame: Frame
    /// One LaTeX string per line.
    public var latex: [String]
    public var color: RGBA
    /// The handwriting it was converted from ("Copy Handwriting").
    public var sourceInk: [Stroke]?

    public init(frame: Frame, latex: [String], color: RGBA = .black, sourceInk: [Stroke]? = nil) {
        self.frame = frame
        self.latex = latex
        self.color = color
        self.sourceInk = sourceInk
    }

    enum CodingKeys: String, CodingKey { case frame, latex, color, sourceInk }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        latex = try c.decodeIfPresent([String].self, forKey: .latex) ?? []
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .black
        sourceInk = try c.decodeIfPresent([Stroke].self, forKey: .sourceInk)
    }
}

public struct CommentMessage: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    /// Unix seconds.
    public var at: Double
    public var edited: Bool

    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970, edited: Bool = false) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, edited }

    /// Lenient: only `text` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}

public struct CommentItem: Codable, Equatable {
    /// Pin location. When `Item.attachedTo` is set the pin follows that item.
    public var anchor: Point
    public var messages: [CommentMessage]
    public var resolved: Bool

    public init(anchor: Point, messages: [CommentMessage], resolved: Bool = false) {
        self.anchor = anchor
        self.messages = messages
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case anchor, messages, resolved }

    /// Lenient: only `anchor` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(Point.self, forKey: .anchor)
        messages = try c.decodeIfPresent([CommentMessage].self, forKey: .messages) ?? []
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

// MARK: - Plugin / custom items

public enum DisplayOpKind: String, Codable, CaseIterable {
    case rect, ellipse, line, polyline, polygon, text, image, hlines, vlines, dots
}

/// One drawing instruction. Coordinates are relative to the owning frame's top-left (custom items)
/// or to the page (templates). Unused fields stay nil.
public struct DisplayOp: Codable, Equatable {
    public var op: DisplayOpKind
    public var rect: Rect?
    public var points: [Point]?
    public var stroke: RGBA?
    public var fill: RGBA?
    public var width: Double?
    public var dash: [Double]?
    public var text: String?
    public var fontSize: Double?
    public var fontName: String?
    public var asset: AssetRef?
    /// Line / dot spacing for hlines, vlines, dots.
    public var spacing: Double?
    /// Corner radius (rect) or dot radius (dots).
    public var radius: Double?
    /// contracts-v2: `text` alignment inside `rect` (nil = natural / left).
    public var align: ParagraphAlignment?
    /// contracts-v2: `text` weight of the system font (ignored with `fontName`); nil = regular.
    public var weight: DisplayFontWeight?

    public init(op: DisplayOpKind, rect: Rect? = nil, points: [Point]? = nil, stroke: RGBA? = nil, fill: RGBA? = nil,
                width: Double? = nil, dash: [Double]? = nil, text: String? = nil, fontSize: Double? = nil,
                fontName: String? = nil, asset: AssetRef? = nil, spacing: Double? = nil, radius: Double? = nil,
                align: ParagraphAlignment? = nil, weight: DisplayFontWeight? = nil) {
        self.op = op
        self.rect = rect
        self.points = points
        self.stroke = stroke
        self.fill = fill
        self.width = width
        self.dash = dash
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.asset = asset
        self.spacing = spacing
        self.radius = radius
        self.align = align
        self.weight = weight
    }
}

/// contracts-v2: font weights a `DisplayOp` text can use (template headings, planner labels).
public enum DisplayFontWeight: String, Codable, CaseIterable {
    case light, regular, medium, semibold, bold, heavy
}

/// A tiny vector format drawn by the host renderer (templates, plugin items, math graphs, AI diagrams).
public struct DisplayList: Codable, Equatable {
    public var ops: [DisplayOp]
    public init(ops: [DisplayOp] = []) { self.ops = ops }

    enum CodingKeys: String, CodingKey { case ops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decodeIfPresent([DisplayOp].self, forKey: .ops) ?? []
    }
}

/// An item whose meaning is owned by a feature or plugin. It always renders from `display`,
/// so it survives the owner being disabled or uninstalled.
public struct CustomItem: Codable, Equatable {
    /// Feature or plugin id, e.g. "nib.mathgraph" or "dev.example.chart".
    public var owner: String
    public var type: String
    public var frame: Frame
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, frame: Frame, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.frame = frame
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, frame, data, display }

    /// Lenient: `owner`, `type` and `frame` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        frame = try c.decode(Frame.self, forKey: .frame)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

// MARK: - Item

/// Every object on a page. Exactly one payload matching `kind` is non-nil.
/// JSON: {"id":"…","kind":"stroke","layer":0,"z":"V","stroke":{…}}.
public struct Item: Codable, Equatable, Identifiable, LWWRecord {
    public var id: ElementID
    public var rev: Rev
    /// Tombstone (kept for sync / undo).
    public var deleted: Bool
    public var kind: ItemKind
    /// Fractional z-order key; empty = assign on first write (top of the page).
    public var z: String
    /// 0…4.
    public var layer: Int
    public var locked: Bool
    /// Container shape / sticky note / anchored comment target.
    public var attachedTo: ElementID?
    /// Provenance: "user", "ai:<chat>", "plugin:<id>", "bridge:<client>".
    public var createdBy: String?
    /// Plugin-owned data keyed by plugin id.
    public var ext: [String: JSONValue]?

    public var stroke: Stroke?
    public var shape: ShapeItem?
    public var connector: ConnectorItem?
    public var text: TextBoxItem?
    public var image: ImageItem?
    public var sticky: StickyItem?
    public var math: MathItem?
    public var comment: CommentItem?
    public var custom: CustomItem?

    public init(id: ElementID = NibID.make(), kind: ItemKind, z: String = "", layer: Int = 0, locked: Bool = false,
                attachedTo: ElementID? = nil, createdBy: String? = nil, ext: [String: JSONValue]? = nil,
                stroke: Stroke? = nil, shape: ShapeItem? = nil, connector: ConnectorItem? = nil, text: TextBoxItem? = nil,
                image: ImageItem? = nil, sticky: StickyItem? = nil, math: MathItem? = nil, comment: CommentItem? = nil,
                custom: CustomItem? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.kind = kind
        self.z = z
        self.layer = layer
        self.locked = locked
        self.attachedTo = attachedTo
        self.createdBy = createdBy
        self.ext = ext
        self.stroke = stroke
        self.shape = shape
        self.connector = connector
        self.text = text
        self.image = image
        self.sticky = sticky
        self.math = math
        self.comment = comment
        self.custom = custom
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, kind, z, layer, locked, attachedTo, createdBy, ext
        case stroke, shape, connector, text, image, sticky, math, comment, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(ElementID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        kind = try c.decode(ItemKind.self, forKey: .kind)
        z = try c.decodeIfPresent(String.self, forKey: .z) ?? ""
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        attachedTo = try c.decodeIfPresent(ElementID.self, forKey: .attachedTo)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
        stroke = try c.decodeIfPresent(Stroke.self, forKey: .stroke)
        shape = try c.decodeIfPresent(ShapeItem.self, forKey: .shape)
        connector = try c.decodeIfPresent(ConnectorItem.self, forKey: .connector)
        text = try c.decodeIfPresent(TextBoxItem.self, forKey: .text)
        image = try c.decodeIfPresent(ImageItem.self, forKey: .image)
        sticky = try c.decodeIfPresent(StickyItem.self, forKey: .sticky)
        math = try c.decodeIfPresent(MathItem.self, forKey: .math)
        comment = try c.decodeIfPresent(CommentItem.self, forKey: .comment)
        custom = try c.decodeIfPresent(CustomItem.self, forKey: .custom)
    }

    // MARK: Factories

    public static func makeStroke(_ s: Stroke, layer: Int = 0) -> Item { Item(kind: .stroke, layer: layer, stroke: s) }
    public static func makeShape(_ s: ShapeItem, layer: Int = 0) -> Item { Item(kind: .shape, layer: layer, shape: s) }
    public static func makeConnector(_ c: ConnectorItem, layer: Int = 0) -> Item { Item(kind: .connector, layer: layer, connector: c) }
    public static func makeText(_ t: TextBoxItem, layer: Int = 0) -> Item { Item(kind: .text, layer: layer, text: t) }
    public static func makeImage(_ i: ImageItem, layer: Int = 0) -> Item { Item(kind: .image, layer: layer, image: i) }
    public static func makeSticky(_ s: StickyItem, layer: Int = 0) -> Item { Item(kind: .sticky, layer: layer, sticky: s) }
    public static func makeMath(_ m: MathItem, layer: Int = 0) -> Item { Item(kind: .math, layer: layer, math: m) }
    public static func makeComment(_ c: CommentItem, layer: Int = 0) -> Item { Item(kind: .comment, layer: layer, comment: c) }
    public static func makeCustom(_ c: CustomItem, layer: Int = 0) -> Item { Item(kind: .custom, layer: layer, custom: c) }

    // MARK: Derived

    /// True when exactly the payload matching `kind` is present.
    public var isValid: Bool {
        var kinds: [ItemKind] = []
        if stroke != nil { kinds.append(.stroke) }
        if shape != nil { kinds.append(.shape) }
        if connector != nil { kinds.append(.connector) }
        if text != nil { kinds.append(.text) }
        if image != nil { kinds.append(.image) }
        if sticky != nil { kinds.append(.sticky) }
        if math != nil { kinds.append(.math) }
        if comment != nil { kinds.append(.comment) }
        if custom != nil { kinds.append(.custom) }
        return kinds == [kind]
    }

    /// Key used to look up an `ItemDrawer`: "stroke.<tool>", "custom.<owner>.<type>", or the kind name.
    public var drawKey: String {
        switch kind {
        case .stroke: return "stroke." + (stroke?.style.tool.rawValue ?? InkTool.pen.rawValue)
        case .custom: return "custom." + (custom?.owner ?? "") + "." + (custom?.type ?? "")
        default: return kind.rawValue
        }
    }

    /// Frame of frame-based kinds (shape, text, image, sticky, math, custom); nil otherwise.
    public var frame: Frame? {
        get {
            switch kind {
            case .shape: return shape?.frame
            case .text: return text?.frame
            case .image: return image?.frame
            case .sticky: return sticky?.frame
            case .math: return math?.frame
            case .custom: return custom?.frame
            default: return nil
            }
        }
        set {
            guard let f = newValue else { return }
            switch kind {
            case .shape: shape?.frame = f
            case .text: text?.frame = f
            case .image: image?.frame = f
            case .sticky: sticky?.frame = f
            case .math: math?.frame = f
            case .custom: custom?.frame = f
            default: break
            }
        }
    }

    /// Axis-aligned bounds in page coordinates.
    public var bounds: Rect {
        switch kind {
        case .stroke:
            return stroke?.bounds ?? .zero
        case .shape:
            guard let s = shape else { return .zero }
            let pad = s.style.strokeWidth / 2 + 1
            if let r = Rect.bounding(s.points), !s.points.isEmpty { return r.insetBy(-pad) }
            return s.frame.bounds.insetBy(-pad)
        case .connector:
            guard let c = connector else { return .zero }
            let r = Rect.bounding([c.from.point, c.to.point] + c.bends) ?? .zero
            return r.insetBy(-(c.style.strokeWidth / 2 + 6))
        case .comment:
            guard let c = comment else { return .zero }
            return Rect(x: c.anchor.x - 12, y: c.anchor.y - 12, width: 24, height: 24)
        default:
            return frame?.bounds ?? .zero
        }
    }

    /// Point on a side of a frame-based item (0 top, 1 right, 2 bottom, 3 left; t 0…1), used by connectors.
    public func anchorPoint(side: Int, t: Double) -> Point? {
        guard let f = frame else { return nil }
        let c = f.corners
        var a = c[0]
        var b = c[1]
        switch side {
        case 1:
            a = c[1]
            b = c[2]
        case 2:
            a = c[3]
            b = c[2]
        case 3:
            a = c[0]
            b = c[3]
        default:
            break
        }
        let k = max(0, min(1, t))
        return Point(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
    }

    /// Applies a transform to the geometry (points are baked; frames move/scale/rotate; stroke widths scale).
    public func transformed(by t: Affine) -> Item {
        var it = self
        switch kind {
        case .stroke:
            it.stroke = stroke?.transformed(by: t)
        case .shape:
            if var s = shape {
                s.frame = s.frame.applying(t)
                s.points = s.points.map { t.apply($0) }
                it.shape = s
            }
        case .connector:
            if var c = connector {
                c.from.point = t.apply(c.from.point)
                c.to.point = t.apply(c.to.point)
                c.bends = c.bends.map { t.apply($0) }
                it.connector = c
            }
        case .comment:
            if var c = comment {
                c.anchor = t.apply(c.anchor)
                it.comment = c
            }
        case .math:
            if var m = math {
                m.frame = m.frame.applying(t)
                m.sourceInk = m.sourceInk?.map { $0.transformed(by: t) }
                it.math = m
            }
        case .text, .image, .sticky, .custom:
            if let f = frame { it.frame = f.applying(t) }
        }
        return it
    }
}
