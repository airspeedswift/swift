// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -emit-module -o %t/resilient_yield.swiftmodule -module-name resilient_yield \
// RUN:   -enable-library-evolution -parse-as-library %S/Inputs/resilient_yield.swift \
// RUN:   -enable-experimental-feature Lifetimes -enable-experimental-feature CoroutineAccessors
// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all -I %t \
// RUN:   -enable-experimental-feature Lifetimes -enable-experimental-feature CoroutineAccessors

// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors

// A library-evolution ~Escapable yield is address-only to its client: the
// coroutine yields it @in_guaranteed and the client copies it out. The copy
// depends on the coroutine like a loadable yield does. (Each escape is
// reported twice, once per dependence: on the coroutine and on 'h'.)

import resilient_yield

@inline(never) func use(_ r: borrowing Ref) {}

func usesInScope(_ h: Holder) -> UInt {
  let c = h.child
  use(c)
  let d = h[1]
  return c.raw &+ d.raw
}

func escapesViaLet() {
  var outer = Ref(0) // expected-error 2 {{lifetime-dependent variable 'outer' escapes its scope}}
  do {
    let h = Holder(1) // expected-note {{it depends on the lifetime of variable 'h'}}
    let c = h.child // expected-note {{it depends on the lifetime of this parent value}}
    outer = c
  }
  use(outer) // expected-note 2 {{this use of the lifetime-dependent value is out of scope}}
}

func escapesDirect() {
  var outer = Ref(0) // expected-error 2 {{lifetime-dependent variable 'outer' escapes its scope}}
  do {
    let h = Holder(1) // expected-note {{it depends on the lifetime of variable 'h'}}
    outer = h[2] // expected-note {{it depends on the lifetime of this parent value}}
  }
  use(outer) // expected-note 2 {{this use of the lifetime-dependent value is out of scope}}
}
