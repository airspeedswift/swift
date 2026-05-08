// RUN: %target-typecheck-verify-swift

// https://github.com/apple/swift/issues/67631
//
// Destructuring a multi-statement closure's result used to fall through every
// constraint fix's diagnose path and emit the `failed_to_produce_diagnostic`
// placeholder — both branches of a solve either silently defer or fire only
// downstream fixes after the fallback has already printed. Make sure we now
// produce a real source-level diagnostic at the pattern.

func makeTuple() -> (Int, String) { (1, "hi") }

func multiStatementClosureResultDestructure() {
  let (a, b) = { // expected-error {{type annotation missing in pattern}}
    print("whatever")
    makeTuple()
  }()
  _ = (a, b)
}

// Single-statement closures with an implicit return still compile cleanly.
func singleStatementClosureResultDestructure() {
  let (a, b) = { makeTuple() }()
  _ = (a, b)
}

// Direct tuple-arity mismatches still get the specific diagnostic.
func directTupleArityMismatch() {
  let (a, b) = () // expected-error {{'()' is not convertible to '(_, _)', tuples have a different number of elements}}
  _ = (a, b)
}

func emptyClosureDestructure() {
  let (a, b) = {}() // expected-error {{'()' is not convertible to '(_, _)', tuples have a different number of elements}}
  _ = (a, b)
}
