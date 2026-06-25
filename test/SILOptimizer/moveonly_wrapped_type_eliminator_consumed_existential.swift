// RUN: %target-swift-frontend -emit-sil -sil-verify-all %s
// RUN: %target-swift-frontend -O -emit-sil -sil-verify-all %s
// RUN: %target-swift-frontend -emit-sil %s | %FileCheck %s

protocol Foo {
    var foo: String { get }
} 
 
func identity(_ a: consuming any Foo) -> String {
    return a.foo
}

// https://github.com/swiftlang/swift/issues/87489
protocol P: ~Copyable {}
struct S: P, ~Copyable {}

func process<T: P & ~Copyable>(p: consuming T) {}

func foo() {
    let p: any P & ~Copyable = S()
    process(p: p)
}

// Consuming the payload of an opaque existential moves it out of the
// container's backing storage. The storage (which may be an out-of-line box)
// must still be deallocated with deinit_existential_addr -- without it the box
// leaks (rdar://163574532).
protocol Q: ~Copyable { consuming func stop() }
func makeQ() -> any Q & ~Copyable { fatalError() }

// CHECK-LABEL: sil hidden{{.*}}consumeExistential{{.*}} : $@convention(thin) () -> () {
// CHECK:         open_existential_addr mutable_access [[CONTAINER:%[0-9]+]] to
// CHECK:         deinit_existential_addr [[CONTAINER]]
// CHECK:       } // end sil function
func consumeExistential() {
    let e: any Q & ~Copyable = makeQ()
    e.stop()
}
