// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -emit-module -o %t/Lib.swiftmodule -module-name Lib %S/Inputs/coroutine_functions_lib.swift -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes
// RUN: %target-swift-frontend -emit-sil -sil-verify-all -I %t %s -o /dev/null -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes
// RUN: %target-swift-frontend -emit-module -o %t/LibEvo.swiftmodule -module-name LibEvo -enable-library-evolution -swift-version 6 -emit-module-interface-path %t/LibEvo.swiftinterface %S/Inputs/coroutine_functions_lib.swift -enable-experimental-feature CoroutineFunctions -enable-experimental-feature Lifetimes
// RUN: %FileCheck --check-prefix=INTERFACE %s < %t/LibEvo.swiftinterface
// RUN: %target-swift-typecheck-module-from-interface(%t/LibEvo.swiftinterface) -module-name LibEvo

// REQUIRES: swift_feature_CoroutineFunctions
// REQUIRES: swift_feature_Lifetimes

// INTERFACE: @yield_once public func call(_ a: LibEvo::Ref) throws yields (LibEvo::Ref) -> ()
// INTERFACE: @yield_once public func gen<T>(_ x: T) yields (T) -> ()

import Lib

func f(_ g: Ref, _ a: Ref) throws -> Int { let r = try g.call(a); return r.raw }
func g() -> Int { gen(41) &+ 1 }
