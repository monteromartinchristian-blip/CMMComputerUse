// ComputerUseAuthorization.swift — per-application authorization for the CMM
// Computer Use bridge.
//
// WHY THIS EXISTS
//
// TCC is a consent about the HELPER: once the person grants Accessibility to
// CMMComputerUse.app, that process can read and drive every application. That
// is the wrong granularity for a reusable capability: a client asking about a
// rehearsal app must not be able to read a mail window, and permission to
// LOOK at an application is not permission to ACT on it.
//
// So the deployment carries an explicit, user-owned allowlist
// (~/.cmm/computer-bridge/policy.json). Rules:
//
// - DENY BY DEFAULT. No file, unreadable file, malformed file, or an app that
//   is not listed all mean "no access". A broken policy never falls back to
//   permissive behaviour.
// - SEPARATE SCOPES. `observe` (read the AX tree, capture that app's window)
//   and `control` (press / set value on its elements) are granted separately.
//   Observe does not imply control.
// - WINDOW LIMITS. A grant may name window title fragments; an empty list
//   means any window of that application, and a named list means only those.
//
// VERSION 2 adds the CLIENT dimension. A v1 document authorizes APPLICATIONS;
// it says nothing about which program may connect, so the socket boundary is
// only the file system (see docs/client-authentication.md). A v2 document also
// lists `clients`, each with a code-signing requirement, and then a request that
// touches an application must satisfy BOTH dimensions:
//
//   effective = application grant ∩ client grant (by verified code identity)
//
// The client identity is NEVER taken from the request: it is resolved from the
// peer process and validated against a designated requirement (see
// ComputerUseClientIdentity.swift). A self-declared identifier is not a control.
//
// Pure Foundation, no AppKit, no Security: the decision rules here are values and
// policies. Resolving a peer to a SecCode lives in ComputerUseClientIdentity.swift,
// so these rules stay testable on any machine, with or without signing identities.

import Foundation

/// What a client may do with one authorized application.
public enum BridgeScope: String, CaseIterable, Sendable {
    /// Read the accessibility tree of its windows and capture them.
    case observe
    /// Act on its elements (press, set value).
    case control
}

/// One application the deployment authorizes, with its own scopes and windows.
public struct BridgeAppGrant: Equatable, Sendable {
    /// Bundle id, when the policy names one. Exact, case-insensitive.
    public var bundleID: String
    /// Display name, as `NSRunningApplication.localizedName` reports it.
    public var name: String
    public var scopes: Set<BridgeScope>
    /// Window title fragments. Empty means "any window of this application".
    public var windowPatterns: [String]

    public init(
        bundleID: String = "", name: String = "",
        scopes: Set<BridgeScope> = [], windowPatterns: [String] = []
    ) {
        self.bundleID = bundleID
        self.name = name
        self.scopes = scopes
        self.windowPatterns = windowPatterns
    }

    /// Does this grant match the application?
    ///
    /// Exact bundle id first, then exact display name — the same "unknown stays
    /// unknown" rule the rest of the bridge uses. Never a prefix or fuzzy match:
    /// a policy that matched by prefix would authorize the wrong app.
    public func matches(bundleID candidateBundle: String, name candidateName: String) -> Bool {
        if !bundleID.isEmpty,
           bundleID.caseInsensitiveCompare(candidateBundle) == .orderedSame {
            return true
        }
        if !name.isEmpty, name.caseInsensitiveCompare(candidateName) == .orderedSame {
            return true
        }
        return false
    }

    /// Is this window title covered by the grant?
    public func covers(windowTitle: String) -> Bool {
        if windowPatterns.isEmpty { return true }
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title cannot be verified against a named window list: refuse
        // rather than assume the window is the authorized one.
        guard !title.isEmpty else { return false }
        for pattern in windowPatterns {
            let fragment = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            if title.range(of: fragment, options: .caseInsensitive) != nil { return true }
        }
        return false
    }
}

/// Whether this deployment can verify WHO is asking.
public enum BridgeClientAuthorization: String, Sendable {
    /// A version-1 document. There is no client dimension at all: the bridge is
    /// reachable by any process running as this user. Reported explicitly so it
    /// can never be mistaken for "clients are authenticated".
    case legacyNone = "legacy_none"
    /// A version-2 document that lists clients. Every request that touches an
    /// application must match exactly one client by verified code identity.
    case required
}

/// One program allowed to use the bridge, identified by what it IS, not by what
/// it claims.
public struct BridgeClientGrant: Equatable, Sendable {
    /// Diagnostic label. Never used to authorize: a caller can invent any string.
    public var clientID: String
    /// A code-signing designated requirement, evaluated against the peer's
    /// SecCode. This is the only load-bearing field.
    public var requirement: String
    /// Exact bundle ids or display names this client may touch. EMPTY MEANS NONE,
    /// never "any": a client that authenticates but is granted no application
    /// can do nothing with one.
    public var apps: [String]
    public var scopes: Set<BridgeScope>

