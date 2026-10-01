// Nib app icon generator (F094, P-113). Run from the repository root on macOS:
//
//     swift Scripts/make_icons.swift            writes the icons, then checks them
//     swift Scripts/make_icons.swift --check    only checks what is on disk (exit 1 when anything is missing)
//     swift Scripts/make_icons.swift <dir>      writes into another .appiconset folder (tests, previews)
//
// It draws the Nib mark with CoreGraphics (a pen nib that is also a water drop: a round shoulder tapering to a split
// point, with the breather hole and slit cut through) in three appearances and writes them into
// Nib/Resources/Assets.xcassets/AppIcon.appiconset with an appearance-aware Contents.json (Xcode's single-size
// iOS icon; actool derives every smaller size, iOS 17 uses the light one):
//
//     AppIcon-Light.png   opaque, the Pool-blue nib on a cool paper white        (the default, "Any")
//     AppIcon-Dark.png    transparent, the dark-mode Pool nib; iOS draws its dark background   (luminosity: dark)
//     AppIcon-Tinted.png  opaque greyscale, a light nib on black; iOS tints it by luminance    (luminosity: tinted)
//
// The PNGs are build products (CI runs this script before `xcodegen generate`); Contents.json is committed and is
// rewritten byte for byte. Colours are DESIGN.md §3.2's accent (Pool #0066E0, dark #3D8BFF) and paper white.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Output

let side = 1024
let iconFiles = (light: "AppIcon-Light.png", dark: "AppIcon-Dark.png", tinted: "AppIcon-Tinted.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("make_icons: error: " + message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardOutput.write(Data(("make_icons: " + message + "\n").utf8))
}

/// The repository root: two levels above this script, else the working directory.
func repositoryRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let script = URL(fileURLWithPath: #filePath, relativeTo: cwd).standardizedFileURL
    let root = script.deletingLastPathComponent().deletingLastPathComponent()
    let marker = root.appendingPathComponent("Nib/Resources", isDirectory: true).path
    return FileManager.default.fileExists(atPath: marker) ? root : cwd
}

var checkOnly = false
var outputArgument: String?
for argument in CommandLine.arguments.dropFirst() {
    if argument == "--check" {
        checkOnly = true
    } else if argument.hasPrefix("-") {
        fail("unknown option \(argument) (usage: swift Scripts/make_icons.swift [--check] [appiconset folder])")
    } else {
        outputArgument = argument
    }
}

let root = repositoryRoot()
let catalog = root.appendingPathComponent("Nib/Resources/Assets.xcassets", isDirectory: true)
let iconSet = outputArgument.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Palette {
    /// Background, top to bottom; nil = transparent (the system draws the dark icon's background).
    var background: (CGColor, CGColor)?
    /// The nib, top to bottom.
    var nib: (CGColor, CGColor)
    /// The light-directional rim highlight on the shoulder (DESIGN.md §10.9: lit from the top left), nil = none.
    var rim: CGColor?
    /// A soft shadow under the nib on the light icon, nil = none.
    var shadow: CGColor?
}

let lightPalette = Palette(background: (colour(0xFFFFFF), colour(0xECF0F6)),
                           nib: (colour(0x3D8BFF), colour(0x0066E0)),
                           rim: colour(0xFFFFFF, 0.32),
                           shadow: colour(0x0B2A55, 0.20))
let darkPalette = Palette(background: nil,
                          nib: (colour(0x74B0FF), colour(0x3D8BFF)),
                          rim: colour(0xFFFFFF, 0.34),
                          shadow: nil)
let tintedPalette = Palette(background: (colour(0x000000), colour(0x000000)),
                            nib: (colour(0xFFFFFF), colour(0xB4B4B4)),
                            rim: nil,
                            shadow: nil)

// MARK: - Geometry (design space: 1024 × 1024, y grows downwards; `pt` flips it for CoreGraphics)

let centreX: CGFloat = 512
let heelY: CGFloat = 176              // the nib's straight top edge (where it meets the pen)
let tipY: CGFloat = 872               // the split point
let holeY: CGFloat = 548              // centre of the round end of the drop-shaped breather hole
let holeRadius: CGFloat = 46
let holePointY: CGFloat = 430         // the breather hole is a water drop: its point faces the heel
let slitHalfWidth: CGFloat = 9        // where the slit leaves the hole; it closes to nothing at the point

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: CGFloat(side) - y) }

/// One cubic segment in design space.
struct Segment {
    var start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint

    static func line(_ a: CGPoint, _ b: CGPoint) -> Segment {
        Segment(start: a, control1: CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3),
                control2: CGPoint(x: a.x + 2 * (b.x - a.x) / 3, y: a.y + 2 * (b.y - a.y) / 3), end: b)
    }

    /// Mirrored across the centre line and run backwards (the left half from the right half).
    var mirroredReversed: Segment {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: 2 * centreX - p.x, y: p.y) }
        return Segment(start: m(end), control1: m(control2), control2: m(control1), end: m(start))
    }
}

