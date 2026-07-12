//===--- SILGenStmt.cpp - Implements Lowering of ASTs -> SIL for Stmts ----===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "ArgumentScope.h"
#include "ArgumentSource.h"
#include "Condition.h"
#include "Conversion.h"
#include "ExecutorBreadcrumb.h"
#include "Initialization.h"
#include "LValue.h"
#include "RValue.h"
#include "SILGen.h"
#include "Scope.h"
#include "StorageRefResult.h"
#include "SwitchEnumBuilder.h"
#include "swift/AST/ConformanceLookup.h"
#include "swift/AST/DiagnosticsSIL.h"
#include "swift/AST/ExistentialLayout.h"
#include "swift/Basic/Assertions.h"
#include "swift/Basic/Defer.h"
#include "swift/Basic/ProfileCounter.h"
#include "swift/SIL/AbstractionPatternGenerators.h"
#include "swift/SIL/BasicBlockUtils.h"
#include "swift/SIL/InstructionUtils.h"
#include "swift/SIL/SILArgument.h"
#include "swift/SIL/SILProfiler.h"
#include "swift/SIL/SILUndef.h"
#include "llvm/Support/SaveAndRestore.h"

using namespace swift;
using namespace Lowering;

template<typename...T, typename...U>
static void diagnose(ASTContext &Context, SourceLoc loc, Diag<T...> diag,
                     U &&...args) {
  Context.Diags.diagnose(loc,
                         diag, std::forward<U>(args)...);
}

SILBasicBlock *SILGenFunction::createBasicBlockAfter(SILBasicBlock *afterBB) {
  assert(afterBB);
  return F.createBasicBlockAfter(afterBB);
}

SILBasicBlock *SILGenFunction::createBasicBlockBefore(SILBasicBlock *beforeBB) {
  assert(beforeBB);
  return F.createBasicBlockBefore(beforeBB);
}

SILBasicBlock *SILGenFunction::createBasicBlock() {
  // If we have a current insertion point, insert there.
  if (B.hasValidInsertionPoint()) {
    return F.createBasicBlockAfter(B.getInsertionBB());

  // Otherwise, insert at the end of the current section.
  } else {
    return createBasicBlock(CurFunctionSection);
  }
}

SILBasicBlock *SILGenFunction::createBasicBlock(llvm::StringRef debugName) {
  auto block = createBasicBlock();
  block->setDebugName(debugName);
  return block;
}

SILBasicBlock *SILGenFunction::createBasicBlock(FunctionSection section) {
  switch (section) {
  case FunctionSection::Ordinary: {
    // The end of the ordinary section is just the end of the function
    // unless postmatter blocks exist.
    if (StartOfPostmatter != F.end()) {
      return F.createBasicBlockBefore(&*StartOfPostmatter);
    } else {
      return F.createBasicBlock();
    }
  }

  case FunctionSection::Postmatter: {
    // The end of the postmatter section is always the end of the function.
    // Register the new block as the start of the postmatter if needed.
    SILBasicBlock *newBB = F.createBasicBlock();
    if (StartOfPostmatter == F.end())
      StartOfPostmatter = newBB->getIterator();
    return newBB;
  }

  }
  llvm_unreachable("bad function section");
}

SILBasicBlock *
SILGenFunction::createBasicBlockAndBranch(SILLocation loc,
                                          SILBasicBlock *destBB) {
  auto *newBB = createBasicBlock();
  SILGenBuilder(B, newBB).createBranch(loc, destBB);
  return newBB;
}

void SILGenFunction::eraseBasicBlock(SILBasicBlock *block) {
  assert(block->pred_empty() && "erasing block with predecessors");
  assert(block->empty() && "erasing block with content");
  SILFunction::iterator blockIt = block->getIterator();
  if (blockIt == StartOfPostmatter) {
    StartOfPostmatter = next_or_end(blockIt, F.end());
  }
  block->eraseFromParent();
}

// Merge blocks during a single traversal of the block list. Only unconditional
// branch edges are visited. Consequently, this takes only as much time as a
// linked list traversal and requires no additional storage.
//
// For each block, check if it can be merged with its successor. Place the
// merged block at the successor position in the block list.
//
// Typically, the successor occurs later in the list. This is most efficient
// because merging moves instructions from the successor to the
// predecessor. This way, instructions will only be moved once. Furthermore, the
// merged block will be visited again to determine if it can be merged with it's
// successor, and so on, so no edges are skipped.
//
// In rare cases, the predecessor is merged with its earlier successor, which has
// already been visited. If the successor can also be merged, then it has
// already happened, and there is no need to revisit the merged block.
void SILGenFunction::mergeCleanupBlocks() {
  for (auto bbPos = F.begin(), bbEnd = F.end(), nextPos = bbPos; bbPos != bbEnd;
       bbPos = nextPos) {
    // A forward iterator referring to the next unprocessed block in the block
    // list. If blocks are merged and moved, then this will be updated.
    nextPos = std::next(bbPos);

    // Consider the current block as the predecessor.
    auto *predBB = &*bbPos;
    auto *BI = dyn_cast<BranchInst>(predBB->getTerminator());
    if (!BI)
      continue;

    // predBB has an unconditional branch to succBB. If succBB has no other
    // predecessors, then merge the blocks.
    auto *succBB = BI->getDestBB();
    if (!succBB->getSinglePredecessorBlock())
      continue;

    // Before merging, establish iterators that won't be invalidated by erasing
    // succBB. Use a reverse iterator to remember the position before a block.
    //
    // Remember the block before the current successor as a position for placing
    // the merged block.
    auto beforeSucc = std::next(SILFunction::reverse_iterator(succBB));

    // Remember the position before the current predecessor to avoid skipping
    // blocks or revisiting blocks unnecessarily.
    auto beforePred = std::next(SILFunction::reverse_iterator(predBB));
    // Since succBB will be erased, move before it.
    if (beforePred == SILFunction::reverse_iterator(succBB))
      ++beforePred;

    // Merge `predBB` with `succBB`. This erases `succBB`.
    mergeBasicBlockWithSingleSuccessor(predBB, succBB);

    // If predBB is first in the list, then it must be the entry block which
    // cannot be moved.
    if (beforePred != F.rend()) {
      // Move the merged block into the successor position. (If the blocks are
      // not already adjacent, then the first is typically the trampoline.)
      assert(beforeSucc != F.rend()
             && "entry block cannot have a predecessor.");
      F.moveBlockAfter(predBB, &*beforeSucc);
    }
    // If after moving predBB there are no more blocks to process, then break.
    if (beforePred == F.rbegin())
      break;

    // Update the loop iterator to the next unprocessed block.
    nextPos = SILFunction::iterator(&*std::prev(beforePred));
  }
}

//===----------------------------------------------------------------------===//
// SILGenFunction emitStmt implementation
//===----------------------------------------------------------------------===//

namespace {
  class StmtEmitter : public Lowering::ASTVisitor<StmtEmitter> {
    SILGenFunction &SGF;
  public:
    StmtEmitter(SILGenFunction &sgf) : SGF(sgf) {}
#define STMT(ID, BASE) void visit##ID##Stmt(ID##Stmt *S);
#include "swift/AST/StmtNodes.def"

    ASTContext &getASTContext() { return SGF.getASTContext(); }

    SILBasicBlock *createBasicBlock() { return SGF.createBasicBlock(); }

    JumpDest createJumpDest(Stmt *cleanupLoc) {
      return JumpDest(SGF.createBasicBlock(),
                      SGF.getCleanupsDepth(),
                      CleanupLocation(cleanupLoc));
    }
    JumpDest createThrowDest(Stmt *cleanupLoc, ThrownErrorInfo errorInfo) {
      return JumpDest(SGF.createBasicBlock(FunctionSection::Postmatter),
                      SGF.getCleanupsDepth(),
                      CleanupLocation(cleanupLoc),
                      errorInfo);
    }
  };
} // end anonymous namespace

void SILGenFunction::emitStmt(Stmt *S) {
  StmtEmitter(*this).visit(S);
}

/// getOrEraseBlock - If there are branches to the specified JumpDest,
/// return the block, otherwise return NULL. The JumpDest must be valid.
static SILBasicBlock *getOrEraseBlock(SILGenFunction &SGF, JumpDest &dest) {
  SILBasicBlock *BB = dest.takeBlock();
  if (BB->pred_empty()) {
    // If the block is unused, we don't need it; just delete it.
    SGF.eraseBasicBlock(BB);
    return nullptr;
  }
  return BB;
}

/// emitOrDeleteBlock - If there are branches to the specified JumpDest,
/// emit it per emitBlock.  If there aren't, then just delete the block - it
/// turns out to have not been needed.
static void emitOrDeleteBlock(SILGenFunction &SGF, JumpDest &dest,
                              SILLocation BranchLoc) {
  // If we ever add a single-use optimization here (to just continue
  // the predecessor instead of branching to a separate block), we'll
  // need to update visitDoCatchStmt so that code like:
  //   try { throw x } catch _ { }
  // doesn't leave us emitting the rest of the function in the
  // postmatter section.
  SILBasicBlock *BB = getOrEraseBlock(SGF, dest);
  if (BB != nullptr)
    SGF.B.emitBlock(BB, BranchLoc);
}

Condition SILGenFunction::emitCondition(Expr *E, bool invertValue,
                                        ArrayRef<SILType> contArgs,
                                        ProfileCounter NumTrueTaken,
                                        ProfileCounter NumFalseTaken) {
  assert(B.hasValidInsertionPoint() &&
         "emitting condition at unreachable point");

  // Sema forces conditions to have Bool type, which guarantees this.
  SILValue V;
  {
    FullExpr Scope(Cleanups, CleanupLocation(E));
    V = emitRValue(E).forwardAsSingleValue(*this, E);
  }
  auto i1Value = emitUnwrapIntegerResult(E, V);
  return emitCondition(i1Value, E, invertValue, contArgs, NumTrueTaken,
                       NumFalseTaken);
}

Condition SILGenFunction::emitCondition(SILValue V, SILLocation Loc,
                                        bool invertValue,
                                        ArrayRef<SILType> contArgs,
                                        ProfileCounter NumTrueTaken,
                                        ProfileCounter NumFalseTaken) {
  assert(B.hasValidInsertionPoint() &&
         "emitting condition at unreachable point");

  SILBasicBlock *ContBB = createBasicBlock();

  for (SILType argTy : contArgs) {
    ContBB->createPhiArgument(argTy, OwnershipKind::Owned);
  }

  SILBasicBlock *FalseBB = createBasicBlock();
  SILBasicBlock *TrueBB = createBasicBlock();

  if (invertValue)
    B.createCondBranch(Loc, V, FalseBB, TrueBB, NumFalseTaken, NumTrueTaken);
  else
    B.createCondBranch(Loc, V, TrueBB, FalseBB, NumTrueTaken, NumFalseTaken);

  return Condition(TrueBB, FalseBB, ContBB, Loc);
}