    public init(
        clientID: String, requirement: String,
        apps: [String] = [], scopes: Set<BridgeScope> = []
    ) {
        self.clientID = clientID
        self.requirement = requirement
        self.apps = apps
        self.scopes = scopes
    }

    /// Does this client cover that application? Exact bundle id or exact display
    /// name — the same rule an application grant uses.
    public func covers(bundleID: String, name: String) -> Bool {
        for entry in apps {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.caseInsensitiveCompare(bundleID) == .orderedSame { return true }
            if !name.isEmpty, value.caseInsensitiveCompare(name) == .orderedSame { return true }
        }
        return false
    }
}

/// The deployment's authorization document, as loaded at startup.
public struct BridgeAuthorizationPolicy: Equatable, Sendable {
    /// Version 1 authorizes applications. Version 2 adds the client dimension.
    /// Anything else is refused rather than read optimistically.
    public static let supportedVersions: Set<Int> = [1, 2]
    public static let latestVersion = 2

    /// Ceiling declared by the file itself. The helper applies the stricter of
    /// this and its launch flag, so neither alone can widen what runs.
    public let mode: BridgeInteractionMode
    public let grants: [BridgeAppGrant]
    /// Empty unless the document is version 2 with a `clients` array.
    public let clients: [BridgeClientGrant]
    public let clientAuthorization: BridgeClientAuthorization
    /// Where this policy came from (file path), for diagnostics only.
    public let source: String
    /// False when no file was readable: the allowlist is then empty and every
    /// target is refused.
    public let loaded: Bool

    public init(
        mode: BridgeInteractionMode, grants: [BridgeAppGrant],
        source: String, loaded: Bool,
        clients: [BridgeClientGrant] = [],
        clientAuthorization: BridgeClientAuthorization = .legacyNone
    ) {
        self.mode = mode
        self.grants = grants
        self.source = source
        self.loaded = loaded
        self.clients = clients
        self.clientAuthorization = clientAuthorization
    }

    /// The strict state: nothing authorized, nothing observable.
    public static func denyAll(source: String) -> BridgeAuthorizationPolicy {
        BridgeAuthorizationPolicy(
            mode: .background, grants: [], source: source, loaded: false,
            clients: [], clientAuthorization: .legacyNone)
    }

    /// Parse a policy document. Returns nil for anything malformed, so the
    /// caller can fall back to ``denyAll`` and never to a permissive default.
    public static func parse(_ data: Data, source: String) -> BridgeAuthorizationPolicy? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let document = object as? [String: Any]
        else { return nil }
        guard let version = document["version"] as? Int,
              supportedVersions.contains(version)
        else { return nil }
        guard let rawMode = document["mode"] as? String,
              let mode = BridgeInteractionMode(flag: rawMode)
        else { return nil }
        // `default` exists only so a future version can say something else; in
        // version 1 anything other than "deny" is a malformed policy, not a
        // permission.
        if let fallback = document["default"] as? String,
           fallback.caseInsensitiveCompare("deny") != .orderedSame {
            return nil
        }
        // Version 1 has no client dimension. A v1 document that also carries
        // `clients` is contradictory, so it is refused instead of being read as
        // either one of the two meanings.
        var clients: [BridgeClientGrant] = []
        var clientAuthorization: BridgeClientAuthorization = .legacyNone
        if document["clients"] != nil {
            guard version >= 2 else { return nil }
            guard let rawClients = document["clients"] as? [[String: Any]] else { return nil }
            for rawClient in rawClients {
                guard let client = parseClient(rawClient) else { return nil }
                clients.append(client)
            }
            // Present-but-empty still means "clients are required and none is
            // authorized", which is the strict reading.
            clientAuthorization = .required
        }

