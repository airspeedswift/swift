// RUN: %target-typecheck-verify-swift -enable-experimental-feature CoroutineAccessors
// RUN: %target-typecheck-verify-swift -enable-experimental-feature CoroutineAccessors -enable-library-evolution

// REQUIRES: concurrency
// REQUIRES: swift_feature_CoroutineAccessors

// A getter of noncopyable type may be 'async' or 'throws'. An opaque read of
// such storage calls the getter and produces an owned value, so it can only be
// witnessed or overridden by a getter.

public struct NC: ~Copyable { public var x = 1 }
public struct E: Error {}

public struct S {
  public var a: NC { get throws { NC() } }
  public var b: NC { get async { NC() } }
  public var c: NC { get async throws { NC() } }
  public var d: NC { get throws(E) { throw E() } }
  public subscript(i: Int) -> NC { get throws { NC(x: i) } }
  public subscript<R: ~Copyable>(_ k: String, _ body: (Int) throws -> R) -> R {
    get throws { try body(k.count) }
  }
}

public class Holder {
  var one: NC { get async { NC() } }
  var two: NC { get throws { NC() } }
}

// '@_borrowed' still cannot be combined with an effectful getter.
public struct Borrowed {
  @_borrowed var nc: NC { get throws { NC() } } // expected-error {{getter cannot be '@_borrowed' if it is 'async' or 'throws'}}
}

// MARK: protocol witnesses

public protocol P: ~Copyable {
  var nc: NC { get throws } // expected-note 3 {{protocol requires property 'nc' with type 'NC'}}
}

struct GetterWitness: P { var nc: NC { get throws { NC() } } }
struct NonThrowingGetterWitness: P { var nc: NC { NC() } }

struct StoredWitness: P, ~Copyable { // expected-error {{type 'StoredWitness' does not conform to protocol 'P'}} expected-note {{add stubs for conformance}}
  var nc = NC() // expected-note {{candidate only lends its non-'Copyable' value, but the protocol requires an 'async' or 'throws' getter, which returns an owned value}}
}

struct ReadWitness: P { // expected-error {{type 'ReadWitness' does not conform to protocol 'P'}} expected-note {{add stubs for conformance}}
  var nc: NC { _read { yield NC() } } // expected-note {{candidate only lends its non-'Copyable' value, but the protocol requires an 'async' or 'throws' getter, which returns an owned value}}
}

struct YieldingBorrowWitness: P { // expected-error {{type 'YieldingBorrowWitness' does not conform to protocol 'P'}} expected-note {{add stubs for conformance}}
  var nc: NC { yielding borrow { yield NC() } } // expected-note {{candidate only lends its non-'Copyable' value, but the protocol requires an 'async' or 'throws' getter, which returns an owned value}}
}

// A requirement whose type is only noncopyable for some conformers.
public protocol Q {
  associatedtype T: ~Copyable
  var t: T { get throws }
}
struct CopyableStoredWitness: Q { var t = 1 }
struct NoncopyableGetterWitness: Q { var t: NC { get throws { NC() } } }

// A non-effectful requirement is unchanged: a stored property witnesses it.
public protocol R: ~Copyable { var nc: NC { get } }
struct StoredWitnessOfPlainGet: R, ~Copyable { var nc = NC() }

// MARK: overrides

class Base {
  var nc: NC { get throws { NC() } } // expected-note 2 {{attempt to override property here}}
}
class GetterOverride: Base { override var nc: NC { get throws { NC(x: 2) } } }
class NonThrowingGetterOverride: Base { override var nc: NC { NC(x: 3) } }
class ReadOverride: Base {
  override var nc: NC { _read { yield NC() } } // expected-error {{property 'nc' must be overridden with a getter, because the overridden 'async' or 'throws' getter returns an owned non-'Copyable' value}}
}
class YieldingBorrowOverride: Base {
  override var nc: NC { yielding borrow { yield NC() } } // expected-error {{property 'nc' must be overridden with a getter, because the overridden 'async' or 'throws' getter returns an owned non-'Copyable' value}}
}
