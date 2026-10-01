import XCTest
import SwiftUI
import UIKit
import NibContracts
import NibTesting
@testable import NibDesign

/// Structural and contrast regressions always run hostless. A live scene additionally exercises native optics.
@MainActor
final class GlassForegroundSnapshotTests: XCTestCase {
    private let size = CGSize(width: 360, height: 240)

    func testBarPaletteAndDeepGlyphsStayCrispAndReadable() async throws {
        try assertHostlessForegroundGuarantees()
        guard NibSnapshot.supportsHostedImages else { return }
        try await assertLiveAppearanceChangesOverWhitePaper()
        try await assertPortraitNativeSurfacesHaveOneEdgeAndAClearCore()
        for variant in [NibSnapshot.Variant.light, .dark] {
            for surface in [NibGlassForegroundGallery.Surface.bar, .palette, .deep, .hud, .standaloneHUD] {
                let reference = try await capture(surface, glass: false, variant: variant)
                let rendered = try await capture(surface, variant: variant)
                let empty = try await capture(surface, showsContent: false, variant: variant)
                let name = "\(surface)-\(variant.rawValue)"
                attach(reference, name: "\(name)-unglassed")
                attach(rendered, name: "\(name)-glass")
                attach(empty, name: "\(name)-material")

                var cores = 0, crisp = 0, readable = 0
                // Sample solid glyph pixels from the unglassed reference, excluding coloured ink swatches.
                for y in 102..<138 {
                    for x in 44..<316 {
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        let ref = try XCTUnwrap(NibSnapshot.pixel(reference, at: point))
                        let isNeutral = abs(Int(ref.r) - Int(ref.g)) < 5 && abs(Int(ref.g) - Int(ref.b)) < 5
                        let isCore = variant == .dark ? min(ref.r, ref.g, ref.b) > 252 : max(ref.r, ref.g, ref.b) < 3
                        guard isNeutral && isCore else { continue }
                        cores += 1
                        let actual = try XCTUnwrap(NibSnapshot.pixel(rendered, at: point))
                        let body = try XCTUnwrap(NibSnapshot.pixel(empty, at: point))
                        let delta = max(abs(Int(actual.r) - Int(ref.r)), abs(Int(actual.g) - Int(ref.g)),
                                        abs(Int(actual.b) - Int(ref.b)))
                        if delta <= 38 { crisp += 1 }
                        if contrast(actual, body) >= 4.5 { readable += 1 }
                    }
                }
                XCTAssertGreaterThan(cores, 40, "\(name): reference must contain real glyphs")
                XCTAssertGreaterThanOrEqual(Double(crisp) / Double(max(cores, 1)), 0.9,
                                            "\(name): glyph cores differ from the unglassed render (blur/refraction)")
                XCTAssertGreaterThanOrEqual(Double(readable) / Double(max(cores, 1)), 0.9,
                                            "\(name): small labels must retain 4.5:1 contrast over ink/paper")

                // A bar's top and bottom rims must not mirror its own title or swatches.
                var rimPixels = 0, ghosts = 0
                for y in [99, 100, 139, 140] {
                    for x in 68..<292 {
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        let actual = try XCTUnwrap(NibSnapshot.pixel(rendered, at: point))
                        let body = try XCTUnwrap(NibSnapshot.pixel(empty, at: point))
                        rimPixels += 1
                        if abs(luminance(actual) - luminance(body)) > 0.15 { ghosts += 1 }
                    }
                }
                XCTAssertLessThanOrEqual(Double(ghosts) / Double(rimPixels), 0.02,
                                         "\(name): the rim must refract only the backdrop")
            }
        }
    }

