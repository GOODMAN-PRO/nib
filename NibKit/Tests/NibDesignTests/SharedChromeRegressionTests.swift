import XCTest
import SwiftUI
import UIKit
import QuartzCore
import NibTesting
import NibContracts
@testable import NibDesign

@MainActor
final class SharedChromeRegressionTests: XCTestCase {
    func testNativePopoverActionRemainsHittableAndTracksDisabledStateAcrossRefresh() async throws {
        var count = 0
        func content(_ enabled: Bool) -> AnyView {
            AnyView(NibButton("Custom Colour") { count += 1 }
                .nibNativeAction { count += 1 }
                .disabled(!enabled))
        }
        let host = UIHostingController(rootView: content(true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func taps(_ view: UIView) -> [NibActionTapRecognizer] {
            (view.gestureRecognizers ?? []).compactMap { $0 as? NibActionTapRecognizer }
                + view.subviews.flatMap(taps)
        }
        for enabled in [true, false, true] {
            host.rootView = content(enabled)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let actions = taps(host.view)
            XCTAssertEqual(actions.count, 1)
            let tap = try XCTUnwrap(actions.first)
            XCTAssertEqual(tap.isEnabled, enabled)
            if enabled {
                let target = try XCTUnwrap(tap.view)
                let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: host.view)
                let hit = try XCTUnwrap(host.view.hitTest(point, with: nil))
                XCTAssertTrue(hit.isDescendant(of: target), "The native gesture must receive the control's touches")
                XCTAssertFalse(target.point(inside: CGPoint(x: -1, y: -1), with: nil))
                target.isHidden = true
                XCTAssertFalse(host.view.hitTest(point, with: nil) === target, "A hidden control cannot receive taps")
                target.isHidden = false
                let before = count
                tap.activate()
                XCTAssertEqual(count, before + 1)
            }
        }
    }

    func testPaletteTouchOwnershipSurvivesHostingButYieldsToScrollingAndHolds() {
        let tap = NibActionTapRecognizer()
        XCTAssertFalse(tap.canBePrevented(by: UIGestureRecognizer()))
        XCTAssertFalse(tap.canBePrevented(by: UITapGestureRecognizer()))
        XCTAssertTrue(tap.canBePrevented(by: UIPanGestureRecognizer()))
        XCTAssertTrue(tap.canBePrevented(by: UILongPressGestureRecognizer()))
        var count = 0
        tap.action = { count += 1 }
        tap.activate()
        XCTAssertEqual(count, 1)
    }

    func testRetainedPopoverStopsNativeScrollingAndHitTestingAcrossRelayouts() async throws {
        func panel(_ presented: Bool, width: CGFloat) -> some View {
            NibPopoverPanel(title: "Apple Pencil", width: width, maxHeight: 220) {
                ForEach(0..<24) { index in
                    Button("Preference \(index)") {}
                        .frame(minHeight: NibMetrics.hitTarget)
                }
            }
            .budsFrom("settings", isPresented: .constant(presented))
        }
        let host = UIHostingController(rootView: panel(true, width: 312))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 760, height: 706))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func scroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<5 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let original = try XCTUnwrap(scroll(in: host.view))
        XCTAssertGreaterThan(original.contentSize.height, original.bounds.height)
        original.setContentOffset(CGPoint(x: 0, y: 180), animated: false)

