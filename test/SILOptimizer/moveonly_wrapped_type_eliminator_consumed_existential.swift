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

// Calling a consuming witness method on a noncopyable existential whose base is
// the load of an lvalue (e.g. a consuming parameter) used to copy the opened
// payload out of a temporary existential, which the move-only checker rejected
// as a copy of a noncopyable value. The existential storage is now opened in
// place and the opened payload is consumed directly, with no copy.
protocol RestartableBody: ~Copyable {
    consuming func restart() -> Self
    consuming func stop()
}

// CHECK-LABEL: sil hidden{{.*}}callConsumingWitness{{.*}} : $@convention(thin) (@in any RestartableBody & ~Copyable) -> () {
// CHECK:         [[OPENED:%.*]] = open_existential_addr mutable_access
// CHECK-NOT:     copy_addr
// CHECK:         [[WITNESS:%.*]] = witness_method {{.*}}#RestartableBody.stop
// CHECK:         apply [[WITNESS]]<{{.*}}>([[OPENED]])
// CHECK:       } // end sil function
func callConsumingWitness(_ e: consuming any RestartableBody & ~Copyable) {
    e.stop()
}

func callConsumingWitnessReturningSelf(
    _ e: consuming any RestartableBody & ~Copyable
) -> any RestartableBody & ~Copyable {
    e.restart()
}

func callConsumingWitnessViaVar(_ e: consuming any RestartableBody & ~Copyable) {
    var x = e
    x.stop()
}

struct Wrapper: ~Copyable {
    var _body: any RestartableBody & ~Copyable
    var body: any RestartableBody & ~Copyable {
        consuming get { _body }
    }
}

func callConsumingWitnessViaConsumingGet(_ w: consuming Wrapper) {
    w.body.stop()
}

struct Body: ~Copyable {
    var body: any RestartableBody & ~Copyable

    init(_ body: consuming any RestartableBody & ~Copyable) {
        self.body = body
    }

    consuming func restart() -> Body {
        Body(self.body.restart())
    }
}

