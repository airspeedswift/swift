// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all \
// RUN:   -enable-experimental-feature CoroutineFunctions \
// RUN:   -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: swift_feature_Lifetimes

// The value of a call to a yield-once function depends on the coroutine, like
// a value read through a 'yielding borrow' accessor.

struct E: Error {}
func mayThrow() throws {}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }

  @_lifetime(borrow self)
  @yield_once func child() yields (Ref) -> () { yield Ref(raw &+ 1) }

  @_lifetime(borrow self, copy a)
  @yield_once func call(_ a: Ref) throws yields (Ref) -> () {
    if a.raw < 0 { throw E() }
    yield Ref(raw &+ a.raw)
  }

  @_lifetime(borrow self)
  @yield_once func late() throws yields (Ref) -> () {
    yield Ref(raw) // expected-note {{previous yield was here}}
    try mayThrow() // expected-error {{function must not throw after it yields; errors must be thrown before the yield or handled}}
  }
}

nonisolated(unsafe) var sink: Any? = nil

func uses(_ g: Ref, _ a: Ref) throws -> Int {
  let r = try g.call(a)       // a ~Escapable function argument
  let b = g.child()
  let s = try g.call(b)       // a ~Escapable local
  let t = try r.call(r)       // chained
  return r.raw + s.raw + t.raw
}

@_lifetime(copy g)
func escapeByReturn(_ g: Ref) -> Ref { // expected-note {{it depends on the lifetime of argument 'g'}}
  let r = g.child() // expected-error 2 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1 {{it depends on the lifetime of this parent value}}
  return r // expected-note 2 {{this use causes the lifetime-dependent value to escape}}
}

func escapeByClosure(_ g: Ref) { // expected-note 2 {{it depends on the lifetime of argument 'g'}}
  let r = g.child() // expected-error 3 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1 {{it depends on the lifetime of this parent value}}
  let f: () -> Int = { r.raw } // expected-note 3 {{this use causes the lifetime-dependent value to escape}}
  sink = f
}

// An optional ~Escapable argument (passed as an enum of a copy), defaulted to nil.
struct Fn: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  @_lifetime(borrow self) @yield_once func call(this: Ref? = nil, _ args: Int...) throws yields (Ref) -> () {
    yield Ref(raw &+ args.count)
  }
  @_lifetime(borrow self, copy this) @yield_once func callCopying(this: Ref? = nil) throws yields (Ref) -> () {
    yield Ref(raw &+ (this?.raw ?? 0))
  }
}
func optionalArgument(_ s: Ref, _ m: Fn) throws -> Int {
  let r = try m.call(this: s, 1)
  let t = try m.call(2, 3)
  let u = try m.callCopying(this: s)
  let v = try m.callCopying()
  return r.raw + t.raw + u.raw + v.raw
}
