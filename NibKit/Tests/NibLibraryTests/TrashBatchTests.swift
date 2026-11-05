import XCTest
import NibContracts
@testable import NibLibrary

@MainActor
final class TrashBatchTests: XCTestCase {
    func testOverlappingTrashRefsCompleteInEitherOrderAndReportEveryRef() async throws {
        for parentFirst in [true, false] {
            let lib = try TempLibrary()
            defer { try? FileManager.default.removeItem(at: lib.root) }
            await lib.library.waitForScans()
            let folder = try lib.library.createFolder(title: "Old", in: nil, style: nil)
            let parentRef = NodeRef.folder(folder).description
            let child = try await lib.run("doc.create", ["kind": "notebook", "folder": .string(parentRef)])
            let childRef = try XCTUnwrap(child["ref"]?.stringValue)
            let remaining = try await lib.run("doc.create", ["kind": "notebook", "title": "Other"])
            let remainingRef = try XCTUnwrap(remaining["ref"]?.stringValue)
            try await lib.run("library.trash", ["refs": [.string(parentRef), .string(remainingRef)]])
            let refs = (parentFirst ? [parentRef, childRef] : [childRef, parentRef]) + [remainingRef]
            let params: JSONValue = ["refs": .array(refs.map(JSONValue.string))]
            let preview = try await lib.h.app.bus.execute(Invocation(command: "trash.deletePermanently", params: params, dryRun: true))
            XCTAssertEqual(preview.value["deleted"]?.arrayValue?.compactMap(\.stringValue), refs)
            XCTAssertNotNil(lib.library.node(folder))
            let result = try await lib.run("trash.deletePermanently", params)
            XCTAssertEqual(result["deleted"]?.arrayValue?.compactMap(\.stringValue), refs)
            XCTAssertNil(lib.library.node(folder))
            XCTAssertNil(lib.library.node(NodeRef.documentID(from: childRef)))
            XCTAssertNil(lib.library.node(NodeRef.documentID(from: remainingRef)))
            XCTAssertTrue(lib.library.trashedNodes().isEmpty)
        }
    }
}
