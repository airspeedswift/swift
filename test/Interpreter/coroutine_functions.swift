// RUN: %target-run-simple-swift(-enable-experimental-feature CoroutineFunctions -enable-experimental-feature CoroutineAccessors -enable-experimental-feature Lifetimes -Xfrontend -sil-verify-all) | %FileCheck %s
// RUN: %target-run-simple-swift(-O -enable-experimental-feature CoroutineFunctions -enable-experimental-feature CoroutineAccessors -enable-experimental-feature Lifetimes -Xfrontend -sil-verify-all) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

struct E: Error, CustomStringConvertible {
  let v: Int
  var description: String { "E(\(v))" }
}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(raw &+ 100) } }

  @_lifetime(borrow self, copy a)
  @yield_once func call(_ a: Ref) throws yields (Ref) -> () {
    if a.raw < 0 { throw E(v: a.raw) }
    print("ramp \(raw) \(a.raw)")
    defer { print("end \(raw) \(a.raw)") }
    yield Ref(raw &+ a.raw)
  }
}

@yield_once func gen<T>(_ x: T) yields (T) -> () {
  print("gen ramp")
  defer { print("gen end") }
  yield x
}

func viaArg(_ g: Ref, _ a: Ref) throws -> Int {
  let r = try g.call(a)
  print("use \(r.raw)")
  return r.raw
}
func viaLocal(_ g: Ref) throws -> Int {
  let a = g.child
  let r = try g.call(a)
  print("use \(r.raw)")
  return r.raw
}
func chained(_ g: Ref) throws -> Int {
  let r = try g.call(g.child)
  let s = try r.call(r)
  print("use \(s.raw)")
  return s.raw
}
func callerThrows(_ g: Ref, _ a: Ref) throws -> Int {
  let r = try g.call(a)
  if r.raw > 0 { throw E(v: 1000) }
  return r.raw
}

// The coroutine stays suspended while the yielded value is in use.
// CHECK: ramp 1 2
// CHECK-NEXT: use 3
// CHECK-NEXT: end 1 2
// CHECK-NEXT: 3
print(try viaArg(Ref(1), Ref(2)))
// CHECK-NEXT: ramp 1 101
// CHECK-NEXT: use 102
// CHECK-NEXT: end 1 101
print(try viaLocal(Ref(1)))
// CHECK: ramp 1 101
// CHECK-NEXT: ramp 102 102
// CHECK-NEXT: use 204
// CHECK-NEXT: end 102 102
// CHECK-NEXT: end 1 101
print(try chained(Ref(1)))
// Throw before the yield: the coroutine never started.
// CHECK: caught E(-5)
do { _ = try viaArg(Ref(1), Ref(-5)) } catch { print("caught \(error)") }
// The caller throws while the coroutine is suspended: the second half runs.
// CHECK-NEXT: ramp 1 2
// CHECK-NEXT: end 1 2
// CHECK-NEXT: caught E(1000)
do { _ = try callerThrows(Ref(1), Ref(2)) } catch { print("caught \(error)") }
// An escapable yield: the coroutine ends with the statement.
// CHECK-NEXT: gen ramp
// CHECK-NEXT: gen end
// CHECK-NEXT: got hello
let s = gen("hello")
print("got \(s)")
