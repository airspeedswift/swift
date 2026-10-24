// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

// The value yielded by a throwing 'yielding borrow' depends on the access like
// any yielded value.

struct E: Error {}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  var checked: Ref {
    @_lifetime(borrow self)
    yielding borrow throws {
      if raw < 0 { throw E() }
      yield Ref(raw)
    }
  }
}

nonisolated(unsafe) var sink: Any? = nil

func use(_ g: Ref) throws -> Int {
  let r = try g.checked
  let s = try r.checked
  return r.raw + s.raw
}

// Escapes are reported more than once (as for non-throwing yielding accessors).
@_lifetime(copy g)
func escapeByReturn(_ g: Ref) throws -> Ref { // expected-note {{it depends on the lifetime of argument 'g'}}
  let r = try g.checked // expected-error 2 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1 {{it depends on the lifetime of this parent value}}
  return r // expected-note 2 {{this use causes the lifetime-dependent value to escape}}
}

func escapeByClosure(_ g: Ref) throws { // expected-note 2 {{it depends on the lifetime of argument 'g'}}
  let r = try g.checked // expected-error 3 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1 {{it depends on the lifetime of this parent value}}
  let f: () -> Int = { r.raw } // expected-note 3 {{this use causes the lifetime-dependent value to escape}}
  sink = f
}
