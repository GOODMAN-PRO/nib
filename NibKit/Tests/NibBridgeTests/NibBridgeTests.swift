import XCTest
import NibContracts
import NibTesting
@testable import NibBridge

/// Records start/stop instead of opening a socket.
final class RecordingServer: HTTPServing {
    private(set) var started = 0
    private(set) var stopped = 0
    func start() throws { started += 1 }
    func stop() { stopped += 1 }
}

/// CIDR allowlist, token and Origin checks, the router's check order, the REST gateway and the bridge commands.
@MainActor
final class NibBridgeTests: XCTestCase {
    private var token: String { BridgeTestCommands.token }
    private var lan: [UInt8]? { BridgeIP.parse("192.168.1.9") }

    /// The Keychain fake is shared by every Harness in the process, so each test sets the token it expects.
    private func setToken(_ value: String?) {
        Keychain.setString(value, service: BridgeSecrets.service, account: BridgeSecrets.account)
    }

    private func make() throws -> (Harness, BridgeController, RecordingServer) {
        let h = Harness(features: [NibBridgeFeature.self])
        BridgeTestCommands.register(in: h.app)
        let c = try BridgeController.resolve(h.app.services)
        let server = RecordingServer()
        c.makeServer = { _ in server }
        return (h, c, server)
    }

    private func get(_ path: String, auth: String? = nil, origin: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let a = auth { headers["Authorization"] = a }
        if let o = origin { headers["Origin"] = o }
        return HTTPRequest(method: "GET", path: path, headers: headers)
    }

    private func body(_ r: HTTPResponse) throws -> JSONValue {
        try JSONValue.parse(String(decoding: r.body, as: UTF8.self))
    }

    // MARK: Conformance

    func testCommandsConform() async {
        let problems = await CommandConformance.check(features: [NibBridgeFeature.self], owners: [NibBridgeFeature.id])
        XCTAssertEqual(problems, [])
        let h = Harness(features: [NibBridgeFeature.self])
        XCTAssertEqual(h.app.commands.all().filter { $0.owner == NibBridgeFeature.id }.map { $0.id },
                       ["bridge.setEnabled", "bridge.status"])
        XCTAssertEqual(h.app.commands.descriptor("bridge.setEnabled")?.effect, .session)
        XCTAssertTrue(h.app.commands.descriptor("bridge.setEnabled")?.scopes.contains(.security) ?? false)
        XCTAssertEqual(h.app.commands.descriptor("bridge.status")?.effect, .read)
    }

    // MARK: CIDR allowlist

    func testDefaultNetworksAreLoopbackLANTailscaleAndLinkLocal() {
        let networks = BridgeNetworks.parse(BridgeNetworks.defaults)
        XCTAssertEqual(networks.count, BridgeNetworks.defaults.count, "every default parses")
        let allowed = ["127.0.0.1", "127.9.8.7", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.20",
                       "100.64.0.1", "100.127.255.254", "169.254.3.4", "::1", "fd7a:115c:a1e0::1",
                       "fd7a:115c:a1e0:ab12:4843:cd96:6258:b240", "fe80::1%en0", "::ffff:192.168.1.5", "[::1]"]
        for a in allowed {
            XCTAssertTrue(BridgeNetworks.allows(BridgeIP.parse(a), in: networks), a)
        }
        let refused = ["8.8.8.8", "172.32.0.1", "172.15.255.255", "100.128.0.1", "100.63.255.255", "192.169.0.1",
                       "11.0.0.1", "2001:db8::1", "fd7a:115c:a1e1::1", "fec0::1", "::ffff:8.8.8.8", "::2"]
        for a in refused {
            XCTAssertFalse(BridgeNetworks.allows(BridgeIP.parse(a), in: networks), a)
        }
        XCTAssertFalse(BridgeNetworks.allows(nil, in: networks), "an unknown remote address is refused")
    }

