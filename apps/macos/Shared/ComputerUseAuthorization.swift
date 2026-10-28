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
// Pure Foundation, no AppKit: compiled into the helper and into the tests, so
// the exact rules the helper enforces are the rules the tests pin.

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

/// The deployment's authorization document, as loaded at startup.
public struct BridgeAuthorizationPolicy: Equatable, Sendable {
    public static let supportedVersion = 1

    /// Ceiling declared by the file itself. The helper applies the stricter of
    /// this and its launch flag, so neither alone can widen what runs.
    public let mode: BridgeInteractionMode
    public let grants: [BridgeAppGrant]
    /// Where this policy came from (file path), for diagnostics only.
    public let source: String
    /// False when no file was readable: the allowlist is then empty and every
    /// target is refused.
    public let loaded: Bool

    public init(
        mode: BridgeInteractionMode, grants: [BridgeAppGrant],
        source: String, loaded: Bool
    ) {
        self.mode = mode
        self.grants = grants
        self.source = source
        self.loaded = loaded
    }

    /// The strict state: nothing authorized, nothing observable.
    public static func denyAll(source: String) -> BridgeAuthorizationPolicy {
        BridgeAuthorizationPolicy(
            mode: .background, grants: [], source: source, loaded: false)
    }

    /// Parse a policy document. Returns nil for anything malformed, so the
    /// caller can fall back to ``denyAll`` and never to a permissive default.
    public static func parse(_ data: Data, source: String) -> BridgeAuthorizationPolicy? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let document = object as? [String: Any]
        else { return nil }
        guard let version = document["version"] as? Int,
              version == supportedVersion
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
        var grants: [BridgeAppGrant] = []
        if let rawApps = document["apps"] {
            guard let apps = rawApps as? [[String: Any]] else { return nil }
            for app in apps {
                guard let grant = parseGrant(app) else { return nil }
                grants.append(grant)
            }
        }
        return BridgeAuthorizationPolicy(
            mode: mode, grants: grants, source: source, loaded: true)
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

    /// Decide one request against the allowlist.
    ///
    /// `APPROVAL_REJECTED` is the frozen code for "the permission this needs was
    /// not granted"; the detail says exactly which fact was missing so a client
    /// can explain it without guessing.
    public func decision(
        bundleID: String, name: String, windowTitle: String?, scope: BridgeScope
    ) -> BridgePolicyDecision {
        guard let grant = grant(bundleID: bundleID, name: name) else {
            let target = bundleID.isEmpty ? name : bundleID
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "\(target) is not authorized for computer use on this Mac.",
                detail: "auth=app_not_granted;app=\(bounded(target));scope=\(scope.rawValue)"))
        }
        guard grant.scopes.contains(scope) else {
            let granted = grant.scopes.map { $0.rawValue }.sorted().joined(separator: ",")
            let target = bundleID.isEmpty ? name : bundleID
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "\(target) is not authorized for \(scope.rawValue) on this Mac."
                    + " The policy grants: \(granted.isEmpty ? "nothing" : granted).",
                detail: "auth=scope_not_granted;app=\(bounded(target));scope=\(scope.rawValue);granted=\(granted)"))
        }
        if let windowTitle, !grant.covers(windowTitle: windowTitle) {
            let target = bundleID.isEmpty ? name : bundleID
            return .refused(BridgePolicyRefusal(
                code: "APPROVAL_REJECTED",
                message: "The window of \(target) is outside the authorized set.",
                detail: "auth=window_not_granted;app=\(bounded(target));scope=\(scope.rawValue);windows=\(grant.windowPatterns.count)"))
        }
        return .allowed
    }

    /// Bound a diagnostic token so a policy refusal never echoes a long title.
    private func bounded(_ value: String) -> String {
        String(value.prefix(80))
    }
}
