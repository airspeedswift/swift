// RUN: %target-swift-frontend %s -emit-sil -o /dev/null -verify -sil-verify-all \
// RUN:   -enable-experimental-feature Lifetimes \
// RUN:   -enable-experimental-feature CoroutineAccessors

// REQUIRES: swift_feature_Lifetimes
// REQUIRES: swift_feature_CoroutineAccessors

// A non-lexical ~Escapable variable ends at its last use, not at the end of
// its scope: the access it depends on does not overlap a later mutation.

struct Ref: ~Escapable {
  let raw: Int
  @_lifetime(immortal) init(_ r: Int) { raw = r }
}
struct Box {
  var n = 0
  var child: Ref { @_lifetime(borrow self) get { Ref(n) } }
  var yielded: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
}
@inline(never) func use(_ r: borrowing Ref) {}

func useThenMutate(_ b: inout Box) {
  let r = b.child
  use(r)
  b.n += 1
}

func readThenMutate(_ b: inout Box) -> Int {
  let r = b.child
  let x = r.raw
  b.n += x
  return b.n
}

func guardLetThenMutate(_ b: inout Box, _ c: Bool) {
  guard c else { return }
  let r = b.yielded
  use(r)
  b.n += 1
}

// Ending variables early does not hide an escape from a scope.
func escapesScope() {
  var outer = Ref(0) // expected-error {{lifetime-dependent variable 'outer' escapes its scope}}
  do {
    let b = Box() // expected-note {{it depends on the lifetime of variable 'b'}}
    let r = b.yielded
    outer = r
  }
  use(outer) // expected-note {{this use of the lifetime-dependent value is out of scope}}
}
