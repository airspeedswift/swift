// RUN: %target-swift-frontend %s -emit-sil \
// RUN:   -o /dev/null \
// RUN:   -verify \
// RUN:   -sil-verify-all \
// RUN:   -module-name test \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

// A lifetime-dependent value captured by a non-escaping closure passed to a 'rethrows' or 'throws(E)' function that
// does not throw. The try_apply's error successor is a dead end. Scope fixup ends the extended scope at the start of
// that block, and ClosureLifetimeFixup then rewrites the closure's destroy_value [dead_end] into an end_borrow and a
// destroy_value of the captured copy after the scope's end. Those lifetime ends are redundant in a dead-end block and
// must not be diagnosed.

struct Ref: ~Escapable {
  let raw: Int

  @_lifetime(immortal)
  init(_ r: Int) { raw = r }

  var child: Ref {
    @_lifetime(borrow self)
    yielding borrow { yield Ref(raw &+ 1) }
  }

  var plain: Ref {
    @_lifetime(borrow self)
    get { Ref(raw &+ 1) }
  }
}

struct E: Error {}

func runR<R>(_ f: () throws -> R) rethrows -> R { try f() }
func runT<R>(_ f: () throws -> R) throws -> R { try f() }
func runTyped<R, X: Error>(_ f: () throws(X) -> R) throws(X) -> R { try f() }
func runN<R>(_ f: () -> R) -> R { f() }

nonisolated(unsafe) var sink: Any? = nil

// MARK: yielded value (coroutine scope)

func rethrowsNonThrowingClosure(_ g: Ref) -> Int {
  let r = g.child
  return runR { r.raw }
}

func rethrowsNonThrowingClosureInThrowingCaller(_ g: Ref) throws -> Int {
  let r = g.child
  if r.raw < 0 { throw E() }
  return runR { r.raw }
}

func arrayMap(_ g: Ref) -> [Int] {
  let r = g.child
  return [1, 2].map { $0 &+ r.raw }
}

func typedThrowsNever(_ g: Ref) -> Int {
  let r = g.child
  return runTyped { r.raw }
}

func rethrowsThrowingClosure(_ g: Ref) throws -> Int {
  let r = g.child
  return try runR { if r.raw < 0 { throw E() }; return r.raw }
}

func throwsCallee(_ g: Ref) throws -> Int {
  let r = g.child
  return try runT { r.raw }
}

func nonThrowingCallee(_ g: Ref) -> Int {
  let r = g.child
  return runN { r.raw }
}

func plainGetter(_ g: Ref) -> Int {
  let r = g.plain
  return runR { r.raw }
}

func useOnDeadEndPath(_ g: Ref, _ c: Bool) -> Int {
  let r = g.child
  if c { fatalError("\(r.raw)") }
  return runR { r.raw }
}

// MARK: other scopes

final class Owner { var x = 1 }

extension Owner {
  var dep: Ref {
    @_lifetime(borrow self)
    get { Ref(x) }
  }
}

struct Client {
  let o: Owner
  var computedOwner: Owner { o }

  // Owned temporary scope.
  func rethrowsTemporaryOwner() -> Int {
    let d = computedOwner.dep
    return runR { d.raw }
  }
}

struct Box { var o = Owner() }

// Access scope.
func rethrowsAccess(_ b: inout Box) -> Int {
  let d = b.o.dep
  return runR { d.raw }
}

// MARK: real escapes are still diagnosed
//
// Each escape is currently reported three times: twice against the argument 'g' (the mark_dependence on the caller's
// argument) and once against the coroutine scope.

func escapingClosure(_ g: Ref) -> () -> Int { // expected-note 2 {{it depends on the lifetime of argument 'g'}}
  let r = g.child // expected-error 3 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1{{it depends on the lifetime of this parent value}}
  return { r.raw } // expected-note 3 {{this use causes the lifetime-dependent value to escape}}
}

func escapeOnDeadEndPath(_ g: Ref, _ c: Bool) -> Int { // expected-note 2 {{it depends on the lifetime of argument 'g'}}
  let r = g.child // expected-error 3 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1{{it depends on the lifetime of this parent value}}
  if c {
    let f: () -> Int = { r.raw } // expected-note 3 {{this use causes the lifetime-dependent value to escape}}
    sink = f
    fatalError()
  }
  return r.raw
}