        // Closing, relayout while closed, then reopening must retain the content and
        // scroll position, but never leave an invisible native input surface on top.
        for (presented, width) in [(false, CGFloat(312)), (false, 280), (true, 280)] {
            host.rootView = panel(presented, width: width)
            try await settle()
            let current = try XCTUnwrap(scroll(in: host.view))
            XCTAssertTrue(current === original, "Keep the user's position in a long preferences panel")
            XCTAssertEqual(current.isScrollEnabled, presented)
            XCTAssertEqual(current.isUserInteractionEnabled, presented)
            XCTAssertEqual(current.accessibilityElementsHidden, !presented)
            if !presented {
                XCTAssertNil(current.hitTest(CGPoint(x: current.bounds.midX, y: current.bounds.midY), with: nil),
                             "A closed popover must not consume the next navigation or preset tap")
                // Reproduce UIKit refreshing the retained host after the probe disabled it.
                // SwiftUI's source-level gate must still protect the controls underneath.
                current.isUserInteractionEnabled = true
                let point = current.convert(CGPoint(x: current.bounds.midX, y: current.bounds.midY), to: host.view)
                let hit = host.view.hitTest(point, with: nil)
                XCTAssertFalse(hit?.isDescendant(of: current) == true,
                               "A native host refresh must not resurrect a closed menu's hit target")
                current.isUserInteractionEnabled = false
            } else {
                let point = current.convert(CGPoint(x: current.bounds.midX, y: current.bounds.midY), to: host.view)
                XCTAssertTrue(host.view.hitTest(point, with: nil)?.isDescendant(of: current) == true,
                              "Reopening must restore actual interaction with preferences")
            }
            XCTAssertEqual(current.contentOffset.y, 180, accuracy: 1)
        }
    }

    func testPlannerFormAdaptsToAConstrainedViewportWithoutLosingDateAndWeekControls() async throws {
        // A keyboard, landscape phone or resized iPad window supplies a finite height,
        // unlike the ideal-size query below. The default must not force a 640 pt form
        // outside that viewport, and the list must still scroll to its lower controls.
        for size in [CGSize(width: 720, height: 320), CGSize(width: 390, height: 460)] {
            let host = UIHostingController(rootView: SheetViewportFixture().modifier(NibSheetChrome())
                .ignoresSafeArea())
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            func list(in view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap { list(in: $0) }.first
            }
            for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let scroll = try XCTUnwrap(list(in: host.view))
            // SwiftUI List may extend its native scroll view under the header and
            // reserve that space with adjustedContentInset instead of its frame.
            let frame = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.view)
            XCTAssertGreaterThan(frame.height, 200, "Planner controls need more than a single-row viewport")
            XCTAssertGreaterThanOrEqual(frame.minY, 60, "Scrolling content must clear the sheet header")
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
            XCTAssertGreaterThan(scroll.contentSize.height, 0)
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            host.view.layoutIfNeeded()
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1,
                           "The date and count rows must remain reachable in the constrained form")
        }
    }

    func testClosedPopoverDoesNotCoverAnEditableTextView() async throws {
        // A retained native popover used to consume a tap even after its SwiftUI
        // content had disappeared. Exercise the underlying input hit target too.
        let host = UIHostingController(rootView:
            NibPopoverPanel(title: "Menu") { Button("Action") {} }
                .budsFrom("source", isPresented: .constant(false)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func list(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let scroll = try XCTUnwrap(list(in: host.view))
        XCTAssertNil(scroll.hitTest(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), with: nil),
                     "A closed menu must not claim the text editor's touch")
        let parent = try XCTUnwrap(scroll.superview)
        let input = UITextView(frame: scroll.frame)
        parent.insertSubview(input, belowSubview: scroll)
        let point = CGPoint(x: input.frame.midX, y: input.frame.midY)
        let hit = try XCTUnwrap(parent.hitTest(point, with: nil))
        XCTAssertTrue(hit === input || hit.isDescendant(of: input),
                      "The input behind the retained popover must receive the tap")
        XCTAssertTrue(input.becomeFirstResponder())
        input.insertText("First block title")
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertEqual(input.text, "First block title")
    }

    func testFormSheetLeavesAUsableViewportForANativeList() async throws {
        // Package tests have no UIWindowScene to present a modal. Exercise the same ideal
        // size query used by presentationSizing, with a real hosted native list instead.
        let content = SheetViewportFixture().modifier(NibSheetChrome())
            .fixedSize(horizontal: false, vertical: true)
        let host = UIHostingController(rootView: content)
        // This is a form-content measurement, not a full-screen hosting controller.
        // A hostless UIWindow's status/home safe areas are not part of the 640 pt form.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let size = host.sizeThatFits(in: CGSize(width: 720, height: 1366))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        func list(in view: UIView) -> UIScrollView? {
            if let list = view as? UIScrollView { return list }
            return view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let visible = try XCTUnwrap(list(in: host.view), "The form must contain the native list")
        XCTAssertGreaterThan(visible.bounds.height, 300,
                             "Intrinsic-height fitting must not collapse a planner form to one row")
        XCTAssertEqual(size.height, NibMetrics.newDocumentSheetSize.height, accuracy: 1)
        // Existing explicitly sized and small intrinsic sheets remain backward compatible.
        for height in [CGFloat(160), 640] {
            let fixed = Color.clear.frame(width: 720, height: height).modifier(NibSheetChrome())
                .fixedSize(horizontal: false, vertical: true)
            XCTAssertEqual(NibSnapshot.fittingSize(fixed, width: 720).height, height, accuracy: 1)
        }
    }

    func testClosedPopoverDisablesItsNativeScrollHitTargetAndReopens() async throws {
        func panel(_ presented: Bool) -> some View {
            NibPopoverPanel(title: "Menu") { Button("Action") {} }
                .budsFrom("source", isPresented: .constant(presented))
        }
        let host = UIHostingController(rootView: panel(false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func scrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let scroll = try XCTUnwrap(scrollView(host.view))
        XCTAssertFalse(scroll.isUserInteractionEnabled, "A hidden menu must not consume taps on Library or sidebar buttons")
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        host.rootView = panel(true)
        for _ in 0..<5 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(scroll.isUserInteractionEnabled, "The same retained popover must become interactive when reopened")
        XCTAssertFalse(scroll.accessibilityElementsHidden)
    }

    func testToastDoesNotCaptureOutsideTapsOrPopoverDismissal() {
        let field = DropletField()
        field.reduceMotion = true
        field.setWorldAnchor("source", CGRect(x: 300, y: 700, width: 1, height: 1))
        field.setRest("toast", CGRect(x: 100, y: 620, width: 400, height: 48), style: .toast)
        var toastDismissed = false
        field.setBud("toast", source: "source", presented: true, instant: true) { toastDismissed = true }
        XCTAssertTrue(field.node("toast").presentation.isDrawn)
        XCTAssertFalse(field.hasOpenBud, "A toast must leave navigation and library cells interactive")

        field.setRest("menu", CGRect(x: 100, y: 200, width: 300, height: 200), style: .popover)
        var menuDismissed = false
        field.setBud("menu", source: "source", presented: true, instant: true) { menuDismissed = true }
        XCTAssertTrue(field.hasOpenBud)
        field.dismissBuds()
        XCTAssertTrue(menuDismissed)
        XCTAssertFalse(toastDismissed, "Outside dismissal belongs to the menu, not the Undo notification")
        field.unregister("menu")
        field.unregister("toast")
    }

    func testReducedMotionBudsStayAtTheirFinalMeasuredPosition() {
        for mode in [NibLiquidMode.full, .off] {
            let field = DropletField()
            field.mode = mode
            field.reduceMotion = mode == .full
            field.setWorldAnchor("source", CGRect(x: 700, y: 16, width: 96, height: 44))
            field.setRest("menu", CGRect(x: 0, y: 0, width: 312, height: 200), style: .popover)
            field.setBud("menu", source: "source", presented: true, instant: false, dismiss: {})
            _ = field.tick(1.0 / 120)

            // Content height and the source frame arrive in separate layout passes after opening.
            for frame in [CGRect(x: 506, y: 80, width: 312, height: 200),
                          CGRect(x: 506, y: 80, width: 312, height: 460)] {
                field.setRest("menu", frame, style: .popover)
                XCTAssertEqual(field.visualFrame("menu"), frame, "\(mode)")
                XCTAssertEqual(field.node("menu").presentation.contentTransform, .identity)
                XCTAssertTrue(field.node("menu").presentation.isDrawn)
                _ = field.tick(1.0 / 120)
                XCTAssertEqual(field.visualFrame("menu"), frame, "A fade must not move the popover")
            }
            field.unregister("menu")
        }
    }

    func testInitialMeasurementsDoNotAnimateButSubsequentMovesDo() {
        let field = DropletField()
        let provisional = CGRect(x: -48, y: -22, width: 96, height: 44)
        let placed = CGRect(x: 0, y: 0, width: 96, height: 44)
        field.setRest("new", provisional, style: .primary)
        field.setRest("new", placed, style: .primary)
        XCTAssertEqual(field.node("new").presentation.contentTransform, .identity)
        XCTAssertEqual(field.visualFrame("new"), placed)

        _ = field.tick(1.0 / 120)
        field.setRest("new", placed.offsetBy(dx: 100, dy: 0), style: .primary)
        XCTAssertEqual(field.node("new").presentation.contentTransform.tx, -100, accuracy: 0.01)
        XCTAssertEqual(field.visualFrame("new"), placed)
    }

    func testRestingControlsPublishGeometryWithoutAFrameTickEvenWhileInking() {
        for frozen in [false, true] {
            let field = DropletField()
            field.usesSystemGlass = true
            field.setInking(frozen)
            for (index, style) in [DropletStyle.bar, .primary, .hud, .palette].enumerated() {
                let id = "control.\(index)"
                let frame = CGRect(x: 20, y: CGFloat(20 + index * 80), width: 180, height: 44)
                let node = field.node(id)
                field.setRest(id, .zero, style: style)
                XCTAssertFalse(node.presentation.isDrawn)
                field.setRest(id, frame, style: style)
                XCTAssertTrue(node.presentation.isDrawn)
                XCTAssertEqual(node.presentation.restSize, frame.size)
                XCTAssertEqual(node.presentation.bodySize, frame.size)
                XCTAssertTrue(DropletBodyModifier.drawsBody(style: style, presentation: node.presentation))
                // Invalid transient geometry must never erase a working body.
                field.setRest(id, .zero, style: style)
                XCTAssertEqual(node.presentation.bodySize, frame.size)
                field.unregister(id)
                XCTAssertTrue(node === field.node(id), "Layout reattachment retains the glass node identity")
                XCTAssertFalse(node.presentation.isDrawn)
                field.setRest(id, frame, style: style)
                XCTAssertTrue(node.presentation.isDrawn)
                field.unregister(id)
            }
        }
    }

    func testClosedBudsAndDryCoversHaveNoNativeGlassHost() {
        var closed = DropletPresentation(hidden: true, hasBud: true)
        closed.isDrawn = true // a stale measurement must not resurrect a closed host
        XCTAssertFalse(DropletBodyModifier.drawsBody(style: .popover, presentation: closed, isBud: true))
        XCTAssertFalse(DropletBodyModifier.drawsBody(style: .popover, presentation: DropletPresentation(),
                                                    isBud: true, requestedHidden: true))
        XCTAssertFalse(DropletBodyModifier.drawsBody(style: .card, presentation: DropletPresentation()))
        XCTAssertFalse(DropletBodyModifier.drawsBody(style: .frame, presentation: DropletPresentation()))
        XCTAssertTrue(DropletBodyModifier.drawsBody(style: .bar, presentation: DropletPresentation()))
    }

    func testDismissalCompletesWithMissingRemovedAndLiveSources() {
        for sourceExists in [false, true] {
            for removeSource in [false, true] {
                let field = DropletField()
                let source = CGRect(x: 80, y: 700, width: 44, height: 44)
                if sourceExists { field.setRest("source", source, style: .bar) }
                field.setRest("bud", CGRect(x: 30, y: 180, width: 312, height: 500), style: .popover)
                field.setBud("bud", source: "source", presented: true, instant: true, dismiss: {})
                _ = field.tick(1.0 / 60)
                XCTAssertTrue(field.node("bud").presentation.isDrawn)
                if removeSource { field.unregister("source") }
                field.setBud("bud", source: "source", presented: false, instant: false, dismiss: {})
                let now = CACurrentMediaTime()
                for frame in 1...120 { _ = field.tick(1.0 / 60, now: now + Double(frame) / 60) }
                let p = field.node("bud").presentation
                XCTAssertTrue(p.hidden)
                XCTAssertFalse(p.isDrawn)
                XCTAssertFalse(p.revealed)
                XCTAssertFalse(field.hasOpenBud)
                XCTAssertFalse(field.clusters.flatMap(\.renders).contains { $0.id == "bud" })
                XCTAssertFalse(field.necks.contains { $0.id.contains("bud") })
                XCTAssertFalse(field.tick(1.0 / 60, now: now + 3), "A closed bud must not keep the display link running")
                field.setBud("bud", source: "source", presented: true, instant: true, dismiss: {})
                XCTAssertTrue(field.node("bud").presentation.isDrawn, "Retained content can reopen")
                field.setBud("bud", source: "source", presented: false, instant: true, dismiss: {})
                XCTAssertFalse(field.node("bud").presentation.isDrawn)
                XCTAssertFalse(field.clusters.flatMap(\.renders).contains { $0.id == "bud" })
                field.unregister("bud")
                field.unregister("source")
            }
        }
    }

    func testPopoverFlipsAtEveryEdgeAndClampsBothAxes() {
        for bounds in [CGRect(x: 0, y: 0, width: 393, height: 852),
                       CGRect(x: 0, y: 0, width: 852, height: 350),
                       CGRect(x: 20, y: 40, width: 834, height: 1094)] {
            let anchors: [(NibBudPlacement, CGRect)] = [
                (.below, CGRect(x: bounds.maxX - 64, y: bounds.maxY - 60, width: 44, height: 44)),
                (.above, CGRect(x: bounds.minX + 20, y: bounds.minY + 16, width: 44, height: 44)),
                (.leading, CGRect(x: bounds.minX + 16, y: bounds.maxY - 60, width: 44, height: 44)),
                (.trailing, CGRect(x: bounds.maxX - 60, y: bounds.minY + 16, width: 44, height: 44))
            ]
            for (placement, anchor) in anchors {
                let available = placement.availableSize(beside: anchor, gap: 16, in: bounds)
                let size = CGSize(width: min(312, available.width), height: min(520, available.height))
                let centre = placement.centre(size: size, beside: anchor, gap: 16, in: bounds)
                let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                   width: size.width, height: size.height)
                let inset = bounds.insetBy(dx: 16, dy: 16)
                XCTAssertGreaterThanOrEqual(frame.minX, inset.minX)
                XCTAssertGreaterThanOrEqual(frame.minY, inset.minY)
                XCTAssertLessThanOrEqual(frame.maxX, inset.maxX)
                XCTAssertLessThanOrEqual(frame.maxY, inset.maxY)
                switch placement {
                case .below: XCTAssertLessThanOrEqual(frame.maxY, anchor.minY - 16)
                case .above: XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY + 16)
                case .leading: XCTAssertGreaterThanOrEqual(frame.minX, anchor.maxX + 16)
                case .trailing: XCTAssertLessThanOrEqual(frame.maxX, anchor.minX - 16)
                }
            }
        }
    }

    func testLongPopoverUsesBoundedScrollViewportAtAX3() {
        let panel = NibPopoverPanel(title: "New Notebook", width: 312, maxHeight: 180) {
            ForEach(0..<30) { Text("Command \($0)").frame(minHeight: NibMetrics.hitTarget) }
        }
        for variant in [NibSnapshot.Variant.light, .largeText] {
            let size = NibSnapshot.fittingSize(panel, width: 312, variant: variant)
            XCTAssertEqual(size.width, 312, accuracy: 0.01)
            XCTAssertEqual(size.height, 180, accuracy: 0.01)
        }
        XCTAssertTrue(String(reflecting: type(of: panel.body)).contains("ScrollView"))
    }

    func testSceneResolvedUnderlaysIgnoreAmbientTraitsAndLeavePaperWhite() {
        for scheme in [ColorScheme.light, .dark] {
            let opposite = UITraitCollection(userInterfaceStyle: scheme == .dark ? .light : .dark)
            let clear = UIColor(NibGlassBodyTint.color(.clear, paperShare: 1, colorScheme: scheme))
                .resolvedColor(with: opposite)
            XCTAssertEqual(clear.cgColor.alpha, scheme == .dark ? 0.8 : 0.46, accuracy: 0.001)
            let underlay = UIColor(NibGlassBodyTint.systemUnderlay(.deep, colorScheme: scheme, paperShare: 1))
                .resolvedColor(with: opposite)
            XCTAssertEqual(underlay.cgColor.alpha, scheme == .dark ? 0.86 : 0, accuracy: 0.001)
            XCTAssertEqual(NibPaper.white.uiColor.resolvedColor(with: opposite),
                           NibPaper.white.uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        }
    }

    func testCarrierKeepsSourceHiddenUntilLandingAndUsesOnlyCoverBounds() {
        let reflow = NibReflow<String>(combines: false)
        let first = UUID(), second = UUID()
        reflow.attachCarrier(first)
        reflow.attachCarrier(second)
        reflow.frames["book"] = CGRect(x: 24, y: 32, width: 140, height: 240)
        reflow.coverFrames["book"] = CGRect(x: 24, y: 32, width: 140, height: 182)
        reflow.begin("book", order: ["book"], at: CGPoint(x: 94, y: 123))
        XCTAssertEqual(reflow.carrierFrame, reflow.coverFrames["book"])
        XCTAssertTrue(reflow.hidesSource("book"))
        XCTAssertEqual(DropletStyle.card.envelope, 3)
        reflow.detachCarrier(first)
        XCTAssertTrue(reflow.hidesSource("book"), "An old host disappearing must not reveal an active carrier's source")
        _ = reflow.end()
        XCTAssertTrue(reflow.hidesSource("book"), "Keep hiding throughout the release animation")
        reflow.landed()
        XCTAssertFalse(reflow.hidesSource("book"))
        reflow.detachCarrier(second)
        XCTAssertFalse(reflow.hasCarrier)
    }

    func testDocumentCarrierOmitsCaptionLayout() {
        let card = NibDocumentCard(title: "A long notebook title", subtitle: "12 pages") { Color.white }
        let lifted = NibSnapshot.fittingSize(card.environment(\.nibReflowCoverOnly, true), width: 140)
        let resting = NibSnapshot.fittingSize(card, width: 140)
        XCTAssertEqual(lifted, NibMetrics.coverSize)
        XCTAssertGreaterThan(resting.height, lifted.height)
    }

    func testSelectedIconHasANeutralOutlineAndKeepsItsHitTarget() throws {
        for variant in [NibSnapshot.Variant.light, .dark] {
            let on = NibIconButton(.search, label: "Pages", isOn: true) {}
            let off = NibIconButton(.search, label: "Pages") {}
            let size = CGSize(width: 44, height: 44)
            let selected = try XCTUnwrap(NibSnapshot.image(on, size: size, variant: variant))
            let unselected = try XCTUnwrap(NibSnapshot.image(off, size: size, variant: variant))
            // The top of the circle has no glyph: its presence is a shape cue, independent of accent hue.
            let edge = try XCTUnwrap(NibSnapshot.pixel(selected, at: CGPoint(x: 22, y: 3)))
            let empty = try XCTUnwrap(NibSnapshot.pixel(unselected, at: CGPoint(x: 22, y: 3)))
            XCTAssertGreaterThan(Int(edge.a), Int(empty.a) + 100)
            XCTAssertLessThanOrEqual(abs(Int(edge.r) - Int(edge.g)), 2)
            XCTAssertLessThanOrEqual(abs(Int(edge.g) - Int(edge.b)), 2)
            let measured = NibSnapshot.fittingSize(on, width: 44, variant: variant)
            XCTAssertGreaterThanOrEqual(measured.width, 44)
            XCTAssertGreaterThanOrEqual(measured.height, 44)
        }
    }
}

private struct SheetViewportFixture: View {
    var body: some View {
        VStack(spacing: 0) {
            NibSheetHeader("New Event Planner", onCancel: {})
            List {
                Text("Layout")
                Text("Week starts on")
                DatePicker("Starts", selection: .constant(Date()), displayedComponents: .date)
                Text("7 days")
            }
            .listStyle(.insetGrouped)
        }
    }
}