        var grants: [BridgeAppGrant] = []
        if let rawApps = document["apps"] {
            guard let apps = rawApps as? [[String: Any]] else { return nil }
            for app in apps {
                guard let grant = parseGrant(app) else { return nil }
                grants.append(grant)
            }
        }
        return BridgeAuthorizationPolicy(
            mode: mode, grants: grants, source: source, loaded: true,
            clients: clients, clientAuthorization: clientAuthorization)
    }

    /// Parse one client entry. The requirement text is validated for shape here
    /// and compiled at connection time: a requirement that does not compile
    /// matches nothing, which fails closed.
    private static func parseClient(_ client: [String: Any]) -> BridgeClientGrant? {
        guard let identifier = (client["client_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty
        else { return nil }
        guard let requirement = (client["requirement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requirement.isEmpty
        else { return nil }
        var apps: [String] = []
        if let rawApps = client["apps"] {
            guard let list = rawApps as? [String] else { return nil }
            apps = list
        }
        var scopes: Set<BridgeScope> = []
        if let rawScopes = client["scopes"] {
            guard let list = rawScopes as? [String] else { return nil }
            for entry in list {
                guard let scope = BridgeScope(rawValue: entry.lowercased()) else { return nil }
                scopes.insert(scope)
            }
        }
        return BridgeClientGrant(
            clientID: identifier, requirement: requirement, apps: apps, scopes: scopes)
    }

    private static func parseGrant(_ app: [String: Any]) -> BridgeAppGrant? {
        let bundleID = (app["bundle_id"] as? String) ?? ""
        let name = (app["name"] as? String) ?? ""
        guard !bundleID.isEmpty || !name.isEmpty else { return nil }
        var scopes: Set<BridgeScope> = []
        if let rawScopes = app["scopes"] {
            guard let list = rawScopes as? [String] else { return nil }
            for entry in list {
                guard let scope = BridgeScope(rawValue: entry.lowercased()) else {
                    // An unknown scope is a typo, not a grant: refuse the whole
                    // document instead of silently authorizing less (or more).
                    return nil
                }
                scopes.insert(scope)
            }
        }
        var windows: [String] = []
        if let rawWindows = app["windows"] {
            guard let list = rawWindows as? [String] else { return nil }
            windows = list
        }
        return BridgeAppGrant(
            bundleID: bundleID, name: name, scopes: scopes, windowPatterns: windows)
    }

    /// The grant covering an application, if any.
    public func grant(bundleID: String, name: String) -> BridgeAppGrant? {
        grants.first { $0.matches(bundleID: bundleID, name: name) }
    }

    /// Decide one request against the allowlist AND, when required, the client.
    ///
    /// The client is checked FIRST. Beyond being the correct order, it means an
    /// unauthorized caller learns only that it is not authorized, not which
    /// applications this deployment happens to grant.
    ///
    /// `client` is the grant whose requirement the peer's code identity
    /// satisfied, or nil when no client matched. Under `.required`, nil is a
    /// refusal — never "carry on as the anonymous operator".
    ///
    /// `APPROVAL_REJECTED` is the frozen code for "the permission this needs was
    /// not granted"; the detail says exactly which fact was missing so a client
    /// can explain it without guessing.
    public func decision(
        bundleID: String, name: String, windowTitle: String?, scope: BridgeScope,
        client: BridgeClientGrant? = nil
    ) -> BridgePolicyDecision {
        let target = bundleID.isEmpty ? name : bundleID

        // ---- the caller, first ------------------------------------------------
        // Before anything about the target is revealed, answer "who is asking".
        // An unauthorized caller learns only that it has no identity here, never
        // which applications this deployment happens to grant.
        if clientAuthorization == .required {
            guard let client else {
                return .refused(BridgePolicyRefusal(
                    code: "APPROVAL_REJECTED",
                    message: "This deployment requires a verified client identity and this process has none.",
                    detail: "auth=client_not_authorized;scope=\(scope.rawValue);clients=\(clients.count)"))
            }
            guard client.scopes.contains(scope) else {
                let granted = client.scopes.map { $0.rawValue }.sorted().joined(separator: ",")
                return .refused(BridgePolicyRefusal(
                    code: "APPROVAL_REJECTED",
                    message: "Client \(bounded(client.clientID)) is not authorized for \(scope.rawValue).",
                    detail: "auth=client_scope_not_granted;client=\(bounded(client.clientID));scope=\(scope.rawValue);granted=\(granted.isEmpty ? "nothing" : granted)"))
            }
        }

        // ---- the application --------------------------------------------------
        guard let grant = grant(bundleID: bundleID, name: name) else {
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "\(bounded(target)) is not authorized for computer use on this Mac.",
                detail: "auth=app_not_granted;app=\(bounded(target));scope=\(scope.rawValue)"))
        }

        // ---- the caller's slice of that application ---------------------------
        // Compared against the GRANT's own identifiers, not the raw request: a
        // caller may name an application by display name ("Terminal"), and the
        // client list is written in exact bundle ids.
        if clientAuthorization == .required, let client,
           !client.covers(bundleID: grant.bundleID, name: grant.name) {
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "Client \(bounded(client.clientID)) is not authorized to reach \(bounded(target)).",
                detail: "auth=client_app_not_granted;client=\(bounded(client.clientID));app=\(bounded(target));apps=\(client.apps.count)"))
        }

        guard grant.scopes.contains(scope) else {
            let granted = grant.scopes.map { $0.rawValue }.sorted().joined(separator: ",")
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "\(bounded(target)) is not authorized for \(scope.rawValue) on this Mac."
                    + " The policy grants: \(granted.isEmpty ? "nothing" : granted).",
                detail: "auth=scope_not_granted;app=\(bounded(target));scope=\(scope.rawValue);granted=\(granted)"))
        }
        if let windowTitle, !grant.covers(windowTitle: windowTitle) {
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "The window of \(bounded(target)) is outside the authorized set.",
                detail: "auth=window_not_granted;app=\(bounded(target));scope=\(scope.rawValue);windows=\(grant.windowPatterns.count)"))
        }
        return .allowed
    }

    /// Bound a diagnostic token so a policy refusal never echoes a long title.
    private func bounded(_ value: String) -> String {
        String(value.prefix(80))
    }
}
