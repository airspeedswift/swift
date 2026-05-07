// RUN: %target-swift-emit-silgen %s | %FileCheck %s

// https://github.com/swiftlang/swift/issues/69945
//
// A pack expansion pattern that is an lvalue (here, a mutable class property
// reached through a pack element) must be load-coerced to an rvalue before
// SILGen. CSApply's outer `coerceToType` on the expansion short-circuits
// when the expansion type already matches the destination (both are
// `repeat each U`), so it never descended into the pattern. The pattern
// reached SILGen still typed as `@lvalue τ_…_…`, tripping the
// "l-values must be emitted with emitLValue" assertion in
// `emitRValue`.
//
// Regression: the AST of the `repeat (each tail).value` pattern must have
// a `load_expr` wrapping the `member_ref_expr`, and SILGen must emit the
// function without crashing.

class Thing<T> {
  var value: T
  init(_ value: T) { self.value = value }

  // CHECK-LABEL: sil hidden [ossa] @$s40pack_expansion_lvalue_pattern_load_699455ThingC13combineThings4head4tailyACyxG_ACyqd__Gqd__QptRvd__lF
  // The pack-expansion loop body must load the Thing<each U> element from the
  // pack and invoke the getter on it (not take the address of `.value` as an
  // lvalue). The getter writes directly into the result tuple slot.
  // CHECK: [[ELT_ADDR:%.*]] = pack_element_get {{.*}} as $*Thing<@pack_element({{.*}}) each U>
  // CHECK-NEXT: [[ELT:%.*]] = load [copy] [[ELT_ADDR]]
  // CHECK: class_method {{.*}}, #Thing.value!getter
  func combineThings<each U>(head: Thing<T>, tail: repeat Thing<each U>) {
    let _ = Thing<(T, repeat each U)>((head.value, repeat (each tail).value))
  }
}
