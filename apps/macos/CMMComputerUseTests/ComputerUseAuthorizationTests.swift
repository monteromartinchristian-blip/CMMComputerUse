import XCTest

/// Regression tests for per-application authorization
/// (apps/macos/Shared/ComputerUseAuthorization.swift).
///
/// The claim being pinned: TCC grants the HELPER process, not an application,
/// so the helper itself must decide — per app, per scope, per window — what a
/// client may touch, and must deny everything it was not explicitly told to
/// allow. These are the exact rules the live helper enforces; they are pure
/// Foundation so they can be exercised without a window server.
final class ComputerUseAuthorizationTests: XCTestCase {

    private func parse(_ json: String) -> BridgeAuthorizationPolicy? {
        BridgeAuthorizationPolicy.parse(
            Data(json.utf8), source: "/tmp/policy.json")
    }

    private let fixtureGrant = """
    {"version":1,"mode":"background","default":"deny","apps":[
      {"bundle_id":"com.cmm.cu.fixture","name":"CMM CU Fixture",
       "scopes":["observe","control"],"windows":["Fixture"]}
    ]}
    """

    // MARK: - Parsing

    func testValidPolicyLoadsGrantAndMode() {
        guard let policy = parse(fixtureGrant) else { return XCTFail("valid policy must parse") }
        XCTAssertEqual(policy.mode, .background)
        XCTAssertTrue(policy.loaded)
        XCTAssertEqual(policy.grants.count, 1)
        XCTAssertEqual(policy.grants[0].bundleID, "com.cmm.cu.fixture")
        XCTAssertEqual(policy.grants[0].scopes, [.observe, .control])
        XCTAssertEqual(policy.grants[0].windowPatterns, ["Fixture"])
    }

