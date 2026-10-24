// RUN: %target-swift-frontend -emit-irgen %s -module-name m -enable-experimental-feature CoroutineFunctions | %FileCheck %s

// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: CPU=arm64 || CPU=x86_64

// A yield-once function is a caller-allocated (yield_once_2) coroutine, like
// a 'yielding borrow' accessor.

// CHECK-LABEL: define {{.*}} @"$s1m4coroyySiXySiF"(
// CHECK:         call token @llvm.coro.id.retcon.once.dynamic(
// CHECK:         call {{.*}} @llvm.coro.suspend.retcon
@yield_once func coro(_ x: Int) yields (Int) -> () { yield x &+ 1 }

// The caller allocates the frame on its own stack and calls the ramp and the
// continuation.
// CHECK-LABEL: define {{.*}} @"$s1m1fSiyF"(
// CHECK:         [[FRAME:%.*]] = alloca i8, i64
// CHECK:         [[RAMP:%.*]] = call ptr @llvm.coro.prepare.retcon(ptr @"$s1m4coroyySiXySiF")
// CHECK:         call swiftcc { ptr, i64 } [[RAMP]](ptr noalias [[FRAME]],
func f() -> Int { coro(1) }
