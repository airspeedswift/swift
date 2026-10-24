// RUN: %target-swift-frontend -emit-sil -Onone -sil-verify-all %s \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-callee-allocated-coro-abi \
// RUN:   | %FileCheck %s
// RUN: %target-swift-frontend -emit-sil -O -sil-verify-all %s \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-callee-allocated-coro-abi -o /dev/null

// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

// A yielding access used as a temporary in an expression that branches before
// the access ends (a throwing call, a force unwrap). SILGen ends the coroutine
// before the branch but deallocates its callee-allocated frame in each
// successor. Extending the access over the branch must leave exactly one
// dealloc_stack of the frame on each path (it used to leave two, and
// StackNesting crashed).

struct E: Error {}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  var numberValue: Double? { raw > 0 ? Double(raw) : nil }
  var plainChild: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(raw &+ 1) } }
  func set(_ k: String, _ v: Ref) throws { if k.isEmpty { throw E() } }
}

final class VM {
  var n = 1
  var plain: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n &+ 2) } }
}

// Across a try_apply.
// CHECK-LABEL: sil hidden @$s{{.*}}14acrossTryApplyyyAA2VMC_AA3RefVtKF :
// CHECK:         ({{%[0-9]+}}, [[TOKEN:%[0-9]+]], [[FRAME:%[0-9]+]]) = begin_apply
// CHECK-NOT:     dealloc_stack [[FRAME]]
// CHECK:         try_apply
// CHECK:       bb1(
// CHECK:         end_apply [[TOKEN]]
// CHECK:         dealloc_stack [[FRAME]]
// CHECK-NOT:     dealloc_stack [[FRAME]]
// CHECK:       bb2(
// CHECK:         end_apply [[TOKEN]]
// CHECK:         dealloc_stack [[FRAME]]
// CHECK-NOT:     dealloc_stack [[FRAME]]
// CHECK-LABEL: } // end sil function '$s{{.*}}14acrossTryApplyyyAA2VMC_AA3RefVtKF'
func acrossTryApply(_ vm: VM, _ d: Ref) throws { try d.set("a", vm.plain) }

// Across a force unwrap.
// CHECK-LABEL: sil hidden @$s{{.*}}17acrossForceUnwrapySdAA3RefVF :
// CHECK:         ({{%[0-9]+}}, [[TOKEN:%[0-9]+]], [[FRAME:%[0-9]+]]) = begin_apply
// CHECK:         end_apply [[TOKEN]]
// CHECK:         dealloc_stack [[FRAME]]
// CHECK-NOT:     dealloc_stack [[FRAME]]
// CHECK-LABEL: } // end sil function '$s{{.*}}17acrossForceUnwrapySdAA3RefVF'
func acrossForceUnwrap(_ o: Ref) -> Double { o.plainChild.numberValue! }

// In an initializer.
struct Art {
  var w: Double
  init(js o: Ref) { w = o.plainChild.numberValue! }
}