void StmtEmitter::visitBraceStmt(BraceStmt *S) {
  // Enter a new scope.
  LexicalScope BraceScope(SGF, CleanupLocation(S));
  // This scope was added to properly handle local borrow bindings.
  // Without this, the access scope ends prematurely as it is bound
  // to very restrictive scopes, causing illegal borrow accesses.
  FormalEvaluationScope BraceEvaluationScope(SGF);
  // This is a workaround until the FIXME in SILGenFunction::getOrCreateScope
  // has been addressed. Property wrappers create incorrect source locations.
  DebugScope DbgScope(SGF, S);
  // Keep in sync with DiagnosticsSIL.def.
  const unsigned ReturnStmtType   = 0;
  const unsigned BreakStmtType    = 1;
  const unsigned ContinueStmtType = 2;
  const unsigned ThrowStmtType    = 3;
  const unsigned UnknownStmtType  = 4;
  unsigned StmtType = UnknownStmtType;

  // Emit local auxiliary declarations.
  if (!SGF.LocalAuxiliaryDecls.empty()) {
    for (auto *var : SGF.LocalAuxiliaryDecls) {
      if (auto *patternBinding = var->getParentPatternBinding())
        SGF.visit(patternBinding);

      SGF.visit(var);
    }

    SGF.LocalAuxiliaryDecls.clear();
  }

  bool didDiagnoseUnreachableElements = false;
  for (auto &ESD : S->getElements()) {
    
    if (auto D = ESD.dyn_cast<Decl*>()) {
      // Hoisted declarations are emitted at the top level by emitSourceFile().
      if (D->isHoisted())
        continue;

      // PatternBindingBecls represent local variable bindings that execute
      // as part of the function's execution.
      if (!isa<PatternBindingDecl>(D) && !isa<VarDecl>(D)) {
        // Other decls define entities that may be used by the program, such as
        // local function declarations. So handle them here, before checking for
        // reachability, and then continue looping.
        if (!SGF.SGM.shouldSkipDecl(D))
          SGF.visit(D);
        continue;
      }
    }
    
    // If we ever reach an unreachable point, stop emitting statements and issue
    // an unreachable code diagnostic.
    if (!SGF.B.hasValidInsertionPoint()) {
      // If this is an implicit statement or expression, just skip over it,
      // don't emit a diagnostic here.
      if (auto *S = ESD.dyn_cast<Stmt*>()) {
        // Return statement in a single-expression closure or function is
        // implicit, but the result isn't. So, skip over return statements
        // that are implicit and either have no results or the result is
        // implicit. Otherwise, don't so we can emit unreachable code
        // diagnostics.
        if (S->isImplicit() && isa<ReturnStmt>(S)) {
          auto returnStmt = cast<ReturnStmt>(S);
          if (!returnStmt->hasResult()) {
            continue;
          }
          if (returnStmt->getResult()->isImplicit()) {
            continue;
          }
        }
        if (S->isImplicit() && !isa<ReturnStmt>(S)) {
          continue;
        }
      } else if (auto *E = ESD.dyn_cast<Expr*>()) {
        if (E->isImplicit()) {
          // Some expressions, like `OptionalEvaluationExpr` and
          // `OpenExistentialExpr`, are implicit but may contain non-implicit
          // children that should be diagnosed as unreachable. Check
          // descendants here to see if there is anything to diagnose.
          bool hasDiagnosableDescendant = false;
          E->forEachChildExpr([&](auto *childExpr) -> Expr * {
            if (!childExpr->isImplicit())
              hasDiagnosableDescendant = true;

            return hasDiagnosableDescendant ? nullptr : childExpr;
          });

          // If there's nothing to diagnose, ignore this expression.
          if (!hasDiagnosableDescendant)
            continue;
        }
      } else if (auto D = ESD.dyn_cast<Decl*>()) {
        // Local declarations aren't unreachable - only their usages can be. To
        // that end, we only care about pattern bindings since their
        // initializer expressions can be unreachable.
        if (!isa<PatternBindingDecl>(D))
          continue;
      }
      
      if (didDiagnoseUnreachableElements)
        continue;
      didDiagnoseUnreachableElements = true;
      
      if (StmtType != UnknownStmtType) {
        diagnose(getASTContext(), ESD.getStartLoc(),
                 diag::unreachable_code_after_stmt, StmtType);
      } else {
        diagnose(getASTContext(), ESD.getStartLoc(),
                 diag::unreachable_code);
        if (!S->getElements().empty()) {
          for (auto *arg : SGF.getFunction().getArguments()) {
            auto argTy = arg->getType().getASTType();
            if (argTy->isStructurallyUninhabited()) {
              // Use the interface type in this diagnostic because the SIL type
              // unpacks tuples. But, the SIL type being exploded means it
              // points directly at the offending tuple element type and we can
              // use that to point the user at problematic component(s).
              auto argIFaceTy = arg->getDecl()->getInterfaceType();
              diagnose(getASTContext(), S->getStartLoc(),
                       diag::unreachable_code_uninhabited_param_note,
                       arg->getDecl()->getBaseName().userFacingName(),
                       argIFaceTy,
                       argIFaceTy->is<EnumType>(),
                       argTy);
              break;
            }
          }
        }
      }
      continue;
    }

    // Process children.
    if (auto *S = ESD.dyn_cast<Stmt*>()) {
      visit(S);
      if (isa<ReturnStmt>(S))
        StmtType = ReturnStmtType;
      if (isa<BreakStmt>(S))
        StmtType = BreakStmtType;
      if (isa<ContinueStmt>(S))
        StmtType = ContinueStmtType;
      if (isa<ThrowStmt>(S))
        StmtType = ThrowStmtType;
    } else if (auto *E = ESD.dyn_cast<Expr*>()) {
      SGF.emitIgnoredExpr(E);
    } else {
      auto *D = cast<Decl *>(ESD);
      assert((isa<PatternBindingDecl>(D) || isa<VarDecl>(D)) &&
             "other decls should be handled before the reachability check");
      SGF.visit(D);
    }
  }
}

namespace {
  class StoreResultInitialization : public Initialization {
    SILValue &Storage;
    SmallVectorImpl<CleanupHandle> &Cleanups;
  public:
    StoreResultInitialization(SILValue &storage,
                              SmallVectorImpl<CleanupHandle> &cleanups)
      : Storage(storage), Cleanups(cleanups) {}

    void copyOrInitValueInto(SILGenFunction &SGF, SILLocation loc,
                             ManagedValue value, bool isInit) override {
      Storage = value.getValue();
      auto cleanup = value.getCleanup();
      if (cleanup.isValid()) Cleanups.push_back(cleanup);
    }
  };
} // end anonymous namespace

static void wrapInSubstToOrigInitialization(SILGenFunction &SGF,
                                    InitializationPtr &init,
                                    AbstractionPattern origType,
                                    CanType substType,
                                    SILType expectedTy) {
  auto loweredSubstTy = SGF.getLoweredRValueType(substType);
  if (expectedTy.getASTType() != loweredSubstTy) {
    auto conversion =
      Conversion::getSubstToOrig(origType, substType,
                                 SILType::getPrimitiveObjectType(loweredSubstTy),
                                 expectedTy);
    auto convertingInit = new ConvertingInitialization(conversion,
                                                       std::move(init));
    init.reset(convertingInit);
  }
}

static InitializationPtr
createIndirectResultInit(SILGenFunction &SGF, SILValue addr,
                         SmallVectorImpl<CleanupHandle> &cleanups) {
  // Create an initialization which will initialize it.
  auto &resultTL = SGF.getTypeLowering(addr->getType());
  auto temporary = SGF.useBufferAsTemporary(addr, resultTL);

  // Remember the cleanup that will be activated.
  auto cleanup = temporary->getInitializedCleanup();
  if (cleanup.isValid())
    cleanups.push_back(cleanup);

  return temporary;
}

static InitializationPtr
createIndirectResultInit(SILGenFunction &SGF, SILValue addr,
                         AbstractionPattern origType,
                         CanType substType,
                         SmallVectorImpl<CleanupHandle> &cleanups) {
  auto init = createIndirectResultInit(SGF, addr, cleanups);
  wrapInSubstToOrigInitialization(SGF, init, origType, substType,
                                  addr->getType());
  return init;
}

static void
preparePackResultInit(SILGenFunction &SGF, SILLocation loc,
                      AbstractionPattern origExpansionType,
                      CanTupleEltTypeArrayRef resultEltTypes,
                      SILArgument *packAddr,
                      SmallVectorImpl<CleanupHandle> &cleanups,
                      SmallVectorImpl<InitializationPtr> &inits) {
  auto loweredPackType = packAddr->getType().castTo<SILPackType>();
  assert(loweredPackType->getNumElements() == resultEltTypes.size() &&
         "mismatched pack components; possible missing substitutions on orig type?");

  // If the pack expanded to nothing, there shouldn't be any initializers
  // for it in our context.
  if (resultEltTypes.empty()) {
    return;
  }

  auto origPatternType = origExpansionType.getPackExpansionPatternType();

  // Induce a formal pack type from the slice of the tuple elements.
  CanPackType formalPackType =
    CanPackType::get(SGF.getASTContext(), resultEltTypes);

  for (auto componentIndex : indices(resultEltTypes)) {
    auto resultComponentType = formalPackType.getElementType(componentIndex);
    auto loweredComponentType = loweredPackType->getElementType(componentIndex);
    assert(isa<PackExpansionType>(loweredComponentType)
             == isa<PackExpansionType>(resultComponentType) &&
           "need expansions in similar places");

    // If we have a pack expansion, the initializer had better be a
    // pack expansion expression, and we'll generate a loop for it.
    // Preserve enough information to do this properly.
    if (isa<PackExpansionType>(resultComponentType)) {
      auto resultPatternType =
        cast<PackExpansionType>(resultComponentType).getPatternType();
      auto expectedPatternTy = SILType::getPrimitiveAddressType(
        cast<PackExpansionType>(loweredComponentType).getPatternType());

      auto init = PackExpansionInitialization::create(SGF, packAddr,
                                                      formalPackType,
                                                      componentIndex);

      // Remember the cleanup for destroying all of the expansion elements.
      auto expansionCleanup = init->getExpansionCleanup();
      if (expansionCleanup.isValid())
        cleanups.push_back(expansionCleanup);

      inits.emplace_back(init.release());
      wrapInSubstToOrigInitialization(SGF, inits.back(), origPatternType,
                                      resultPatternType,
                                      expectedPatternTy);

    // Otherwise, we should be able to just project out the pack
    // address and set up a nomal indirect result into it.
    } else {
      auto packIndex =
        SGF.B.createScalarPackIndex(loc, componentIndex, formalPackType);
      auto eltAddr =
        SGF.B.createPackElementGet(loc, packIndex, packAddr,
                SILType::getPrimitiveAddressType(loweredComponentType));

      inits.push_back(createIndirectResultInit(SGF, eltAddr,
                                               origPatternType,
                                               resultComponentType,
                                               cleanups));
    }
  }
}

