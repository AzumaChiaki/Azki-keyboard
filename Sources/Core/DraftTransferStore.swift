// SPDX-License-Identifier: MIT
import Foundation

/// A single, short-lived composition handoff. It has no persistence or history.
/// Keep one reference on the owning actor (the keyboard uses MainActor). This
/// type deliberately does not conform to Sendable or expose pending content.
public final class DraftTransferStore {
    public static let maximumCharacters = 128
    public static let maximumUTF8Bytes = 4_096
    public static let lifetime: TimeInterval = 60

    public struct Scope: Equatable, Sendable {
        public let document: UUID
        public let language: KeyboardLanguage

        public init(document: UUID, language: KeyboardLanguage) {
            self.document = document
            self.language = language
        }
    }

    /// An opaque capability for the current controller/document activation.
    /// A fresh activation invalidates every capability issued before it.
    public struct Lease: Hashable, Sendable {
        fileprivate let identifier: UUID
        fileprivate init() { identifier = UUID() }
    }

    public struct Snapshot: Equatable, Sendable {
        public let input: String
        public let language: KeyboardLanguage
    }

    private struct Session {
        let scope: Scope
        let lease: Lease
    }

    private struct Pending {
        let scope: Scope
        let snapshot: Snapshot
        let storedAt: TimeInterval
    }

    private let clock: () -> TimeInterval
    private var current: Session?
    private var pending: Pending?

    /// ContinuousClock keeps advancing while the device is asleep. An uptime
    /// clock that pauses during sleep must not extend a draft's recovery window.
    public convenience init() {
        let continuous = ContinuousClock()
        let origin = continuous.now
        self.init(clock: {
            let elapsed = origin.duration(to: continuous.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        })
    }

    /// The injected clock is continuous monotonic elapsed time, never a wall date.
    public init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    /// Does not expose or automatically transfer any text. Mismatched pending
    /// content can only be read through a fresh, explicit user confirmation.
    public func activate(_ scope: Scope) -> Lease {
        expire()
        let lease = Lease()
        current = Session(scope: scope, lease: lease)
        return lease
    }

    /// Ownership is independent of pending content. A controller must not regain
    /// ownership merely because hasPending returned false for an expired lease.
    public func isActive(_ lease: Lease) -> Bool { current?.lease == lease }

    /// Automatically restorable only when BOTH public document UUID and language
    /// still match. A mismatch preserves hidden pending content without returning it.
    public func restoreMatching(using lease: Lease) -> Snapshot? {
        guard let session = current, session.lease == lease else { return nil }
        expire()
        guard let value = pending, value.scope == session.scope else { return nil }
        pending = nil
        return value.snapshot
    }

    /// Presence only: callers cannot preview another scope's text or language.
    public func hasPending(using lease: Lease) -> Bool {
        guard current?.lease == lease else { return false }
        expire()
        return pending != nil
    }

    /// Call ONLY from a new, explicit UI confirmation for the current input target,
    /// after independently validating that target's live input ticket. The core
    /// cannot verify a gesture. Returned text is a draft, never a host insertion.
    public func restoreAfterUserConfirmation(using lease: Lease) -> Snapshot? {
        guard current?.lease == lease else { return nil }
        expire()
        let value = pending?.snapshot
        pending = nil
        return value
    }

    /// Discarding a pending handoff does not end the current controller's lease.
    @discardableResult
    public func discardPending(using lease: Lease) -> Bool {
        guard current?.lease == lease else { return false }
        let discarded = pending != nil
        pending = nil
        return discarded
    }

    /// Save at most one composition and end its producer's lease immediately.
    /// Empty/invalid input also ends that lease and clears any older pending draft.
    /// An old controller can neither overwrite a successor nor extend its own TTL.
    @discardableResult
    public func park(_ input: String, using lease: Lease) -> Bool {
        guard let session = current, session.lease == lease else { return false }
        current = nil
        pending = nil
        let now = clock()
        guard now.isFinite, now >= 0, !input.isEmpty,
              input.utf8.prefix(Self.maximumUTF8Bytes + 1).count <= Self.maximumUTF8Bytes,
              input.count <= Self.maximumCharacters else { return false }
        pending = Pending(scope: session.scope,
                          snapshot: Snapshot(input: input, language: session.scope.language),
                          storedAt: now)
        return true
    }

    /// End an empty controller's ownership without discarding a hidden handoff.
    /// This does not renew the pending draft's original expiry or reveal its text.
    /// Use revoke for explicit cancellation; invalid park input still fails closed.
    @discardableResult
    public func relinquish(using lease: Lease) -> Bool {
        guard current?.lease == lease else { return false }
        current = nil
        expire()
        return true
    }

    /// Only the currently active capability can revoke ownership and clear data.
    /// A parked producer has ended its lease and cannot erase a successor's draft.
    @discardableResult
    public func revoke(using lease: Lease) -> Bool {
        guard current?.lease == lease else { return false }
        current = nil
        pending = nil
        return true
    }

    /// Safe for an expiry timer: a late timer checks the CURRENT snapshot's age
    /// and cannot erase a younger replacement or revoke an active controller.
    @discardableResult
    public func expire() -> Bool { discardExpired(at: clock()) }

    /// Relative monotonic delay for the owning actor's expiry timer. Expiry is
    /// also enforced on every read; delayed timers never permit stale restoration.
    public func timeUntilExpiry() -> TimeInterval? {
        let now = clock()
        discardExpired(at: now)
        guard let value = pending else { return nil }
        return max(0, Self.lifetime - (now - value.storedAt))
    }

    @discardableResult
    private func discardExpired(at now: TimeInterval) -> Bool {
        guard let value = pending else { return false }
        let age = now - value.storedAt
        guard !now.isFinite || !age.isFinite || age < 0 || age >= Self.lifetime else { return false }
        pending = nil
        return true
    }
}
