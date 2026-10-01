import XCTest
import NibContracts

final class FractionalIndexRegressionTests: XCTestCase {
    func testLongBoundaryRunsGrowLogarithmicallyInBothDirections() {
        for increasing in [true, false] {
            var previous: String?
            var longest = 0
            for i in 0..<100_000 {
                let next = increasing ? FractionalIndex.between(previous, nil) : FractionalIndex.between(nil, previous)
                if let previous {
                    XCTAssertTrue(increasing ? previous < next : next < previous)
                    let middle = increasing ? FractionalIndex.between(previous, next) : FractionalIndex.between(next, previous)
                    XCTAssertTrue(increasing ? (previous < middle && middle < next) : (next < middle && middle < previous))
                    assertValid(middle)
                }
                assertValid(next)
                longest = max(longest, next.utf8.count)
                if i == 999 { XCTAssertLessThanOrEqual(longest, 4) }
                previous = next
            }
            XCTAssertLessThanOrEqual(longest, 6, "100k boundary keys must not grow one character per few inserts")
        }
    }

    func testLegacyKeysKeepTheirOrderWithoutMigration() {
        let legacy = ["1", "V", "VV", "W", "k", "z", "zV", "zk", "zz", "zzV",
                      "0000001", "0V", "a0V", "yzzzzV", String(repeating: "z", count: 170) + "V"]
        for key in legacy {
            let before = FractionalIndex.between(nil, key)
            let after = FractionalIndex.between(key, nil)
            XCTAssertLessThan(before, key)
            XCTAssertLessThan(key, after)
            assertValid(before)
            assertValid(after)
            XCTAssertEqual(FractionalIndex.between(nil, key), before, "No process-local counter or cache")
            XCTAssertEqual(FractionalIndex.between(key, nil), after)
        }
        let sorted = legacy.sorted()
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            let middle = FractionalIndex.between(left, right)
            XCTAssertLessThan(left, middle)
            XCTAssertLessThan(middle, right)
            assertValid(middle)
        }
        // Bounded insertion retains the legacy midpoint rule, even at zero-padded boundaries.
        XCTAssertEqual(FractionalIndex.between("V", "W"), "VV")
        XCTAssertEqual(FractionalIndex.between("V", "V1"), "V0V")
        XCTAssertEqual(FractionalIndex.between("0V", "1"), "0k")
        XCTAssertEqual(FractionalIndex.between("a0V", "a1"), "a0k")
    }

    func testVeryLongLegacyPrefixesDoNotNeedRecursiveSuffixCopies() {
        let prefix = String(repeating: "z", count: 20_000)
        XCTAssertEqual(FractionalIndex.between(prefix + "V", prefix + "W"), prefix + "VV")
        XCTAssertLessThan(prefix, FractionalIndex.between(prefix, nil))
        let low = String(repeating: "0", count: 20_000) + "1"
        XCTAssertLessThan(FractionalIndex.between(nil, low), low)
    }

    func testBatchAndSequentialInsertionStayCompatible() {
        XCTAssertEqual(FractionalIndex.sequence(after: nil, count: 0), [])
        XCTAssertEqual(FractionalIndex.sequence(after: "V", count: -1), [])
        let intervals: [(String?, String?)] = [(nil, nil), ("V", "W"), ("zV", nil), (nil, "001")]
        for bounds in intervals {
            let keys = FractionalIndex.balanced(count: 10_000, after: bounds.0, before: bounds.1)
            XCTAssertTrue(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 })
            XCTAssertTrue(keys.allSatisfy { key in
                (bounds.0.map { $0 < key } ?? true) && (bounds.1.map { key < $0 } ?? true)
            })
            keys.forEach { assertValid($0) }
            if bounds.0 == nil && bounds.1 == nil {
                XCTAssertLessThanOrEqual(keys.map { $0.utf8.count }.max() ?? 0, 4)
            }
            let appended = FractionalIndex.sequence(after: keys.last, count: 1_000)
            XCTAssertLessThan(keys.last!, appended.first!)
            XCTAssertTrue(zip(appended, appended.dropFirst()).allSatisfy { $0 < $1 })
            appended.forEach { assertValid($0) }
        }
    }

    private func assertValid(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(key.isEmpty, file: file, line: line)
        XCTAssertFalse(key.hasSuffix("0"), file: file, line: line)
        XCTAssertTrue(key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) },
                      file: file, line: line)
    }
}
