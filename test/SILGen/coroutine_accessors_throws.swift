// RUN: %target-swift-emit-silgen -module-name m %s -enable-experimental-feature CoroutineAccessors | %FileCheck %s
// RUN: %target-swift-emit-sil -module-name m %s -enable-experimental-feature CoroutineAccessors -sil-verify-all -o /dev/null

// REQUIRES: swift_feature_CoroutineAccessors

struct E: Error {}

struct S {
  var storage = 0
  var checked: Int {
    yielding borrow throws { if storage < 0 { throw E() }; yield storage }
    yielding mutate throws { yield &storage }
  }
}

// The coroutines have an error result.
// CHECK-LABEL: sil hidden [ossa] @$s1m1SV7checkedSivy : $@yield_once_2 @convention(method) (S) -> (@yields Int, @error any Error) {
// CHECK:         throw
// CHECK:         yield
// CHECK-LABEL: } // end sil function '$s1m1SV7checkedSivy'
// CHECK-LABEL: sil hidden [ossa] @$s1m1SV7checkedSivx : $@yield_once_2 @convention(method) (@inout S) -> (@yields @inout Int, @error any Error) {

// The synthesized getter throws what the coroutine throws.
// CHECK-LABEL: sil hidden [transparent] [ossa] @$s1m1SV7checkedSivg : $@convention(method) (S) -> (Int, @error any Error) {

// No setter or legacy coroutines are synthesized: they cannot throw.
// CHECK-NOT: @$s1m1SV7checkedSivs
// CHECK-NOT: @$s1m1SV7checkedSivr
// CHECK-NOT: @$s1m1SV7checkedSivM

// CHECK-LABEL: sil hidden [ossa] @$s1m4readySiAA1SVKF :
// CHECK:         ([[YIELD:%.*]], [[TOKEN:%.*]], [[FRAME:%.*]]) = begin_apply %{{.*}}(%0)
// CHECK-NEXT:    begin_apply_error_br [[TOKEN]], normal [[NORMAL:bb[0-9]+]], error [[ERROR:bb[0-9]+]]
// CHECK:       [[NORMAL]]:
// CHECK:         end_apply [[TOKEN]]
// CHECK:         dealloc_stack [[FRAME]]
// CHECK:       [[ERROR]]([[E:%.*]] : @owned $any Error):
// CHECK-NEXT:    end_borrow [[TOKEN]]
// CHECK-NEXT:    dealloc_stack [[FRAME]]
// CHECK:         throw [[E]]
// CHECK-LABEL: } // end sil function '$s1m4readySiAA1SVKF'
func read(_ s: S) throws -> Int { try s.checked }
