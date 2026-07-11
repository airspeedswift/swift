// RUN: %target-swift-frontend -emit-ir -enable-experimental-feature Become %s | %FileCheck %s

// REQUIRES: swift_feature_Become

func pong(_ n: Int) -> Int { return n }

// A 'become' is lowered to an LLVM 'musttail' call, which guarantees the tail
// call is turned into a jump (no stack growth).
// CHECK-LABEL: define {{.*}} @"$s6become4pingyS2iF"
// CHECK: musttail call swiftcc {{.*}} @"$s6become4pongyS2iF"
func ping(_ n: Int) -> Int {
  become pong(n)
}
