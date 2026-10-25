// RUN: %target-swift-frontend -emit-irgen %s -module-name m \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-experimental-feature CoroutineAccessors \
// RUN:   -enable-experimental-feature CoroutineFunctions \
// RUN:   | %FileCheck %s

// REQUIRES: concurrency
// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_CoroutineFunctions

// An async caller allocates a callee-allocated coroutine's frame on the native
// stack, out of the async context, when no suspension point is reached while
// the frame is allocated. Otherwise it uses the task allocator.

public struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
public struct H {
  var n = 0
  public var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
  @_noSuspendingAccess
  public var guarded: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
  @_lifetime(borrow self) @yield_once public func call() yields (Ref) -> () { yield Ref(n) }
}
@inline(never) func later() async -> Int { 1 }

// CHECK-LABEL: define {{.*}}swifttailcc void @"$s1m9noSuspendySiAA1HVYaF"(
// CHECK-NOT:     swift_task_alloc
// CHECK:         [[TOKEN:%.*]] = call token @llvm.coro.alloca.alloc.frame.i64(
// CHECK:         [[FRAME:%.*]] = call ptr @llvm.coro.alloca.get(token [[TOKEN]])
// CHECK-NOT:     swift_task_alloc
// CHECK:         call swiftcc { ptr, i64 } {{%.*}}(ptr noalias [[FRAME]], ptr swiftcoro @_swift_coro_malloc_allocator
// CHECK-NOT:     _swift_coro_async_allocator
// CHECK:       {{^}}}
public func noSuspend(_ h: H) async -> Int {
  let r = h.child
  return r.raw
}

// Awaits before and after the access, a yield-once function, and the
// '@_noSuspendingAccess' guarantee.
// CHECK-LABEL: define {{.*}}swifttailcc void @"$s1m13betweenAwaitsySiAA1HVYaF"(
// CHECK-NOT:     _swift_coro_async_allocator
// CHECK:       {{^}}}
public func betweenAwaits(_ h: H) async -> Int {
  let a = await later()
  let r = h.call()
  let g = h.guarded
  let v = r.raw + g.raw
  return a + v + (await later())
}

// The access spans an await: the frame is in the task allocator.
// CHECK-LABEL: define {{.*}}swifttailcc void @"$s1m5spansySiAA1HVYaF"(
// CHECK:         [[FRAME:%.*]] = call swiftcc ptr @swift_task_alloc(
// CHECK:         call swiftcc { ptr, i64 } {{%.*}}(ptr noalias [[FRAME]], ptr swiftcoro @_swift_coro_async_allocator
public func spans(_ h: H) async -> Int {
  let r = h.child
  let a = await later()
  return a + r.raw
}

// A local whose address escapes and is not live across a suspension point
// stays on the native stack too.
// CHECK-LABEL: define {{.*}}swifttailcc void @"$s1m11escapingVarSiyYaF"(
// CHECK:         alloca %TSi, align 8, !coro.outside.frame
@inline(never) func touch(_ p: UnsafeMutablePointer<Int>) {}
public func escapingVar() async -> Int {
  let a = await later()
  var x = a
  withUnsafeMutablePointer(to: &x) { touch($0) }
  return x
}
