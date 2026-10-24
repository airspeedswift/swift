// RUN: %target-swift-emit-silgen -verify %s -enable-experimental-feature CoroutineFunctions

// REQUIRES: swift_feature_CoroutineFunctions

// PROTOTYPE: only direct calls to yield-once functions are lowered.

@yield_once func coro(_ x: Int) yields (Int) -> () { yield x }

func value() -> @yield_once (Int) yields (Int) -> () {
  coro // expected-error {{using a yield-once function as a value is not supported yet; call it directly}}
}
