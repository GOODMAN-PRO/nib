import XCTest
import NibContracts
import NibTesting
@testable import FeatLock

@MainActor
final class FeatLockTests: XCTestCase {
    func testFeatureID() { XCTAssertEqual(FeatLockFeature.id, "lock") }

    func testCommandConformance() async {
        let problems = await CommandConformance.check(features: [FeatLockFeature.self])
        XCTAssertEqual(problems, [])
    }

    func testRegistersItsServicesCommandsAndSurfaces() throws {
        let h = Harness(features: [FeatLockFeature.self])
        XCTAssertTrue(h.app.services.lock is LockServiceImpl)
        XCTAssertNotNil(h.app.ui.openGate)
        let owned = h.app.commands.all().filter { $0.owner == FeatLockFeature.id }.map { $0.id }
        XCTAssertEqual(Set(owned), ["lock.setup", "doc.setLocked", "doc.unlock"])

        let setup = try XCTUnwrap(h.app.commands.descriptor("lock.setup"))
        XCTAssertTrue(setup.scopes.contains(.security), "only the user sets the password")
        XCTAssertTrue(setup.userPresence)
        XCTAssertEqual(setup.effect, .session)
        let setLocked = try XCTUnwrap(h.app.commands.descriptor("doc.setLocked"))
        XCTAssertEqual(setLocked.effect, .edit)
        XCTAssertTrue(setLocked.userPresence)
        let unlock = try XCTUnwrap(h.app.commands.descriptor("doc.unlock"))
        XCTAssertEqual(unlock.effect, .session)
        XCTAssertTrue(unlock.userPresence)

        XCTAssertNotNil(h.app.ui.settingsPages.get(LockIDs.settingsPage))
        XCTAssertNotNil(h.app.ui.menus.get(LockIDs.menuLockLibrary))
        XCTAssertNotNil(h.app.ui.menus.get(LockIDs.menuUnlockDocument))
        XCTAssertTrue(h.app.bus.hooks.all.contains { $0.id == LockIDs.unlockGuard })
        let verifier = try XCTUnwrap(h.app.settings.descriptor("security.lock.verifier"))
        XCTAssertTrue(verifier.synced, "the password travels with the library")
        XCTAssertTrue(verifier.userOnly)
        let biometrics = try XCTUnwrap(h.app.settings.descriptor("security.lock.biometrics"))
        XCTAssertFalse(biometrics.synced, "Face ID is per device")
    }

    func testLockSetupAndItsSecretsAreUserOnly() async throws {
        let s = try await LockTesting.make()
        for principal in [Principal.ai("chat"), .bridge("laptop")] {
            let setup = await LockTesting.code { try await s.harness.run("lock.setup", [:], as: principal) }
            XCTAssertEqual(setup, .permissionDenied)
            let read = await LockTesting.code {
                try await s.harness.run("settings.get", ["name": "security.lock.verifier"], as: principal)
            }
            XCTAssertEqual(read, .permissionDenied, "the verifier never leaves through settings.get")
        }
        XCTAssertTrue(s.presenter.setupRequests.isEmpty)
    }

