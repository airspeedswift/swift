// RUN: %target-swift-emit-sil -verify -enable-experimental-feature Become %s

// REQUIRES: swift_feature_Become

// A trivial guaranteed tail call is accepted.
func ping(_ n: Int) -> Int {
  if n == 0 { return 0 }
  become pong(n - 1)
}
func pong(_ n: Int) -> Int {
  if n == 0 { return 0 }
  become ping(n - 1)
}

// A 'consuming' argument may be forwarded into the tail call.
class C {}
func takeC(_ c: consuming C) -> Int { return 0 }
func forwardConsuming(_ c: consuming C) -> Int {
  become takeC(c)
}

// 'inout' forwarding is allowed, including of noncopyable values.
struct NC: ~Copyable { var i: Int }
func stepNC(_ c: inout NC, _ budget: Int) -> Int {
  if budget == 0 { return c.i }
  c.i += 1
  become stepNC(&c, budget - 1)
}

// 'become' requires a call expression.
func notACall(_ n: Int) -> Int {
  become n // expected-error {{'become' requires a function or method call}}
}

// A value that must be destroyed after the call is rejected.
func liveValueAfterCall(_ n: Int) -> Int {
  let c = C() // expected-warning {{never used}}
  become pong(n)
  // expected-error@-1 {{'become' cannot guarantee a tail call here because a value would need to be destroyed after the call returns}}
}
