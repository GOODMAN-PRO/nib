import XCTest
import SwiftUI
import UIKit
import NibDesign
import NibTesting
@testable import FeatStudySession

@MainActor
final class StudyGradeContrastTests: XCTestCase {
    func testGradeAndIntervalMeetSmallTextContrastInBothAppearances() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            func luminance(_ color: Color) -> CGFloat {
                let resolved = UIColor(color).resolvedColor(with: traits)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
                XCTAssertEqual(a, 1, "The grade surface and text must not inherit the study desk colour")
                func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
            let foreground = luminance(StudyGradeButton.foreground)
            let background = luminance(StudyGradeButton.background)
            XCTAssertGreaterThanOrEqual((max(foreground, background) + 0.05) / (min(foreground, background) + 0.05), 4.5)
        }
    }

    func testGradePillKeepsItsHitTargetAndGrowsForLargeText() {
        let button = StudyGradeButton(title: "Again", detail: "10m",
                                      shortcut: KeyboardShortcut("1", modifiers: []), action: {})
        let regular = NibSnapshot.fittingSize(button, width: 150)
        let large = NibSnapshot.fittingSize(button, width: 150, variant: .largeText)
        XCTAssertGreaterThanOrEqual(regular.height, NibMetrics.hitTarget)
        XCTAssertGreaterThan(large.height, regular.height)
    }
}
