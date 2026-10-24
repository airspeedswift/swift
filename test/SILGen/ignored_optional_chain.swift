// RUN: %target-swift-emit-silgen %s | %FileCheck %s

// A discarded optional chain is evaluated for its side effects only: its value
// is ignored inside the non-nil branch and only an Optional<()> reaches the
// merge point.

final class C {
  var next: C?
  func bump() -> Int { 1 }
}

// CHECK-LABEL: sil hidden [ossa] @$s22ignored_optional_chain7discardyyAA1CCSgF
// CHECK:       switch_enum {{.*}}, case #Optional.some!enumelt: [[SOME:bb[0-9]+]], case #Optional.none!enumelt: [[NONE:bb[0-9]+]]
// CHECK:       [[SOME]]([[C:%.*]] : @owned $C):
// CHECK:         [[R:%.*]] = apply {{%.*}}([[C]])
// CHECK:         ignored_use
// CHECK:         [[V:%.*]] = enum $Optional<()>, #Optional.some!enumelt
// CHECK:         br [[MERGE:bb[0-9]+]]([[V]])
// CHECK:       [[MERGE]]({{%.*}} : $Optional<()>):
// CHECK-NOT:     $Optional<Int>
// CHECK:       } // end sil function
func discard(_ c: C?) {
  _ = c?.bump()
}
