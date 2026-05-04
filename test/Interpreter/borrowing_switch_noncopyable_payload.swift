// RUN: %target-run-simple-swift(-Xfrontend -disable-availability-checking)
// RUN: %target-run-simple-swift(-O -Xfrontend -disable-availability-checking)

// REQUIRES: executable_test

// UNSUPPORTED: back_deployment_runtime || use_os_stdlib

// Regression test for a SILGen bug where `bindBorrow` emitted a `copy_value`
// on a noncopyable typed value when destructuring an enum payload of a
// `borrowing` switch over a `~Copyable` enum. The move-only checker rightly
// rejected the copy with the "missed copy" diagnostic, so source code that
// hit this pattern failed to compile with a "compiler bug" message.
//
// Fix: spill the @guaranteed payload into a stack temporary via store_borrow
// and apply mark_unresolved_non_copyable_value to the address. The move-only
// checker recognizes that pattern as a borrowed init.

struct Box: ~Copyable {
  var x: Int
}

enum E: ~Copyable {
  case empty
  case single(Box)
  case pair(Box, Box)
}

func sum(_ e: borrowing E) -> Int {
  switch e {
  case .empty:
    return 0
  case .single(let b):
    return b.x
  case .pair(let l, let r):
    return l.x + r.x
  }
}

precondition(sum(.empty) == 0)
precondition(sum(.single(Box(x: 42))) == 42)
precondition(sum(.pair(Box(x: 3), Box(x: 4))) == 7)
