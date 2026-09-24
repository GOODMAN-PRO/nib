import XCTest
import NibContracts
import FeatShapeRecognition

@MainActor
final class FeatShapeRecognitionTests: XCTestCase {
    func testFeatureID() { XCTAssertFalse(FeatShapeRecognitionFeature.id.isEmpty) }
}