    func testLibraryNewHasAccentBehindItsLabelInBothAppearances() async throws {
        try assertHostlessAccentGuarantees()
        guard NibSnapshot.supportsHostedImages else { return }
        for variant in [NibSnapshot.Variant.light, .dark] {
            let image = try await capture(.library, variant: variant)
            attach(image, name: "library-new-\(variant.rawValue)")
            var accentPixels = 0
            // Interior of the 96 × 44 New droplet beside the three library controls, excluding its rim.
            for y in 105..<135 {
                for x in 218..<298 {
                    let p = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: CGFloat(x), y: CGFloat(y))))
                    if Int(p.b) - Int(p.r) > 50 && Int(p.b) - Int(p.g) > 30 { accentPixels += 1 }
                }
            }
            XCTAssertGreaterThan(accentPixels, 800, "\(variant): New needs an accent body beneath onAccent text")
        }
    }

    func testPhysicsEnvelopeDoesNotChangeTheRestLayout() {
        let field = DropletField()
        field.usesSystemGlass = true
        var presentation = DropletPresentation()
        presentation.restSize = CGSize(width: 280, height: 44)
        presentation.bodySize = CGSize(width: 310, height: 49)
        presentation.bodyOffset = CGPoint(x: 20, y: -10)
        presentation.isDrawn = true
        let view = Text("Physics")
            .frame(width: 280, height: 44)
            .modifier(DropletBodyModifier(id: "test.bar", style: .bar, presentation: presentation,
                                          namespace: nil, field: field))
        let measured = NibSnapshot.fittingSize(view, width: 360)
        XCTAssertEqual(measured.width, 280, accuracy: 0.01)
        XCTAssertEqual(measured.height, 44, accuracy: 0.01)
    }

    func testDarkPaperBodyReachesTheSpecifiedOpacity() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let fullPaper = UIColor(NibGlassBodyTint.color(.clear, paperShare: 1)).resolvedColor(with: dark)
        let partialPaper = UIColor(NibGlassBodyTint.color(.clear, paperShare: 0.7)).resolvedColor(with: dark)
        XCTAssertEqual(fullPaper.cgColor.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(partialPaper.cgColor.alpha, 0.62 + 0.18 * 0.7, accuracy: 0.001)
        XCTAssertEqual(NibUIColor.deepBody.resolvedColor(with: dark).cgColor.alpha, 0.86, accuracy: 0.001)
    }

    func testNativeBackdropDarkensOnlyTheDropletSilhouettesBeforeGlassComposites() throws {
        let canvas = CGSize(width: 360, height: 400)
        let paper = CGRect(origin: .zero, size: canvas)
        let surfaces: [(DropletStyle, CGRect)] = [
            (.bar, CGRect(x: 40, y: 100, width: 280, height: 44)),
            (.palette, CGRect(x: 40, y: 44, width: 56, height: 300)),
            (.popover, CGRect(x: 40, y: 40, width: 280, height: 320)),
            (.hud, CGRect(x: 40, y: 100, width: 120, height: 40)),
            // A nonrefracting page-resident chip still needs the same neutral contrast protection.
            (.chip, CGRect(x: 40, y: 100, width: 180, height: 44))
        ]
        for (style, frame) in surfaces {
            for variant in [NibSnapshot.Variant.light, .dark] {
                let underlay = backdropProbe(frame: frame, style: style, paper: [paper]).background(Color.white)
                let image = try XCTUnwrap(NibSnapshot.image(underlay, size: canvas, variant: variant))
                let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)))
                if variant == .dark {
                    XCTAssertLessThan(max(centre.r, centre.g, centre.b), 85, "Glass must sample a dark backdrop")
                    XCTAssertGreaterThanOrEqual(contrast(RGBA.white, centre), 4.5)
                } else {
                    XCTAssertEqual(centre, RGBA.white, "No extra body behind light system glass")
                }
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: 2, y: 2)), RGBA.white,
                               "The underlay must not tint the page outside the droplet")
            }
            // Leaving paper removes the exception without a display-link tick.
            if style.material == .clear {
                let image = try XCTUnwrap(NibSnapshot.image(backdropProbe(frame: frame, style: style, paper: []).background(Color.white),
                                                           size: canvas, variant: .dark))
                XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)), RGBA.white)
            }
        }
    }

    func testChromeColoursKeepAppAppearanceWhenGlassAdaptsToTheOppositeBackdrop() {
        for scheme in [ColorScheme.light, .dark] {
            var app = EnvironmentValues()
            app.colorScheme = scheme
            var glass = EnvironmentValues()
            glass.colorScheme = scheme == .dark ? .light : .dark
            glass.nibChromeAppearance = NibChromeAppearance(app)
            for token in [NibColor.label, NibColor.labelSecondary, NibColor.accent, NibColor.warning,
                          NibColor.onAccent, NibInk.cobalt.color] {
                XCTAssertEqual(NibChromeColor(token).resolve(in: glass), token.resolve(in: app))
            }
            // Ordinary components still follow their local appearance when they are outside a glass host.
            glass.nibChromeAppearance = nil
            XCTAssertEqual(NibChromeColor(NibColor.label).resolve(in: glass), NibColor.label.resolve(in: glass))
        }
    }

    func testNativeUnderlayUsesLivePaperGeometryAndCapturedAppAppearance() throws {
        let frame = CGRect(x: 40, y: 100, width: 280, height: 44)
        let paper = CGRect(origin: .zero, size: size)
        var app = EnvironmentValues()
        app.colorScheme = .dark
        for style in [DropletStyle.bar, .palette, .hud, .chip] {
            let field = DropletField()
            field.usesSystemGlass = true
            field.setRest("live", frame, style: style)
            defer { field.unregister("live") }
            XCTAssertEqual(field.node("live").presentation.paperShare, 0)
            // The physics field still has stale paper coverage; the actual native host anchor must win.
            // Simulate native glass adapting the local environment to light at that same moment.
            let live = backdropProbe(frame: frame, style: style, paper: [paper])
                .environment(field)
                .environment(\.nibChromeAppearance, NibChromeAppearance(app))
                .environment(\.colorScheme, .light)
                .background(Color.white)
            let image = try XCTUnwrap(NibSnapshot.image(live, size: size))
            let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 180, y: 120)))
            XCTAssertLessThan(max(centre.r, centre.g, centre.b), 85)
            XCTAssertGreaterThanOrEqual(contrast(.white, centre), 4.5)
            XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: 2, y: 2)), .white)

            // And the inverse: leaving white paper removes the exception without waiting for physics.
            field.setBackdrop([paper])
            let removed = backdropProbe(frame: frame, style: style, paper: [])
                .environment(field)
                .environment(\.nibChromeAppearance, NibChromeAppearance(app))
                .background(Color.white)
            let cleared = try XCTUnwrap(NibSnapshot.image(removed, size: size, variant: .dark))
            XCTAssertEqual(NibSnapshot.pixel(cleared, at: CGPoint(x: 180, y: 120)), .white)
        }
    }

    /// Keep one UIKit host alive while SwiftUI changes appearance. Fresh hosts whose UIKit traits already
    /// match the requested snapshot cannot detect a stale native glass subtree.
    private func assertLiveAppearanceChangesOverWhitePaper() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: AppearanceProbe(surface: .bar, scheme: .light, showsContent: true))
        // Deliberately leave UIKit light. Nib must apply the live app appearance at the native effect boundary.
        host.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        for surface in [NibGlassForegroundGallery.Surface.bar, .palette, .hud, .standaloneHUD, .deep] {
            for scheme in [ColorScheme.light, .dark, .light, .dark] {
                host.rootView = AppearanceProbe(surface: surface, scheme: scheme, showsContent: true)
                host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 500_000_000)
                let rendered = try liveImage(host.view)
                host.rootView = AppearanceProbe(surface: surface, scheme: scheme, showsContent: false)
                host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 500_000_000)
                let empty = try liveImage(host.view)
                let variant: NibSnapshot.Variant = scheme == .dark ? .dark : .light
                let reference = try XCTUnwrap(NibSnapshot.image(
                    NibGlassForegroundGallery(surface: surface, glass: false), size: size, variant: variant))
                var cores = 0, readable = 0
                for y in 102..<138 {
                    for x in 44..<316 {
                        let point = CGPoint(x: x, y: y)
                        let ref = try XCTUnwrap(NibSnapshot.pixel(reference, at: point))
                        let neutral = abs(Int(ref.r) - Int(ref.g)) < 5 && abs(Int(ref.g) - Int(ref.b)) < 5
                        let core = scheme == .dark ? min(ref.r, ref.g, ref.b) > 252 : max(ref.r, ref.g, ref.b) < 3
                        guard neutral && core else { continue }
                        cores += 1
                        let glyph = try XCTUnwrap(NibSnapshot.pixel(rendered, at: point))
                        let body = try XCTUnwrap(NibSnapshot.pixel(empty, at: point))
                        if contrast(glyph, body) >= 4.5 { readable += 1 }
                    }
                }
                attach(rendered, name: "live-appearance-\(surface)-\(scheme)")
                XCTAssertGreaterThan(cores, 40)
                XCTAssertGreaterThanOrEqual(Double(readable) / Double(max(cores, 1)), 0.9,
                                            "\(surface), \(scheme): live native glass must retain 4.5:1 contrast")
            }
        }
    }

    /// Exercise the native compositor at the sizes where a small HUD snapshot cannot reveal panel facets.
    private func assertPortraitNativeSurfacesHaveOneEdgeAndAClearCore() async throws {
        for canvas in [CGSize(width: 393, height: 852), CGSize(width: 834, height: 1194)] {
            let frames: [(DropletStyle, CGRect)] = [
                (.palette, CGRect(x: 40, y: 100, width: 56, height: 480)),
                (.palette, CGRect(x: 32, y: 100, width: canvas.width - 64, height: 56)),
                (.panel, CGRect(x: 32, y: 100, width: canvas.width - 64, height: canvas.height - 220))
            ]
            for (style, frame) in frames {
                for standalone in [false, true] {
                    let probe = PortraitGlassProbe(canvas: canvas, frame: frame, style: style, standalone: standalone)
                    let rendered = try await NibSnapshot.hostedImage(probe, size: canvas, variant: .dark)
                    let image = try XCTUnwrap(rendered)
                    attach(image, name: "portrait-optics-\(Int(canvas.width))-\(style.glassKind)-\(standalone)-\(Int(frame.height))")
                    let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)))
                    XCTAssertGreaterThanOrEqual(contrast(.white, centre), 4.5)
                    // A neutral underlay protruding by the reported 8 pt is much darker than a soft shadow.
                    for x in [frame.minX - 6, frame.maxX + 6] {
                        let outside = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: x, y: frame.midY)))
                        XCTAssertGreaterThan(min(outside.r, outside.g, outside.b), 160, "No second silhouette")
                    }
                    if style.material == .deep {
                        // Exclude rounded corners, but sample the whole remaining core to catch diagonal wedges.
                        for y in stride(from: frame.minY + 40, through: frame.maxY - 40, by: 32) {
                            for x in stride(from: frame.minX + 40, through: frame.maxX - 40, by: 32) {
                                let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: x, y: y)))
                                let delta = max(abs(Int(pixel.r) - Int(centre.r)), abs(Int(pixel.g) - Int(centre.g)),
                                                abs(Int(pixel.b) - Int(centre.b)))
                                XCTAssertLessThanOrEqual(delta, 12, "Deep's core must have no optical facets or inner rim")
                                XCTAssertGreaterThanOrEqual(contrast(.white, pixel), 4.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct PortraitGlassProbe: View {
        let canvas: CGSize
        let frame: CGRect
        let style: DropletStyle
        let standalone: Bool

        var body: some View {
            ZStack {
                Color.white
                NibDropletContainer {
                    surface.position(x: frame.midX, y: frame.midY)
                }
                .nibBackdrop([CGRect(origin: .zero, size: canvas)])
            }
            .frame(width: canvas.width, height: canvas.height)
        }

        @ViewBuilder private var surface: some View {
            if standalone {
                Color.clear.frame(width: frame.width, height: frame.height)
                    .nibGlass(style.glassKind, cornerRadius: style.cornerRadius, interactive: style.isInteractive)
            } else {
                Color.clear.frame(width: frame.width, height: frame.height)
                    .droplet("portrait.optics", style: style)
            }
        }
    }

    private struct AppearanceProbe: View {
        let surface: NibGlassForegroundGallery.Surface
        let scheme: ColorScheme
        let showsContent: Bool

        var body: some View {
            NibGlassForegroundGallery(surface: surface, showsContent: showsContent)
                .environment(\.colorScheme, scheme)
                .ignoresSafeArea()
        }
    }

    private func liveImage(_ view: UIView) throws -> UIImage {
        view.layoutIfNeeded()
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "The live native compositor must produce the regression image")
        return image
    }

    func testStaticGlassCanCarryItsUnderlayOutsideAContainerWithoutTintingPaper() throws {
        let shape = NibDropletShape()
        for variant in [NibSnapshot.Variant.light, .dark] {
            // Exercise the same anchor transport without a UIKit-backed glass host, so this runs hostless too.
            let view = Color.clear
                .frame(width: 180, height: 44)
                .modifier(NibGlassBackdropModifier(kind: .clear, shape: shape))
                .frame(width: 360, height: 240)
                .backgroundPreferenceValue(NibGlassBackdropKey.self) {
                    NativeGlassBackdropLayer(backdrops: $0)
                }
                .coordinateSpace(NibLiquid.space)
                .nibBackdrop([CGRect(origin: .zero, size: size)])
                .background(Color.white)
            let image = try XCTUnwrap(NibSnapshot.image(view, size: size, variant: variant))
            let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 180, y: 120)))
            if variant == .dark {
                XCTAssertGreaterThanOrEqual(contrast(RGBA.white, centre), 4.5)
            } else {
                XCTAssertEqual(centre, RGBA.white)
            }
            XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: 20, y: 20)), RGBA.white)
        }
    }

    /// The same anchor modifier used by the live native host, without the UIKit material so geometry and
    /// contrast remain testable in the hostless package suite. Placement includes a nonzero ancestor origin.
    private func backdropProbe(frame: CGRect, style: DropletStyle, paper: [CGRect],
                               offset: CGPoint = .zero, growth: CGSize = .zero,
                               frozen: Bool = false, recedes: Bool = false) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .padding(.horizontal, growth.width / 2)
            .padding(.vertical, growth.height / 2)
            .modifier(NibGlassBackdropModifier(kind: style.glassKind,
                shape: NibDropletShape(cornerRadius: style.cornerRadius), frozen: frozen, recedes: recedes))
            .offset(x: offset.x, y: offset.y)
            .padding(.vertical, -growth.height / 2)
            .padding(.horizontal, -growth.width / 2)
            .position(x: frame.midX, y: frame.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backgroundPreferenceValue(NibGlassBackdropKey.self) { NativeGlassBackdropLayer(backdrops: $0) }
            .coordinateSpace(NibLiquid.space)
            .nibBackdrop(paper)
    }

    func testNativeUnderlayFollowsPresentedBoundsWithoutAnOffsetSilhouette() throws {
        let canvas = CGSize(width: 400, height: 700)
        let paper = CGRect(origin: .zero, size: canvas)
        for style in [DropletStyle.palette, .hud, .popover, .panel] {
            let frame = CGRect(x: 45, y: 110, width: 250, height: style.material == .deep ? 420 : 56)
            for offset in [CGPoint.zero, CGPoint(x: 28, y: -36), CGPoint(x: -18, y: 40)] {
                for growth in [CGSize.zero, CGSize(width: 22, height: 14), CGSize(width: -30, height: -18)] {
                    let rect = frame.insetBy(dx: -growth.width / 2, dy: -growth.height / 2)
                        .offsetBy(dx: offset.x, dy: offset.y)
                    let view = backdropProbe(frame: frame, style: style, paper: [paper], offset: offset, growth: growth)
                        .background(Color.white)
                    let image = try XCTUnwrap(NibSnapshot.image(view, size: canvas, variant: .dark))
                    // Across both axes there must be exactly one filled interval, matching the glass host.
                    for x in stride(from: 2.0, to: canvas.width - 2, by: 2) {
                        let point = CGPoint(x: x, y: rect.midY)
                        let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: point))
                        if x < rect.minX - 2 || x > rect.maxX + 2 {
                            XCTAssertEqual(pixel, .white, "No protruding body at \(point), \(rect)")
                        } else if x > rect.minX + 2 && x < rect.maxX - 2 {
                            XCTAssertGreaterThanOrEqual(contrast(.white, pixel), 4.5)
                        }
                    }
                    for y in stride(from: 2.0, to: canvas.height - 2, by: 2) {
                        let pixel = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: rect.midX, y: y)))
                        if y < rect.minY - 2 || y > rect.maxY + 2 { XCTAssertEqual(pixel, .white) }
                        else if y > rect.minY + 2 && y < rect.maxY - 2 {
                            XCTAssertGreaterThanOrEqual(contrast(.white, pixel), 4.5)
                        }
                    }
                }
            }
        }
    }

    func testDeepUnderlayCoreIsUniformAndFrozenBodyKeepsItsBounds() throws {
        let canvas = CGSize(width: 834, height: 1194)
        let frame = CGRect(x: 24, y: 130, width: 786, height: 760)
        for frozen in [false, true] {
            let view = backdropProbe(frame: frame, style: .panel, paper: [CGRect(origin: .zero, size: canvas)],
                                     frozen: frozen).background(Color.white)
            let image = try XCTUnwrap(NibSnapshot.image(view, size: canvas, variant: .dark))
            let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)))
            XCTAssertGreaterThanOrEqual(contrast(.white, centre), 4.5)
            // A lattice across the panel catches triangular shading and inner rims, not only its centre pixel.
            for y in stride(from: frame.minY + 40, through: frame.maxY - 40, by: 40) {
                for x in stride(from: frame.minX + 40, through: frame.maxX - 40, by: 40) {
                    XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: x, y: y)), centre)
                }
            }
            XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: frame.minX - 3, y: frame.midY)), .white)
            XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: frame.maxX + 3, y: frame.midY)), .white)
        }
    }

    func testPaperCoverageUsesTheContainerSpaceForAnInsetBackdropLayer() throws {
        let canvas = CGSize(width: 834, height: 1194)
        let frame = CGRect(x: 420, y: 600, width: 180, height: 44)
        let view = Color.clear
            .frame(width: frame.width, height: frame.height)
            .modifier(NibGlassBackdropModifier(kind: .clear, shape: NibDropletShape()))
            // The backdrop reader itself is inset, unlike a full-window field canvas.
            .backgroundPreferenceValue(NibGlassBackdropKey.self) { NativeGlassBackdropLayer(backdrops: $0) }
            .position(x: frame.midX, y: frame.midY)
            .frame(width: canvas.width, height: canvas.height)
            .coordinateSpace(NibLiquid.space)
            .nibBackdrop([frame])
            .background(Color.white)
        let image = try XCTUnwrap(NibSnapshot.image(view, size: canvas, variant: .dark))
        let centre = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertLessThan(max(centre.r, centre.g, centre.b), 85, "Full paper coverage must use the 80% body")
        XCTAssertGreaterThanOrEqual(contrast(.white, centre), 4.5)
        XCTAssertEqual(NibSnapshot.pixel(image, at: CGPoint(x: frame.minX - 3, y: frame.midY)), .white)
    }

    func testSharedChromeComponentsKeepTheirGlyphsWhenGlassChangesLocalAppearance() throws {
        let components: [(String, AnyView)] = [
            ("title", AnyView(NibBarTitle(title: "Physics", subtitle: "Page 1 of 4"))),
            ("toolbar", AnyView(NibToolbarItem(.search, label: "Search") {})),
            ("tool", AnyView(NibToolButton(tool: NibTool(id: "pen", label: "Pen", symbol: .pen),
                                            isSelected: true) {})),
            ("hud", AnyView(NibHUDText("125%", secondary: "3 of 12"))),
            ("width", AnyView(NibWidthPresetButton(diameter: 12, isSelected: true, label: "Thickness") {})),
            ("search", AnyView(NibSearchField(text: .constant(""), prompt: "Find", style: .onDroplet)
                .frame(width: 240)))
        ]
        for variant in [NibSnapshot.Variant.light, .dark] {
            var app = EnvironmentValues()
            app.colorScheme = variant.colorScheme
            let opposite: ColorScheme = variant == .dark ? .light : .dark
            for (name, component) in components {
                let reference = try XCTUnwrap(NibSnapshot.image(component, size: size, variant: variant))
                let adapted = try XCTUnwrap(NibSnapshot.image(
                    component.environment(\.colorScheme, opposite)
                        .environment(\.nibChromeAppearance, NibChromeAppearance(app)),
                    size: size, variant: variant))
                var cores = 0
                for y in 100..<140 {
                    for x in 40..<320 {
                        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        let ref = try XCTUnwrap(NibSnapshot.pixel(reference, at: point))
                        let isCore = variant == .dark ? min(ref.r, ref.g, ref.b) > 252 : max(ref.r, ref.g, ref.b) < 3
                        guard ref.a > 252, isCore else { continue }
                        cores += 1
                        let actual = try XCTUnwrap(NibSnapshot.pixel(adapted, at: point))
                        XCTAssertEqual(actual, ref, "\(name), \(variant): glass must not recolour the glyph core")
                    }
                }
                XCTAssertGreaterThan(cores, 10, "\(name): sample real full-strength glyphs")
            }
        }
    }

    private func assertHostlessForegroundGuarantees() throws {
        if #available(iOS 26.0, *) {
            let host = NibNativeGlass(effect: NibSystemGlass.of(.clear, interactive: true).glass,
                                      shape: NibDropletShape()) { Text("Foreground") }
            let structure = String(reflecting: type(of: host.body))
            XCTAssertTrue(structure.contains("Text"), structure)
            XCTAssertTrue(structure.localizedCaseInsensitiveContains("glass"), structure)
            XCTAssertTrue(structure.contains("RoundedRectangle"), "Panels must use native optical geometry")
            XCTAssertTrue(structure.contains("Capsule"), "Bars must use native optical geometry")
            XCTAssertFalse(structure.contains("NibDropletShape"), "Do not infer a glass mesh from a custom path")
            for forbidden in ["ZStack", "Overlay", "Background", "TupleView"] {
                XCTAssertFalse(structure.contains(forbidden), "Glass must wrap its foreground directly: \(structure)")
            }
        }
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let ink = UIColor.black, paper = UIColor.white
            for style in [DropletStyle.bar, .palette, .popover, .hud] {
                let field = DropletField()
                field.usesSystemGlass = true
                field.setRest("foreground", CGRect(x: 40, y: 100, width: 280, height: 44), style: style)
                defer { field.unregister("foreground") }
                let presentation = field.node("foreground").presentation
                XCTAssertTrue(presentation.isDrawn, "The first measured frame must draw without a display-link tick")
                XCTAssertTrue(DropletBodyModifier.drawsBody(style: style, presentation: presentation))
                XCTAssertEqual(style.systemGlassSpec.tintsAccent, false)
                let body = NibGlassBodyTint.resolvedColor(style.glassKind, paperShare: dark ? 1 : 0,
                                                         colorScheme: scheme)
                let background = composite(body, over: dark ? paper : ink)
                let glyph = NibUIColor.label.resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(contrast(rgba(glyph), rgba(background)), 4.5,
                                            "\(style.glassKind), \(scheme): full-strength glyphs over ink/paper")
            }
        }
    }

    private func assertHostlessAccentGuarantees() throws {
        let button = NibDropletButton(id: "library.new.button", title: "New", symbol: .plus, kind: .tinted) {}
        let modifier = try XCTUnwrap(findDroplet(in: button.body), "New must use the shared droplet modifier")
        XCTAssertEqual(modifier.style.material, .tinted)
        XCTAssertTrue(modifier.style.systemGlassSpec.tintsAccent)
        XCTAssertTrue(modifier.style.systemGlassSpec.isInteractive)
        XCTAssertTrue(DropletBodyModifier.drawsBody(style: modifier.style, presentation: DropletPresentation()))
        for scheme in [ColorScheme.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let body = NibGlassBodyTint.resolvedColor(modifier.style.glassKind, colorScheme: scheme)
            XCTAssertEqual(body, NibUIColor.accent.resolvedColor(with: traits))
            XCTAssertEqual(body.cgColor.alpha, 1, accuracy: 0.001)
            let foreground = NibUIColor.onAccent.resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(contrast(rgba(foreground), rgba(body)), scheme == .light ? 4.5 : 3)
        }
    }

    private func findDroplet(in value: Any, depth: Int = 0) -> DropletModifier? {
        if let modifier = value as? DropletModifier { return modifier }
        guard depth < 24 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let modifier = findDroplet(in: child.value, depth: depth + 1) { return modifier }
        }
        return nil
    }

    private func rgba(_ color: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return RGBA(UInt8((r * 255).rounded()), UInt8((g * 255).rounded()),
                    UInt8((b * 255).rounded()), UInt8((a * 255).rounded()))
    }

    private func composite(_ color: UIColor, over backdrop: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertTrue(backdrop.getRed(&br, green: &bg, blue: &bb, alpha: &ba))
        return UIColor(red: r * a + br * (1 - a), green: g * a + bg * (1 - a),
                       blue: b * a + bb * (1 - a), alpha: 1)
    }

    private func capture(_ surface: NibGlassForegroundGallery.Surface, glass: Bool = true,
                         showsContent: Bool = true, variant: NibSnapshot.Variant) async throws -> UIImage {
        let image = try await NibSnapshot.hostedImage(
            NibGlassForegroundGallery(surface: surface, glass: glass, showsContent: showsContent),
            size: size, variant: variant)
        return try XCTUnwrap(image, "The live compositor must render the snapshot")
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func luminance(_ pixel: RGBA) -> Double {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel.r) + 0.7152 * linear(pixel.g) + 0.0722 * linear(pixel.b)
    }

    private func contrast(_ foreground: RGBA, _ background: RGBA) -> Double {
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