static InitializationPtr
prepareIndirectResultInit(SILGenFunction &SGF, SILLocation loc,
                          CanSILFunctionType fnTypeForResults,
                          AbstractionPattern origResultType,
                          CanType resultType,
                          ArrayRef<SILResultInfo> &allResults,
                          MutableArrayRef<SILValue> &directResults,
                          ArrayRef<SILArgument*> &indirectResultAddrs,
                          SmallVectorImpl<CleanupHandle> &cleanups) {
  // Recursively decompose tuple abstraction patterns.
  if (origResultType.isTuple()) {
    // Normally, we build a compound initialization for the tuple.  But
    // the initialization we build should match the substituted type,
    // so if the tuple in the abstraction pattern vanishes under variadic
    // substitution, we actually just want to return the initializer
    // for the surviving component.
    TupleInitialization *tupleInit = nullptr;
    SmallVector<InitializationPtr, 1> singletonEltInit;

    bool vanishes = origResultType.doesTupleVanish();
    if (!vanishes) {
      auto resultTupleType = cast<TupleType>(resultType);
      tupleInit = new TupleInitialization(resultTupleType);
      tupleInit->SubInitializations.reserve(
        cast<TupleType>(resultType)->getNumElements());
    }

    // The list of element initializers to build into.
    auto &eltInits = (vanishes
        ? static_cast<SmallVectorImpl<InitializationPtr> &>(singletonEltInit)
        : tupleInit->SubInitializations);

    origResultType.forEachTupleElement(resultType,
                                       [&](TupleElementGenerator &elt) {
      if (!elt.isOrigPackExpansion()) {
        auto eltInit = prepareIndirectResultInit(SGF, loc, fnTypeForResults,
                                                 elt.getOrigType(),
                                                 elt.getSubstTypes()[0],
                                                 allResults,
                                                 directResults,
                                                 indirectResultAddrs,
                                                 cleanups);
        eltInits.push_back(std::move(eltInit));
      } else {
        assert(allResults[0].isPack());
        assert(SGF.silConv.isSILIndirect(allResults[0]));
        allResults = allResults.slice(1);

        auto packAddr = indirectResultAddrs[0];
        indirectResultAddrs = indirectResultAddrs.slice(1);

        preparePackResultInit(SGF, loc, elt.getOrigType(), elt.getSubstTypes(),
                              packAddr, cleanups, eltInits);
      }
    });

    if (vanishes) {
      assert(singletonEltInit.size() == 1);
      return std::move(singletonEltInit.front());
    }

    assert(tupleInit);
    assert(eltInits.size() == cast<TupleType>(resultType)->getNumElements());
    return InitializationPtr(tupleInit);
  }

  // Okay, pull the next result off the list of results.
  auto result = allResults[0];
  allResults = allResults.slice(1);

  // If it's indirect, we should be emitting into an argument.
  InitializationPtr init;
  if (SGF.silConv.isSILIndirect(result)) {
    // Pull off the next indirect result argument.
    SILValue addr = indirectResultAddrs.front();
    indirectResultAddrs = indirectResultAddrs.slice(1);

    init = createIndirectResultInit(SGF, addr, origResultType, resultType,
                                    cleanups);
  } else {
    // Otherwise, make an Initialization that stores the value in the
    // next element of the directResults array.
    auto storeInit = new StoreResultInitialization(directResults[0], cleanups);
    directResults = directResults.slice(1);
    init = InitializationPtr(storeInit);

    SILType expectedResultTy =
      SGF.getSILTypeInContext(result, fnTypeForResults);
    wrapInSubstToOrigInitialization(SGF, init, origResultType, resultType,
                                    expectedResultTy);
  }

  return init;
}

/// Prepare an Initialization that will initialize the result of the
/// current function.
///
/// \param directResultsBuffer - will be filled with the direct
///   components of the result
/// \param cleanups - will be filled (after initialization completes)
///   with all the active cleanups managing the result values
InitializationPtr
SILGenFunction::prepareIndirectResultInit(
                                 SILLocation loc,
                                 AbstractionPattern origResultType,
                                 CanType formalResultType,
                                 SmallVectorImpl<SILValue> &directResultsBuffer,
                                 SmallVectorImpl<CleanupHandle> &cleanups) {
  auto fnConv = F.getConventions();

  // Make space in the direct-results array for all the entries we need.
  directResultsBuffer.append(fnConv.getNumDirectSILResults(), SILValue());

  ArrayRef<SILResultInfo> allResults = fnConv.funcTy->getResults();
  MutableArrayRef<SILValue> directResults = directResultsBuffer;
  ArrayRef<SILArgument*> indirectResultAddrs = F.getIndirectResults();

  auto init = ::prepareIndirectResultInit(*this, loc,
                                          fnConv.funcTy,
                                          origResultType,
                                          formalResultType, allResults,
                                          directResults, indirectResultAddrs,
                                          cleanups);

  assert(allResults.empty());
  assert(directResults.empty());
  assert(indirectResultAddrs.empty());

  return init;
}

static Expr *lookThroughProjections(Expr *expr) {
  auto *lookupExpr = dyn_cast<LookupExpr>(expr);
  if (!lookupExpr) {
    return expr;
  }
  return lookThroughProjections(lookupExpr->getBase());
}

static bool isGlobalLetRefExpr(Expr *expr) {
  auto *decl = dyn_cast<DeclRefExpr>(expr);
  if (!decl) {
    return false;
  }
  auto *varDecl = dyn_cast<VarDecl>(decl->getDecl());
  if (!varDecl || !varDecl->isLet() || !varDecl->isGlobalStorage()) {
    return false;
  }
  return true;
}

bool SILGenFunction::emitBorrowOrMutateAccessorResult(
    SILLocation loc, Expr *ret, SmallVectorImpl<SILValue> &directResults) {
  auto *accessor = cast<AccessorDecl>(FunctionDC->getAsDecl());
  auto accessorName = (accessor->getAccessorKind() == AccessorKind::Borrow)
                          ? "borrow"
                          : "mutate";

  assert(accessor->isBorrowAccessor() || accessor->isMutateAccessor());

  auto emitLoadBorrowFromGuaranteedAddress =
      [&](ManagedValue guaranteedAddress) -> SILValue {
    assert(guaranteedAddress.getValue()->getType().isAddress());
    auto regularLoc = RegularLocation::getAutoGeneratedLocation();
    auto load = B.createLoadBorrow(regularLoc, guaranteedAddress);
    // unchecked_ownership is used to silence the ownership verifier for
    // returning a value produced within a load_borrow scope. SILGenCleanup
    // eliminates it and introduces return_borrow appropriately.
    return B.createUncheckedOwnership(regularLoc, load).getValue();
  };

  auto storageRefResult =
      StorageRefResult::findStorageReferenceExprForBorrow(SGM.M, ret);
  auto lvExpr = storageRefResult.getTransitiveRoot();
  // If the return expression is not an lvalue, diagnose.
  if (!lvExpr) {
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::invalid_borrow_accessor_return, accessorName);
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::borrow_accessor_not_a_projection_note, accessorName);
    return true;
  }
  // For now diagnose multiple return statements in borrow/mutate accessors.
  // We need additional support for this.
  // 1. Address phis are banned in SIL.
  // 2. borrowed from is not inserted in SILGenCleanup.
  if (!ReturnDest.getBlock()->getPredecessorBlocks().empty()) {
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::invalid_multiple_return_borrow_accessor);
    return true;
  }

  // Emit return value at +0.

  auto *baseExpr = lookThroughProjections(storageRefResult.getStorageRef());

  FormalEvaluationScope scope(*this);
  LValueOptions options;

  if (accessor->isMutateAccessor()) {
    options = options.forGuaranteedAddressReturn(true);
  } else {
    assert(accessor->isBorrowAccessor());
    if (F.getSelfArgument()->getType().isAddress() ||
        isGlobalLetRefExpr(baseExpr)) {
      options = options.forGuaranteedAddressReturn(true);
    } else {
      options = options.forGuaranteedReturn(true);
    }
  }

  auto lvalue = emitLValue(ret,
                           F.getSelfArgument()->getType().isObject()
                               ? SGFAccessKind::BorrowedObjectRead
                           : accessor->isBorrowAccessor()
                               ? SGFAccessKind::BorrowedAddressRead
                               : SGFAccessKind::Write,
                           options);

  // If the accessor is annotated with @_unsafeSelfDependentResultAttr,
  // disable diagnosing the return expression.
  // This is needed to implement borrow accessors for Unsafe*Pointer based
  // Container types where the compiler cannot analyze the safety of return
  // expressions based on pointer arithmetic and unsafe addressors.
  // Example:
  // public struct Container<Element: ~Copyable>: ~Copyable {
  //   var _storage: UnsafeMutableBufferPointer<Element>
  //   var _count: Int
  //
  //   public subscript(index: Int) -> Element {
  //     @_unsafeSelfDependentResult
  //     borrow {
  //       precondition(index >= 0 && index < _count, "Index out of bounds")
  //       return _storage.baseAddress.unsafelyUnwrapped.advanced(by:
  //       index).pointee
  //     }
  //   }
  // }
  if (accessor->getAttrs().hasAttribute<UnsafeSelfDependentResultAttr>()) {
    auto regularLoc = RegularLocation::getAutoGeneratedLocation();
    auto resultMV = emitRawProjectedLValue(regularLoc, std::move(lvalue));
    SILValue result = resultMV.getValue();
    if (resultMV.getType().isAddress() &&
        F.getConventions().hasGuaranteedResult()) {
      result = emitLoadBorrowFromGuaranteedAddress(resultMV);
    }
    directResults.push_back(result);
    return false;
  }

  // If the return expression is not a transitive projection of self,
  // diagnose.

  if (!baseExpr->isSelfExprOf(accessor) && !isGlobalLetRefExpr(baseExpr)) {
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::invalid_borrow_accessor_return, accessorName);
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::borrow_accessor_not_a_projection_note, accessorName);
    return true;
  }

  auto resultMV =
      tryEmitProjectedLValue(ret, std::move(lvalue), TSanKind::None);
  if (!resultMV) {
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::invalid_borrow_accessor_return, accessorName);
    diagnose(getASTContext(), ret->getStartLoc(),
             diag::borrow_accessor_not_a_projection_note, accessorName);
    return true;
  }

  SILValue result = resultMV->getValue();
  SILType selfType = F.getSelfArgument()->getType();

  if (F.getConventions().hasGuaranteedResult()) {
    // If we are returning the result of borrow accessor, strip the
    // unnecessary copy_value + mark_unresolved_non_copyable_value
    // instructions.
    if (selfType.isMoveOnly()) {
      result = lookThroughMoveOnlyCheckerPattern(result);
    }
    // If the SIL convention is @guaranteed and the generated result is an
    // address, emit a load_borrow.
    if (result->getType().isAddress()) {
      result = emitLoadBorrowFromGuaranteedAddress(*resultMV);
    }
  }

  directResults.push_back(result);
  return false;
}