/// The right half of the nib, from the middle of the heel to the point: a straight heel with a rounded corner,
/// a shoulder that flares out, then straight tines closing to a sharp point.
let rightHalf: [Segment] = [
    .line(CGPoint(x: 512, y: heelY), CGPoint(x: 616, y: heelY)),
    Segment(start: CGPoint(x: 616, y: heelY), control1: CGPoint(x: 638, y: heelY),
            control2: CGPoint(x: 648, y: heelY + 7), end: CGPoint(x: 657, y: heelY + 26)),
    Segment(start: CGPoint(x: 657, y: heelY + 26), control1: CGPoint(x: 678, y: heelY + 70),
            control2: CGPoint(x: 722, y: 322), end: CGPoint(x: 722, y: 438)),
    Segment(start: CGPoint(x: 722, y: 438), control1: CGPoint(x: 722, y: 556),
            control2: CGPoint(x: 598, y: 712), end: CGPoint(x: 512, y: tipY)),
]

/// The nib's outline (right half, then the mirrored left half back up to the heel).
func outlinePath() -> CGPath {
    let path = CGMutablePath()
    let segments = rightHalf + rightHalf.reversed().map { $0.mirroredReversed }
    path.move(to: pt(segments[0].start.x, segments[0].start.y))
    for s in segments {
        path.addCurve(to: pt(s.end.x, s.end.y), control1: pt(s.control1.x, s.control1.y),
                      control2: pt(s.control2.x, s.control2.y))
    }
    path.closeSubpath()
    return path
}

/// A point on the breather hole's round end; `a` is measured clockwise from +x (y down).
func holePoint(_ a: CGFloat) -> CGPoint { pt(centreX + holeRadius * cos(a), holeY + holeRadius * sin(a)) }

/// The drop-shaped breather hole and the slit as one outline with no self-overlap, so an even-odd clip cuts both
/// cleanly. The slit runs past the point; the outline clip trims it.
func keyholePath() -> CGPath {
    let join = (holeRadius * holeRadius - slitHalfWidth * slitHalfWidth).squareRoot()
    let leftJoin = atan2(join, -slitHalfWidth)                         // lower left, where the slit leaves
    let rightJoin = atan2(join, slitHalfWidth) + 2 * .pi               // lower right, one turn on
    let spread = acos(holeRadius / (holeY - holePointY))               // tangent points of the drop's sides
    let leftTangent = 1.5 * .pi - spread, rightTangent = 1.5 * .pi + spread
    let path = CGMutablePath()
    path.move(to: pt(centreX, tipY + 24))
    path.addLine(to: pt(centreX - slitHalfWidth, holeY + join))
    func arc(_ from: CGFloat, _ to: CGFloat) {
        let steps = 96
        for i in 1...steps { path.addLine(to: holePoint(from + (to - from) * CGFloat(i) / CGFloat(steps))) }
    }
    arc(leftJoin, leftTangent)
    path.addLine(to: pt(centreX, holePointY))
    path.addLine(to: holePoint(rightTangent))
    arc(rightTangent, rightJoin)
    path.addLine(to: pt(centreX + slitHalfWidth, holeY + join))
    path.closeSubpath()
    return path
}

/// The rim highlight: a short stroke just inside the left shoulder (the key light is top left, DESIGN.md §10.9).
func rimPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: pt(408, heelY + 60))
    path.addCurve(to: pt(344, 458), control1: pt(380, heelY + 120), control2: pt(344, 336))
    return path
}

// MARK: - Drawing

func verticalGradient(_ colours: (CGColor, CGColor)) -> CGGradient {
    guard let g = CGGradient(colorsSpace: sRGB, colors: [colours.0, colours.1] as CFArray, locations: [0, 1]) else {
        fail("could not build a gradient")
    }
    return g
}

