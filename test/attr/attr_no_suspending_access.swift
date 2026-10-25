// RUN: %target-typecheck-verify-swift \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-experimental-feature CoroutineFunctions

// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineFunctions

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
struct S {
  var n = 0
  @_noSuspendingAccess var a: Int { n }
  @_noSuspendingAccess subscript(i: Int) -> Int { n }
  @_noSuspendingAccess @_lifetime(borrow self) @yield_once func y() yields (Ref) -> () { yield Ref(n) }
  // A plain function: a call cannot be held across a suspension point anyway.
  @_noSuspendingAccess func f() {}
  var b: Int {
    @_noSuspendingAccess get { n } // expected-error {{'@_noSuspendingAccess' attribute cannot be applied to this declaration}}
  }
}
@_noSuspendingAccess struct T {} // expected-error {{'@_noSuspendingAccess' attribute cannot be applied to this declaration}}