void SILGenFunction::emitReturnExpr(SILLocation branchLoc,
                                    Expr *ret) {
  SmallVector<SILValue, 4> directResults;
  auto retTy = ret->getType()->getCanonicalType();
  
  AbstractionPattern origRetTy = TypeContext
    ? TypeContext->OrigType.getFunctionResultType()
    : AbstractionPattern(retTy);

  if (F.getConventions().hasIndirectSILResults()) {
    // Indirect return of an address-only value.
    FullExpr scope(Cleanups, CleanupLocation(ret));

    // Build an initialization which recursively destructures the tuple.
    SmallVector<CleanupHandle, 4> resultCleanups;
    InitializationPtr resultInit =
      prepareIndirectResultInit(ret, origRetTy,
                                ret->getType()->getCanonicalType(),
                                directResults, resultCleanups);

    // Emit the result expression into the initialization.
    emitExprInto(ret, resultInit.get());

    // Deactivate all the cleanups for the result values.
    for (auto cleanup : resultCleanups) {
      Cleanups.forwardCleanup(cleanup);
    }
  } else if (auto *accessor =
                 dyn_cast_or_null<AccessorDecl>(FunctionDC->getAsDecl());
             (accessor &&
              (accessor->isBorrowAccessor() || accessor->isMutateAccessor()))) {
    bool hasError =
        emitBorrowOrMutateAccessorResult(branchLoc, ret, directResults);
    if (hasError) {
      return;
    }
    assert(!directResults.empty());
  } else {
    // SILValue return.
    FullExpr scope(Cleanups, CleanupLocation(ret));
    FormalEvaluationScope writeback(*this);
    
    // Does the return context require reabstraction?
    RValue RV;
    
    auto loweredRetTy = getLoweredType(retTy);
    auto loweredResultTy = getLoweredType(origRetTy, retTy);
    if (loweredResultTy != loweredRetTy) {
      auto conversion = Conversion::getSubstToOrig(origRetTy, retTy,
                                                   loweredRetTy, loweredResultTy);
      RV = RValue(*this, ret, emitConvertedRValue(ret, conversion));
    } else {
      RV = emitRValue(ret);
    }
    
    std::move(RV)
      .ensurePlusOne(*this, CleanupLocation(ret))
      .forwardAll(*this, directResults);
  }

  Cleanups.emitBranchAndCleanups(ReturnDest, branchLoc, directResults);
}

/// A 'dealloc_stack' in a try_apply successor is "dead across the call" if the
/// storage it frees is not used at or after the call: every non-dealloc use of
/// the storage precedes the try_apply. (Sibling 'dealloc_stack's of the same
/// storage on the other edge don't count as a use.) Such a slot was only needed
/// to form the call's operands, so freeing it before the tail call is valid.
static bool becomeDeallocIsDeadAcrossCall(
    DeallocStackInst *ds,
    const llvm::SmallPtrSetImpl<SILInstruction *> &beforeApply) {
  for (auto *use : ds->getOperand()->getUses()) {
    SILInstruction *user = use->getUser();
    if (user == ds || isa<DeallocStackInst>(user))
      continue;
    if (!beforeApply.contains(user))
      return false;
  }
  return true;
}

/// Classify a successor block of a guaranteed-tail-call 'try_apply' (its normal
/// or error edge) as a "clean tail": nothing between block entry and the
/// terminator lowers to real machine code. 'dealloc_stack's whose storage is
/// dead by the time the call is formed are tolerated (they will be sunk to
/// before the try_apply); everything else must be a scope-ender, debug/lifetime
/// marker, or pure effect-free value instruction. This is a pure predicate --
/// it does not mutate the IR.
///
/// 'beforeApply' is the set of instructions preceding the try_apply in its own
/// block (used to decide which deallocs are dead across the call).
static bool becomeSuccessorIsCleanTail(
    SILBasicBlock *succ, TryApplyInst *tryApply,
    const llvm::SmallPtrSetImpl<SILInstruction *> &beforeApply) {
  for (auto &inst : *succ) {
    if (isa<TermInst>(inst))
      break;
    if (isa<EndAccessInst>(inst) || isa<EndBorrowInst>(inst) ||
        isa<DebugValueInst>(inst) || isa<ExtendLifetimeInst>(inst))
      continue;
    if (auto *ds = dyn_cast<DeallocStackInst>(&inst)) {
      if (becomeDeallocIsDeadAcrossCall(ds, beforeApply))
        continue;
      return false;
    }
    if (!inst.mayHaveSideEffects() && !inst.mayReadFromMemory() &&
        !inst.mayWriteToMemory())
      continue;
    return false;
  }
  return true;
}

/// Determine whether the error edge of a guaranteed-tail-call 'try_apply'
/// re-throws the callee's error as our own without running any teardown that
/// lowers to machine code. The immediate error successor must be clean (per
/// becomeSuccessorIsCleanTail) and either 'throw' the error argument directly,
/// or forward it via a single 'br' to the function's shared throw epilogue
/// (which SILGen has not yet terminated at this point). In both cases IRGen
/// drops the error branch entirely for a musttail call -- the thrown error
/// propagates as our own via the forwarded swifterror register -- so all that
/// matters is that nothing between the call and the rethrow lowers to machine
/// code.
static bool becomeErrorEdgeRethrowsCleanly(
    SILBasicBlock *errorBB, SILValue errorArg, TryApplyInst *tryApply,
    const llvm::SmallPtrSetImpl<SILInstruction *> &beforeApply) {
  if (errorBB->getNumArguments() != 1 ||
      SILValue(errorBB->getArgument(0)) != errorArg)
    return false;
  if (!becomeSuccessorIsCleanTail(errorBB, tryApply, beforeApply))
    return false;
  TermInst *term = errorBB->getTerminator();
  // Direct rethrow.
  if (auto *thr = dyn_cast<ThrowInst>(term))
    return thr->getOperand() == errorArg;
  // Forwarding branch to the shared throw epilogue: 'br dest(errorArg)'. The
  // destination block re-throws; we don't inspect it (it may not be terminated
  // yet during SILGen), but the forwarded value must be exactly our error.
  if (auto *br = dyn_cast<BranchInst>(term))
    return br->getArgs().size() == 1 && br->getArgs()[0] == errorArg;
  return false;
}


