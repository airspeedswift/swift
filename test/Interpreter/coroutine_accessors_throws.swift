// RUN: %target-run-simple-swift(-enable-experimental-feature CoroutineAccessors -enable-experimental-feature Lifetimes -Xfrontend -sil-verify-all) | %FileCheck %s
// RUN: %target-run-simple-swift(-O -enable-experimental-feature CoroutineAccessors -enable-experimental-feature Lifetimes -Xfrontend -sil-verify-all) | %FileCheck %s
// RUN: %target-run-simple-swift(-enable-experimental-feature CoroutineAccessors -enable-experimental-feature Lifetimes -Xfrontend -disable-callee-allocated-coro-abi -Xfrontend -sil-verify-all) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: swift_feature_CoroutineAccessors
// REQUIRES: swift_feature_Lifetimes

// A 'yielding borrow' or 'yielding mutate' accessor may throw before it
// yields. Then the access never begins: the second half does not run.

struct E: Error, CustomStringConvertible {
  let v: Int
  var description: String { "E(\(v))" }
}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
  var checked: Ref {
    @_lifetime(borrow self)
    yielding borrow throws {
      if raw < 0 { throw E(v: raw) }
      defer { print("end access \(raw)") }
      yield Ref(raw &* 10)
    }
  }
}

struct Box {
  var storage: Int
  var log: [String] = []
  var checked: Int {
    yielding borrow throws {
      if storage < 0 { throw E(v: storage) }
      yield storage
    }
    yielding mutate throws {
      if storage < 0 { throw E(v: storage) }
      log.append("begin")
      defer { log.append("end") }
      yield &storage
    }
  }
  subscript(i: Int) -> Int {
    yielding borrow throws {
      if i >= storage { throw E(v: i) }
      yield i &* 2
    }
  }
  var never: Int { yielding borrow throws(Never) { yield storage } }
}

func readRef(_ g: Ref) throws -> Int { let r = try g.checked; return r.raw }
func bump(_ b: inout Box) throws { try b.checked += 1 }
func assign(_ b: inout Box) throws { try b.checked = 7 }
func nested(_ g: Ref) throws -> Int {
  let r = try g.checked
  let s = try r.checked
  return s.raw
}
func throwWhileOpen(_ g: Ref) throws -> Int {
  let r = try g.checked
  if r.raw > 0 { throw E(v: 1000) }
  return r.raw
}

// CHECK: end access 3
// CHECK-NEXT: readRef 30
// CHECK-NEXT: readRef caught E(-3)
for v in [3, -3] {
  do { print("readRef", try readRef(Ref(v))) } catch { print("readRef caught", error) }
}

// CHECK-NEXT: bump 2 ["begin", "end"]
var b = Box(storage: 1)
do { try bump(&b); print("bump", b.storage, b.log) } catch { print("bump caught", error) }

// The mutate coroutine threw: the access did not begin.
// CHECK-NEXT: bump caught E(-1) -1 []
var bad = Box(storage: -1)
do { try bump(&bad); print("not thrown") } catch { print("bump caught", error, bad.storage, bad.log) }

// CHECK-NEXT: assign 7
do { try assign(&b); print("assign", b.storage) } catch { print("assign caught", error) }

// CHECK-NEXT: subscript 2
// CHECK-NEXT: subscript caught E(9)
do { print("subscript", try b[1]); _ = try b[9] } catch { print("subscript caught", error) }

// CHECK-NEXT: never 7
print("never", b.never)

// CHECK-NEXT: end access 20
// CHECK-NEXT: end access 2
// CHECK-NEXT: nested 200
// CHECK-NEXT: nested caught E(-2)
do { print("nested", try nested(Ref(2))) } catch { print("nested caught", error) }
do { _ = try nested(Ref(-2)) } catch { print("nested caught", error) }

// The caller throws while the access is open: the second half still runs.
// CHECK-NEXT: end access 4
// CHECK-NEXT: caller caught E(1000)
do { _ = try throwWhileOpen(Ref(4)) } catch { print("caller caught", error) }
