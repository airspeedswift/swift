//===--- DiagnoseSuspendingAccess.cpp - @_noSuspendingAccess checking -----===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Diagnose an access to a '@_noSuspendingAccess' declaration -- a yielding
// accessor of a property or subscript, or a call to a yield-once function --
// that is held across a suspension point of an async function.
//
// It runs after the lifetime-dependence passes, so the access's scope is the
// one scope fixup extended over the uses of the yielded value. IRGen relies on
// it: the coroutine frame of such an access always lives on the native stack.
//
//===----------------------------------------------------------------------===//

#define DEBUG_TYPE "diagnose-suspending-access"

#include "swift/AST/DiagnosticsSIL.h"
#include "swift/SIL/InstructionUtils.h"
#include "swift/SIL/SILFunction.h"
#include "swift/SIL/SILInstruction.h"
#include "swift/SILOptimizer/PassManager/Transforms.h"

using namespace swift;

namespace {
class DiagnoseSuspendingAccess : public SILFunctionTransform {
  void run() override {
    SILFunction *fn = getFunction();
    if (!fn->isAsync())
      return;
    auto &diags = fn->getModule().getASTContext().Diags;
    for (auto &block : *fn) {
      for (auto &inst : block) {
        auto *bai = dyn_cast<BeginApplyInst>(&inst);
        if (!bai)
          continue;
        const ValueDecl *from = nullptr;
        auto *decl = getNoSuspendingAccessDecl(bai, &from);
        if (!decl)
          continue;
        // The old yield-once ABI (a resilient access, or `_read`) passes a
        // fixed-size buffer and the callee allocates a frame that does not fit
        // with malloc, so the frame cannot be guaranteed to be on the stack.
        // Reject rather than silently heap-allocate.
        if (!bai->isCalleeAllocated()) {
          diags.diagnose(bai->getLoc().getSourceLoc(),
                         diag::no_suspending_access_resilient, decl);
          diags.diagnose(decl->getLoc(),
                         diag::no_suspending_access_resilient_note);
          continue;
        }
        auto *suspension = findSuspensionInCoroutineAccess(bai);
        if (!suspension)
          continue;
        diagnoseSuspendingAccess(diags, bai, decl, from, suspension);
      }
    }
  }
};
} // end anonymous namespace

SILTransform *swift::createDiagnoseSuspendingAccess() {
  return new DiagnoseSuspendingAccess();
}
