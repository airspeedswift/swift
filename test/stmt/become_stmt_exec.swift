// RUN: %empty-directory(%t)
// RUN: %target-swiftc_driver -Xfrontend -enable-experimental-feature -Xfrontend Become -o %t/a.out %s
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

// Also verify the guaranteed tail call survives optimization: a 'become'-using
// function is marked non-inlinable so the optimizer cannot copy the musttail
// into a non-tail-position caller (which would be an invalid LLVM musttail).
// RUN: %target-swiftc_driver -O -Xfrontend -enable-experimental-feature -Xfrontend Become -o %t/a.out.opt %s
// RUN: %target-codesign %t/a.out.opt
// RUN: %target-run %t/a.out.opt | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: swift_feature_Become

// A mutually-recursive chain of guaranteed tail calls must run in O(1) stack:
// without guaranteed TCO this would overflow long before 100 million frames.
func ping(_ n: Int) -> Int {
  if n == 0 { return 0 }
  become pong(n - 1)
}
func pong(_ n: Int) -> Int {
  if n == 0 { return 0 }
  become ping(n - 1)
}

// CHECK: 0
print(ping(100_000_000))
