// RUN: %target-run-simple-swift( -enable-experimental-feature Lifetimes -enable-experimental-feature CoroutineAccessors -enable-experimental-feature CoroutineFunctions -parse-as-library) | %FileCheck %s
// RUN: %target-run-simple-swift( -O -enable-experimental-feature Lifetimes -enable-experimental-feature CoroutineAccessors -enable-experimental-feature CoroutineFunctions -parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_CoroutineFunctions
// UNSUPPORTED: back_deployment_runtime

// The coroutine frame of an access from an async function lives on the thread
// stack when no suspension point is reached during the access, and in the task
// allocator when one is.

import Darwin

nonisolated(unsafe) var frameOnStack = false

@inline(never) func note(_ p: UnsafeMutableRawPointer) {
  let top = UnsafeMutableRawPointer(pthread_get_stackaddr_np(pthread_self()))
  let size = pthread_get_stacksize_np(pthread_self())
  frameOnStack = p <= top && p > top - size
}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
struct H {
  var n = 1
  var child: Ref {
    @_lifetime(borrow self) yielding borrow {
      var local = n
      withUnsafeMutablePointer(to: &local) { note(UnsafeMutableRawPointer($0)) }
      yield Ref(local)
      _ = local
    }
  }
  @_noSuspendingAccess @_lifetime(borrow self)
  @yield_once func call() yields (Ref) -> () {
    var local = n
    withUnsafeMutablePointer(to: &local) { note(UnsafeMutableRawPointer($0)) }
    yield Ref(local)
    _ = local
  }
}

@inline(never) func later() async -> Int { await Task.yield(); return 1 }

@inline(never) func noAwait(_ h: H) async -> Bool {
  let r = h.child
  _ = r.raw
  return frameOnStack
}
@inline(never) func betweenAwaits(_ h: H) async -> Bool {
  _ = await later()
  let r = h.call()
  let result = frameOnStack
  _ = r.raw
  _ = await later()
  return result
}
@inline(never) func spans(_ h: H) async -> Bool {
  let r = h.child
  let result = frameOnStack
  _ = await later()
  _ = r.raw
  return result
}
actor A {
  let h = H()
  func run() async -> Bool {
    _ = await later()
    let r = h.child
    _ = r.raw
    return frameOnStack
  }
}

@main struct Main {
  static func main() async {
    // CHECK: no await: true
    print("no await: \(await noAwait(H()))")
    // CHECK: between awaits: true
    print("between awaits: \(await betweenAwaits(H()))")
    // CHECK: actor: true
    print("actor: \(await A().run())")
    // CHECK: spans an await: false
    print("spans an await: \(await spans(H()))")
  }
}