void SILGenFunction::emitBecomeStmt(SILLocation loc, BecomeStmt *S) {
  Expr *E = S->getResult();

  // Guaranteed tail calls with an indirect (address-only) result are not yet
  // supported; fall back to an ordinary return so we still produce valid SIL.
  if (F.getConventions().hasIndirectSILResults()) {
    diagnose(getASTContext(), S->getBecomeLoc(), diag::become_indirect_result);
    emitReturnExpr(loc, E);
    return;
  }

  auto retTy = E->getType()->getCanonicalType();
  AbstractionPattern origRetTy = TypeContext
    ? TypeContext->OrigType.getFunctionResultType()
    : AbstractionPattern(retTy);

  // If the call result would need reabstraction to match the enclosing
  // function's result type, reabstraction code would run between the call and
  // the return, so we can't guarantee a tail call.
  if (getLoweredType(origRetTy, retTy) != getLoweredType(retTy)) {
    diagnose(getASTContext(), S->getBecomeLoc(), diag::become_needs_reabstraction);
    emitReturnExpr(loc, E);
    return;
  }

  CleanupLocation cleanupLoc(E);
  SmallVector<SILValue, 4> directResults;
  ApplyInst *tailApply = nullptr;
  {
    FullExpr scope(Cleanups, cleanupLoc);
    FormalEvaluationScope writeback(*this);

    // Remember where we are so we can find the call we're about to emit.
    SILBasicBlock *startBB = B.getInsertionBB();
    SILInstruction *marker =
        (startBB && !startBB->empty()) ? &startBB->back() : nullptr;

    RValue RV = emitRValue(E);
    std::move(RV)
        .ensurePlusOne(*this, cleanupLoc)
        .forwardAll(*this, directResults);

    // The tail call is the last apply emitted while lowering the expression.
    if (SILBasicBlock *bb = B.getInsertionBB()) {
      auto it = (bb == startBB && marker) ? std::next(marker->getIterator())
                                          : bb->begin();
      for (; it != bb->end(); ++it) {
        if (auto *ai = dyn_cast<ApplyInst>(&*it))
          tailApply = ai;
      }
    }
  } // expr scope closes here, emitting this expression's teardown

  // A throwing tail call ('become try f()') lowers to a 'try_apply' terminator:
  // after emitting it we are positioned in its normal successor, and the
  // try_apply is the terminator of that block's single predecessor. Handle that
  // shape here -- the apply-in-this-block search above found nothing.
  TryApplyInst *tailTryApply = nullptr;
  if (!tailApply) {
    if (SILBasicBlock *normalBB = B.getInsertionBB())
      if (SILBasicBlock *pred = normalBB->getSinglePredecessorBlock())
        if (auto *ta = dyn_cast<TryApplyInst>(pred->getTerminator()))
          if (ta->getNormalBB() == normalBB)
            tailTryApply = ta;
  }

  if (tailTryApply) {
    // A guaranteed *throwing* tail call ('become try f()'). The throwing call
    // lowered to a 'try_apply' terminator whose normal edge (the bb we're now
    // in) carries the result and whose error edge rethrows to our own error
    // dest. For this to be a genuine musttail we require both successor edges to
    // be clean tails: the normal edge just returns the call's result and the
    // error edge just rethrows the call's error, with nothing in between that
    // lowers to real machine code. IRGen then emits 'musttail call ...; ret ...'
    // and drops the error branch -- the thrown error propagates as our own via
    // the forwarded swifterror register (x21 on AArch64). The LLVM backend has
    // been taught to tail-call a musttail swiftcc call carrying a swifterror
    // argument.

    // Emit the return of the call's result into the (current) normal edge.
    // The normal-edge cleanups were already emitted when the expression scope
    // closed above; this just terminates the block.
    if (B.hasValidInsertionPoint()) {
      Cleanups.emitCleanupsForReturn(cleanupLoc, NotForUnwind);
      SILValue result;
      if (directResults.size() == 1) {
        result = directResults[0];
      } else {
        auto resultTy =
            F.getConventions().getSILResultType(getTypeExpansionContext());
        result = B.createTuple(loc, resultTy, directResults);
      }
      B.createReturn(loc, result);
    }

    SILBasicBlock *normalBB = tailTryApply->getNormalBB();
    SILBasicBlock *errorBB = tailTryApply->getErrorBB();

    // Instructions preceding the try_apply in its own block, used to decide
    // which trailing deallocs in the successors are dead across the call.
    llvm::SmallPtrSet<SILInstruction *, 16> beforeApply;
    for (auto &inst : *tailTryApply->getParent()) {
      if (&inst == tailTryApply)
        break;
      beforeApply.insert(&inst);
    }

    // The normal edge must return exactly the call's result (its BB argument),
    // and the error edge must re-throw exactly the call's error (its BB
    // argument), possibly through a chain of clean forwarding blocks.
    bool normalReturnsResult = false;
    if (auto *ret = dyn_cast<ReturnInst>(normalBB->getTerminator()))
      normalReturnsResult =
          normalBB->getNumArguments() == 1 &&
          ret->getOperand() == SILValue(normalBB->getArgument(0));
    else if (isa<UnreachableInst>(normalBB->getTerminator()))
      // '-> Never'-shaped normal edge (no result to forward): also acceptable.
      normalReturnsResult = normalBB->getNumArguments() <= 1;

    bool errorRethrows =
        errorBB->getNumArguments() == 1 &&
        becomeErrorEdgeRethrowsCleanly(
            errorBB, SILValue(errorBB->getArgument(0)), tailTryApply,
            beforeApply);

    bool cleanThrowingTail =
        normalReturnsResult && errorRethrows &&
        becomeSuccessorIsCleanTail(normalBB, tailTryApply, beforeApply);

    if (cleanThrowingTail) {
      tailTryApply->setMustTailCall();
      // See the non-throwing case: don't inline a function that makes a
      // guaranteed tail call, or the musttail apply could be copied out of tail
      // position, producing invalid LLVM IR.
      F.setInlineStrategy(NoInline);

      // Fix up stack nesting: the temporaries that were only needed to form the
      // call's operands have a 'dealloc_stack' on *both* successor edges. IRGen
      // drops both edges (it emits just 'musttail call; ret'), so keep a single
      // 'dealloc_stack' per distinct storage moved to before the try_apply and
      // erase the now-redundant copies on both edges. This keeps SIL stack
      // nesting balanced (one alloc_stack, one dealloc_stack, before the tail
      // call).
      llvm::SmallPtrSet<SILValue, 4> sunk;
      SmallVector<DeallocStackInst *, 8> deadDeallocs;
      for (SILBasicBlock *edge : {normalBB, errorBB})
        for (auto &inst : *edge)
          if (auto *ds = dyn_cast<DeallocStackInst>(&inst))
            if (becomeDeallocIsDeadAcrossCall(ds, beforeApply))
              deadDeallocs.push_back(ds);
      for (auto *ds : deadDeallocs) {
        if (sunk.insert(ds->getOperand()).second)
          // First dealloc of this storage: reuse it, moved before the call.
          ds->moveBefore(tailTryApply);
        else
          // Redundant sibling-edge dealloc of the same storage: drop it.
          ds->eraseFromParent();
      }
    } else {
      diagnose(getASTContext(), S->getBecomeLoc(),
               diag::become_cleanup_after_call);
    }
    return;
  }

  // Emit the rest of the return-path teardown (parameters, enclosing locals,
  // ...) right here, so everything a normal return would run is materialized
  // immediately after the call, where we can classify it.
  if (B.hasValidInsertionPoint())
    Cleanups.emitCleanupsForReturn(cleanupLoc, NotForUnwind);

  // Decide whether this is a genuine guaranteed tail call. It is iff, after
  // sinking stack deallocations that are dead once the call's operands have been
  // formed, every instruction between the apply and the return lowers to no
  // machine code (scope-enders, debug markers, empty aggregates). Anything that
  // emits real teardown after the call -- a destroy, release, store, or call --
  // means the frame is still live past the call, so it cannot be a musttail.
  // This mirrors what LLVM's musttail verifier requires at the IR level (the
  // call must be immediately followed by a return) while tolerating SIL markers
  // that vanish during lowering.
  bool cleanTail = false;
  // The call's result must be exactly what we return: either the single
  // forwarded direct result is the tail apply, or the function returns 'Void'
  // and the call forwards no results (its empty-tuple result is dropped).
  bool resultIsTailCall =
      tailApply &&
      ((directResults.size() == 1 && directResults[0] == SILValue(tailApply)) ||
       (directResults.empty() &&
        F.getLoweredFunctionType()->getNumResults() == 0));
  if (SILBasicBlock *bb = B.getInsertionBB();
      bb && resultIsTailCall && tailApply->getParent() == bb) {
    // Collect the instructions preceding the apply so we can tell which stack
    // allocations are dead by the time the call happens.
    llvm::SmallPtrSet<SILInstruction *, 16> beforeApply;
    for (auto &inst : *bb) {
      if (&inst == tailApply)
        break;
      beforeApply.insert(&inst);
    }

    // Sink a trailing 'dealloc_stack' to before the apply when the storage it
    // frees is not used at or after the call (its only remaining use is the
    // dealloc itself). This is the "the borrow is an illusion" case: a trivial
    // value has already been loaded out of the temporary before the call.
    SmallVector<DeallocStackInst *, 4> toSink;
    for (auto it = std::next(tailApply->getIterator()); it != bb->end(); ++it) {
      auto *ds = dyn_cast<DeallocStackInst>(&*it);
      if (!ds)
        continue;
      bool deadAcrossCall = true;
      for (auto *use : ds->getOperand()->getUses()) {
        SILInstruction *user = use->getUser();
        if (user != ds && !beforeApply.contains(user)) {
          deadAcrossCall = false;
          break;
        }
      }
      if (deadAcrossCall)
        toSink.push_back(ds);
    }
    for (auto *ds : toSink)
      ds->moveBefore(tailApply);

    // Now classify whatever remains after the apply.
    cleanTail = true;
    for (auto it = std::next(tailApply->getIterator()); it != bb->end(); ++it) {
      SILInstruction &inst = *it;
      // Scope-enders and debug markers lower to nothing between the call and the
      // return.
      if (isa<EndAccessInst>(inst) || isa<EndBorrowInst>(inst) ||
          isa<DebugValueInst>(inst))
        continue;
      // Pure, effect-free value instructions (e.g. an unused empty 'tuple ()')
      // also lower to nothing.
      if (!inst.mayHaveSideEffects() && !inst.mayReadFromMemory() &&
          !inst.mayWriteToMemory())
        continue;
      cleanTail = false;
      break;
    }
  }

  if (!tailApply) {
    diagnose(getASTContext(), S->getBecomeLoc(), diag::become_requires_call);
  } else if (!cleanTail) {
    diagnose(getASTContext(), S->getBecomeLoc(),
             diag::become_cleanup_after_call);
  }

  if (!B.hasValidInsertionPoint())
    return;

  // A guaranteed tail call is only valid while the apply stays in tail position
  // (immediately followed by a return of its result). Inlining this function
  // into a non-tail-position caller would copy the 'musttail' apply somewhere it
  // is no longer at the tail, producing invalid LLVM IR. Keep the guarantee (and
  // avoid the miscompile) by not inlining functions that make a guaranteed tail
  // call; the tail call itself is preserved.
  if (cleanTail) {
    tailApply->setMustTailCall();
    F.setInlineStrategy(NoInline);
  }

  // Emit the return. When the call is a genuine tail call this is adjacent to
  // it (modulo markers that lower to nothing); otherwise the diagnosed error has
  // already been produced and this just keeps the SIL well-formed.
  SILValue result;
  if (directResults.size() == 1) {
    result = directResults[0];
  } else {
    auto resultTy =
        F.getConventions().getSILResultType(getTypeExpansionContext());
    result = B.createTuple(loc, resultTy, directResults);
  }
  B.createReturn(loc, result);
}

void StmtEmitter::visitReturnStmt(ReturnStmt *S) {
  SILLocation Loc = S->isImplicit() ?
                      (SILLocation)ImplicitReturnLocation(S) :
                      (SILLocation)ReturnLocation(S);

  SILValue ArgV;
  if (!S->hasResult())
    // Void return.
    SGF.Cleanups.emitBranchAndCleanups(SGF.ReturnDest, Loc);
  else if (S->getResult()->getType()->isUninhabited())
    // Never return.
    SGF.emitIgnoredExpr(S->getResult());
  else
    SGF.emitReturnExpr(Loc, S->getResult());
}

void StmtEmitter::visitBecomeStmt(BecomeStmt *S) {
  SILLocation Loc = RegularLocation(S);
  SGF.emitBecomeStmt(Loc, S);
}

void StmtEmitter::visitThrowStmt(ThrowStmt *S) {
  if (SGF.getASTContext().LangOpts.ThrowsAsTraps) {
    SGF.B.createUnconditionalFail(S, "throw turned into a trap");
    SGF.B.createUnreachable(S);
    return;
  }

  ManagedValue exn;
  {
    FormalEvaluationScope scope(SGF);
    exn = SGF.emitRValueAsSingleValue(S->getSubExpr());
  }
  SGF.emitThrow(S, exn, /* emit a call to willThrow */ true);
}

void StmtEmitter::visitDiscardStmt(DiscardStmt *S) {
  // A 'discard' simply triggers the memberwise, consuming destruction of 'self'.
  ManagedValue selfValue = SGF.emitRValueAsSingleValue(S->getSubExpr());
  CleanupLocation loc(S);

  // \c fn could only be null if the type checker failed to call its 'set', or
  // we somehow got to SILGen when errors were emitted!
  auto *fn = S->getInnermostMethodContext();
  if (!fn)
    llvm_unreachable("internal compiler error with discard statement");

  auto *nominal = fn->getDeclContext()->getSelfNominalTypeDecl();
  assert(nominal);

  // Check if the nominal's contents are trivial. This is a temporary
  // restriction until we get discard implemented the way we want.
  for (auto *varDecl : nominal->getStoredProperties()) {
    assert(varDecl->hasStorage());
    auto varType = varDecl->getTypeInContext();
    auto &varTypeLowering = SGF.getTypeLowering(varType);
    if (!varTypeLowering.isTrivial()) {
      diagnose(getASTContext(),
               S->getStartLoc(),
               diag::discard_nontrivial_storage,
               nominal->getDeclaredInterfaceType());

      // emit a note pointing out the problematic storage type
      if (auto varLoc = varDecl->getLoc()) {
        diagnose(getASTContext(),
                 varLoc,
                 diag::discard_nontrivial_storage_note,
                 varType);
      } else {
        diagnose(getASTContext(),
                 nominal->getLoc(),
                 diag::discard_nontrivial_implicit_storage_note,
                 nominal->getDeclaredInterfaceType(),
                 varType);
      }

      break; // only one diagnostic is needed per discard
    }
  }

  SGF.emitMoveOnlyMemberDestruction(selfValue.forward(SGF), nominal, loc);
}

void StmtEmitter::visitYieldStmt(YieldStmt *S) {
  SmallVector<ArgumentSource, 4> sources;
  SmallVector<AbstractionPattern, 4> origTypes;
  for (auto yield : S->getYields()) {
    sources.emplace_back(yield);
    origTypes.emplace_back(yield->getType());
  }

  FullExpr fullExpr(SGF.Cleanups, CleanupLocation(S));

  SGF.emitYield(S, sources, origTypes, SGF.CoroutineUnwindDest);
}

void StmtEmitter::visitThenStmt(ThenStmt *S) {
  auto *E = S->getResult();

  // Retrieve the initialization for the parent SingleValueStmtExpr. If we don't
  // have an init, we don't care about the result, emit an ignored expr. This is
  // the case if e.g the result is being converted to Void.
  if (auto init = SGF.getSingleValueStmtInit(E)) {
    SGF.emitExprInto(E, init.get());
  } else {
    SGF.emitIgnoredExpr(E);
  }
}

