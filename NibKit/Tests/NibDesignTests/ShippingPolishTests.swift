import XCTest
import SwiftUI
import UIKit
import NibTesting
@testable import NibDesign

@MainActor
final class ShippingPolishTests: XCTestCase {
    func testLiquidOffReachesExistingAndNewCanvasHandles() async throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let controller = UIViewController()
        controller.view = parent
        let window = UIWindow(frame: parent.bounds)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let handle = NibHandleView()
        parent.addSubview(handle)
        let frame = NibFrameView(frame: CGRect(x: 0, y: 60, width: 200, height: 80))
        parent.addSubview(frame)
        parent.traitOverrides[NibLiquidModeTrait.self] = .off
        try await Task.sleep(for: .milliseconds(30))
        parent.layoutIfNeeded()
        XCTAssertEqual(handle.traitCollection[NibLiquidModeTrait.self], .off)
        handle.layoutIfNeeded()
        let body = try XCTUnwrap(handle.layer.sublayers?.first as? CAShapeLayer)
        let rim = try XCTUnwrap(handle.layer.sublayers?.compactMap { $0 as? NibDirectionalRimLayer }.first)
        XCTAssertTrue(rim.isHidden)
        XCTAssertTrue(try XCTUnwrap(frame.layer.sublayers?.first).isHidden)
        XCTAssertEqual(body.shadowOpacity, 0)
        XCTAssertNil(body.shadowPath)
        XCTAssertEqual(body.fillColor, NibUIColor.chromeOpaque.resolvedColor(with: handle.traitCollection).cgColor)
        let tinted = NibHandleView(style: .tinted)
        parent.addSubview(tinted)
        try await Task.sleep(for: .milliseconds(30))
        tinted.layoutIfNeeded()
        XCTAssertEqual(tinted.layer.sublayers?.first?.shadowOpacity, 0)
        XCTAssertEqual((tinted.layer.sublayers?.first as? CAShapeLayer)?.fillColor,
                       NibUIColor.accent.resolvedColor(with: tinted.traitCollection).cgColor)
        parent.traitOverrides[NibLiquidModeTrait.self] = .full
        try await Task.sleep(for: .milliseconds(30))
        handle.layoutIfNeeded()
        XCTAssertFalse(rim.isHidden)
        XCTAssertGreaterThan(body.shadowOpacity, 0)
    }

    func testUIKitRimUsesKeyAndHalfStrengthCounterWithinAHairline() throws {
        let rim = NibDirectionalRimLayer()
        rim.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        rim.cornerRadius = 20
        rim.rimColor = UIColor.white.cgColor
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        let image = UIGraphicsImageRenderer(size: rim.bounds.size, format: format).image { context in
            rim.draw(in: context.cgContext)
        }
        // Sample the two diagonal peaks, away from antialiased outer coverage.
        let key = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 6.1, y: 6.1)))
        let counter = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 33.7, y: 33.7)))
        XCTAssertGreaterThan(key.a, 160)
        XCTAssertGreaterThan(counter.a, 60)
        XCTAssertLessThan(counter.a, key.a)
        XCTAssertEqual(Double(counter.a) / Double(key.a), 0.5, accuracy: 0.18)
        let core = try XCTUnwrap(NibSnapshot.pixel(image, at: CGPoint(x: 7.5, y: 7.5)))
        XCTAssertEqual(core.a, 0, "The obsolete ~1.9 pt crescent must not return")
    }

    func testOpaqueStandaloneGlassHasNoShadowOutsideItsOutline() throws {
        for kind in [NibGlass.clear, .deep, .tinted, .bead] {
            let surface = NibGlassModifier(kind: kind, shape: NibDropletShape(cornerRadius: 12), interactive: false)
            let image = try XCTUnwrap(NibSnapshot.image(
                surface.opaque.frame(width: 80, height: 40).padding(12), size: CGSize(width: 104, height: 64)))
            for point in [CGPoint(x: 52, y: 56), CGPoint(x: 6, y: 32), CGPoint(x: 97, y: 32)] {
                XCTAssertEqual(try XCTUnwrap(NibSnapshot.pixel(image, at: point)).a, 0)
            }
        }
    }

    func testDeepFrostStopsInsideTheOriginalRimWithConcentricCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
        for radius in [CGFloat?.none, 12, 100] {
            let shape = NibDropletShape(cornerRadius: radius)
            let frost = NibFrostShape(shape: shape).path(in: bounds)
            let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
            XCTAssertEqual(frost.boundingRect, inner)
            let expectedRadius = min(radius ?? 30, 30) - 1.5
            XCTAssertEqual(frost, NibDropletShape(cornerRadius: expectedRadius).path(in: inner))
            XCTAssertEqual(shape.path(in: bounds).boundingRect, bounds)
        }
    }

    func testShortChipsOwnFullTargetsAndSelectedChipsHaveAShapeCue() {
        for variant in [NibSnapshot.Variant.light, .largeText] {
            let off = NibSnapshot.fittingSize(NibChip("All", style: .filter(isSelected: false), action: {}),
                                              width: 300, variant: variant)
            let on = NibSnapshot.fittingSize(NibChip("All", style: .filter(isSelected: true), action: {}),
                                             width: 300, variant: variant)
            XCTAssertGreaterThanOrEqual(off.width, 44)
            XCTAssertGreaterThanOrEqual(off.height, 44)
            XCTAssertGreaterThan(on.width, off.width, "Selected filters include a checkmark")
        }
    }

    func testPaperNamesGrowRatherThanTruncateAtAccessibilitySizes() {
        for width in [CGFloat(88), 104] {
            let short = NibPaperTile(name: "Dots", isSelected: false, size: CGSize(width: width, height: 135), action: {}) {
                Color.white
            }
            let long = NibPaperTile(name: "Engineering grid with margin", isSelected: false,
                                    size: CGSize(width: width, height: 135), action: {}) { Color.white }
            let shortSize = NibSnapshot.fittingSize(short, width: width, variant: .largeText)
            let longSize = NibSnapshot.fittingSize(long, width: width, variant: .largeText)
            XCTAssertEqual(longSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(longSize.height, shortSize.height + 40)
        }
    }

    func testFolderNamesWrapAndGrowWithinTheirGridColumns() {
        for variant in [NibSnapshot.Variant.light, .dark, .largeText] {
            let allowedLines = variant == .largeText ? 3 : 2
            for width in [NibMetrics.folderTileMinWidth, NibMetrics.folderTileMinWidth + NibMetrics.libraryGutter * 2] {
                func size(_ name: String) -> CGSize {
                    NibSnapshot.fittingSize(NibFolderTile(name: name, count: "9", color: NibColor.accent),
                                            width: width, variant: variant)
                }
                let short = size("A")
                let long = size("Semester notes and assignments for computer science")
                // Explicit line breaks provide a measured reference, independent of word wrapping or font metrics.
                let full = size(Array(repeating: "A", count: allowedLines).joined(separator: "\n"))
                let overflow = size(Array(repeating: "A", count: allowedLines + 1).joined(separator: "\n"))
                XCTAssertEqual(short.width, width, accuracy: 1)
                XCTAssertEqual(long.width, width, accuracy: 1, "Names must not widen the grid column")
                XCTAssertGreaterThanOrEqual(short.height, NibMetrics.folderTileHeight)
                XCTAssertGreaterThan(long.height, short.height, "Long names must wrap beyond one line and grow the tile")
                XCTAssertEqual(long.height, full.height, accuracy: 1, "The long name uses every allowed line")
                XCTAssertEqual(overflow.height, full.height, accuracy: 1, "Further lines truncate instead of growing indefinitely")
                if variant == .largeText {
                    XCTAssertGreaterThan(long.height, size("A\nA").height, "Accessibility names use a third line")
                } else {
                    XCTAssertEqual(short.height, NibMetrics.folderTileHeight, accuracy: 1)
                }
            }
        }
    }

    func testSegmentsReflowWhenLabelsCannotFit() {
        let control = NibSegmentedControl(selection: .constant(0), options: [0, 1, 2]) {
            ["Always ask", "Ask for destructive changes", "Allow all changes"][$0]
        }
        let wide = NibSnapshot.fittingSize(control, width: 900)
        let narrow = NibSnapshot.fittingSize(control, width: 220)
        let accessible = NibSnapshot.fittingSize(control, width: 320, variant: .largeText)
        XCTAssertLessThanOrEqual(wide.height, 50)
        XCTAssertLessThanOrEqual(narrow.width, 220)
        XCTAssertGreaterThanOrEqual(narrow.height, 44 * 3)
        XCTAssertLessThanOrEqual(accessible.width, 320)
        XCTAssertGreaterThan(accessible.height, narrow.height)
    }

    func testFittingSegmentsShareNarrowRowsAndPreserveAccessibleFallback() {
        let tabs = ["Pages", "Outline", "Bookmarks"]
        let control = NibSegmentedControl(selection: .constant("Pages"), options: tabs, sizing: .fitting) { $0 }
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let size = NibSnapshot.fittingSize(control.environment(\.layoutDirection, direction), width: 240)
            XCTAssertEqual(size.width, 240, accuracy: 1)
            XCTAssertEqual(size.height, NibMetrics.hitTarget, accuracy: 1,
                           "The 240 pt page switcher must remain a single row")
        }
        let tooNarrow = NibSnapshot.fittingSize(control, width: 100)
        XCTAssertLessThanOrEqual(tooNarrow.width, 100)
        XCTAssertGreaterThanOrEqual(tooNarrow.height, 3 * NibMetrics.hitTarget)
        let accessible = NibSnapshot.fittingSize(control, width: 240, variant: .largeText)
        XCTAssertLessThanOrEqual(accessible.width, 240)
        XCTAssertGreaterThanOrEqual(accessible.height, 3 * NibMetrics.hitTarget)

        for labels in [["Left", "Centre", "Right", "Justify"], ["Auto", "1.15", "1.5", "2"],
                       ["Always ask", "Ask for destructive changes", "Allow all changes"]] {
            let fitting = NibSegmentedControl(selection: .constant(labels[0]), options: labels, sizing: .fitting) { $0 }
            let size = NibSnapshot.fittingSize(fitting, width: 280)
            XCTAssertEqual(size.width, 280, accuracy: 1, "Paragraph rows must align at the right edge")
            XCTAssertEqual(size.height, NibMetrics.hitTarget, accuracy: 1,
                           "Long labels truncate at the existing type size instead of forcing a stack")
        }
    }

    func testPageSwitcherLabelsFitAt240PointsBeforeTruncation() {
        let sizing = NibSegmentedControl<String>.Sizing.fitting
        // SidebarHost has 4 pt outer insets; the track has 2 pt inner insets.
        let labelWidth = (240 - 2 * NibSpacing.xs - 4) / 3 - 2 * sizing.labelPadding
        let font = UIFont.preferredFont(forTextStyle: .footnote,
                                       compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let selected = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold)!, size: font.pointSize)
        for label in ["Pages", "Outline", "Bookmarks"] {
            for face in [font, selected] {
                let width = (label as NSString).size(withAttributes: [.font: face]).width
                XCTAssertLessThanOrEqual(width * sizing.minimumLabelScale, labelWidth,
                                         "\(label) must fit even when selected")
            }
        }
        XCTAssertGreaterThanOrEqual(sizing.minimumLabelScale, 0.85)
        XCTAssertEqual(NibSegmentedControl<String>.Sizing.intrinsic.labelPadding, NibSpacing.m)
        XCTAssertEqual(NibSegmentedControl<String>.Sizing.intrinsic.minimumLabelScale, 1)
    }

    func testCompactFittingSegmentsPreserveTargetsAndAccessibleFallbackBesideMenu() {
        let tabs = ["Pages", "Outline", "Bookmarks"]
        let control = NibSegmentedControl(selection: .constant("Bookmarks"), options: tabs,
                                          sizing: .compactFitting) { $0 }
        let width = NibMetrics.navigatorWidth - NibMetrics.hitTarget - 2 * NibSpacing.xs
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let size = NibSnapshot.fittingSize(control.environment(\.layoutDirection, direction), width: width)
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertEqual(size.height, NibMetrics.hitTarget, accuracy: 1)
        }
        let accessible = NibSnapshot.fittingSize(control, width: width, variant: .largeText)
        XCTAssertLessThanOrEqual(accessible.width, width)
        XCTAssertGreaterThanOrEqual(accessible.height, 3 * NibMetrics.hitTarget)
    }

    func testPanelHeaderPreservesLongProviderAndKeyInformation() {
        let header = NibPanelHeader(title: "Assistant",
            subtitle: "OpenAI-compatible provider · Local language model · API key is not configured",
            symbol: .search, onClose: {}) {
                NibIconButton(.more, label: "More") {}
            }
        let regular = NibSnapshot.fittingSize(header, width: 312)
        let accessible = NibSnapshot.fittingSize(header, width: 312, variant: .largeText)
        XCTAssertLessThanOrEqual(regular.width, 312)
        XCTAssertLessThanOrEqual(accessible.width, 312)
        XCTAssertGreaterThan(accessible.height, regular.height + 40)
    }

    func testPluginChromeAcceptsTheNarrowViewportAtAccessibilityFive() {
        let chrome = NibPluginPanelChrome(name: "Word Count", symbol: .puzzle, onReload: {},
                                         onPermissions: {}, onReport: {}, onClose: {}) {
            Color.clear
        }
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.dynamicTypeSize, .accessibility5)
        let host = UIHostingController(rootView: chrome)
        let size = host.sizeThatFits(in: CGSize(width: 300, height: 560))
        XCTAssertEqual(size.width, 300, accuracy: 1,
                       "Both sidebars can leave only 300 pt; plugin chrome must not insist on 420 pt")
        XCTAssertLessThanOrEqual(size.height, 560)
    }
}
