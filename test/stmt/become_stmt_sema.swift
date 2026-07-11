// RUN: %target-typecheck-verify-swift -enable-experimental-feature Become

// REQUIRES: swift_feature_Become

func callee(_ n: Int) -> Int { return n }

// 'become' cannot appear in a 'defer'.
func inDefer(_ n: Int) -> Int {
  defer {
    become callee(n) // expected-error {{'become' cannot transfer control out of a defer statement}}
  }
  return 0
}

// The tail-call expression is type-checked against the function result type.
func mismatch() -> String {
  become callee(0) // expected-error {{cannot convert return expression of type 'Int' to return type 'String'}}
}
