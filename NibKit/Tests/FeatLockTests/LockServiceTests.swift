import XCTest
import NibContracts
import NibTesting
@testable import FeatLock

// MARK: - Test doubles (shared by this target's tests)

/// Types the scripted passwords into the unlock prompt one after another (through the request's own check, so wrong
/// entries count and the hint comes due exactly as on the device) and answers the setup sheet with `setupResult`.
@MainActor
final class ScriptedLockPresenter: LockPresenting {
    var passwords: [String] = []
    /// Tap the prompt's Face ID button first.
    var usesBiometricsButton = false
    var setupResult: PasswordSetupResult?
    /// Change mode: the current password the sheet checks before it returns `setupResult`.
    var setupCurrentPassword: String?
    private(set) var unlockRequests: [UnlockRequest] = []
    private(set) var checks: [PasswordCheck] = []
    private(set) var setupRequests: [PasswordSetupRequest] = []
    private(set) var coverCalls = 0
    private(set) var uncovered: [DocumentID] = []

    func presentUnlock(_ request: UnlockRequest) async -> UnlockOutcome {
        unlockRequests.append(request)
        if usesBiometricsButton, await request.biometric() { return .unlocked }
        while !passwords.isEmpty {
            let result = await request.check(passwords.removeFirst())
            checks.append(result)
            if result == .accepted { return .unlocked }
        }
        return .cancelled
    }

    func presentSetup(_ request: PasswordSetupRequest) async -> PasswordSetupResult? {
        setupRequests.append(request)
        if request.mode == .change, let current = setupCurrentPassword {
            guard await request.check(current) == .accepted else { return nil }
        }
        return setupResult
    }

    func coverLockedWindows() { coverCalls += 1 }
    func uncover(_ doc: DocumentID) { uncovered.append(doc) }
}

@MainActor
final class FakeBiometrics: BiometricAuthenticating {
    var kind: BiometryKind?
    var succeeds: Bool
    private(set) var reasons: [String] = []

    init(kind: BiometryKind? = .faceID, succeeds: Bool = true) {
        self.kind = kind
        self.succeeds = succeeds
    }

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return succeeds
    }
}

@MainActor
enum LockTesting {
    static let password = "correct horse"
    static let hint = "the stable"
    /// PBKDF2 rounds for tests (the real 600,000 are checked once, in `testDefaultVerifierUsesTheOWASPRounds`).
    static let rounds = 1_000

    struct Setup {
        let harness: Harness
        let service: LockServiceImpl
        let presenter: ScriptedLockPresenter
    }

    /// The feature in a Harness with a scripted presenter and, unless `configured` is false, the password set up.
    static func make(configured: Bool = true) async throws -> Setup {
        let h = Harness(features: [FeatLockFeature.self])
        let service = try XCTUnwrap(h.app.services.lock as? LockServiceImpl)
        service.iterations = rounds
        let presenter = ScriptedLockPresenter()
        service.presenter = presenter
        if configured {
            let v = try await LockVerifier.make(password: password, hint: hint, iterations: rounds)
            h.app.settings.set(LockSettings.verifier, v)
        }
        return Setup(harness: h, service: service, presenter: presenter)
    }

    /// Locks a fixture document as the user (not shown in the Harness window, so it locks at once).
    static func lock(_ doc: DocumentID, in setup: Setup) async throws {
        try await setup.harness.run("doc.setLocked", ["doc": .string("doc:" + doc.raw), "locked": true])
    }

    static func code(_ body: () async throws -> Void) async -> NibError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return NibError.wrap(error).code
        }
    }
}

// MARK: - Verifier, hashing, rules, relock policy

final class LockVerifierTests: XCTestCase {
    private func hex(_ data: Data?) -> String? { data.map { $0.map { String(format: "%02x", $0) }.joined() } }

