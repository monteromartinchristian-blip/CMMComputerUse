// BridgeTargeting.swift — shared app/window targeting for the Computer Bridge.
//
// ONE source of truth, compiled into BOTH the CMMComputerUse helper
// (via scripts/build-helper.sh) and the CMMComputerUseTests bundle (via
// project.yml), so the resolution rules the helper executes are exactly the
// rules the regression tests pin. No AppKit: pure matching over caller-
// supplied candidates, so tests never touch the window server.
//
// Rules (deliberately narrow — no fuzzy inference):
// - app requests resolve by exact localized name OR exact bundle id,
//   case-insensitive, names first. Anything else is unknown, never guessed.
// - window requests match by case-insensitive fragment (the planner contract
//   is "<window title fragment>"); an empty fragment never matches.

import Foundation

/// A running application as far as targeting cares: display name, bundle id,
/// and whether it is currently active. Matching ignores `isActive`; the
/// caller decides what to do with it (e.g. activate the owner first).
public struct BridgeAppCandidate: Equatable {
    public var name: String
    public var bundleID: String
    public var isActive: Bool

    public init(name: String, bundleID: String, isActive: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.isActive = isActive
    }
}

/// Resolve an `app.activate`/`app.open` request against the running apps.
/// Returns nil for empty or unknown requests — the caller reports that
/// truthfully instead of activating a guess.
public func bridgeResolveApp(
    request: String,
    candidates: [BridgeAppCandidate]
) -> BridgeAppCandidate? {
    let query = request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let lowered = query.lowercased()
    if let byName = candidates.first(where: { $0.name.lowercased() == lowered }) {
        return byName
    }
    if let byBundle = candidates.first(where: { $0.bundleID.lowercased() == lowered }) {
        return byBundle
    }
    return nil
}

/// Match a `window.focus` request against one window title. Fragment
/// semantics per the planner contract; empty requests never match so a
/// missing title cannot focus an arbitrary window.
public func bridgeWindowTitleMatches(windowTitle: String, request: String) -> Bool {
    let query = request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return false }
    return windowTitle.lowercased().contains(query.lowercased())
}

/// How an activation attempt ended. These are DIFFERENT facts and the helper
/// must not collapse them: a refused activation, an accepted one that never
/// took effect, and one that worked are three distinct outcomes.
public enum BridgeActivationOutcome: Equatable {
    case alreadyActive
    case activated
    case refused(reason: String)
    case acceptedButNotFrontmost
}

/// Decide what an activation attempt means.
///
/// `isActive` is the measured truth, not the return value: `activate()`
/// returns true even when the system silently drops the request, which is
/// exactly the failure this exists to report honestly.
public func bridgeActivationOutcome(
    wasActive: Bool,
    activateAccepted: Bool,
    becameActive: Bool,
    name: String
) -> BridgeActivationOutcome {
    if wasActive || becameActive { return .activated }
    if !activateAccepted { return .refused(reason: "activation was refused for \(name)") }
    return .acceptedButNotFrontmost
}

/// How a `window.focus` request should proceed.
public enum BridgeFocusPlan: Equatable {
    /// The owner is already active: raise the window without activating.
    case raiseOnly
    /// The owner is not active: activate the owner first, then raise.
    case activateThenRaise
}

/// Decide the order of operations for `window.focus`.
///
/// Activating the application BEFORE raising the window is required: an AX
/// raise on a window owned by a background application has no visible effect,
/// so doing it in the other order silently fails.
public func bridgeFocusPlan(ownerIsActive: Bool) -> BridgeFocusPlan {
    ownerIsActive ? .raiseOnly : .activateThenRaise
}

/// Decide whether a traversed accessibility node is readable content.
///
/// Generic, role-agnostic: a label that merely repeats the node's own role
/// or role description ("celda", "file row") describes the widget, not what
/// it shows, and is dropped. Everything else is content a person can read.
public func bridgeIsReadableContent(
    label: String?, role: String, roleDescription: String?
) -> Bool {
    guard let label else { return false }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 400 else { return false }
    if trimmed.caseInsensitiveCompare(role) == .orderedSame { return false }
    if let description = roleDescription {
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty,
           trimmed.caseInsensitiveCompare(normalized) == .orderedSame {
            return false
        }
    }
    return true
}