void StmtEmitter::visitPoundAssertStmt(PoundAssertStmt *stmt) {
  SILValue condition;
  {
    FullExpr scope(SGF.Cleanups, CleanupLocation(stmt));
    condition =
        SGF.emitRValueAsSingleValue(stmt->getCondition()).getUnmanagedValue();
  }

  // Extract the i1 from the Bool struct.
  auto i1Value = SGF.emitUnwrapIntegerResult(stmt, condition);

  SILValue message = SGF.B.createStringLiteral(
      stmt, stmt->getMessage(), StringLiteralInst::Encoding::UTF8);

  auto resultType = SGF.getASTContext().TheEmptyTupleType;
  SGF.B.createBuiltin(
      stmt, SGF.getASTContext().getIdentifier("poundAssert"),
      SGF.getLoweredType(resultType), {}, {i1Value, message});
}

/// Should we use "inline defer", which avoids emitting a separate
/// defer function and instead just emits the body inline as a cleanup?
///
/// This is arguably a superior emission approach in general for small
/// defer bodies, and even for large defer bodies if we found a way to
/// avoid duplicating the code. But for now, limit to cases where we
/// truly need it, like when there's a use/def relationship that we
/// need to build in SIL. Those should all involve builtin calls.
static bool shouldUseInlineDefer(FuncDecl *deferDecl) {
  auto body = deferDecl->getBody();
  assert(body);

  // Require the body to have the exact form:
  //   defer { Builtin.foo(...) }
  // (possibly with try/unsafe/await markers)

  auto expr = body->getSingleActiveExpression();
  if (!expr) return false;
  expr = expr->getSemanticsProvidingExpr();
  auto call = dyn_cast<CallExpr>(expr);
  if (!call) return false;
  auto memberRef = dyn_cast<DotSyntaxBaseIgnoredExpr>(call->getFn());
  if (!memberRef) return false;
  auto fnRef = dyn_cast<DeclRefExpr>(memberRef->getRHS());
  if (!fnRef) return false;
  auto builtinFn = dyn_cast<FuncDecl>(fnRef->getDecl());
  if (!builtinFn) return false;
  if (!builtinFn->getModuleContext()->isBuiltinModule()) return false;

  // We could limit this to specific builtins at this point, but that
  // seems unnecessary.
  return true;
}

namespace {
  // This is a little cleanup that ensures that there are no jumps out of a
  // defer body.  The cleanup is only active and installed when emitting the
  // body of a defer, and it is disabled at the end.  If it ever needs to be
  // emitted, it crashes the compiler because Sema missed something.
  class DeferEscapeCheckerCleanup : public Cleanup {
    SourceLoc deferLoc;
  public:
    DeferEscapeCheckerCleanup(SourceLoc deferLoc) : deferLoc(deferLoc) {}
    void emit(SILGenFunction &SGF, CleanupLocation l, ForUnwind_t forUnwind) override {
      assert(false && "Sema didn't catch exit out of a defer?");
    }
    void dump(SILGenFunction &) const override {
#ifndef NDEBUG
      llvm::errs() << "DeferEscapeCheckerCleanup\n"
                   << "State: " << getState() << "\n";
#endif
    }
  };

  class InlineDeferCleanup : public Cleanup {
    SourceLoc deferLoc;
    FuncDecl *deferDecl;
  public:
    InlineDeferCleanup(SourceLoc deferLoc, FuncDecl *deferDecl)
      : deferLoc(deferLoc), deferDecl(deferDecl) {}
    void emit(SILGenFunction &SGF, CleanupLocation l, ForUnwind_t forUnwind) override {
      SGF.Cleanups.pushCleanup<DeferEscapeCheckerCleanup>(deferLoc);
      auto TheCleanup = SGF.Cleanups.getTopCleanup();

      auto body = deferDecl->getBody()->getSingleActiveExpression();
      SGF.emitIgnoredExpr(body);
      
      if (SGF.B.hasValidInsertionPoint())
        SGF.Cleanups.setCleanupState(TheCleanup, CleanupState::Dead);
    }
    void dump(SILGenFunction &) const override {
#ifndef NDEBUG
      llvm::errs() << "InlineDeferCleanup\n"
                   << "State: " << getState() << "\n";
#endif
    }
  };

  class DeferCleanup : public Cleanup {
    SourceLoc deferLoc;
    Expr *call;
  public:
    DeferCleanup(SourceLoc deferLoc, Expr *call)
      : deferLoc(deferLoc), call(call) {}
    void emit(SILGenFunction &SGF, CleanupLocation l, ForUnwind_t forUnwind) override {
      SGF.Cleanups.pushCleanup<DeferEscapeCheckerCleanup>(deferLoc);
      auto TheCleanup = SGF.Cleanups.getTopCleanup();

      SGF.emitIgnoredExpr(call);
      
      if (SGF.B.hasValidInsertionPoint())
        SGF.Cleanups.setCleanupState(TheCleanup, CleanupState::Dead);
    }
    void dump(SILGenFunction &) const override {
#ifndef NDEBUG
      llvm::errs() << "DeferCleanup\n"
                   << "State: " << getState() << "\n";
#endif
    }
  };
} // end anonymous namespace

void StmtEmitter::visitDeferStmt(DeferStmt *S) {
  FuncDecl *deferDecl = S->getTempDecl();

  // Check if the defer should use the inline defer mechanism.
  if (shouldUseInlineDefer(deferDecl)) {
    SGF.Cleanups.pushCleanup<InlineDeferCleanup>(S->getDeferLoc(), deferDecl);
    return;
  }

  // Emit the closure for the defer, along with its binding.
  // If the defer is at the top-level code, insert 'mark_escape_inst'
  // to the top-level code to check initialization of any captured globals.  
  auto *Ctx = deferDecl->getDeclContext();
  if (isa<TopLevelCodeDecl>(Ctx) && SGF.isEmittingTopLevelCode()) {
      auto Captures = deferDecl->getCaptureInfo();
      SGF.emitMarkFunctionEscapeForTopLevelCodeGlobals(S, std::move(Captures));
  }
  SGF.visitFuncDecl(deferDecl);

  // Register a cleanup to invoke the closure on any exit paths.
  SGF.Cleanups.pushCleanup<DeferCleanup>(S->getDeferLoc(), S->getCallExpr());
}

void StmtEmitter::visitIfStmt(IfStmt *S) {
  Scope condBufferScope(SGF.Cleanups, S);
  
  // Create a continuation block.
  JumpDest contDest = createJumpDest(S->getThenStmt());
  auto contBB = contDest.getBlock();

  // Set the destinations for any 'break' and 'continue' statements inside the
  // body.  Note that "continue" is not valid out of a labeled 'if'.
  SGF.BreakContinueDestStack.push_back(
                               { S, contDest, JumpDest(CleanupLocation(S)) });

  // Set up the block for the false case.  If there is an 'else' block, we make
  // a new one, otherwise it is our continue block.
  JumpDest falseDest = contDest;
  if (S->getElseStmt())
    falseDest = createJumpDest(S);

  // Emit the condition, along with the "then" part of the if properly guarded
  // by the condition and a jump to ContBB.  If the condition fails, jump to
  // the CondFalseBB.
  {
    // Enter a scope for any bound pattern variables.
    LexicalScope trueScope(SGF, S);

    auto NumTrueTaken = SGF.loadProfilerCount(S->getThenStmt());
    auto NumFalseTaken = ProfileCounter();
    if (auto *Else = S->getElseStmt())
      NumFalseTaken = SGF.loadProfilerCount(Else);

    SGF.emitStmtCondition(S->getCond(), falseDest, S, NumTrueTaken,
                          NumFalseTaken);

    // In the success path, emit the 'then' part if the if.
    SGF.emitProfilerIncrement(S->getThenStmt());
    SGF.emitStmt(S->getThenStmt());
  
    // Finish the "true part" by cleaning up any temporaries and jumping to the
    // continuation block.
    if (SGF.B.hasValidInsertionPoint()) {
      RegularLocation L(S->getThenStmt());
      L.pointToEnd();
      SGF.Cleanups.emitBranchAndCleanups(contDest, L);
    }
  }
  
  // If there is 'else' logic, then emit it.
  if (S->getElseStmt()) {
    SGF.B.emitBlock(falseDest.getBlock());
    visit(S->getElseStmt());
    if (SGF.B.hasValidInsertionPoint()) {
      RegularLocation L(S->getElseStmt());
      L.pointToEnd();
      SGF.B.createBranch(L, contBB);
    }
  }

  // If the continuation block was used, emit it now, otherwise remove it.
  if (contBB->pred_empty()) {
    SGF.eraseBasicBlock(contBB);
  } else {
    RegularLocation L(S->getThenStmt());
    L.pointToEnd();
    SGF.B.emitBlock(contBB, L);
  }
  SGF.BreakContinueDestStack.pop_back();
}

void StmtEmitter::visitGuardStmt(GuardStmt *S) {
  // Create a block for the body and emit code into it before processing any of
  // the patterns, because none of the bound variables will be in scope in the
  // 'body' context.
  JumpDest bodyBB =
    JumpDest(createBasicBlock(), SGF.getCleanupsDepth(), CleanupLocation(S));

  {
    // Move the insertion point to the 'body' block temporarily and emit it.
    // Note that we don't push break/continue locations since they aren't valid
    // in this statement.
    SILGenSavedInsertionPoint savedIP(SGF, bodyBB.getBlock());
    SGF.emitProfilerIncrement(S->getBody());
    SGF.emitStmt(S->getBody());

    // The body block must end in a noreturn call, return, break etc.  It
    // isn't valid to fall off into the normal flow.  To model this, we emit
    // an unreachable instruction and then have SIL diagnostic check this.
    if (SGF.B.hasValidInsertionPoint())
      SGF.B.createUnreachable(S);
  }

  // Emit the condition bindings, branching to the bodyBB if they fail.
  auto NumFalseTaken = SGF.loadProfilerCount(S->getBody());
  auto NumNonTaken = SGF.loadProfilerCount(S);
  SGF.emitStmtCondition(S->getCond(), bodyBB, S, NumNonTaken, NumFalseTaken);
}

