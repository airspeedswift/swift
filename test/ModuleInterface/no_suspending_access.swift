// RUN: %empty-directory(%t)
// RUN: %target-swift-emit-module-interface(%t/Lib.swiftinterface) %s -module-name Lib \
// RUN:   -enable-experimental-feature Lifetimes -enable-experimental-feature CoroutineAccessors
// RUN: %target-swift-typecheck-module-from-interface(%t/Lib.swiftinterface) -module-name Lib
// RUN: %FileCheck %s < %t/Lib.swiftinterface

// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors

public struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
public struct S {
  var n = 0
  // CHECK: @_noSuspendingAccess public var child: Lib::Ref {
  @_noSuspendingAccess
  public var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
}
