// RUN: %target-typecheck-verify-swift -enable-experimental-feature CoroutineAccessors

// REQUIRES: swift_feature_CoroutineAccessors

struct E: Error {}

struct S {
  var storage = 0

  var a: Int { yielding borrow throws { if storage < 0 { throw E() }; yield storage } } // expected-note {{property declared here}}
  var b: Int {
    yielding borrow throws { yield storage }
    yielding mutate throws { yield &storage }
  }
  var c: Int { yielding borrow throws(Never) { yield storage } }
  var d: Int { yielding borrow throws(any Error) { yield storage } }

  var async: Int { yielding borrow async { yield storage } } // expected-error {{'yielding_borrow' accessor cannot have specifier 'async'}}

  var mismatch: Int {
    yielding borrow throws { yield storage }
    yielding mutate { yield &storage } // expected-error {{a 'yielding mutate' accessor must have the same 'throws' clause as a 'yielding borrow' accessor}}
  }
  var other: Int {
    yielding borrow throws { yield storage }
    set { } // expected-error {{a setter is not allowed together with a 'yielding borrow' accessor that is 'throws'}}
  }
  var typed: Int { yielding borrow throws(E) { yield storage } } // expected-error {{a 'yielding borrow' accessor cannot have a typed 'throws' clause yet; use 'throws'}}

  subscript(i: Int) -> Int { yielding borrow throws { yield i } }
}

func noTry(_ s: S) -> Int {
  s.a // expected-error {{property access can throw, but it is not marked with 'try' and the error is not handled}}
}
func noTryMutate(_ s: inout S) throws {
  s.b += 1 // expected-error {{property access can throw but is not marked with 'try'}}
  // expected-note @-1 {{did you mean to use 'try'?}}
  // expected-note @-2 {{did you mean to handle error as optional value?}}
  // expected-note @-3 {{did you mean to disable error propagation?}}
}
func subscriptNoTry(_ s: S) throws -> Int {
  s[0] // expected-error {{subscript access can throw but is not marked with 'try'}}
  // expected-note @-1 {{did you mean to use 'try'?}}
  // expected-note @-2 {{did you mean to handle error as optional value?}}
  // expected-note @-3 {{did you mean to disable error propagation?}}
}
func ok(_ s: inout S) throws -> Int {
  try s.b += 1
  try s.b = 2
  return try s.a + s.c + (try s.d) + (try s[3])
}

let kp = \S.a // expected-error {{cannot form key path to property with 'throws' or 'async'}}