    func testSetUpChangeAndTurnOffThePassword() async throws {
        let s = try await LockTesting.make(configured: false)
        let settings = s.harness.app.settings
        s.presenter.setupResult = PasswordSetupResult(action: .create(password: "first pass"), hint: " vacation ",
                                                      biometrics: false)
        let created = try await s.harness.run("lock.setup")
        XCTAssertEqual(created["outcome"]?.stringValue, "created")
        XCTAssertEqual(created["configured"]?.boolValue, true)
        let first = try XCTUnwrap(settings.get(LockSettings.verifier))
        XCTAssertEqual(first.hint, "vacation")
        let firstMatches = await first.matches("first pass")
        XCTAssertTrue(firstMatches)

        // Change: the sheet checks the current password, then only the hint changes.
        s.presenter.setupCurrentPassword = "first pass"
        s.presenter.setupResult = PasswordSetupResult(action: .change(newPassword: nil), hint: "summer", biometrics: false)
        let hinted = try await s.harness.run("lock.setup")
        XCTAssertEqual(hinted["outcome"]?.stringValue, "changed")
        let second = try XCTUnwrap(settings.get(LockSettings.verifier))
        XCTAssertEqual(second.hash, first.hash, "a new hint keeps the password")
        XCTAssertEqual(second.hint, "summer")
        XCTAssertEqual(s.presenter.setupRequests.last?.mode, .change)
        XCTAssertEqual(s.presenter.setupRequests.last?.hint, "vacation")

        s.presenter.setupResult = PasswordSetupResult(action: .change(newPassword: "second pass"), hint: "winter",
                                                      biometrics: false)
        _ = try await s.harness.run("lock.setup")
        let third = try XCTUnwrap(settings.get(LockSettings.verifier))
        let oldRejected = await third.matches("first pass")
        let newAccepted = await third.matches("second pass")
        XCTAssertFalse(oldRejected)
        XCTAssertTrue(newAccepted)

        // Turning it off is refused while a document still has a lock.
        try await LockTesting.lock(Fixtures.textDocID, in: s)
        XCTAssertEqual(s.presenter.setupRequests.last?.lockedDocuments, 0)
        s.presenter.setupCurrentPassword = "second pass"
        s.presenter.setupResult = PasswordSetupResult(action: .remove, hint: "", biometrics: false)
        let refused = await LockTesting.code { try await s.harness.run("lock.setup") }
        XCTAssertEqual(refused, .conflict)
        XCTAssertEqual(s.presenter.setupRequests.last?.lockedDocuments, 1, "the sheet knows why it cannot turn off")
        XCTAssertNotNil(settings.get(LockSettings.verifier))

        s.presenter.passwords = ["second pass"]
        _ = try await s.harness.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": false])
        let removed = try await s.harness.run("lock.setup")
        XCTAssertEqual(removed["outcome"]?.stringValue, "removed")
        XCTAssertEqual(removed["configured"]?.boolValue, false)
        XCTAssertNil(settings.get(LockSettings.verifier))
    }

    func testCancelledSetupChangesNothing() async throws {
        let s = try await LockTesting.make(configured: false)
        let value = try await s.harness.run("lock.setup")
        XCTAssertEqual(value["outcome"]?.stringValue, "cancelled")
        XCTAssertNil(s.harness.app.settings.get(LockSettings.verifier))
    }

    func testSetupRefusesAWeakPasswordEvenFromTheSheet() async throws {
        let s = try await LockTesting.make(configured: false)
        s.presenter.setupResult = PasswordSetupResult(action: .create(password: "abc"), hint: "", biometrics: false)
        let code = await LockTesting.code { try await s.harness.run("lock.setup") }
        XCTAssertEqual(code, .invalidParams)
        XCTAssertNil(s.harness.app.settings.get(LockSettings.verifier))
    }

    func testLockingIsOneUndoStepAndRemovingAsksForThePassword() async throws {
        let s = try await LockTesting.make()
        let h = s.harness
        let doc = Fixtures.textDocID
        let depth = h.undoDepth(doc)
        let locked = try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": true])
        XCTAssertEqual(locked["changed"]?.boolValue, true)
        XCTAssertEqual(h.undoDepth(doc), depth + 1)
        XCTAssertTrue(try h.app.workspace.content(doc).meta.locked)
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty, "adding a lock needs no password")

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertFalse(try h.app.workspace.content(doc).meta.locked)
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertTrue(try h.app.workspace.content(doc).meta.locked)

        // Removing: a cancelled prompt leaves the lock (and is not an error for the user).
        s.presenter.passwords = ["wrong"]
        let kept = try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": false])
        XCTAssertEqual(kept["changed"]?.boolValue, false)
        XCTAssertTrue(try h.app.workspace.content(doc).meta.locked)
        XCTAssertEqual(s.presenter.unlockRequests.last?.purpose, .removeLock)
        XCTAssertNil(s.presenter.unlockRequests.last?.biometry, "removing a lock always takes the password")

        s.presenter.passwords = [LockTesting.password]
        let removed = try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": false])
        XCTAssertEqual(removed["changed"]?.boolValue, true)
        XCTAssertFalse(try h.app.workspace.content(doc).meta.locked)
        XCTAssertFalse(s.service.isLocked(doc))

