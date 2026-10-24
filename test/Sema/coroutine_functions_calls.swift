// RUN: %target-typecheck-verify-swift -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: swift_feature_Lifetimes

// PROTOTYPE: a call to a yield-once function with one yield and a '()' result
// evaluates to its yielded value.

struct E: Error {}

@yield_once func coro(_ x: Int) yields (Int) -> () { yield x }
@yield_once func throwing(_ x: Int) throws yields (Int) -> () { yield x }
@yield_once func gen<T>(_ x: T) yields (T) -> () { yield x }

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  @_lifetime(borrow self) @yield_once func child() yields (Ref) -> () { yield Ref(raw) }
}

func calls(_ g: Ref) throws {
  let a: Int = coro(1)
  let b = coro(2) + coro(3)
  let c: String = gen("s")
  let d = try throwing(4)
  let e = g.child().raw
  _ = (a, b, c, d, e)
}

func missingTry() -> Int {
  throwing(1) // expected-error {{call can throw, but it is not marked with 'try' and the error is not handled}}
}

// Declarations of other shapes are accepted; calls to them are not lowered yet.
@yield_once func twoYields(_ x: Int) yields (Int, Int) -> () { yield (x, x) }
@yield_once func withResult(_ x: Int) yields (Int) -> Int { yield x; return x }
@yield_once func inoutYield(_ x: inout Int) yields (inout Int) -> () { yield &x }

func unsupportedCalls() {
  twoYields(1) // expected-error {{calls to yield-once functions with other than exactly one yield are not supported yet}}
  _ = withResult(1) // expected-error {{calls to yield-once functions with a result other than '()' are not supported yet}}
  var v = 0
  _ = inoutYield(&v) // expected-error {{calls to yield-once functions with an 'inout' yield are not supported yet}}
}