func render(_ palette: Palette, opaque: Bool) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: info) else { fail("could not create a \(side) pt bitmap") }
    let bounds = CGRect(x: 0, y: 0, width: side, height: side)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(bounds)
    if let background = palette.background {
        ctx.drawLinearGradient(verticalGradient(background), start: pt(0, 0), end: pt(0, CGFloat(side)), options: [])
    }

    let outline = outlinePath()
    let keyhole = keyholePath()

    // The nib, shadowed as one shape: clip to the outline, cut the keyhole (even-odd against the whole canvas).
    ctx.saveGState()
    if let shadow = palette.shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: shadow)
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.addRect(bounds)
    ctx.addPath(keyhole)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(verticalGradient(palette.nib), start: pt(centreX, heelY), end: pt(centreX, tipY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if let rim = palette.rim {
        ctx.addPath(rimPath())
        ctx.setStrokeColor(rim)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fail("could not finish the icon bitmap") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

// MARK: - Asset catalog JSON (Xcode's own layout: sorted keys, "key" : value, two-space indent)

func jsonData(_ object: Any) -> Data {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not encode Contents.json")
    }
    data.append(0x0A)
    return data
}

let xcodeInfo: [String: Any] = ["author": "xcode", "version": 1]

func iconEntry(_ file: String, luminosity: String?) -> [String: Any] {
    var entry: [String: Any] = ["filename": file, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if let luminosity { entry["appearances"] = [["appearance": "luminosity", "value": luminosity]] }
    return entry
}

let iconContents: [String: Any] = [
    "images": [
        iconEntry(iconFiles.light, luminosity: nil),
        iconEntry(iconFiles.dark, luminosity: "dark"),
        iconEntry(iconFiles.tinted, luminosity: "tinted"),
    ],
    "info": xcodeInfo,
]

func write(_ data: Data, to url: URL) {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
}

// MARK: - Checks (the CI gate: every file exists, is 1024 × 1024 and has the right alpha)

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
}

/// True when every pixel has equal red, green and blue (within one step): the tinted icon must be greyscale.
func isGreyscale(_ image: CGImage) -> Bool {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return false }
    var i = 0
    while i < pixels.count {
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        if abs(r - g) > 1 || abs(g - b) > 1 { return false }
        i += 4
    }
    return true
}

func check() -> [String] {
    var problems: [String] = []
    let contentsURL = iconSet.appendingPathComponent("Contents.json")
    guard let data = try? Data(contentsOf: contentsURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let images = json["images"] as? [[String: Any]] else {
        return ["\(contentsURL.path) is missing or unreadable"]
    }
    var seen: [String: String] = [:]
    for entry in images {
        let luminosity = ((entry["appearances"] as? [[String: String]])?
            .first { $0["appearance"] == "luminosity" })?["value"] ?? "any"
        guard let file = entry["filename"] as? String else {
            problems.append("Contents.json has an icon slot (\(luminosity)) without a file")
            continue
        }
        if entry["size"] as? String != "1024x1024" || entry["idiom"] as? String != "universal" {
            problems.append("\(file) is not a universal 1024x1024 icon in Contents.json")
        }
        seen[luminosity] = file
    }
    for (luminosity, expected) in [("any", iconFiles.light), ("dark", iconFiles.dark), ("tinted", iconFiles.tinted)] {
        guard let file = seen[luminosity] else {
            problems.append("Contents.json has no \(luminosity) icon")
            continue
        }
        if file != expected { problems.append("the \(luminosity) icon is \(file), expected \(expected)") }
        let url = iconSet.appendingPathComponent(file)
        guard let image = loadImage(url) else {
            problems.append("\(url.path) is missing or not a PNG (run swift Scripts/make_icons.swift)")
            continue
        }
        if image.width != side || image.height != side {
            problems.append("\(file) is \(image.width)x\(image.height), expected \(side)x\(side)")
        }
        let wantsAlpha = luminosity == "dark"
        if hasAlpha(image) != wantsAlpha {
            problems.append(wantsAlpha ? "\(file) must keep its transparent background"
                                       : "\(file) must be opaque (no alpha channel)")
        }
        if luminosity == "tinted" && !isGreyscale(image) { problems.append("\(file) must be greyscale") }
    }
    return problems
}

// MARK: - Run

if !checkOnly {
    do {
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(iconSet.path): \(error.localizedDescription)")
    }
    let catalogContents = catalog.appendingPathComponent("Contents.json")
    if outputArgument == nil && !FileManager.default.fileExists(atPath: catalogContents.path) {
        write(jsonData(["info": xcodeInfo]), to: catalogContents)
    }
    writePNG(render(lightPalette, opaque: true), to: iconSet.appendingPathComponent(iconFiles.light))
    writePNG(render(darkPalette, opaque: false), to: iconSet.appendingPathComponent(iconFiles.dark))
    writePNG(render(tintedPalette, opaque: true), to: iconSet.appendingPathComponent(iconFiles.tinted))
    write(jsonData(iconContents), to: iconSet.appendingPathComponent("Contents.json"))
    note("wrote \(iconFiles.light), \(iconFiles.dark), \(iconFiles.tinted) and Contents.json to \(iconSet.path)")
}

let problems = check()
if !problems.isEmpty {
    for p in problems { FileHandle.standardError.write(Data(("make_icons: error: " + p + "\n").utf8)) }
    exit(1)
}
note("checked: light, dark and tinted icons are \(side)x\(side) with an appearance-aware Contents.json")
