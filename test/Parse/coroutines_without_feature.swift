// RUN: not %target-swift-frontend -typecheck %s 2>&1 | %FileCheck %s

// Without CoroutineFunctions, a yield-once declaration is an error, not a
// crash (the declaration has '@yield_once' but no yields clause).

// CHECK: error: `yields` requires '-enable-experimental-feature CoroutineFunctions'
struct S {
  var v = 0
  @yield_once func call() throws yields (Int) -> () { yield v }
}
func f(_ s: S) throws { _ = try s.call() }
