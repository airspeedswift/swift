// RUN: %target-swift-frontend -emit-sil -verify -o /dev/null %s -enable-experimental-feature CoroutineAccessors

// REQUIRES: swift_feature_CoroutineAccessors

// A throwing yielding accessor can only throw before it yields.

struct E: Error {}
func mayThrow() throws {}

struct S {
  var storage = 0

  var direct: Int {
    yielding borrow throws {
      yield storage // expected-note {{previous yield was here}}
      if storage > 0 { throw E() } // expected-error {{accessor must not throw after it yields; errors must be thrown before the yield or handled}}
    }
  }

  var propagated: Int {
    yielding borrow throws {
      try mayThrow()
      yield storage // expected-note {{previous yield was here}}
      try mayThrow() // expected-error {{accessor must not throw after it yields; errors must be thrown before the yield or handled}}
    }
  }

  var handled: Int {
    yielding borrow throws {
      try mayThrow()
      do {
        yield storage
        try mayThrow()
      } catch {}
    }
  }

  var mutate: Int {
    yielding borrow throws { yield storage }
    yielding mutate throws {
      yield &storage // expected-note {{previous yield was here}}
      throw E() // expected-error {{accessor must not throw after it yields; errors must be thrown before the yield or handled}}
    }
  }
}
