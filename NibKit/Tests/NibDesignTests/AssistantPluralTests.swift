import XCTest
@testable import NibDesign

final class AssistantPluralTests: XCTestCase {
    func testProposalReviewAndReceiptCountsUseEnglishAndGermanPlurals() throws {
        for language in ["en", "de"] {
            // Some SwiftPM resource layouts keep the development language in the
            // module bundle. German must still have its compiled translation.
            let bundle: Bundle
            if language == "en" {
                bundle = Bundle.module.path(forResource: language, ofType: "lproj")
                    .flatMap { Bundle(path: $0) } ?? .module
            } else {
                let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
                bundle = try XCTUnwrap(Bundle(path: path))
            }
            for count in [0, 1, 2] {
                let locale = Locale(identifier: language)
                let changes = String(localized: "\(count) changes", bundle: bundle, locale: locale)
                let review = String(localized: "Review \(count) changes", bundle: bundle, locale: locale)
                let receipt = String(localized: "Applied \(count) changes", bundle: bundle, locale: locale)
                if language == "en" {
                    let noun = count == 1 ? "change" : "changes"
                    XCTAssertEqual(changes, "\(count) \(noun)")
                    XCTAssertEqual(review, "Review \(count) \(noun)")
                    XCTAssertEqual(receipt, "Applied \(count) \(noun)")
                } else {
                    let noun = count == 1 ? "Änderung" : "Änderungen"
                    XCTAssertEqual(changes, "\(count) \(noun)")
                    XCTAssertEqual(review, "\(count) \(noun) prüfen")
                    XCTAssertEqual(receipt, "\(count) \(noun) angewendet")
                }
            }
        }
    }
}
