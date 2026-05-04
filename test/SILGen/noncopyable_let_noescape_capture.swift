// RUN: %target-swift-emit-silgen -Xllvm -sil-print-types %s | %FileCheck %s

// Anchor the SIL shape that SILGen emits when capturing a `~Copyable` `let`
// into a non-escaping closure.
//
// A previous implementation emitted `load [copy]` (or `copy_value`) of the
// `@guaranteed` capture at the `partial_apply` site, plus a matching
// `copy_value` of the `@guaranteed` parameter inside the closure body.
// Both produced illegal SIL that the move-only checker rejected with
// `copy of noncopyable typed value. This is a compiler bug.`
//
// The current emission forms the closure as `partial_apply [on_stack]`
// with a borrowed capture (load_borrow on the marked address), and the
// closure body spills the `@guaranteed` parameter into a stack temporary
// via `alloc_stack` + `store_borrow`, then applies
// `mark_unresolved_non_copyable_value [strict] [no_consume_or_assign]` to
// the address. Uses go through `load_borrow` of the mark.

struct NC: ~Copyable {
    func f() {}
}

func g(op: () -> ()) {}

// Outer: capture by load_borrow + on_stack partial_apply.
//
// CHECK-LABEL: sil {{.*}}@{{.*}}12directInitNC
// CHECK: [[CLOSURE_FN:%.*]] = function_ref @${{.*}}12directInitNC{{.*}}fU_
// CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [no_consume_or_assign] {{%.*}} : $*NC
// CHECK: [[BORROW:%.*]] = load_borrow [[MARK]] : $*NC
// CHECK: [[PAI:%.*]] = partial_apply [callee_guaranteed] [on_stack] [[CLOSURE_FN]]([[BORROW]])
// CHECK: apply {{%.*}}([[PAI]])
// CHECK: destroy_value [[PAI]]
// CHECK: end_borrow [[BORROW]]

// Closure body: store_borrow + strict mark for the captured let binding.
//
// CHECK-LABEL: sil {{.*}}@${{.*}}12directInitNC{{.*}}fU_ : $@convention(thin) (@guaranteed NC) -> ()
// CHECK: bb0([[ARG:%.*]] : @closureCapture @guaranteed $NC):
// CHECK: [[STACK:%.*]] = alloc_stack $NC, let, name "nc"
// CHECK: [[SB:%.*]] = store_borrow [[ARG]] to [[STACK]] : $*NC
// CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB]] : $*NC
// CHECK: [[LB:%.*]] = load_borrow [[MARK]] : $*NC
// CHECK: apply {{.*}}([[LB]])
// CHECK: end_borrow [[LB]]
// CHECK: end_borrow [[SB]]
// CHECK: dealloc_stack [[STACK]]
func directInitNC() {
    let nc = NC()
    g {
        nc.f()
    }
}

// Deferred-init: the outer let lives in an alloc_box (because of conditional
// initialization) but the capture path is the same.
//
// CHECK-LABEL: sil {{.*}}@{{.*}}14deferredInitNC
// CHECK: alloc_box ${ let NC }, let, name "nc"
// CHECK: [[CLOSURE_FN:%.*]] = function_ref @${{.*}}14deferredInitNC{{.*}}fU_
// CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [no_consume_or_assign] {{%.*}} : $*NC
// CHECK: [[BORROW:%.*]] = load_borrow [[MARK]] : $*NC
// CHECK: [[PAI:%.*]] = partial_apply [callee_guaranteed] [on_stack] [[CLOSURE_FN]]([[BORROW]])
// CHECK: apply {{%.*}}([[PAI]])
func deferredInitNC() {
    let nc: NC
    if .random() {
        nc = NC()
    } else {
        nc = NC()
    }
    g {
        nc.f()
    }
}