    func testMalformedJSONIsRejected() {
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse("[]"))
    }

    func testVersionIsExplicitlyBounded() {
        // Version 1 authorizes applications; version 2 adds the client
        // dimension. Anything else is refused rather than read optimistically.
        XCTAssertNotNil(parse(#"{"version":1,"mode":"background","apps":[]}"#))
        XCTAssertNotNil(parse(#"{"version":2,"mode":"background","apps":[]}"#))
        XCTAssertNil(parse(#"{"version":3,"mode":"background","apps":[]}"#))
        XCTAssertNil(parse(#"{"version":0,"mode":"background","apps":[]}"#))
    }

    // MARK: - Clients (version 2)

    private let fixtureClients = """
    {"version":2,"mode":"background","default":"deny","apps":[
      {"bundle_id":"com.cmm.cu.fixture","name":"CMM CU Fixture","scopes":["observe","control"]},
      {"bundle_id":"com.cmm.cu.other","name":"CMM CU Other","scopes":["observe"]}
    ],"clients":[
      {"client_id":"alpha","requirement":"identifier \\"com.cmm.cu.alpha\\"",
       "apps":["com.cmm.cu.fixture"],"scopes":["observe"]},
      {"client_id":"beta","requirement":"identifier \\"com.cmm.cu.beta\\"",
       "apps":["com.cmm.cu.fixture"],"scopes":["observe","control"]}
    ]}
    """

    func testVersionOneDocumentHasNoClientDimensionAndSaysSo() {
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        XCTAssertEqual(policy.clientAuthorization, .legacyNone)
        XCTAssertTrue(policy.clients.isEmpty)
        // Legacy documents keep working: the app grant is the only gate.
        XCTAssertTrue(policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "Fixture", scope: .control).isAllowed)
    }

    func testVersionTwoWithClientsRequiresOneAndReportsIt() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        XCTAssertEqual(policy.clientAuthorization, .required)
        XCTAssertEqual(policy.clients.map(\.clientID), ["alpha", "beta"])
        XCTAssertEqual(policy.clients[0].scopes, [.observe])
        XCTAssertEqual(policy.clients[1].scopes, [.observe, .control])
    }

    func testVersionOneDocumentCarryingClientsIsContradictoryAndRefused() {
        XCTAssertNil(parse("""
        {"version":1,"mode":"background","apps":[],"clients":[
          {"client_id":"alpha","requirement":"identifier \\"x\\"","apps":["a"],"scopes":["observe"]}]}
        """))
    }

    func testClientDimensionDeniesWhenNoClientMatched() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        // nil = the peer's code identity satisfied nobody's requirement.
        let refusal = policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "Fixture", scope: .observe, client: nil).refusal
        XCTAssertEqual(refusal?.code, "APPROVAL_REJECTED")
        XCTAssertEqual(refusal?.detail.contains("client_not_authorized"), true)
    }

    func testClientCannotExceedItsOwnScopes() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        let alpha = policy.clients[0]
        // The APPLICATION grants control; the CLIENT only observe. The
        // intersection is what applies, so control is refused.
        let refusal = policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "Fixture", scope: .control, client: alpha).refusal
        XCTAssertEqual(refusal?.detail.contains("client_scope_not_granted"), true)
        XCTAssertTrue(policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "Fixture", scope: .observe, client: alpha).isAllowed)
    }

    func testClientCannotReachAnApplicationItWasNotGranted() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        let alpha = policy.clients[0]
        // Granted by the deployment, but not to this client.
        let refusal = policy.decision(
            bundleID: "com.cmm.cu.other", name: "CMM CU Other",
            windowTitle: nil, scope: .observe, client: alpha).refusal
        XCTAssertEqual(refusal?.detail.contains("client_app_not_granted"), true)
    }

    func testApplicationAbsentFromTheDeploymentIsReportedAsSuchToAnAuthorizedClient() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        let alpha = policy.clients[0]
        // Nothing granted this application, so the answer is about the
        // application, not about the client's slice of it.
        let refusal = policy.decision(
            bundleID: "com.apple.finder", name: "Finder",
            windowTitle: nil, scope: .observe, client: alpha).refusal
        XCTAssertEqual(refusal?.detail.contains("app_not_granted"), true)
        XCTAssertEqual(refusal?.detail.contains("client_app_not_granted"), false)
    }

    func testDisplayNameRequestIsJudgedAgainstTheResolvedGrant() {
        guard let policy = parse(fixtureClients) else { return XCTFail("parse") }
        let alpha = policy.clients[0]
        // A caller that names the application "CMM CU Fixture" (display name, no
        // bundle id) must be judged against the grant's identifiers, or a client
        // written in bundle ids would appear unauthorized.
        XCTAssertTrue(policy.decision(
            bundleID: "", name: "CMM CU Fixture", windowTitle: nil,
            scope: .observe, client: alpha).isAllowed)
    }

    func testClientWithNoAppsAuthorizesNothing() {
        guard let policy = parse("""
        {"version":2,"mode":"background","default":"deny","apps":[
          {"bundle_id":"com.cmm.cu.fixture","scopes":["observe"]}],
         "clients":[{"client_id":"empty","requirement":"identifier \\"x\\"","scopes":["observe"]}]}
        """) else { return XCTFail("parse") }
        let client = policy.clients[0]
        // Empty apps means NONE, never "any".
        XCTAssertFalse(policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "", windowTitle: nil,
            scope: .observe, client: client).isAllowed)
    }

    func testClientEntryWithoutRequirementOrIdentifierIsRefused() {
        XCTAssertNil(parse("""
        {"version":2,"mode":"background","apps":[],"clients":[{"client_id":"a","apps":[]}]}
        """))
        XCTAssertNil(parse("""
        {"version":2,"mode":"background","apps":[],"clients":[{"requirement":"identifier \\"a\\""}]}
        """))
        XCTAssertNil(parse("""
        {"version":2,"mode":"background","apps":[],"clients":[{"client_id":"a","requirement":"x","scopes":["write"]}]}
        """))
    }

    func testEmptyClientListIsStillRequiredAndDeniesEveryone() {
        guard let policy = parse(#"{"version":2,"mode":"background","apps":[],"clients":[]}"#) else {
            return XCTFail("an explicit empty client list is a valid, strict document")
        }
        XCTAssertEqual(policy.clientAuthorization, .required)
        XCTAssertFalse(policy.decision(
            bundleID: "a", name: "", windowTitle: nil, scope: .observe, client: nil).isAllowed)
    }

    func testUnknownModeIsRejected() {
        // A typo must not quietly become the permissive mode.
        XCTAssertNil(parse(#"{"version":1,"mode":"backgroundd","apps":[]}"#))
    }

    func testNonDenyDefaultIsRejected() {
        XCTAssertNil(parse(#"{"version":1,"mode":"background","default":"allow","apps":[]}"#))
    }

    func testUnknownScopeIsRejected() {
        // A misspelled scope is a typo, not a grant.
        XCTAssertNil(parse("""
        {"version":1,"mode":"background","apps":[
          {"bundle_id":"com.example.app","scopes":["observ","control"]}]}
        """))
    }

    func testGrantWithoutNameOrBundleIsRejected() {
        XCTAssertNil(parse(#"{"version":1,"mode":"background","apps":[{"scopes":["observe"]}]}"#))
    }

    func testEmptyPolicyIsValidAndDeniesEverything() {
        guard let policy = parse(#"{"version":1,"mode":"background"}"#) else {
            return XCTFail("a policy with no apps is a valid deny-all document")
        }
        XCTAssertTrue(policy.loaded)
        XCTAssertTrue(policy.grants.isEmpty)
        XCTAssertEqual(
            policy.decision(bundleID: "com.apple.finder", name: "Finder",
                            windowTitle: "Desktop", scope: .observe).refusal?.code,
            "APPROVAL_REJECTED")
    }

    func testMissingFilePolicyIsDenyAllAndNotLoaded() {
        let policy = BridgeAuthorizationPolicy.denyAll(source: "/tmp/missing.json")
        XCTAssertFalse(policy.loaded)
        XCTAssertTrue(policy.grants.isEmpty)
        XCTAssertEqual(
            policy.decision(bundleID: "com.apple.finder", name: "Finder",
                            windowTitle: "Desktop", scope: .control).refusal?.detail
                .contains("auth=app_not_granted"), true)
    }

    // MARK: - Matching

    func testGrantMatchesByBundleIDAndByName() {
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        XCTAssertNotNil(policy.grant(bundleID: "com.cmm.cu.fixture", name: ""))
        XCTAssertNotNil(policy.grant(bundleID: "", name: "CMM CU Fixture"))
        XCTAssertNotNil(policy.grant(bundleID: "COM.CMM.CU.FIXTURE", name: "x"))
    }

    func testGrantDoesNotMatchByPrefixOrFuzzyName() {
        // A prefix match would authorize the wrong application.
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        XCTAssertNil(policy.grant(bundleID: "com.cmm.cu.fixture.evil", name: ""))
        XCTAssertNil(policy.grant(bundleID: "", name: "CMM CU Fixture Pro"))
        XCTAssertNil(policy.grant(bundleID: "", name: "CMM CU"))
    }

    // MARK: - Scope separation

    func testObserveOnlyGrantCannotControl() {
        let policy = parse("""
        {"version":1,"mode":"background","apps":[
          {"bundle_id":"com.example.app","scopes":["observe"]}]}
        """)
        guard let policy else { return XCTFail("parse") }
        XCTAssertEqual(
            policy.decision(bundleID: "com.example.app", name: "App",
                            windowTitle: "W", scope: .observe), .allowed)
        let refusal = policy.decision(
            bundleID: "com.example.app", name: "App", windowTitle: "W", scope: .control).refusal
        XCTAssertEqual(refusal?.code, "APPROVAL_REJECTED")
        XCTAssertEqual(refusal?.detail.contains("auth=scope_not_granted"), true)
        XCTAssertEqual(refusal?.detail.contains("scope=control"), true)
        XCTAssertEqual(refusal?.detail.contains("granted=observe"), true)
    }

    func testControlOnlyGrantCannotObserve() {
        let policy = parse("""
        {"version":1,"mode":"background","apps":[
          {"bundle_id":"com.example.app","scopes":["control"]}]}
        """)
        guard let policy else { return XCTFail("parse") }
        XCTAssertEqual(
            policy.decision(bundleID: "com.example.app", name: "App",
                            windowTitle: "W", scope: .control), .allowed)
        XCTAssertEqual(
            policy.decision(bundleID: "com.example.app", name: "App",
                            windowTitle: "W", scope: .observe).refusal?.detail.contains("scope=observe"),
            true)
    }

    func testGrantWithoutScopesAllowsNothing() {
        let policy = parse(#"{"version":1,"mode":"background","apps":[{"bundle_id":"com.example.app"}]}"#)
        guard let policy else { return XCTFail("parse") }
        for scope in BridgeScope.allCases {
            XCTAssertFalse(
                policy.decision(bundleID: "com.example.app", name: "App",
                                windowTitle: "W", scope: scope).isAllowed)
        }
    }

    func testUnauthorizedApplicationIsRefusedWithTheMissingFact() {
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        let refusal = policy.decision(
            bundleID: "com.apple.mail", name: "Mail", windowTitle: "Inbox", scope: .observe).refusal
        XCTAssertEqual(refusal?.code, "APPROVAL_REJECTED")
        XCTAssertEqual(refusal?.detail.contains("app_not_granted"), true)
        XCTAssertEqual(refusal?.detail.contains("com.apple.mail"), true)
    }

    // MARK: - Window limits

    func testEmptyWindowListAllowsAnyWindowOfTheApp() {
        let policy = parse("""
        {"version":1,"mode":"background","apps":[
          {"bundle_id":"com.example.app","scopes":["observe","control"]}]}
        """)
        guard let policy else { return XCTFail("parse") }
        XCTAssertTrue(policy.decision(
            bundleID: "com.example.app", name: "App",
            windowTitle: "anything at all", scope: .control).isAllowed)
    }

    func testNamedWindowIsTheOnlyAuthorizedOne() {
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        XCTAssertTrue(policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "CMM CU Fixture — window", scope: .control).isAllowed)
        let refusal = policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "Algo distinto", scope: .control).refusal
        XCTAssertEqual(refusal?.detail.contains("auth=window_not_granted"), true)
    }

    func testEmptyTitleWithNamedWindowsIsRefused() {
        // An unidentifiable window cannot be assumed to be the authorized one.
        guard let policy = parse(fixtureGrant) else { return XCTFail("parse") }
        XCTAssertFalse(policy.decision(
            bundleID: "com.cmm.cu.fixture", name: "CMM CU Fixture",
            windowTitle: "", scope: .control).isAllowed)
    }

    // MARK: - Capture

    func testDisplayCaptureIsRefusedUnderAuthorization() {
        let refusal = bridgeAuthorizedCaptureDecision(
            mode: .unrestricted, hasWindowTarget: false, authorizationLoaded: true).refusal
        XCTAssertEqual(refusal?.code, "APPROVAL_REJECTED")
        XCTAssertEqual(refusal?.detail.contains("display_capture_not_permitted"), true)
        XCTAssertEqual(
            bridgeAuthorizedCaptureDecision(
                mode: .background, hasWindowTarget: true, authorizationLoaded: true), .allowed)
    }
}
