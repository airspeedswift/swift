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

// A trivial value read into a local before the call does not block the tail
// call: its (no-op) storage teardown is scheduled before the call.
func trivialLocal(_ n: Int) -> Int {
  let d = n &+ 1
  let _ = d
  become pong(n)
}

// Dispatch through a fixed table of thin function pointers is a tail call: the
// looked-up function pointer is trivial, so the table access leaves nothing to
// tear down after the call.
typealias Handler = @convention(thin) (Int) -> Int
let table: InlineArray<1, Handler> = [pong]
func dispatch(_ n: Int) -> Int {
  become table[0](n)
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

// A non-trivial value that must be destroyed after the call is rejected: here
// the class instance's release would run after the tail call.
class C {}
func liveValueAfterCall(_ n: Int) -> Int {
  let c = C()
  _ = c
  become pong(n)
  // expected-error@-1 {{'become' cannot guarantee a tail call here because a value would need to be destroyed after the call returns}}
}

// A 'consuming' argument whose ownership is managed through a move-only box is
// likewise rejected, because releasing the (emptied) box is real teardown that
// would run after the call.
func takeC(_ c: consuming C) -> Int { return 0 }
func forwardConsumingClass(_ c: consuming C) -> Int {
  become takeC(c)
  // expected-error@-1 {{'become' cannot guarantee a tail call here because a value would need to be destroyed after the call returns}}
}