void StmtEmitter::visitWhileStmt(WhileStmt *S) {
  LexicalScope condBufferScope(SGF, S);

  // Create a new basic block and jump into it.
  JumpDest loopDest = createJumpDest(S->getBody());
  SGF.B.emitBlock(loopDest.getBlock(), S);
  
  // Create a break target (at this level in the cleanup stack) in case it is
  // needed.
  JumpDest breakDest = createJumpDest(S->getBody());

  // Set the destinations for any 'break' and 'continue' statements inside the
  // body.
  SGF.BreakContinueDestStack.push_back({S, breakDest, loopDest});
  
  // Evaluate the condition, the body, and a branch back to LoopBB when the
  // condition is true.  On failure, jump to BreakBB.
  {
    // Enter a scope for any bound pattern variables.
    Scope conditionScope(SGF.Cleanups, S);
    // This scope was added to properly handle local borrow bindings.
    FormalEvaluationScope WhileBodyEvaluationScope(SGF);

    auto NumTrueTaken = SGF.loadProfilerCount(S->getBody());
    auto NumFalseTaken = SGF.loadProfilerCount(S);
    SGF.emitStmtCondition(S->getCond(), breakDest, S, NumTrueTaken, NumFalseTaken);
    
    // In the success path, emit the body of the while.
    if (!S->getParentForEach())
      SGF.emitProfilerIncrement(S->getBody());
    SGF.emitStmt(S->getBody());
    
    // Finish the "true part" by cleaning up any temporaries and jumping to the
    // continuation block.
    if (SGF.B.hasValidInsertionPoint()) {
      RegularLocation L(S->getBody());
      L.pointToEnd();
      SGF.Cleanups.emitBranchAndCleanups(loopDest, L);
    }
  }

  SGF.BreakContinueDestStack.pop_back();

  // Handle break block.  If it was used, we link it up with the cleanup chain,
  // otherwise we just remove it.
  SILBasicBlock *breakBB = breakDest.getBlock();
  if (breakBB->pred_empty()) {
    SGF.eraseBasicBlock(breakBB);
  } else {
    SGF.B.emitBlock(breakBB);
  }
}

void StmtEmitter::visitDoStmt(DoStmt *S) {
  // We don't need to do anything fancy if we don't have a label.
  // Otherwise, assume we might break or continue.
  bool hasLabel = (bool) S->getLabelInfo();

  JumpDest endDest = JumpDest::invalid();
  if (hasLabel) {
    // Create the end dest first so that the loop dest comes in-between.
    endDest = createJumpDest(S->getBody());

    // Create a new basic block and jump into it.
    JumpDest loopDest = createJumpDest(S->getBody());
    SGF.B.emitBlock(loopDest.getBlock(), S);

    // Set the destinations for 'break' and 'continue'.
    SGF.BreakContinueDestStack.push_back({S, endDest, loopDest});
  }

  // Emit the body.
  visit(S->getBody());

  if (hasLabel) {
    SGF.BreakContinueDestStack.pop_back();
    emitOrDeleteBlock(SGF, endDest, CleanupLocation(S));
  }
}

void StmtEmitter::visitDoCatchStmt(DoCatchStmt *S) {
  Type formalExnType = S->getCaughtErrorType();
  auto &exnTL = SGF.getTypeLowering(formalExnType);

  SILValue exnArg;
  bool errorIsIndirect = exnTL.isAddress();
  
  if (errorIsIndirect) {
    exnArg = SGF.B.createAllocStack(
        S, exnTL.getLoweredType());
    SGF.enterDeallocStackCleanup(exnArg);
  }

  // Create the throw destination at the end of the function.
  JumpDest throwDest = createThrowDest(S->getBody(),
                                       ThrownErrorInfo(exnArg));

  if (!errorIsIndirect) {
    exnArg = throwDest.getBlock()->createPhiArgument(
        exnTL.getLoweredType(), OwnershipKind::Owned);
  }

  // We always need a continuation block because we might fall out of
  // a catch block.  But we don't need a loop block unless the 'do'
  // statement is labeled.
  JumpDest endDest = createJumpDest(S->getBody());

  // We don't need to do anything too fancy about emission if we don't
  // have a label.  Otherwise, assume we might break or continue.
  bool hasLabel = (bool) S->getLabelInfo();
  if (hasLabel) {
    // Create a new basic block and jump into it.
    JumpDest loopDest = createJumpDest(S->getBody());
    SGF.B.emitBlock(loopDest.getBlock(), S);

    // Set the destinations for 'break' and 'continue'.
    SGF.BreakContinueDestStack.push_back({S, endDest, loopDest});
  }

  // Emit the body.
  {
    // Push the new throw destination.
    llvm::SaveAndRestore<JumpDest> savedThrowDest(SGF.ThrowDest, throwDest);

    visit(S->getBody());
  }

  // Emit the catch clauses, but only if the body of the function
  // actually throws. This is a consequence of the fact that a
  // DoCatchStmt with a non-throwing body will type check even in
  // a non-throwing lexical context. In this case, our local throwDest
  // has no predecessors, and SGF.ThrowDest may not be valid either.
  if (auto *BB = getOrEraseBlock(SGF, throwDest)) {
    // Move the insertion point to the throw destination.
    SILGenSavedInsertionPoint savedIP(SGF, BB, FunctionSection::Postmatter);

    // The exception cleanup should be getting forwarded around
    // correctly anyway, but push a scope to ensure it gets popped.
    Scope exnScope(SGF.Cleanups, CleanupLocation(S));

    // Take ownership of the exception.
    ManagedValue exn = SGF.emitManagedRValueWithCleanup(exnArg, exnTL);

    // Emit all the catch clauses, branching to the end destination if
    // we fall out of one.
    SGF.emitCatchDispatch(S, exn, S->getCatches(), endDest);

    // We assume that exn's cleanup is still valid at this point. To ensure that
    // we do not re-emit it and do a double consume, we rely on us having
    // finished emitting code and thus unsetting the insertion point here. This
    // assert is to make sure this invariant is clear in the code and validated.
    assert(!SGF.B.hasValidInsertionPoint());
  }

  if (hasLabel) {
    SGF.BreakContinueDestStack.pop_back();
  }

  // Handle falling out of the do-block.
  //
  // It's important for good code layout that the insertion point be
  // left in the original function section after this.  So if
  // emitOrDeleteBlock ever learns to just continue in the
  // predecessor, we'll need to suppress that here.
  emitOrDeleteBlock(SGF, endDest, CleanupLocation(S->getBody()));
}

void StmtEmitter::visitRepeatWhileStmt(RepeatWhileStmt *S) {
  // Create a new basic block and jump into it.
  SILBasicBlock *loopBB = createBasicBlock();
  SGF.B.emitBlock(loopBB, S);
  
  // Set the destinations for 'break' and 'continue'
  JumpDest endDest = createJumpDest(S->getBody());
  JumpDest condDest = createJumpDest(S->getBody());
  SGF.BreakContinueDestStack.push_back({ S, endDest, condDest });

  // Emit the body, which is always evaluated the first time around.
  SGF.emitProfilerIncrement(S->getBody());
  visit(S->getBody());

  // Let's not differ from C99 6.8.5.2: "The evaluation of the controlling
  // expression takes place after each execution of the loop body."
  emitOrDeleteBlock(SGF, condDest, S);

  if (SGF.B.hasValidInsertionPoint()) {
    // Evaluate the condition with the false edge leading directly
    // to the continuation block.
    auto NumTrueTaken = SGF.loadProfilerCount(S->getBody());
    auto NumFalseTaken = SGF.loadProfilerCount(S);
    Condition Cond = SGF.emitCondition(S->getCond(),
                                       /*invertValue*/ false, /*contArgs*/ {},
                                       NumTrueTaken, NumFalseTaken);

    Cond.enterTrue(SGF);
    if (SGF.B.hasValidInsertionPoint()) {
      SGF.B.createBranch(S->getCond(), loopBB);
    }
    
    Cond.exitTrue(SGF);
    // Complete the conditional execution.
    Cond.complete(SGF);
  }
  
  emitOrDeleteBlock(SGF, endDest, S);
  SGF.BreakContinueDestStack.pop_back();
}

void StmtEmitter::visitOpaqueStmt(OpaqueStmt *S) {
  auto *stmt = SGF.OpaqueStmts[S];
  ASSERT(stmt);

  auto *P = SGF.F.getProfiler();
  auto ref = ProfileCounterRef::node(stmt);
  if (P && P->hasCounterFor(ref))
    SGF.emitProfilerIncrement(ref);

  visit(SGF.OpaqueStmts[S]);
}

void StmtEmitter::visitForEachStmt(ForEachStmt *S) {

  if (auto *expansion = dyn_cast<PackExpansionExpr>(S->getSequence())) {
    auto formalPackType = dyn_cast<PackType>(
        PackType::get(SGF.getASTContext(), expansion->getType())
            ->getCanonicalType());

    std::optional<JumpDest> continueDest;
    std::optional<JumpDest> breakDest;

    SGF.emitDynamicPackLoop(
        SILLocation(expansion), formalPackType, 0,
        expansion->getGenericEnvironment(),
        [&]() -> SILBasicBlock * {
          breakDest = createJumpDest(S->getBody());
          continueDest = createJumpDest(S->getBody());
          return continueDest->getBlock();
        },
        [&](SILValue indexWithinComponent, SILValue packExpansionIndex,
            SILValue packIndex) {
          Scope innerForScope(SGF.Cleanups, CleanupLocation(S->getBody()));
          auto letValueInit =
              SGF.emitPatternBindingInitialization(S->getPattern(), *continueDest);

          SGF.emitExprInto(expansion->getPatternExpr(), letValueInit.get());

          // Set the destinations for 'break' and 'continue'.
          SGF.BreakContinueDestStack.push_back({S, *breakDest, *continueDest});
          visit(S->getBody());
          SGF.BreakContinueDestStack.pop_back();
        });

    emitOrDeleteBlock(SGF, *breakDest, S);

    return;
  }

  auto *opaqueSequence = S->getOpaqueSequenceExpr();
  ASSERT(opaqueSequence);
  SGF.OpaqueExprs[opaqueSequence] = S->getSequence();
  SWIFT_DEFER { SGF.OpaqueExprs.erase(opaqueSequence); };

  auto *opaqueWhere = S->getOpaqueWhereExpr();
  if (opaqueWhere) {
    ASSERT(S->getWhere());
    SGF.OpaqueExprs[opaqueWhere] = S->getWhere();
  }
  SWIFT_DEFER {
    if (opaqueWhere)
      SGF.OpaqueExprs.erase(opaqueWhere);
  };

  auto *opaqueBodyStmt = S->getOpaqueBodyStmt();
  ASSERT(opaqueBodyStmt);
  SGF.OpaqueStmts[opaqueBodyStmt] = S->getBody();
  SWIFT_DEFER { SGF.OpaqueStmts.erase(opaqueBodyStmt); };

  auto *braceStmt = S->getDesugaredStmt();
  ASSERT(braceStmt || SGF.getASTContext().hadError());
  if (braceStmt)
    visitBraceStmt(braceStmt);
}

void StmtEmitter::visitBreakStmt(BreakStmt *S) {
  assert(S->getTarget() && "Sema didn't fill in break target?");
  SGF.emitBreakOutOf(S, S->getTarget());
}

void SILGenFunction::emitBreakOutOf(SILLocation loc, Stmt *target) {
  // Find the target JumpDest based on the target that sema filled into the
  // stmt.
  if (auto *forEachStmt = dyn_cast<ForEachStmt>(target))
    if (auto *breakTarget = forEachStmt->getBreakTarget())
      target = breakTarget;
  for (auto &elt : BreakContinueDestStack) {
    if (target == elt.Target) {
      Cleanups.emitBranchAndCleanups(elt.BreakDest, loc);
      return;
    }
  }
  llvm_unreachable("Break has available target block.");
}