    func testCIDRParsing() {
        XCTAssertEqual(CIDR("10/8"), CIDR("10.0.0.0/8"))
        XCTAssertEqual(CIDR("172.16/12"), CIDR("172.16.0.0/12"))
        XCTAssertEqual(CIDR("10.0.0.0/8")?.prefix, 8)
        XCTAssertEqual(CIDR("fd7a:115c:a1e0::/48")?.bytes.count, 16)

        let host = CIDR("192.168.1.5")
        XCTAssertEqual(host?.prefix, 32, "a bare address is one host")
        XCTAssertTrue(host?.contains([192, 168, 1, 5]) ?? false)
        XCTAssertFalse(host?.contains([192, 168, 1, 6]) ?? true)

        let everything = CIDR("0.0.0.0/0")
        XCTAssertTrue(everything?.contains([8, 8, 8, 8]) ?? false)
        XCTAssertFalse(everything?.contains(BridgeIP.parse("2001:db8::1") ?? []) ?? true, "IPv4 ranges never match IPv6")

        for bad in ["", "abc", "10.0.0.0/33", "fe80::/129", "300.1.1.1/8", "1.2.3.4.5", "10.0.0.0/8/1", "10.0.0.0/-1",
                    "10.0.0.0/x", "/8"] {
            XCTAssertNil(CIDR(bad), bad)
        }
        XCTAssertEqual(BridgeNetworks.parse(["bad", "10/8", ""]).count, 1, "unparseable entries are skipped")
    }

    func testIPv4MappedIPv6FoldsToIPv4() {
        XCTAssertEqual(BridgeIP.parse("::ffff:192.168.1.5"), [192, 168, 1, 5])
        XCTAssertEqual(BridgeIP.parse("192.168.1.5"), [192, 168, 1, 5])
        XCTAssertEqual(BridgeIP.parse("fe80::1%utun3")?.count, 16)
        XCTAssertNil(BridgeIP.parse("ipad.local"))
    }

    func testStatusURLsListOnlyReachableAllowedAddresses() {
        let urls = LocalAddresses.urls(port: 7331, networks: BridgeNetworks.parse(BridgeNetworks.defaults),
                                       addresses: ["192.168.1.20", "8.8.8.8", "100.101.102.103", "fe80::1", "fd7a:115c:a1e0::5"])
        XCTAssertEqual(urls, ["http://192.168.1.20:7331/mcp", "http://100.101.102.103:7331/mcp",
                              "http://[fd7a:115c:a1e0::5]:7331/mcp"])
    }

    // MARK: Token and Origin

