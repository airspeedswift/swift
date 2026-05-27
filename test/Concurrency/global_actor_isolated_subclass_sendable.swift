// RUN: %target-typecheck-verify-swift -swift-version 6

// REQUIRES: concurrency
// REQUIRES: objc_interop

// SE-0434: A global-actor-isolated subclass of a non-isolated, non-Sendable
// superclass cannot conform to 'Sendable'. The implicit conformance is
// suppressed; an explicit (or implied) conformance must be diagnosed.

import Foundation

class NonSendable {
  func test() {}
}

@MainActor
class IsolatedSubclass: NonSendable, Sendable {}
// expected-error@-1 {{global-actor-isolated class 'IsolatedSubclass' cannot conform to 'Sendable' because its superclass 'NonSendable' is not 'Sendable'}}

@globalActor
actor MyActor {
  static let shared = MyActor()
}

@MyActor
class OtherIsolatedSubclass: NonSendable, Sendable {}
// expected-error@-1 {{global-actor-isolated class 'OtherIsolatedSubclass' cannot conform to 'Sendable' because its superclass 'NonSendable' is not 'Sendable'}}

// Implied via a protocol that refines Sendable is also diagnosed.
protocol RefinesSendable: Sendable {}

@MainActor
class IsolatedSubclassImplied: NonSendable, RefinesSendable {}
// expected-error@-1 {{global-actor-isolated class 'IsolatedSubclassImplied' cannot conform to 'Sendable' because its superclass 'NonSendable' is not 'Sendable'}}

// '@unchecked Sendable' is the user's explicit opt-out and is allowed.
@MainActor
final class IsolatedSubclassUnchecked: NonSendable, @unchecked Sendable {}

// NSObject is special-cased for ObjC interop.
@MainActor
final class IsolatedNSObjectSubclass: NSObject, Sendable {}

// Sendable superclass: redundant but valid.
class UncheckedSendableSuper: @unchecked Sendable {}

@MainActor
final class IsolatedSendableSubclass: UncheckedSendableSuper, Sendable {}
// expected-warning@-1 {{class 'IsolatedSendableSubclass' must restate inherited '@unchecked Sendable' conformance}}

// No superclass: not affected.
@MainActor
final class IsolatedNoSuperclass: Sendable {}

// No explicit Sendable: implicit conformance is already suppressed.
@MainActor
class IsolatedNoExplicit: NonSendable {}