        let again = try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": false])
        XCTAssertEqual(again["changed"]?.boolValue, false, "already unlocked: nothing to do")
    }

    func testAssistantMayLockButNotRemoveALockWithoutThePassword() async throws {
        let s = try await LockTesting.make()
        let h = s.harness
        let value = try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC03", "locked": true], as: .ai("chat"))
        XCTAssertEqual(value["locked"]?.boolValue, true)
        XCTAssertTrue(s.service.isLocked(Fixtures.studySetID))
        let blocked = await LockTesting.code {
            try await h.run("doc.setLocked", ["doc": "doc:FIXTUREDOC03", "locked": false], as: .ai("chat"))
        }
        XCTAssertEqual(blocked, .locked, "a locked document is out of reach until the user unlocks it")
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty)
    }

    func testLockingNeedsAPasswordWhenNobodyIsThereToSetOneUp() async throws {
        let s = try await LockTesting.make(configured: false)
        let byAssistant = await LockTesting.code {
            try await s.harness.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": true], as: .ai("chat"))
        }
        XCTAssertEqual(byAssistant, .unavailable)
        s.service.presenter = nil
        let headless = await LockTesting.code {
            try await s.harness.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": true])
        }
        XCTAssertEqual(headless, .unavailable)
        XCTAssertFalse(try s.harness.app.workspace.content(Fixtures.textDocID).meta.locked)
    }

    func testLockingTheDocumentOnScreenKeepsItOpenForThisSession() async throws {
        let s = try await LockTesting.make()
        let doc = Fixtures.docID
        XCTAssertEqual(s.harness.session.document, doc)
        _ = try await s.harness.run("doc.setLocked", ["locked": true])
        XCTAssertTrue(try s.harness.app.workspace.content(doc).meta.locked, "the window's document is the default")
        XCTAssertFalse(s.service.isLocked(doc), "the person looking at it keeps it open until the next relock")
        s.service.relockAll()
        XCTAssertTrue(s.service.isLocked(doc))
    }

    func testDocUnlockOfAnUnlockedOrMissingDocument() async throws {
        let s = try await LockTesting.make()
        let open = try await s.harness.run("doc.unlock", ["doc": "doc:FIXTUREDOC04"])
        XCTAssertEqual(open["unlocked"]?.boolValue, true)
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty)
        let missing = await LockTesting.code { try await s.harness.run("doc.unlock", ["doc": "doc:NOSUCHDOC001"]) }
        XCTAssertEqual(missing, .notFound)
    }

    func testMenusOfferLockOrRemoveLock() async throws {
        let s = try await LockTesting.make()
        let app = s.harness.app
        let context = MenuContext(app: app, nodes: [Fixtures.textDocID])
        let lock = try XCTUnwrap(app.ui.menus.get(LockIDs.menuLockLibrary))
        let unlock = try XCTUnwrap(app.ui.menus.get(LockIDs.menuUnlockLibrary))
        XCTAssertTrue(lock.isVisible(context))
        XCTAssertFalse(unlock.isVisible(context))
        XCTAssertEqual(lock.params(context), ["doc": "doc:FIXTUREDOC02", "locked": true])
        try await LockTesting.lock(Fixtures.textDocID, in: s)
        XCTAssertFalse(lock.isVisible(context))
        XCTAssertTrue(unlock.isVisible(context))
        XCTAssertEqual(unlock.params(context), ["doc": "doc:FIXTUREDOC02", "locked": false])
        XCTAssertFalse(lock.isVisible(MenuContext(app: app, nodes: [Fixtures.folderID])), "folders have no lock")

        let more = try XCTUnwrap(app.ui.menus.get(LockIDs.menuLockDocument))
        XCTAssertTrue(more.isVisible(MenuContext(app: app, doc: Fixtures.docID)))
        XCTAssertFalse(more.isVisible(MenuContext(app: app)))
    }
}

// MARK: - Screens (models; the views are checked on device)

@MainActor
final class LockScreenModelTests: XCTestCase {
    private func request(purpose: UnlockPurpose = .open, requester: Principal = .user, hint: String? = nil,
                         password: String = "letmein", hintText: String = "pet's name",
                         biometricSucceeds: Bool = false) -> UnlockRequest {
        var failures = 0
        return UnlockRequest(
            doc: Fixtures.docID, documentTitle: "Kinematics", purpose: purpose, requester: requester,
            biometry: .faceID, hint: hint,
            check: { typed in
                if typed == password { return .accepted }
                failures += 1
                return .rejected(failures: failures, hint: failures >= 3 ? hintText : nil)
            },
            biometric: { biometricSucceeds })
    }

    func testUnlockPromptShowsTheHintAfterThreeWrongEntries() async {
        let model = UnlockPromptModel(request: request())
        var outcomes: [UnlockOutcome] = []
        model.onFinish = { outcomes.append($0) }
        XCTAssertFalse(model.canSubmit, "nothing typed yet")
        for attempt in 1...3 {
            model.password = "guess \(attempt)"
            await model.submit()
            XCTAssertEqual(model.password, "", "a wrong entry clears the field")
            XCTAssertNotNil(model.error)
            XCTAssertEqual(model.hintText == nil, attempt < 3)
        }
        XCTAssertEqual(model.hintText, "Hint: pet's name")
        model.password = "letmein"
        await model.submit()
        XCTAssertEqual(outcomes, [.unlocked])
        model.cancel()
        XCTAssertEqual(outcomes, [.unlocked], "finishes once")
    }

