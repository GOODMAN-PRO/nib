import XCTest
import UIKit
import UniformTypeIdentifiers
import NibContracts
@testable import FeatImport

@MainActor
final class DocumentPickerLifecycleTests: XCTestCase {
    func testMissingPresentationCompletionFailsAndReleasesThePicker() async {
        let fixture = PickerWindow()
        defer { fixture.close() }
        let finished = expectation(description: "unpresented picker fails within its deadline")
        var lateCompletion: (@MainActor () -> Void)?
        let task = Task { @MainActor in
            do {
                _ = try await DocumentPicker.pick(types: [.pdf], navigator: fixture.navigator,
                    presentationTimeoutNanoseconds: 20_000_000) { _, _, completion in
                        lateCompletion = completion
                    }
                XCTFail("A presenter that neither presents nor completes must fail")
            } catch {
                XCTAssertEqual(NibError.wrap(error).code, .unavailable)
            }
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        lateCompletion?()
        lateCompletion?() // Neither a late nor a duplicate completion resumes twice.
        await assertSubsequentPickSucceeds(fixture.navigator)
    }

    func testDeadlineAcceptsAPresentedControllerEvenWithoutCompletion() async {
        let fixture = PickerWindow()
        defer { fixture.close() }
        let finished = expectation(description: "presented relationship wins at deadline")
        let task = Task { @MainActor in
            let shown = await ImportUI.present(UIViewController(), navigator: fixture.navigator,
                timeoutNanoseconds: 20_000_000) { _, controller, _ in
                    // UIKit has attached the controller, but the presentation completion was lost.
                    fixture.root.presented = controller
                }
            XCTAssertTrue(shown)
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testTimedOutPresentationDismissesALateAttachmentWithOrWithoutCompletion() async {
        for reportsCompletion in [false, true] {
            let fixture = PickerWindow()
            defer { fixture.close() }
            let controller = LatePresentationController()
            let rejected = expectation(description: "unattached controller times out")
            let dismissed = expectation(description: "late attachment is dismissed")
            controller.onDismiss = { dismissed.fulfill() }
            var lateCompletion: (@MainActor () -> Void)?
            let task = Task { @MainActor in
                let shown = await ImportUI.present(controller, navigator: fixture.navigator,
                    timeoutNanoseconds: 20_000_000) { _, _, completion in lateCompletion = completion }
                XCTAssertFalse(shown)
                rejected.fulfill()
            }
            defer { task.cancel() }
            await fulfillment(of: [rejected], timeout: 2)
            controller.presenter = fixture.root
            if reportsCompletion { lateCompletion?() }
            await fulfillment(of: [dismissed], timeout: 2)
            lateCompletion?()
            XCTAssertEqual(controller.dismissCalls, 1)
            XCTAssertNil(controller.presentingViewController)
        }
    }

    func testClosingWindowBeforeOrAfterPresentationCompletionReleasesThePicker() async throws {
        for completePresentation in [false, true] {
            let fixture = PickerWindow()
            defer { fixture.close() }
            let requested = expectation(description: "picker requested")
            let finished = expectation(description: "disconnected picker resolved")
            var picker: UIDocumentPickerViewController?
            var lateCompletion: (@MainActor () -> Void)?
            let task = Task { @MainActor in
                do {
                    _ = try await DocumentPicker.pick(types: [.pdf], navigator: fixture.navigator) { _, controller, completion in
                        picker = controller as? UIDocumentPickerViewController
                        lateCompletion = completion
                        if completePresentation { completion() }
                        requested.fulfill()
                    }
                    XCTFail("Closing the invoking window must end the pending pick")
                } catch {
                    XCTAssertEqual(NibError.wrap(error).code, .unavailable)
                }
                finished.fulfill()
            }
            defer { task.cancel() }
            await fulfillment(of: [requested], timeout: 2)
            let controller = try XCTUnwrap(picker)
            let delegate = try XCTUnwrap(controller.delegate as? DocumentPicker)
            fixture.close()
            // The scene notification's handler; standalone test windows do not have a UIWindowScene.
            delegate.sceneDisconnected()
            delegate.sceneDisconnected()
            await fulfillment(of: [finished], timeout: 2)
            lateCompletion?()
            let remainingWindow = PickerWindow()
            defer { remainingWindow.close() }
            await assertSubsequentPickSucceeds(remainingWindow.navigator)
        }
    }

    func testTaskCancellationBeforeOrAfterPresentationCompletionReleasesThePicker() async {
        for completePresentation in [false, true] {
            let fixture = PickerWindow()
            defer { fixture.close() }
            let requested = expectation(description: "picker requested")
            let finished = expectation(description: "cancelled task resolved")
            var lateCompletion: (@MainActor () -> Void)?
            let task = Task { @MainActor in
                do {
                    _ = try await DocumentPicker.pick(types: [.pdf], navigator: fixture.navigator) { _, _, completion in
                        lateCompletion = completion
                        if completePresentation { completion() }
                        requested.fulfill()
                    }
                    XCTFail("Task cancellation must stop the pending pick")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
                finished.fulfill()
            }
            defer { task.cancel() }
            await fulfillment(of: [requested], timeout: 2)
            task.cancel()
            await fulfillment(of: [finished], timeout: 2)
            lateCompletion?()
            await assertSubsequentPickSucceeds(fixture.navigator)
        }
    }

    func testDelegateCallbackBeforePresentationCompletionStillFinishes() async {
        let fixture = PickerWindow()
        defer { fixture.close() }
        let finished = expectation(description: "delegate resolves before presentation completion")
        let url = URL(fileURLWithPath: "/early.pdf")
        var lateCompletion: (@MainActor () -> Void)?
        let task = Task { @MainActor in
            do {
                let urls = try await DocumentPicker.pick(types: [.pdf], navigator: fixture.navigator) { _, controller, completion in
                    lateCompletion = completion
                    guard let picker = controller as? UIDocumentPickerViewController else {
                        XCTFail("Expected Files picker")
                        return
                    }
                    picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [url])
                }
                XCTAssertEqual(urls, [url])
            } catch { XCTFail("Delegate delivery must win: \(error)") }
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        lateCompletion?()
        await assertSubsequentPickSucceeds(fixture.navigator)
    }

    func testDelegateDoesNotDismissAgainOrWaitForADismissalCompletion() async {
        for cancelled in [false, true] {
            let fixture = PickerWindow()
            defer { fixture.close() }
            let finished = expectation(description: "delegate result without another dismiss")
            let dismissingPicker = DismissingPicker(forOpeningContentTypes: [.pdf], asCopy: false)
            let url = URL(fileURLWithPath: "/picked.pdf")
            let task = Task { @MainActor in
                do {
                    let urls = try await DocumentPicker.pick(types: [.pdf], navigator: fixture.navigator) { _, controller, completion in
                        completion()
                        guard let picker = controller as? UIDocumentPickerViewController else {
                            XCTFail("Expected Files picker")
                            return
                        }
                        let delegate = picker.delegate
                        if cancelled { delegate?.documentPickerWasCancelled?(dismissingPicker) }
                        else { delegate?.documentPicker?(dismissingPicker, didPickDocumentsAt: [url]) }
                        delegate?.documentPickerWasCancelled?(dismissingPicker)
                    }
                    XCTAssertEqual(urls, cancelled ? [] : [url])
                } catch { XCTFail("Picker delegate must resolve without dismiss completion: \(error)") }
                finished.fulfill()
            }
            defer { task.cancel() }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(dismissingPicker.dismissCalls, 0)
            await assertSubsequentPickSucceeds(fixture.navigator)
        }
    }

    private func assertSubsequentPickSucceeds(_ navigator: SceneNavigator) async {
        let finished = expectation(description: "subsequent picker succeeds")
        let url = URL(fileURLWithPath: "/next.pdf")
        let task = Task { @MainActor in
            do {
                let urls = try await DocumentPicker.pick(types: [.pdf], navigator: navigator) { _, controller, completion in
                    completion()
                    guard let picker = controller as? UIDocumentPickerViewController else {
                        XCTFail("Expected Files picker")
                        return
                    }
                    picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [url])
                }
                XCTAssertEqual(urls, [url])
            } catch { XCTFail("Previous picker must release active ownership: \(error)") }
            finished.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [finished], timeout: 2)
    }
}

@MainActor
private final class PickerWindow {
    let root = PickerPresenter()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
    let navigator = PickerNavigator()

    init() {
        window.rootViewController = root
        window.isHidden = false
        navigator.root = root
    }

    func close() {
        root.presented = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class LatePresentationController: UIViewController {
    var presenter: UIViewController?
    var onDismiss: (() -> Void)?
    var dismissCalls = 0
    override var presentingViewController: UIViewController? { presenter }
    override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        XCTAssertFalse(animated)
        dismissCalls += 1
        presenter = nil
        onDismiss?()
        completion?()
    }
}

@MainActor
private final class PickerPresenter: UIViewController {
    var presented: UIViewController?
    override var presentedViewController: UIViewController? { presented }
}

@MainActor
private final class DismissingPicker: UIDocumentPickerViewController {
    let presenter = UIViewController()
    var dismissCalls = 0
    override var presentingViewController: UIViewController? { presenter }
    override var isBeingDismissed: Bool { true }
    override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        dismissCalls += 1
        // UIKit can omit completion when a second dismissal is requested during its own dismissal.
    }
}

@MainActor
private final class PickerNavigator: SceneNavigator {
    let session = EditorSession()
    var root: UIViewController?
    var rootViewController: UIViewController? { root }
    var openDocuments: [DocumentID] { [] }
    var activeDocument: DocumentID? { nil }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {}
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) {}
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}