    func testPBKDF2SHA256MatchesKnownVectors() {
        let salt = Data("salt".utf8)
        XCTAssertEqual(hex(PasswordHasher.derive(password: "password", salt: salt, iterations: 1)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(PasswordHasher.derive(password: "password", salt: salt, iterations: 2)),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(hex(PasswordHasher.derive(password: "password", salt: salt, iterations: 4096)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(hex(PasswordHasher.derive(password: "passwordPASSWORDpassword",
                                                 salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                                                 iterations: 4096, length: 40)),
                       "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
    }

    func testPasswordsAreNormalisedAndEmptyOnesRefused() {
        let salt = Data("salt".utf8)
        let composed = PasswordHasher.derive(password: "caf\u{E9}", salt: salt, iterations: 1)
        XCTAssertNotNil(composed)
        XCTAssertEqual(composed, PasswordHasher.derive(password: "cafe\u{301}", salt: salt, iterations: 1),
                       "a combining accent and a precomposed one are the same password")
        XCTAssertNil(PasswordHasher.derive(password: "", salt: salt, iterations: 1))
        XCTAssertNil(PasswordHasher.derive(password: "x", salt: Data(), iterations: 1))
        XCTAssertNil(PasswordHasher.derive(password: "x", salt: salt, iterations: 0))
    }

    func testVerifierAcceptsOnlyItsPasswordWithAFreshSalt() async throws {
        let a = try await LockVerifier.make(password: "hunter22", hint: "game", iterations: 1_000)
        let b = try await LockVerifier.make(password: "hunter22", hint: "game", iterations: 1_000)
        XCTAssertEqual(a.algorithm, "pbkdf2-sha256")
        XCTAssertEqual(a.salt.count, PasswordHasher.saltLength)
        XCTAssertEqual(a.hash.count, PasswordHasher.keyLength)
        XCTAssertNotEqual(a.salt, b.salt, "every verifier gets its own salt")
        XCTAssertNotEqual(a.hash, b.hash)
        let right = await a.matches("hunter22")
        let wrong = await a.matches("hunter23")
        let empty = await a.matches("")
        let sameOnB = await b.matches("hunter22")
        XCTAssertTrue(right)
        XCTAssertFalse(wrong)
        XCTAssertFalse(empty)
        XCTAssertTrue(sameOnB)
    }

    func testDefaultVerifierUsesTheOWASPRounds() async throws {
        XCTAssertEqual(LockVerifier.defaultIterations, 600_000)
        let start = Date()
        let v = try await LockVerifier.make(password: "long enough", hint: "")
        XCTAssertEqual(v.iterations, 600_000)
        let ok = await v.matches("long enough")
        XCTAssertTrue(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "two derivations at the real cost stay usable")
    }

    func testVerifierRoundTripsThroughSettingsJSONAndDecodesLeniently() async throws {
        let v = try await LockVerifier.make(password: "abcd", hint: "letters", iterations: 500)
        let json = try JSONValue.from(v)
        XCTAssertNotNil(json["salt"]?.stringValue, "salt and hash are stored as base64 text")
        XCTAssertEqual(try json.decode(LockVerifier.self), v)

        let minimal: JSONValue = ["algorithm": "pbkdf2-sha256", "iterations": 500,
                                  "salt": .string(v.salt.base64EncodedString()),
                                  "hash": .string(v.hash.base64EncodedString())]
        let decoded = try minimal.decode(LockVerifier.self)
        XCTAssertEqual(decoded.hint, "")
        XCTAssertEqual(decoded.version, 1)
        let stillMatches = await decoded.matches("abcd")
        XCTAssertTrue(stillMatches)
        XCTAssertThrowsError(try (["algorithm": "pbkdf2-sha256"] as JSONValue).decode(LockVerifier.self))
    }

    func testUnusableVerifiersAcceptNothing() async throws {
        var v = try await LockVerifier.make(password: "abcd", hint: "", iterations: 500)
        v.algorithm = "md5"
        let unknownAlgorithm = await v.matches("abcd")
        XCTAssertFalse(unknownAlgorithm)
        v.algorithm = LockVerifier.algorithmName
        v.iterations = LockVerifier.maximumIterations + 1
        let tooManyRounds = await v.matches("abcd")
        XCTAssertFalse(tooManyRounds, "a synced verifier cannot make the device hash for ever")
    }

    func testConstantTimeComparison() {
        XCTAssertTrue(PasswordHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
    }

    func testPasswordRules() {
        XCTAssertEqual(PasswordRules.problems(password: "abc", confirmation: "abc", hint: ""), [.tooShort])
        XCTAssertEqual(PasswordRules.problems(password: "abcd", confirmation: "abce", hint: ""), [.mismatch])
        XCTAssertEqual(PasswordRules.problems(password: "Tulip", confirmation: "Tulip", hint: "my TULIP garden"),
                       [.hintRevealsPassword])
        XCTAssertEqual(PasswordRules.problems(password: "Tulip", confirmation: "Tulip", hint: "a flower"), [])
        XCTAssertFalse(PasswordRules.message(.mismatch).isEmpty)
    }

    func testHintComesDueOnTheThirdWrongEntry() {
        var attempts = UnlockAttempts()
        attempts.recordFailure()
        attempts.recordFailure()
        XCTAssertFalse(attempts.showsHint)
        attempts.recordFailure()
        XCTAssertTrue(attempts.showsHint)
        attempts.reset()
        XCTAssertFalse(attempts.showsHint)
    }

    func testRelockPolicyWaitsTwoMinutes() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var policy = RelockPolicy()
        XCTAssertFalse(policy.didReturn(at: t0), "nothing to relock when Nib never left")
        policy.didLeave(at: t0)
        policy.didLeave(at: t0.addingTimeInterval(30))
        XCTAssertFalse(policy.isDue(at: t0.addingTimeInterval(119)))
        XCTAssertTrue(policy.isDue(at: t0.addingTimeInterval(120)), "the first departure counts")
        XCTAssertFalse(policy.didReturn(at: t0.addingTimeInterval(90)))
        XCTAssertNil(policy.leftAt)
        policy.didLeave(at: t0)
        XCTAssertTrue(policy.didReturn(at: t0.addingTimeInterval(121)))
    }
}

// MARK: - The service

@MainActor
final class LockServiceTests: XCTestCase {
    func testWrongEntriesShowTheHintFromTheThirdAndResetOnSuccess() async throws {
        let s = try await LockTesting.make()
        let first = await s.service.check("nope")
        let second = await s.service.check("still nope")
        let third = await s.service.check("wrong again")
        XCTAssertEqual(first, .rejected(failures: 1, hint: nil))
        XCTAssertEqual(second, .rejected(failures: 2, hint: nil))
        XCTAssertEqual(third, .rejected(failures: 3, hint: LockTesting.hint))
        XCTAssertEqual(s.service.dueHint, LockTesting.hint, "the next prompt opens with the hint")
        let right = await s.service.check(LockTesting.password)
        XCTAssertEqual(right, .accepted)
        XCTAssertNil(s.service.dueHint)
    }

    func testNonUserPrincipalsGetLockedErrorsForLockedDocuments() async throws {
        let s = try await LockTesting.make()
        let h = s.harness
        let doc = Fixtures.textDocID
        try await LockTesting.lock(doc, in: s)
        XCTAssertTrue(s.service.isLocked(doc))
        XCTAssertTrue(h.app.gateway.isLocked(doc))
        XCTAssertTrue(try h.app.workspace.content(doc).meta.locked)
        // Plugins get the scopes they asked for; this one asked for everything a plugin may have.
        h.app.gateway.grants = { p in p.isUser ? Set(Scope.allCases) : Set(Scope.allCases).subtracting([.security]) }

        for principal in [Principal.ai("chat"), .bridge("laptop"), .plugin("dev.test.plugin")] {
            let byRef = await LockTesting.code { try await h.run("history.list", ["doc": "doc:FIXTUREDOC02"], as: principal) }
            XCTAssertEqual(byRef, .locked, "\(principal) reading the history of a locked document")
            let byID = await LockTesting.code { try await h.run("edit.undo", ["doc": "FIXTUREDOC02"], as: principal) }
            XCTAssertEqual(byID, .locked, "\(principal) naming the locked document by its bare id")
            let open = await LockTesting.code { try await h.run("history.list", ["doc": "doc:FIXTUREDOC01"], as: principal) }
            XCTAssertNil(open, "other documents stay reachable")
        }
        let user = await LockTesting.code { try await h.run("history.list", ["doc": "doc:FIXTUREDOC02"]) }
        XCTAssertNil(user, "the gateway never blocks the user")

        s.presenter.passwords = [LockTesting.password]
        let unlocked = await s.service.unlock(doc)
        XCTAssertTrue(unlocked)
        XCTAssertFalse(s.service.isLocked(doc))
        let afterUnlock = await LockTesting.code { try await h.run("history.list", ["doc": "doc:FIXTUREDOC02"], as: .ai("chat")) }
        XCTAssertNil(afterUnlock, "unlocked for this session: the assistant may read it")
        XCTAssertTrue(try h.app.workspace.content(doc).meta.locked, "unlocking never removes the lock itself")
    }

    func testAssistantCanAskThePersonAtTheDeviceToUnlock() async throws {
        let s = try await LockTesting.make()
        let doc = Fixtures.studySetID
        try await LockTesting.lock(doc, in: s)

        let declined = await LockTesting.code { try await s.harness.run("doc.unlock", ["doc": "doc:FIXTUREDOC03"], as: .ai("chat")) }
        XCTAssertEqual(declined, .userDenied, "nobody typed the password")
        XCTAssertEqual(s.presenter.unlockRequests.last?.requester, .ai("chat"), "the prompt says who asks")
        XCTAssertTrue(s.service.isLocked(doc))

        s.presenter.passwords = ["guess", LockTesting.password]
        let value = try await s.harness.run("doc.unlock", ["doc": "doc:FIXTUREDOC03"], as: .ai("chat"))
        XCTAssertEqual(value["unlocked"]?.boolValue, true)
        XCTAssertEqual(s.presenter.checks, [.rejected(failures: 1, hint: nil), .accepted])
        XCTAssertFalse(s.service.isLocked(doc))
    }

    func testPluginsWithoutTheScopeNeverReachThePrompt() async throws {
        let s = try await LockTesting.make()
        try await LockTesting.lock(Fixtures.studySetID, in: s)
        let code = await LockTesting.code {
            try await s.harness.run("doc.unlock", ["doc": "doc:FIXTUREDOC03"], as: .plugin("dev.test.plugin"))
        }
        XCTAssertEqual(code, .permissionDenied)
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty)
    }

    func testOpenGatePromptsOnlyForLockedDocuments() async throws {
        let s = try await LockTesting.make()
        let gate = try XCTUnwrap(s.harness.app.ui.openGate)
        let plain = await gate(Fixtures.whiteboardID)
        XCTAssertTrue(plain)
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty)

        try await LockTesting.lock(Fixtures.whiteboardID, in: s)
        let cancelled = await gate(Fixtures.whiteboardID)
        XCTAssertFalse(cancelled, "cancelling the prompt keeps the document closed")
        s.presenter.passwords = [LockTesting.password]
        let opened = await gate(Fixtures.whiteboardID)
        XCTAssertTrue(opened)
        let again = await gate(Fixtures.whiteboardID)
        XCTAssertTrue(again)
        XCTAssertEqual(s.presenter.unlockRequests.count, 2, "no prompt once unlocked for the session")
        XCTAssertEqual(s.presenter.uncovered, [Fixtures.whiteboardID])
    }

    func testFaceIDFirstForTheUserButNeverSilentlyForOthers() async throws {
        let s = try await LockTesting.make()
        let biometrics = FakeBiometrics()
        s.service.biometrics = biometrics
        s.harness.app.settings.set(LockSettings.biometrics, true)
        try await LockTesting.lock(Fixtures.textDocID, in: s)
        try await LockTesting.lock(Fixtures.studySetID, in: s)

        let byUser = await s.service.unlock(Fixtures.textDocID)
        XCTAssertTrue(byUser)
        XCTAssertTrue(s.presenter.unlockRequests.isEmpty, "Face ID alone opened it")
        XCTAssertEqual(biometrics.reasons.count, 1)

        s.presenter.usesBiometricsButton = true
        let byAssistant = try await s.harness.run("doc.unlock", ["doc": "doc:FIXTUREDOC03"], as: .ai("chat"))
        XCTAssertEqual(byAssistant["unlocked"]?.boolValue, true)
        XCTAssertEqual(s.presenter.unlockRequests.count, 1, "the assistant's request shows Nib's prompt first")
        XCTAssertEqual(s.presenter.unlockRequests.first?.biometry, .faceID)

        biometrics.succeeds = false
        s.service.relockAll()
        s.presenter.usesBiometricsButton = false
        s.presenter.passwords = [LockTesting.password]
        let fallback = await s.service.unlock(Fixtures.textDocID)
        XCTAssertTrue(fallback, "a failed Face ID falls back to the password")
    }

    func testRelocksTwoMinutesAfterLeavingAndWhenTheDeviceLocks() async throws {
        let s = try await LockTesting.make()
        let doc = Fixtures.textDocID
        var clock = Date(timeIntervalSince1970: 50_000)
        s.service.now = { clock }
        try await LockTesting.lock(doc, in: s)
        s.presenter.passwords = [LockTesting.password]
        _ = await s.service.unlock(doc)
        XCTAssertFalse(s.service.isLocked(doc))

        s.service.appDidEnterBackground()
        clock = clock.addingTimeInterval(90)
        s.service.appWillEnterForeground()
        XCTAssertFalse(s.service.isLocked(doc), "a short trip away keeps it open")

        s.service.appDidEnterBackground()
        clock = clock.addingTimeInterval(RelockPolicy.delay)
        s.service.appWillEnterForeground()
        XCTAssertTrue(s.service.isLocked(doc))
        XCTAssertEqual(s.presenter.coverCalls, 1, "windows that show it are covered")

        s.presenter.passwords = [LockTesting.password]
        _ = await s.service.unlock(doc)
        s.service.deviceWillLock()
        XCTAssertTrue(s.service.isLocked(doc), "locking the device relocks at once")
    }

    func testLockStateOfClosedDocumentsFollowsCommits() async throws {
        let s = try await LockTesting.make()
        await FeatLockFeature.start(s.harness.app)
        let doc = Fixtures.studySetID
        try await LockTesting.lock(doc, in: s)
        s.harness.app.workspace.close(doc)
        XCTAssertFalse(s.harness.app.workspace.isLoaded(doc))
        XCTAssertTrue(s.service.isFlagged(doc), "known from the commit although the catalog has not caught up")
        XCTAssertTrue(s.service.isLocked(doc))
        XCTAssertEqual(s.service.lockedDocuments(), [doc])
    }

    func testLockedWithoutAPasswordAsksTheUserToSetOneUp() async throws {
        let s = try await LockTesting.make(configured: false)
        let doc = Fixtures.textDocID
        s.presenter.setupResult = PasswordSetupResult(action: .create(password: "fresh one"), hint: "", biometrics: false)
        let locked = try await s.harness.run("doc.setLocked", ["doc": "doc:FIXTUREDOC02", "locked": true])
        XCTAssertEqual(locked["changed"]?.boolValue, true, "locking without a password set one up first")
        XCTAssertEqual(s.presenter.setupRequests.count, 1)
        // Now the lock arrives without the library's password (prefs lost, or not synced to this device yet).
        s.harness.app.settings.set(LockSettings.verifier, nil)
        XCTAssertTrue(s.service.isLocked(doc), "still locked: no password never means open")

        let byAssistant = await s.service.unlock(doc, purpose: .open, requester: .ai("chat"))
        XCTAssertFalse(byAssistant, "only the person at the device may set a password up")
        let byUser = await s.service.unlock(doc)
        XCTAssertTrue(byUser)
        XCTAssertTrue(s.service.isConfigured)
        XCTAssertEqual(s.presenter.setupRequests.last?.mode, .create)
        XCTAssertNotNil(s.presenter.setupRequests.last?.reason, "the sheet says why it appeared")
    }
}