    func testUnlockPromptWordsAndBiometrics() async {
        let byAssistant = UnlockPromptModel(request: request(requester: .ai("chat"), hint: ""))
        XCTAssertTrue(byAssistant.message.contains("Kinematics"))
        XCTAssertNotEqual(byAssistant.message, UnlockPromptModel(request: request()).message,
                          "the prompt says when someone else asks")
        XCTAssertEqual(byAssistant.hintText, "No hint was set for this password.")
        let removing = UnlockPromptModel(request: request(purpose: .removeLock))
        XCTAssertEqual(removing.primaryTitle, "Remove Lock")

        let face = UnlockPromptModel(request: request(biometricSucceeds: true))
        var outcome: UnlockOutcome?
        face.onFinish = { outcome = $0 }
        await face.useBiometrics()
        XCTAssertEqual(outcome, .unlocked)
    }

    private func setupRequest(mode: PasswordSetupMode, locked: Int = 0) -> PasswordSetupRequest {
        PasswordSetupRequest(mode: mode, reason: nil, hint: mode == .change ? "old hint" : "", biometry: .faceID,
                             biometricsOn: false, lockedDocuments: locked,
                             check: { $0 == "current" ? .accepted : .rejected(failures: 1, hint: nil) })
    }

    func testSetupSheetValidatesBeforeSaving() async {
        let model = PasswordSetupModel(request: setupRequest(mode: .create))
        var results: [PasswordSetupResult?] = []
        model.onFinish = { results.append($0) }
        XCTAssertFalse(model.canSave)
        model.password = "abc"
        XCTAssertEqual(model.visibleProblem, PasswordRules.message(.tooShort))
        model.password = "abcd"
        model.confirmation = "abce"
        XCTAssertEqual(model.visibleProblem, PasswordRules.message(.mismatch))
        model.confirmation = "abcd"
        model.hint = "ABCD backwards"
        XCTAssertEqual(model.visibleProblem, PasswordRules.message(.hintRevealsPassword))
        XCTAssertFalse(model.canSave)
        model.hint = "  first letters  "
        model.biometrics = true
        XCTAssertTrue(model.canSave)
        await model.save()
        XCTAssertEqual(results, [PasswordSetupResult(action: .create(password: "abcd"), hint: "first letters",
                                                     biometrics: true)])
    }

    func testChangeSheetChecksTheCurrentPassword() async {
        let model = PasswordSetupModel(request: setupRequest(mode: .change))
        var results: [PasswordSetupResult?] = []
        model.onFinish = { results.append($0) }
        XCTAssertFalse(model.changesPassword)
        model.hint = "new hint"
        XCTAssertFalse(model.canSave, "the current password comes first")
        model.current = "wrong"
        await model.save()
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.current, "")
        model.current = "current"
        await model.save()
        XCTAssertEqual(results, [PasswordSetupResult(action: .change(newPassword: nil), hint: "new hint", biometrics: false)])
    }

    func testTurnOffNeedsNoLockedDocumentsAndThePassword() async {
        let blocked = PasswordSetupModel(request: setupRequest(mode: .change, locked: 2))
        XCTAssertFalse(blocked.canTurnOff)
        let model = PasswordSetupModel(request: setupRequest(mode: .change))
        var results: [PasswordSetupResult?] = []
        model.onFinish = { results.append($0) }
        XCTAssertTrue(model.canTurnOff)
        await model.turnOff()
        XCTAssertTrue(results.isEmpty, "no password typed")
        model.current = "current"
        await model.turnOff()
        XCTAssertEqual(results, [PasswordSetupResult(action: .remove, hint: "", biometrics: false)])
    }

    func testLockedFieldTakesThePagesPaper() {
        XCTAssertFalse(LockPaper.isDark(RGBA(0xFC, 0xF3, 0xC8)))
        XCTAssertTrue(LockPaper.isDark(RGBA(0x12, 0x12, 0x12)))
        let h = Harness(features: [FeatLockFeature.self])
        _ = try? h.app.workspace.content(Fixtures.docID)
        XCTAssertFalse(LockPaper.of(Fixtures.docID, in: h.app).isDark)
        XCTAssertFalse(LockPaper.of(NibID("NOTLOADED001"), in: h.app).isDark)
    }
}
