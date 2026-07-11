// RUN: %target-swift-emit-silgen -enable-experimental-feature Become %s | %FileCheck %s

// REQUIRES: swift_feature_Become

// The novel case: forwarding an 'inout' of a noncopyable value into a
// guaranteed tail call. The move-only checker accepts the forward and the call
// still lowers to a tail 'apply'. (For 'inout' the SIL apply is followed by an
// 'end_access' marker that lowers to nothing, preserving the musttail at IR.)
struct NC: ~Copyable { var i: Int }

// CHECK-LABEL: sil hidden [noinline] [ossa] @$s18become_noncopyable6stepNCySiAA0D0Vz_SitF
// CHECK: apply [musttail] {{.*}} : $@convention(thin) (@inout NC, Int) -> Int
func stepNC(_ c: inout NC, _ budget: Int) -> Int {
  if budget == 0 { return c.i }
  c.i += 1
  become stepNC(&c, budget - 1)
}