void StmtEmitter::visitContinueStmt(ContinueStmt *S) {
  assert(S->getTarget() && "Sema didn't fill in continue target?");

  auto *target = S->getTarget();
  if (auto *forEachStmt = dyn_cast<ForEachStmt>(target))
    if (auto *continueTarget = forEachStmt->getContinueTarget())
      target = continueTarget;

  // Find the target JumpDest based on the target that sema filled into the
  // stmt.
  for (auto &elt : SGF.BreakContinueDestStack) {
    if (target == elt.Target) {
      SGF.Cleanups.emitBranchAndCleanups(elt.ContinueDest, S);
      return;
    }
  }
  llvm_unreachable("Continue has available target block.");
}

void StmtEmitter::visitSwitchStmt(SwitchStmt *S) {
  // Implemented in SILGenPattern.cpp.
  SGF.emitSwitchStmt(S);
}

void StmtEmitter::visitCaseStmt(CaseStmt *S) {
  llvm_unreachable("cases should be lowered as part of switch stmt");
}

void StmtEmitter::visitFallthroughStmt(FallthroughStmt *S) {
  // Implemented in SILGenPattern.cpp.
  SGF.emitSwitchFallthrough(S);
}

void StmtEmitter::visitFailStmt(FailStmt *S) {
  // Jump to the failure block.
  assert(SGF.FailDest.isValid() && "too big to fail");
  SGF.Cleanups.emitBranchAndCleanups(SGF.FailDest, S);
}

/// Return a basic block suitable to be the destination block of a
/// try_apply instruction.  The block is implicitly emitted and filled in.
///
/// \param errorAddrOrType Either the address of the indirect error result where
/// the result will be stored, or the type of the expected Owned error value.
///
/// \param suppressErrorPath Should the error path be emitted as unreachable?
SILBasicBlock *
SILGenFunction::getTryApplyErrorDest(SILLocation loc,
                                     CanSILFunctionType fnTy,
                                     ExecutorBreadcrumb prevExecutor,
                                     TaggedUnion<SILValue, SILType> errorAddrOrType,
                                     bool suppressErrorPath) {
  // For now, don't try to re-use destination blocks for multiple
  // failure sites.
  SILBasicBlock *destBB = createBasicBlock(FunctionSection::Postmatter);

  SILValue errorValue;
  if (auto ownedErrorTy = errorAddrOrType.dyn_cast<SILType>()) {
    errorValue = destBB->createPhiArgument(*ownedErrorTy,
                                               OwnershipKind::Owned);
  } else {
    auto errorAddr = errorAddrOrType.get<SILValue>();
    assert(errorAddr->getType().isAddress());
    errorValue = errorAddr;
  }

  assert(B.hasValidInsertionPoint() && B.insertingAtEndOfBlock());
  SILGenSavedInsertionPoint savedIP(*this, destBB, FunctionSection::Postmatter);

  prevExecutor.emit(*this, loc);

  // If we're suppressing error paths, just wrap it up as unreachable
  // and return.
  if (suppressErrorPath) {
    B.createUnreachable(loc);
    return destBB;
  }

  // We don't want to exit here with a dead cleanup on the stack,
  // so push the scope first.
  FullExpr scope(Cleanups, CleanupLocation(loc));
  emitThrow(loc, emitManagedRValueWithCleanup(errorValue));

  return destBB;
}

void SILGenFunction::emitThrow(SILLocation loc, ManagedValue exnMV,
                               bool emitWillThrow) {
  assert(ThrowDest.isValid() &&
         "calling emitThrow with invalid throw destination!");

  if (getASTContext().LangOpts.ThrowsAsTraps) {
    B.createUnconditionalFail(loc, "throw turned into a trap");
    B.createUnreachable(loc);
    return;
  }

  if (auto *E = loc.getAsASTNode<Expr>()) {
    // Check to see whether we have a counter associated with the error branch
    // of this node, and if so emit a counter increment.
    auto *P = F.getProfiler();
    auto ref = ProfileCounterRef::errorBranchOf(E);
    if (P && P->hasCounterFor(ref))
      emitProfilerIncrement(ref);
  }

  SmallVector<SILValue, 1> args;

  auto indirectErrorAddr = ThrowDest.getThrownError().IndirectErrorResult;

  // If exnMV was not provided by the caller, we must have an indirect
  // error result that already stores the thrown error.
  assert(!exnMV.isInContext() || indirectErrorAddr);

  SILValue exn;
  if (!exnMV.isInContext()) {
    // Whether the thrown exception is already an Error existential box.
    SILType existentialBoxType = SILType::getExceptionType(getASTContext());
    bool isExistentialBox = exnMV.getType() == existentialBoxType;

    // If we are supposed to emit a call to swift_willThrow(Typed), do so now.
    if (emitWillThrow) {
      ASTContext &ctx = SGM.getASTContext();
      if (isExistentialBox) {
        // Generate a call to the 'swift_willThrow' runtime function to allow the
        // debugger to catch the throw event.

        // Claim the exception value.
        exn = exnMV.forward(*this);

        B.createBuiltin(loc,
                        ctx.getIdentifier("willThrow"),
                        SGM.Types.getEmptyTupleType(), {}, {exn});
      } else {
        // Call the _willThrowTyped entrypoint, which handles
        // arbitrary error types.
        FuncDecl *entrypoint = ctx.getWillThrowTyped();
        auto genericSig = entrypoint->getGenericSignature();
        SubstitutionMap subMap = SubstitutionMap::get(
            genericSig, [&](SubstitutableType *dependentType) {
              return exnMV.getType().getASTType();
            }, LookUpConformanceInModule());

        // Generic errors are passed indirectly.
        if (!exnMV.getType().isAddress() && useLoweredAddresses()) {
          // Materialize the error so we can pass the address down to the
          // swift_willThrowTyped.
          exnMV = exnMV.materialize(*this, loc);
        }

        emitApplyOfLibraryIntrinsic(
            loc, entrypoint, subMap,
            { exnMV },
            SGFContext());

        // Claim the exception value.
        exn = exnMV.forward(*this);
      }
    } else {
      // Claim the exception value.
      exn = exnMV.forward(*this);
    }
  }

  bool shouldDiscard = ThrowDest.getThrownError().Discard;
  SILType exnType = exn->getType().getObjectType();
  SILBasicBlock &throwBB = *ThrowDest.getBlock();
  SILType destErrorType =  indirectErrorAddr
      ? indirectErrorAddr->getType().getObjectType()
      : !throwBB.getArguments().empty() 
        ? throwBB.getArguments()[0]->getType().getObjectType()
        : exnType;

  // If the thrown error type differs from what the throw destination expects,
  // perform the conversion. The shape of the conversion depends on the
  // destination type: existential erasure for `any P` (including `any Error`),
  // a class upcast when the destination is a superclass of the in-flight
  // error.
  if (exnType != destErrorType) {
    CanType destASTType = destErrorType.getASTType();
    auto &exnTL = getTypeLowering(exnType);

    if (destASTType->isExistentialType()) {
      // Erase to the destination existential. The conformances we look up
      // are dictated by the existential's layout, not always `Error`: for
      // `do throws(any P) { ... }` where `P` refines `Error`, the layout
      // contains `P`, and the inner thrown value must be convertible to
      // `any P`.
      //
      // FIXME: Parameterized protocols (`any P<X>`) and class-bound
      // composition existentials (`any (BaseClass & P)`) are not handled
      // here — the former drops the parameter constraint and the latter
      // skips the implicit superclass upcast that would be needed before
      // the erasure. Sema does not currently surface either shape as a
      // typed-throws destination, but if it ever does this code will need
      // to look at `getParameterizedProtocols()` and `explicitSuperclass`.
      auto layout = destASTType->getExistentialLayout();
      SmallVector<ProtocolConformanceRef, 4> conformances;
      conformances.reserve(layout.getProtocols().size());
      for (auto *proto : layout.getProtocols()) {
        conformances.push_back(
            checkConformance(exn->getType().getASTType(), proto));
      }

      // The lambda passed to `emitExistentialErasure` is invoked once,
      // before the outer `exn` is reassigned with the erasure result.
      exn = emitExistentialErasure(
          loc,
          exnType.getASTType(),
          exnTL,
          getTypeLowering(destErrorType),
          getASTContext().AllocateCopy(llvm::ArrayRef<ProtocolConformanceRef>(
              conformances)),
          SGFContext(),
          [&](SGFContext C) -> ManagedValue {
            if (exn->getType().isAddress()) {
              return emitLoad(loc, exn, exnTL, SGFContext(), IsTake);
            }

            return ManagedValue::forForwardedRValue(*this, exn);
          }).forward(*this);
    } else if (destASTType->getClassOrBoundGenericClass()) {
      // Class upcast: the in-flight error is a reference to a subclass of
      // the destination. SIL's `upcast` instruction additionally verifies
      // the subclass relationship in asserts builds; release builds rely
      // on Sema having rejected unrelated classes upstream.
      if (exn->getType().isAddress()) {
        exn = emitLoad(loc, exn, exnTL, SGFContext(), IsTake).forward(*this);
      }
      exn = B.createUpcast(loc, exn, destErrorType);
    } else {
      // We don't have a SILGen lowering for this conversion shape today.
      // Diagnose and substitute an undef of the destination type so the
      // rest of the function can lower; the diagnostic ensures the
      // compilation as a whole fails.
      SGM.diagnose(loc, diag::not_implemented,
                   "throw conversion from '" +
                       exnType.getASTType()->getString() + "' to '" +
                       destASTType->getString() + "'");
      exn = SILUndef::get(F, destErrorType);
    }
  }
  assert(exn->getType().getObjectType() == destErrorType);

  if (indirectErrorAddr) {
    if (exn->getType().isAddress()) {
      B.createCopyAddr(loc, exn, indirectErrorAddr,
                       IsTake, IsInitialization);
    }
    
    // If the error is represented as a value, then we should forward it into
    // the indirect error return slot. We have to wait to do that until after
    // we pop cleanups, though, since the value may have a borrow active in
    // scope that won't be released until the cleanups pop.
  } else if (!throwBB.getArguments().empty()) {
    // Load if we need to.
    if (exn->getType().isAddress()) {
      exn = emitLoad(loc, exn, getTypeLowering(exnType), SGFContext(), IsTake)
         .forward(*this);
    }

    // A direct error value is passed to the epilog block as a BB argument.
    args.push_back(exn);
  } else if (shouldDiscard) {
    if (exn->getType().isAddress())
      B.emitDestroyAddrAndFold(loc, exn);
    else
      B.emitDestroyValueOperation(loc, exn);
  }

  // Emit clean-ups needed prior to entering throw block.
  Cleanups.emitCleanupsBeforeBranch(ThrowDest, IsForUnwind);
  
  if (indirectErrorAddr && !exn->getType().isAddress()) {
    // Forward the error value into the return slot now. This has to happen
    // after emitting cleanups because the active scope may be borrowing the
    // error value, and we can't forward ownership until those borrows are
    // released.
    emitSemanticStore(loc, exn, indirectErrorAddr,
                      getTypeLowering(destErrorType), IsInitialization);
  }
  
  getBuilder().createBranch(loc, ThrowDest.getBlock(), args);
}
