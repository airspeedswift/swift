// RUN: %target-swift-emit-silgen -enable-experimental-feature Become %s | %FileCheck %s

// REQUIRES: swift_feature_Become

func pong(_ n: Int) -> Int { return n }

// A 'become' lowers to a tail 'apply' that is immediately followed by 'return'.
// The enclosing function is marked [noinline] so the guaranteed tail call is
// never copied into a non-tail-position caller by the optimizer.
// CHECK-LABEL: sil hidden [noinline] [ossa] @$s6become4pingyS2iF
// CHECK: [[R:%.*]] = apply [musttail] {{.*}} : $@convention(thin) (Int) -> Int
// CHECK-NEXT: return [[R]]
func ping(_ n: Int) -> Int {
  become pong(n)
}
