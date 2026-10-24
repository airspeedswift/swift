// RUN: %target-swift-emit-silgen -module-name m %s -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes | %FileCheck %s
// RUN: %target-swift-emit-sil -module-name m %s -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes -sil-verify-all -o /dev/null

// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: swift_feature_Lifetimes

struct E: Error {}

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}

extension Ref {
  // A yield-once function lowers to a caller-allocated coroutine, with the
  // lifetime dependence on its yield and an error result when it throws.
  // CHECK-LABEL: sil hidden [ossa] @$s1m3RefV4callyyACXySiKF : $@yield_once_2 @convention(method) (Int, @guaranteed Ref) -> @lifetime(borrow 1) (@yields @guaranteed Ref, @error any Error) {
  // CHECK:         throw
  // CHECK:         yield {{%.*}}, resume
  // CHECK-LABEL: } // end sil function '$s1m3RefV4callyyACXySiKF'
  @_lifetime(borrow self)
  @yield_once func call(_ a: Int) throws yields (Ref) -> () {
    if a < 0 { throw E() }
    yield Ref(raw &+ a)
  }
}

// The call begins the coroutine, copies the yield, and ends the coroutine;
// the lifetime dependence passes extend it over the dependent uses.
// CHECK-LABEL: sil hidden [ossa] @$s1m1fySiAA3RefVKF :
// CHECK:         ([[Y:%.*]], [[TOKEN:%.*]], [[FRAME:%.*]]) = begin_apply %{{.*}}(%{{.*}}, %0)
// CHECK-NEXT:    begin_apply_error_br [[TOKEN]], normal [[NORMAL:bb[0-9]+]], error [[ERROR:bb[0-9]+]]
// CHECK:       [[NORMAL]]:
// CHECK:         copy_value [[Y]]
// CHECK:         end_apply [[TOKEN]]
// CHECK:       [[ERROR]]({{%.*}} : @owned $any Error):
// CHECK-NEXT:    end_borrow [[TOKEN]]
// CHECK-NEXT:    dealloc_stack [[FRAME]]
// CHECK-LABEL: } // end sil function '$s1m1fySiAA3RefVKF'
func f(_ g: Ref) throws -> Int { let r = try g.call(1); return r.raw }

// An address yield is copied out before the coroutine ends.
// CHECK-LABEL: sil hidden [ossa] @$s1m3genyyxXyxlF : $@yield_once_2 @convention(thin) <T> (@in_guaranteed T) -> @yields @in_guaranteed T {
@yield_once func gen<T>(_ x: T) yields (T) -> () { yield x }

// CHECK-LABEL: sil hidden [ossa] @$s1m1gSiyF :
// CHECK:         ([[Y:%.*]], [[TOKEN:%.*]], {{%.*}}) = begin_apply
// CHECK-NEXT:    load [trivial] [[Y]]
// CHECK-NEXT:    end_apply [[TOKEN]]
// CHECK-LABEL: } // end sil function '$s1m1gSiyF'
func g() -> Int { gen(41) &+ 1 }