    func testTokensAreNibPrefixedBase64URLOf32RandomBytes() {
        let a = BridgeAuth.generateToken(), b = BridgeAuth.generateToken()
        XCTAssertTrue(a.hasPrefix("nib_"))
        XCTAssertEqual(a.count, 47)
        XCTAssertTrue(BridgeAuth.isWellFormed(a), a)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("+") || a.contains("/") || a.contains("="))
        XCTAssertFalse(BridgeAuth.isWellFormed("nib_short"))
        XCTAssertEqual(BridgeAuth.base64url(Data([0xfb, 0xff, 0xfe])), "-__-")
    }

    func testBearerHeaderAndConstantTimeComparison() {
        XCTAssertEqual(BridgeAuth.bearer("Bearer nib_x"), "nib_x")
        XCTAssertEqual(BridgeAuth.bearer("bearer   nib_x "), "nib_x")
        XCTAssertNil(BridgeAuth.bearer("Basic bmliOng="))
        XCTAssertNil(BridgeAuth.bearer("Bearer "))
        XCTAssertNil(BridgeAuth.bearer(nil))

        XCTAssertTrue(BridgeAuth.constantTimeEquals(token, token))
        XCTAssertFalse(BridgeAuth.constantTimeEquals(token, token + "A"))
        XCTAssertFalse(BridgeAuth.constantTimeEquals(token, String(token.dropLast()) + "B"))
        XCTAssertFalse(BridgeAuth.constantTimeEquals("", token))

        XCTAssertTrue(BridgeAuth.authorized("Bearer " + token, token: token))
        XCTAssertFalse(BridgeAuth.authorized("Bearer " + token, token: nil), "no token issued: nothing passes")
        XCTAssertFalse(BridgeAuth.authorized(nil, token: token))
        XCTAssertFalse(BridgeAuth.authorized("Bearer nib_wrong", token: token))
    }

    func testOriginMustBeAbsentOrAllowlisted() {
        XCTAssertTrue(BridgeAuth.originAllowed(nil, allowlist: []))
        XCTAssertTrue(BridgeAuth.originAllowed("", allowlist: []))
        XCTAssertFalse(BridgeAuth.originAllowed("http://evil.example", allowlist: []))
        XCTAssertFalse(BridgeAuth.originAllowed("null", allowlist: ["http://localhost:5173"]))
        XCTAssertTrue(BridgeAuth.originAllowed("HTTP://LocalHost:5173", allowlist: ["http://localhost:5173/"]))
        XCTAssertFalse(BridgeAuth.originAllowed("http://localhost:5174", allowlist: ["http://localhost:5173"]))
    }

    // MARK: Router

    func testRouterChecksNetworkThenTokenThenOrigin() async throws {
        let (h, c, _) = try make()
        setToken(token)
        let bearer = "Bearer " + token

        let outside = await c.router.route(get("/health"), remote: BridgeIP.parse("8.8.8.8"))
        XCTAssertEqual(outside.status, 403, "the network check comes before everything, /health included")
        let unknownRemote = await c.router.route(get("/health"), remote: nil)
        XCTAssertEqual(unknownRemote.status, 403)

        let health = await c.router.route(get("/health"), remote: lan)
        XCTAssertEqual(health.status, 200, "/health needs no token")
        XCTAssertEqual(try body(health), ["ok": true, "app": "nib", "api": 1])
        let postHealth = await c.router.route(HTTPRequest(method: "POST", path: "/health"), remote: lan)
        XCTAssertEqual(postHealth.status, 405)

        let missing = await c.router.route(get("/mcp"), remote: lan)
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.header("WWW-Authenticate"), "Bearer")
        XCTAssertEqual(try body(missing)["error"]?["code"], "permission_denied")
        let wrong = await c.router.route(get("/mcp", auth: "Bearer nib_" + String(repeating: "B", count: 43)), remote: lan)
        XCTAssertEqual(wrong.status, 401)

        let rebinding = await c.router.route(get("/mcp", auth: bearer, origin: "http://evil.example"), remote: lan)
        XCTAssertEqual(rebinding.status, 403, "browser pages from other origins are refused (DNS rebinding)")
        h.app.settings.set(BridgeSettings.origins, ["http://localhost:5173"])
        let allowedOrigin = await c.router.route(get("/mcp", auth: bearer, origin: "http://localhost:5173"), remote: lan)
        XCTAssertEqual(allowedOrigin.status, 405, "past the checks: GET /mcp has no server-initiated stream")

        let tailscale = await c.router.route(get("/mcp/", auth: bearer), remote: BridgeIP.parse("fd7a:115c:a1e0::9"))
        XCTAssertEqual(tailscale.status, 405)
        let unknown = await c.router.route(get("/nope", auth: bearer), remote: lan)
        XCTAssertEqual(unknown.status, 404)
        let getCall = await c.router.route(get("/api/v1/call", auth: bearer), remote: lan)
        XCTAssertEqual(getCall.status, 405)

        h.app.settings.set(BridgeSettings.networks, ["10.0.0.0/8"])
        let narrowed = await c.router.route(get("/health"), remote: lan)
        XCTAssertEqual(narrowed.status, 403, "the allowed networks come from the user's setting")

        setToken(nil)
        h.app.settings.set(BridgeSettings.networks, BridgeNetworks.defaults)
        let noToken = await c.router.route(get("/mcp", auth: bearer), remote: lan)
        XCTAssertEqual(noToken.status, 401, "a token missing from the Keychain lets nobody in")
    }

    func testRESTCallReturnsTheInvocationResultAndMapsErrors() async throws {
        let (_, c, _) = try make()
        setToken(token)
        let headers = ["Authorization": "Bearer " + token, "X-Nib-Client": "smoke"]
        func call(_ json: String) async -> HTTPResponse {
            await c.router.route(HTTPRequest(method: "POST", path: "/api/v1/call", headers: headers, body: Data(json.utf8)),
                                 remote: lan)
        }
        let ok = await call(#"{"command":"test.whoami","params":{}}"#)
        XCTAssertEqual(ok.status, 200)
        let result = try body(ok)
        XCTAssertEqual(result["value"]?["principal"], "bridge:smoke")
        XCTAssertEqual(result["changes"]?["created"], [])
        XCTAssertNotNil(result["group"]?.stringValue)
        XCTAssertEqual(c.status().lastCall?.client, "smoke")
        XCTAssertEqual(c.status().lastCall?.tool, "api")

        let edit = await call(#"{"command":"test.rename","params":{"page":"page:FIXTUREDOC01/FIXTUREPG002","title":"Smoke"},"dryRun":true}"#)
        XCTAssertEqual(try body(edit)["changes"]?["updated"], ["page:FIXTUREDOC01/FIXTUREPG002"])

        let unknown = await call(#"{"command":"nope.missing"}"#)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(try body(unknown)["error"]?["code"], "not_found")
        let security = await call(#"{"command":"bridge.setEnabled","params":{"enabled":false}}"#)
        XCTAssertEqual(security.status, 403, "bridge control is user-only")
        XCTAssertEqual(try body(security)["error"]?["code"], "permission_denied")
        let invalid = await call(#"{"command":"test.rename","params":{}}"#)
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(try body(invalid)["error"]?["path"], "$.page")
        let noCommand = await call(#"{"params":{}}"#)
        XCTAssertEqual(noCommand.status, 400)
        let notJSON = await call("[1,2]")
        XCTAssertEqual(notJSON.status, 400)
        XCTAssertEqual(c.status().lastCall?.error, "invalid_params")
    }

    func testAssetLinksLastFiveMinutes() {
        let assets = BridgeAssets()
        var now = Date(timeIntervalSince1970: 1_000)
        assets.now = { now }
        let link = assets.link("render.png")
        XCTAssertEqual(link.count, 22, "16 random bytes, base64url")
        XCTAssertEqual(assets.resolve(link), "render.png")
        XCTAssertNil(assets.resolve("nope"))
        now = now.addingTimeInterval(299)
        XCTAssertEqual(assets.resolve(link), "render.png")
        now = now.addingTimeInterval(2)
        XCTAssertNil(assets.resolve(link), "expired after 5 minutes")
    }

    // MARK: Commands and lifecycle

    func testSetEnabledIsUserOnlyIssuesATokenAndStartsTheListener() async throws {
        let (h, c, server) = try make()
        setToken(nil)
        do {
            try await h.run("bridge.setEnabled", ["enabled": true], as: .bridge("claude-code"))
            XCTFail("the bridge cannot turn itself on")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("bridge.setEnabled", ["enabled": true], as: .ai("chat"))
            XCTFail("the AI cannot turn the bridge on")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        XCTAssertEqual(server.started, 0)

        let on = try await h.run("bridge.setEnabled", ["enabled": true])
        XCTAssertEqual(on["tokenIssued"], true)
        XCTAssertEqual(on["state"], "starting")
        XCTAssertEqual(on["port"], 7331)
        let issued = try XCTUnwrap(BridgeSecrets.token())
        XCTAssertTrue(BridgeAuth.isWellFormed(issued))
        XCTAssertEqual(server.started, 1)

        c.serverEvent(.ready(port: 7331), generation: c.generation)
        let status = try await h.run("bridge.status", as: .bridge("claude-code"))
        XCTAssertEqual(status["state"], "listening")
        XCTAssertEqual(status["running"], true)
        XCTAssertEqual(status["bonjour"], "_nib._tcp")
        XCTAssertEqual(status["tokenMissing"], false)
        for url in status["urls"]?.arrayValue ?? [] {
            XCTAssertTrue(url.stringValue?.hasSuffix(":7331/mcp") ?? false, "\(url)")
        }
        XCTAssertFalse(status.jsonString().contains(issued), "bridge.status never reveals the token")

        let again = try await h.run("bridge.setEnabled", ["enabled": true])
        XCTAssertEqual(again["tokenIssued"], false, "an existing token is kept")
        XCTAssertEqual(BridgeSecrets.token(), issued)
        XCTAssertEqual(server.started, 1, "already listening on the same port: no restart")

        let off = try await h.run("bridge.setEnabled", ["enabled": false])
        XCTAssertEqual(off["state"], "off")
        XCTAssertEqual(server.stopped, 1)
        XCTAssertFalse(h.app.settings.get(BridgeSettings.enabled))
    }

    func testRotatingTheTokenEndsEverySession() async throws {
        let (h, c, _) = try make()
        setToken(token)
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#
        _ = await c.mcp.handle(HTTPRequest(method: "POST", path: "/mcp", body: Data(initialize.utf8)),
                               baseURL: "http://127.0.0.1:7331")
        XCTAssertEqual(c.mcp.sessions.count, 1)
        let r = try await h.run("bridge.setEnabled", ["enabled": true, "rotateToken": true])
        XCTAssertEqual(r["tokenIssued"], true)
        let rotated = try XCTUnwrap(BridgeSecrets.token())
        XCTAssertNotEqual(rotated, token)
        XCTAssertTrue(c.mcp.sessions.isEmpty)
        let old = await c.router.route(get("/mcp", auth: "Bearer " + token), remote: lan)
        XCTAssertEqual(old.status, 401, "clients of the old token must re-pair")
    }

    func testListenerRunsOnlyInTheForeground() throws {
        let (h, c, server) = try make()
        setToken(token)
        h.app.settings.set(BridgeSettings.enabled, true)
        c.reconcile()
        XCTAssertEqual(server.started, 1)
        c.setForeground(false)
        XCTAssertEqual(c.status().state, "suspended")
        XCTAssertEqual(server.stopped, 1)
        c.setForeground(true)
        XCTAssertEqual(server.started, 2, "recreated when the app returns to the foreground")
        XCTAssertEqual(c.status().state, "starting")

        setToken(nil)
        c.reconcile()
        let status = c.status()
        XCTAssertEqual(status.state, "tokenMissing")
        XCTAssertTrue(status.tokenMissing)
        XCTAssertTrue(status.error?.contains("credentials missing") ?? false)
        XCTAssertEqual(server.stopped, 2)
    }

    func testBridgeConfirmationPolicyComesFromItsSecuritySetting() throws {
        let (h, _, _) = try make()
        let edit = try XCTUnwrap(h.app.commands.descriptor("test.rename"))
        let wipe = try XCTUnwrap(h.app.commands.descriptor("test.wipe"))
        let gateway = h.app.gateway
        XCTAssertFalse(gateway.needsConfirmation(edit, principal: .bridge("x")))
        XCTAssertTrue(gateway.needsConfirmation(wipe, principal: .bridge("x")), "destructive by default")
        h.app.settings.set(NibSettings.bridgeConfirmationPolicy, .always)
        XCTAssertTrue(gateway.needsConfirmation(edit, principal: .bridge("x")))
        XCTAssertFalse(gateway.needsConfirmation(edit, principal: .ai("chat")), "other principals keep their policy")
        h.app.settings.set(NibSettings.bridgeConfirmationPolicy, .never)
        XCTAssertFalse(gateway.needsConfirmation(wipe, principal: .bridge("x")))
        var sensitive = edit
        sensitive.sensitive = true
        XCTAssertTrue(gateway.needsConfirmation(sensitive, principal: .bridge("x")), "sensitive commands are always confirmed")
    }
}
