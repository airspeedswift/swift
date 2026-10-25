// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature CoroutineFunctions

// REQUIRES: concurrency
// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_CoroutineFunctions

// An access to a '@_noSuspendingAccess' declaration may not be held across a
// suspension point. The access's scope is the one that covers every use of the
// yielded value; a ~Escapable variable ends at its last use.

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
struct VM {
  var n = 0
  @_noSuspendingAccess
  subscript(_ k: String) -> Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
  var plain: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
  @_noSuspendingAccess @_lifetime(borrow self)
  @yield_once func call(_ x: Int) throws yields (Ref) -> () { yield Ref(n &+ x) }
}
func later() async -> Int { 1 }

func betweenAwaits(_ vm: VM) async throws -> Int {
  let a = await later()
  let r = vm["x"]
  let s = try vm.call(1)
  let v = r.raw + s.raw
  return a + v + (await later())
}

func usedInTheAwaitingExpression(_ vm: VM) async throws -> Int {
  let r = try vm.call(1)
  return r.raw + (await later())
}

func acrossAwait(_ vm: VM) async -> Int {
  let r = vm["x"] // expected-error {{access to 'subscript(_:)' cannot be held across 'await'}}
  let a = await later() // expected-note {{the access is still in progress at this suspension point}}
  return a + r.raw
}

func yieldOnceAcrossAwait(_ vm: VM) async throws -> Int {
  let r = try vm.call(1) // expected-error {{access to 'call' cannot be held across 'await'}}
  let a = await later() // expected-note {{the access is still in progress at this suspension point}}
  return a + r.raw
}

// Without the attribute, an access across an await is fine.
func plainAcrossAwait(_ vm: VM) async -> Int {
  let r = vm.plain
  let a = await later()
  return a + r.raw
}

func sync(_ vm: VM) -> Int {
  let r = vm["x"]
  return r.raw
}

// Inherited from a protocol requirement and an overridden declaration.
protocol Holder {
  @_noSuspendingAccess
  var child: Ref { @_lifetime(borrow self) yielding borrow } // expected-note {{'child' inherits '@_noSuspendingAccess' from this protocol requirement}}
}
struct H: Holder {
  var n = 0
  var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
}
func viaRequirement<T: Holder>(_ h: T) async -> Int {
  let r = h.child // expected-error {{access to 'child' cannot be held across 'await'}}
  let a = await later() // expected-note {{the access is still in progress at this suspension point}}
  return a + r.raw
}
func viaWitness(_ h: H) async -> Int {
  let r = h.child // expected-error {{access to 'child' cannot be held across 'await'}}
  let a = await later() // expected-note {{the access is still in progress at this suspension point}}
  return a + r.raw
}

class Base {
  var n = 0
  @_noSuspendingAccess
  var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } } // expected-note {{'child' inherits '@_noSuspendingAccess' from the overridden declaration}}
}
class Derived: Base {
  override var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n + 1) } }
}
func viaOverride(_ d: Derived) async -> Int {
  let r = d.child // expected-error {{access to 'child' cannot be held across 'await'}}
  let a = await later() // expected-note {{the access is still in progress at this suspension point}}
  return a + r.raw
}
