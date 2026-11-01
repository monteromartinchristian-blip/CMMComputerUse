import Security
import XCTest

/// The client dimension of a policy is a code-signing requirement, and a
/// requirement has three states a person has to be able to tell apart:
/// it does not compile, it compiles and does not match, it compiles and matches.
/// Before `ComputerUseRequirement.swift` existed the helper could only ever
/// answer the last two, folded into "no client matched".
final class ComputerUseRequirementTests: XCTestCase {

    // MARK: Compilation

    func testAWellFormedRequirementCompiles() {
        let verdict = bridgeCompileRequirement(
            #"identifier "com.cmm.console" and anchor apple generic"#)
        XCTAssertTrue(verdict.compiles)
        XCTAssertEqual(verdict.status, errSecSuccess)
        XCTAssertEqual(verdict.message, "ok")
    }

    func testAnUnterminatedStringDoesNotCompileAndIsNamedAsSuch() {
        let verdict = bridgeCompileRequirement(
            #"identifier "com.cmm.console and anchor apple generic"#)
        XCTAssertFalse(verdict.compiles)
        XCTAssertEqual(verdict.status, errSecCSReqInvalid)
        XCTAssertEqual(verdict.message, "invalid_requirement")
    }

    func testAnUnknownAttributeDoesNotCompile() {
        let verdict = bridgeCompileRequirement(#"identifier "x" and nope_attr = "y""#)
        XCTAssertFalse(verdict.compiles)
        XCTAssertEqual(verdict.message, "invalid_requirement")
    }

    func testAnEmptyRequirementDoesNotCompile() {
        XCTAssertFalse(bridgeCompileRequirement("").compiles)
        XCTAssertFalse(bridgeCompileRequirement("   \n ").compiles)
    }

    /// A wildcard compiles: it is a legal requirement that describes a binary
    /// whose identifier literally contains an asterisk. The helper reports the
    /// truth; deciding that this is a mistake is a host policy decision, and
    /// Console rejects it. Pinned here so nobody "fixes" the helper by silently
    /// refusing a syntactically valid expression.
    func testAWildcardCompilesBecauseItIsSyntaxNotSemantics() {
        XCTAssertTrue(bridgeCompileRequirement(#"identifier "com.cmm.*""#).compiles)
    }

    // MARK: Canonical digests

    func testTheRequirementDigestIgnoresSurroundingWhitespace() {
        let plain = bridgeRequirementDigest(#"identifier "a""#)
        let padded = bridgeRequirementDigest("  \n" + #"identifier "a""# + "\t ")
        XCTAssertEqual(plain, padded)
        XCTAssertEqual(plain.count, 64)
        XCTAssertNotEqual(plain, bridgeRequirementDigest(#"identifier "b""#))
    }

    func testTheAppsDigestIsOrderCaseAndDuplicateInsensitive() {
        let base = bridgeAppsDigest(["com.example.A", "com.example.B"])
        XCTAssertEqual(base, bridgeAppsDigest(["com.example.b", "com.example.a"]))
        XCTAssertEqual(base, bridgeAppsDigest(["com.example.B", " com.example.A ", "com.example.a"]))
        XCTAssertEqual(base, bridgeAppsDigest(["com.example.A", "", "com.example.B"]))
        XCTAssertNotEqual(base, bridgeAppsDigest(["com.example.A"]))
        XCTAssertEqual(
            bridgeAppsDigest([]), bridgeAppsDigest(["  "]),
            "an empty list and a list of blanks describe the same grant: none")
    }

    // MARK: Evaluation against a code object

    func testARequirementMatchesTheCodeItDescribes() throws {
        // /bin/ls is a stable, Apple-signed binary on every macOS install.
        let matching = bridgeRequirementMatches(#"identifier "com.apple.ls""#, codeAtPath: "/bin/ls")
        XCTAssertEqual(matching, true)
        let anchored = bridgeRequirementMatches(
            #"identifier "com.apple.ls" and anchor apple generic"#, codeAtPath: "/bin/ls")
        XCTAssertEqual(anchored, true)
        let other = bridgeRequirementMatches(#"identifier "com.example.nope""#, codeAtPath: "/bin/ls")
        XCTAssertEqual(other, false)
    }

    func testAnUnreadablePathIsUnknownNotAMismatch() {
        XCTAssertNil(bridgeRequirementMatches(
            #"identifier "com.apple.ls""#, codeAtPath: "/does/not/exist"))
    }

    func testAnExtraClauseThatTheCodeDoesNotSatisfyIsAMismatch() {
        // `identifier` alone matches; adding a clause the binary does not
        // satisfy must turn that into a mismatch. This is the difference a weak
        // requirement hides: it compiles, it matches, and it names nothing.
        XCTAssertEqual(
            bridgeRequirementMatches(#"identifier "com.apple.ls""#, codeAtPath: "/bin/ls"), true)
        XCTAssertEqual(
            bridgeRequirementMatches(
                #"identifier "com.apple.ls" and certificate leaf[subject.OU] = "NOPE""#,
                codeAtPath: "/bin/ls"),
            false)
    }

    // MARK: Load-time audit

    private func policy(_ json: String) -> BridgeAuthorizationPolicy? {
        BridgeAuthorizationPolicy.parse(Data(json.utf8), source: "/tmp/policy.json")
    }

    func testAuditAcceptsACompilingClientDimension() throws {
        let parsed = try XCTUnwrap(policy("""
        {"version":2,"mode":"background","default":"deny","apps":[],"clients":[
          {"client_id":"console","requirement":"identifier \\"com.cmm.console\\" and anchor apple generic",
           "apps":["com.example.A"],"scopes":["observe"]}]}
        """))
        let audit = bridgeAuditClientRequirements(parsed)
        XCTAssertTrue(audit.isValid)
        XCTAssertEqual(audit.verdicts["console"]?.compiles, true)
    }

    func testAuditNamesEveryClientWhoseRequirementCannotCompile() throws {
        let parsed = try XCTUnwrap(policy("""
        {"version":2,"mode":"background","default":"deny","apps":[],"clients":[
          {"client_id":"good","requirement":"identifier \\"a\\""},
          {"client_id":"typo","requirement":"identifier \\"a and anchor apple generic"},
          {"client_id":"worse","requirement":"not_a_requirement"}]}
        """))
        let audit = bridgeAuditClientRequirements(parsed)
        XCTAssertFalse(audit.isValid)
        XCTAssertEqual(audit.invalidClientIDs, ["typo", "worse"])
        XCTAssertEqual(audit.verdicts["good"]?.compiles, true)
        XCTAssertEqual(audit.verdicts["typo"]?.message, "invalid_requirement")
    }

    func testAuditOfADocumentWithoutClientsIsTriviallyValid() throws {
        let parsed = try XCTUnwrap(policy(
            #"{"version":1,"mode":"background","default":"deny","apps":[]}"#))
        XCTAssertTrue(bridgeAuditClientRequirements(parsed).isValid)
    }
}
