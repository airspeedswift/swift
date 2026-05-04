// RUN: %target-swift-emit-silgen -Xllvm -sil-print-types %s | %FileCheck %s

// Anchor the SIL shape that `bindBorrow` (lib/SILGen/SILGenPattern.cpp) emits
// for `let`-binding a `~Copyable` enum payload under a `borrowing` switch.
//
// A previous implementation emitted `copy_value` on the `@guaranteed`
// payload, producing illegal SIL that the move-only checker rejected with
// `copy of noncopyable typed value. This is a compiler bug.` The current
// emission spills the `@guaranteed` value into a stack temporary via
// `alloc_stack` + `store_borrow`, then applies
// `mark_unresolved_non_copyable_value [strict] [no_consume_or_assign]` to the
// address. Uses go through `load_borrow` of the mark.

struct Box: ~Copyable { var x: Int }

enum E: ~Copyable {
    case a(Box)
    case b(Box, Box)
}

func use(_: borrowing Box) {}

// Single noncopyable payload bound by `let`.
//
// CHECK-LABEL: sil {{.*}}@{{.*}}13singlePayload
// CHECK: switch_enum {{.*}} case #E.a!enumelt: [[A_BB:bb[0-9]+]]
// CHECK: [[A_BB]]([[PAYLOAD:%.*]] : @guaranteed $Box):
// CHECK: [[STACK:%.*]] = alloc_stack $Box
// CHECK: [[SB:%.*]] = store_borrow [[PAYLOAD]] to [[STACK]] : $*Box
// CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB]] : $*Box
// CHECK: [[LB:%.*]] = load_borrow [[MARK]] : $*Box
// CHECK: apply {{.*}}([[LB]])
// CHECK: end_borrow [[LB]]
// CHECK: end_borrow [[SB]]
// CHECK: dealloc_stack [[STACK]]
func singlePayload(_ e: borrowing E) {
    switch e {
    case .a(let b):
        use(b)
    case .b:
        ()
    }
}

// Tuple of noncopyable payloads bound by `let`. Each element gets its own
// alloc_stack + store_borrow + mark.
//
// CHECK-LABEL: sil {{.*}}@{{.*}}12tuplePayload
// CHECK: switch_enum {{.*}} case #E.b!enumelt: [[B_BB:bb[0-9]+]]
// CHECK: [[B_BB]]([[TUPLE:%.*]] : @guaranteed $(Box, Box)):
// CHECK: ([[L:%.*]], [[R:%.*]]) = destructure_tuple [[TUPLE]]
// CHECK: [[STACK_L:%.*]] = alloc_stack $Box
// CHECK: [[SB_L:%.*]] = store_borrow [[L]] to [[STACK_L]] : $*Box
// CHECK: [[MARK_L:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB_L]] : $*Box
// CHECK: [[STACK_R:%.*]] = alloc_stack $Box
// CHECK: [[SB_R:%.*]] = store_borrow [[R]] to [[STACK_R]] : $*Box
// CHECK: [[MARK_R:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB_R]] : $*Box
func tuplePayload(_ e: borrowing E) {
    switch e {
    case .a:
        ()
    case .b(let l, let r):
        use(l)
        use(r)
    }
}
