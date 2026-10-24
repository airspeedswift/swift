// RUN: %target-run-simple-swift(-parse-as-library -Xfrontend -sil-verify-all) | %FileCheck %s
// RUN: %target-run-simple-swift(-parse-as-library -O -Xfrontend -sil-verify-all) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

struct NC: ~Copyable {
  var x: Int
  deinit { print("deinit \(x)") }
}
struct E: Error {}

protocol P: ~Copyable { var nc: NC { get throws } }
struct Throwing: P {
  var fail = false
  var nc: NC { get throws { if fail { throw E() }; return NC(x: 1) } }
}
struct NonThrowing: P { var nc: NC { NC(x: 2) } }

struct Typed { var nc: NC { get throws(E) { throw E() } } }
struct Async { var nc: NC { get async throws { NC(x: 3) } } }

class Base { var nc: NC { get throws { NC(x: 4) } } }
class Derived: Base { override var nc: NC { get throws { NC(x: 5) } } }

struct Scoped {
  subscript<R: ~Copyable>(_ k: String, _ body: (Int) throws -> R) -> R {
    get throws { try body(k.count) }
  }
}

func generic<T: P & ~Copyable>(_ t: borrowing T) throws -> Int { try t.nc.x }
func existential(_ p: any P) throws -> Int { try p.nc.x }
func take(_ n: consuming NC) -> Int { n.x }

@main struct Main {
  static func main() async throws {
    // CHECK: deinit 1
    // CHECK-NEXT: generic 1
    print("generic", try generic(Throwing()))
    // CHECK-NEXT: deinit 2
    // CHECK-NEXT: existential 2
    print("existential", try existential(NonThrowing()))
    // CHECK-NEXT: caught E()
    do { _ = try Throwing(fail: true).nc; print("not thrown") } catch { print("caught", error) }
    // CHECK-NEXT: typed E
    do throws(E) { _ = try Typed().nc } catch { print("typed", error) }
    // CHECK-NEXT: deinit 3
    // CHECK-NEXT: async 3
    print("async", try await Async().nc.x)
    // CHECK-NEXT: deinit 5
    // CHECK-NEXT: override 5
    let b: Base = Derived()
    print("override", try b.nc.x)
    // CHECK-NEXT: deinit 1
    // CHECK-NEXT: consumed 1
    print("consumed", take(try Throwing().nc))
    // CHECK-NEXT: deinit 3
    // CHECK-NEXT: noncopyable result 3
    print("noncopyable result", try Scoped()["abc"] { NC(x: $0) }.x)
    // CHECK-NEXT: copyable result 4
    print("copyable result", try Scoped()["abcd"] { $0 })
  }
}
