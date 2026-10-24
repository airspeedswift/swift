// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

// A ~Escapable argument of a coroutine call (here a subscript index). SILGen
// copies it for the call and destroys the copy right after the end_apply.
// Extending the access over the uses of the yielded value must extend that
// copy too.

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(raw &+ 1) } }
  subscript(call arg: Ref) -> Ref { @_lifetime(borrow self) yielding borrow { yield Ref(raw &+ arg.raw) } }
  subscript(copying arg: Ref) -> Ref { @_lifetime(borrow self, copy arg) yielding borrow { yield Ref(raw &+ arg.raw) } }
}

func argument(_ g: Ref, _ a: Ref) -> Int { let r = g[call: a]; return r.raw }
func local(_ g: Ref) -> Int { let a = g.child; let r = g[call: a]; return r.raw }
func copying(_ g: Ref, _ a: Ref) -> Int { let r = g[copying: a]; return r.raw }
func chained(_ g: Ref, _ a: Ref) -> Int { let r = g[call: a]; let s = r[call: r]; return s.raw }

@_lifetime(copy g)
func escapes(_ g: Ref, _ a: Ref) -> Ref { // expected-note {{it depends on the lifetime of argument 'g'}} expected-note {{it depends on the lifetime of argument 'a'}}
  let r = g[call: a] // expected-error 3 {{lifetime-dependent variable 'r' escapes its scope}}
  // expected-note @-1 {{it depends on the lifetime of this parent value}}
  return r // expected-note 3 {{this use causes the lifetime-dependent value to escape}}
}
