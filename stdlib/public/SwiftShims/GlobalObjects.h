//===--- GlobalObjects.h - Statically-initialized objects -------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  Objects that are allocated at global scope instead of on the heap,
//  and statically initialized to avoid synchronization costs, are
//  defined here.
//
//===----------------------------------------------------------------------===//
#ifndef SWIFT_STDLIB_SHIMS_GLOBALOBJECTS_H_
#define SWIFT_STDLIB_SHIMS_GLOBALOBJECTS_H_

#include "SwiftStdint.h"
#include "HeapObject.h"
#include "Visibility.h"

#ifdef __cplusplus
namespace swift { extern "C" {
#endif

struct _SwiftArrayBodyStorage {
  __swift_intptr_t count;
  __swift_uintptr_t _capacityAndFlags;
};

struct _SwiftEmptyArrayStorage {
  struct HeapObject header;
  struct _SwiftArrayBodyStorage body;
};

extern SWIFT_RUNTIME_STDLIB_INTERFACE
struct _SwiftEmptyArrayStorage _swiftEmptyArrayStorage;

struct _SwiftUnsafeBitMap {
  __swift_uintptr_t *values;
  __swift_intptr_t bitCount;
};

struct _SwiftDictionaryBodyStorage {
  __swift_intptr_t capacity;
  __swift_intptr_t count;
  struct _SwiftUnsafeBitMap initializedEntries;
  void *keys;
  void *values;
};

struct _SwiftSetBodyStorage {
  __swift_intptr_t capacity;
  __swift_intptr_t count;
  struct _SwiftUnsafeBitMap initializedEntries;
  void *keys;
};

struct _SwiftEmptyDictionaryStorage {
  struct HeapObject header;
  struct _SwiftDictionaryBodyStorage body;
  __swift_uintptr_t entries;
};

struct _SwiftEmptySetStorage {
  struct HeapObject header;
  struct _SwiftSetBodyStorage body;
  __swift_uintptr_t entries;
};

extern SWIFT_RUNTIME_STDLIB_INTERFACE
struct _SwiftEmptyDictionaryStorage _swiftEmptyDictionaryStorage;

extern SWIFT_RUNTIME_STDLIB_INTERFACE
struct _SwiftEmptySetStorage _swiftEmptySetStorage;

struct _SwiftHashingSecretKey {
  __swift_uint64_t key0;
  __swift_uint64_t key1;
};

extern SWIFT_RUNTIME_STDLIB_INTERFACE
struct _SwiftHashingSecretKey _swift_stdlib_Hashing_secretKey;

extern SWIFT_RUNTIME_STDLIB_INTERFACE
__swift_uint64_t _swift_stdlib_HashingDetail_fixedSeedOverride;

#ifdef __cplusplus
}} // extern "C", namespace swift
#endif

#endif
