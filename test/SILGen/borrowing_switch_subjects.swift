// RUN: %target-swift-emit-silgen -Xllvm -sil-print-types %s | %FileCheck %s

struct Inner: ~Copyable {}

struct Outer: ~Copyable {
    var storedInner: Inner

    var readInner: Inner {
        _read { fatalError() }
    }

    var getInner: Inner {
        get { fatalError() }
    }
}

func use(_: borrowing Outer) {}
func use(_: borrowing Inner) {}

func temporary() -> Outer { fatalError() }

// CHECK-LABEL: sil {{.*}}@{{.*}}11borrowParam
// CHECK:  = mark_unresolved_non_copyable_value [no_consume_or_assign]
func borrowParam(x: borrowing Outer) {
    // CHECK: [[STACK:%.*]] = alloc_stack $Outer
    // CHECK: [[SB:%.*]] = store_borrow {{%.*}} to [[STACK]]
    // CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB]]
    switch x {
    case let y:
        // CHECK: [[LB:%.*]] = load_borrow [[MARK]]
        // CHECK: apply {{.*}}([[LB]])
        use(y)
    }
    // CHECK: end_borrow [[LB]]
    // CHECK: end_borrow [[SB]]
    // CHECK: dealloc_stack [[STACK]]


    // CHECK: [[BORROW_OUTER:%.*]] = begin_borrow {{.*}} : $Outer
    // CHECK: [[BORROW_INNER:%.*]] = struct_extract [[BORROW_OUTER]]
    // CHECK: [[BORROW_FIX:%.*]] = begin_borrow [fixed] [[BORROW_INNER]]
    // CHECK: [[STACK_INNER:%.*]] = alloc_stack $Inner
    // CHECK: [[SB_INNER:%.*]] = store_borrow [[BORROW_FIX]] to [[STACK_INNER]]
    // CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB_INNER]]
    switch x.storedInner {
    case let y:
        // CHECK: [[LB:%.*]] = load_borrow [[MARK]]
        // CHECK: apply {{.*}}([[LB]])
        use(y)
    }
    // CHECK: end_borrow [[LB]]
    // CHECK: end_borrow [[SB_INNER]]
    // CHECK: dealloc_stack [[STACK_INNER]]
    // CHECK: end_borrow [[BORROW_OUTER]]

    // CHECK: [[BORROW_OUTER:%.*]] = begin_borrow {{.*}} : $Outer
    // CHECK: ([[BORROW_INNER:%.*]], [[TOKEN:%.*]]) = begin_apply {{.*}}([[BORROW_OUTER]]
    // CHECK: [[COPY_INNER:%.*]] = copy_value [[BORROW_INNER]]
    // CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [no_consume_or_assign] [[COPY_INNER]]
    // CHECK: [[BORROW:%.*]] = begin_borrow [[MARK]]
    // CHECK: [[BORROW_FIX:%.*]] = begin_borrow [fixed] [[BORROW]]
    // CHECK: [[STACK2:%.*]] = alloc_stack $Inner
    // CHECK: [[SB2:%.*]] = store_borrow [[BORROW_FIX]] to [[STACK2]]
    // CHECK: [[MARK2:%.*]] = mark_unresolved_non_copyable_value [strict] [no_consume_or_assign] [[SB2]]
    switch x.readInner {
    case let y:
        // CHECK: [[LB2:%.*]] = load_borrow [[MARK2]]
        // CHECK: apply {{.*}}([[LB2]])
        use(y)
    }
    // CHECK: end_apply [[TOKEN]]
    // CHECK: end_borrow [[BORROW_OUTER]]

    // `temporary()` is an rvalue, so we
    // CHECK: [[FN:%.*]] = function_ref @{{.*}}9temporary
    // CHECK: [[TMP:%.*]] = apply [[FN]]()
    // CHECK: [[BORROW_OUTER:%.*]] = begin_borrow [fixed] [[TMP]]
    // CHECK: end_borrow [[BORROW_OUTER]]
    // CHECK: store [[TMP]] to [init] [[Y:%.*]] :
    // CHECK: [[MARK:%.*]] = mark_unresolved_non_copyable_value [no_consume_or_assign] [[Y]]
    switch temporary() {
    case let y:
        // CHECK: [[LOAD_BORROW:%.*]] = load_borrow [[MARK]]
        // CHECK: apply {{.*}}([[LOAD_BORROW]])
        use(y)
    }
}
