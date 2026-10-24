// RUN: %target-swift-emit-silgen -module-name m %s | %FileCheck %s
// RUN: %target-swift-emit-silgen -module-name m -enable-library-evolution %s | %FileCheck %s

// REQUIRES: concurrency

// An opaque read of noncopyable storage with an 'async' or 'throws' getter
// calls the getter. No read coroutine is synthesized.

public struct NC: ~Copyable { public var x = 1 }

public struct S {
  public var nc: NC { get throws { NC() } }
}

public protocol P: ~Copyable { var nc: NC { get throws } }
extension S: P {}

open class C {
  open var nc: NC { get async throws { NC() } }
}

// CHECK-NOT: @$s1m1SV2ncAA2NCVvr
// CHECK-NOT: @$s1m1SV2ncAA2NCVvy

// CHECK-LABEL: sil {{.*}}[thunk] [ossa] @$s1m1SVAA1PA2aDP2ncAA2NCVvgTW :
// CHECK:         function_ref @$s1m1SV2ncAA2NCVvg :
// CHECK-LABEL: } // end sil function '$s1m1SVAA1PA2aDP2ncAA2NCVvgTW'

// CHECK-LABEL: sil [ossa] @$s1m3useySiAA1SVKF :
// CHECK:         function_ref @$s1m1SV2ncAA2NCVvg :
// CHECK:         try_apply
// CHECK-LABEL: } // end sil function '$s1m3useySiAA1SVKF'
public func use(_ s: S) throws -> Int { try s.nc.x }

// CHECK-LABEL: sil [ossa] @$s1m8useClassySiAA1CCYaKF :
// CHECK:         class_method %0, #C.nc!getter
// CHECK-LABEL: } // end sil function '$s1m8useClassySiAA1CCYaKF'
public func useClass(_ c: C) async throws -> Int { try await c.nc.x }

// CHECK-LABEL: sil_vtable{{.*}} C {
// CHECK-NEXT:    #C.nc!getter:
// CHECK-NOT:     #C.nc!read
// CHECK-NOT:     #C.nc!yielding_borrow

// CHECK-LABEL: sil_witness_table{{.*}} S: P module m {
// CHECK-NEXT:    method #P.nc!getter:
// CHECK-NEXT:  }
