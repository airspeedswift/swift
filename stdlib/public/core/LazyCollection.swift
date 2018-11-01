//===--- LazyCollection.swift ---------------------------------*- swift -*-===//
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

/// A collection on which normally-eager operations such as `map` and
/// `filter` are implemented lazily.
///
/// Please see `LazySequenceProtocol` for background; `LazyCollectionProtocol`
/// is an analogous component, but for collections.
///
/// To add new lazy collection operations, extend this protocol with
/// methods that return lazy wrappers that are themselves
/// `LazyCollectionProtocol`s.
public protocol LazyCollectionProtocol: Collection, LazySequenceProtocol {
  /// A `Collection` that can contain the same elements as this one,
  /// possibly with a simpler type.
  ///
  /// - See also: `elements`
  associatedtype Elements : Collection = Self
}

extension LazyCollectionProtocol {
  // Lazy things are already lazy
  @inlinable // protocol-only
  public var lazy: LazyCollection<Elements> {
    return elements.lazy
  }
}

extension LazyCollectionProtocol where Elements: LazyCollectionProtocol {
  // Lazy things are already lazy
  @inlinable // protocol-only
  public var lazy: Elements {
    return elements
  }
}

/// A collection containing the same elements as a `Base` collection,
/// but on which some operations such as `map` and `filter` are
/// implemented lazily.
///
/// - See also: `LazySequenceProtocol`, `LazyCollection`
public typealias LazyCollection<T: Collection> = LazySequence<T>

extension LazyCollection: LazyCollectionProtocol { }

extension LazyCollection : Collection {
  /// A type that represents a valid position in the collection.
  ///
  /// Valid indices consist of the position of every element and a
  /// "past the end" position that's not valid for use as a subscript.
  public typealias Index = Base.Index
  public typealias Indices = Base.Indices
  public typealias SubSequence = Slice<LazySequence>

  /// The position of the first element in a non-empty collection.
  ///
  /// In an empty collection, `startIndex == endIndex`.
  @inlinable
  public var startIndex: Index { return _base.startIndex }

  /// The collection's "past the end" position---that is, the position one
  /// greater than the last valid subscript argument.
  ///
  /// `endIndex` is always reachable from `startIndex` by zero or more
  /// applications of `index(after:)`.
  @inlinable
  public var endIndex: Index { return _base.endIndex }

  @inlinable
  public var indices: Indices { return _base.indices }

  // TODO: swift-3-indexing-model - add docs
  @inlinable
  public func index(after i: Index) -> Index {
    return _base.index(after: i)
  }

  /// Accesses the element at `position`.
  ///
  /// - Precondition: `position` is a valid position in `self` and
  ///   `position != endIndex`.
  @inlinable
  public subscript(position: Index) -> Element {
    return _base[position]
  }

  /// A Boolean value indicating whether the collection is empty.
  @inlinable
  public var isEmpty: Bool {
    return _base.isEmpty
  }

  /// Returns the number of elements.
  ///
  /// To check whether a collection is empty, use its `isEmpty` property
  /// instead of comparing `count` to zero. Unless the collection guarantees
  /// random-access performance, calculating `count` can be an O(*n*)
  /// operation.
  ///
  /// - Complexity: O(1) if `Self` conforms to `RandomAccessCollection`;
  ///   O(*n*) otherwise.
  @inlinable
  public var count: Int {
    return _base.count
  }

  // The following requirement enables dispatching for firstIndex(of:) and
  // lastIndex(of:) when the element type is Equatable.

  /// Returns `Optional(Optional(index))` if an element was found;
  /// `Optional(nil)` if the element doesn't exist in the collection;
  /// `nil` if a search was not performed.
  ///
  /// - Complexity: Better than O(*n*)
  @inlinable
  public func _customIndexOfEquatableElement(
    _ element: Element
  ) -> Index?? {
    return _base._customIndexOfEquatableElement(element)
  }

  /// Returns `Optional(Optional(index))` if an element was found;
  /// `Optional(nil)` if the element doesn't exist in the collection;
  /// `nil` if a search was not performed.
  ///
  /// - Complexity: Better than O(*n*)
  @inlinable
  public func _customLastIndexOfEquatableElement(
    _ element: Element
  ) -> Index?? {
    return _base._customLastIndexOfEquatableElement(element)
  }

  // TODO: swift-3-indexing-model - add docs
  @inlinable
  public func index(_ i: Index, offsetBy n: Int) -> Index {
    return _base.index(i, offsetBy: n)
  }

  // TODO: swift-3-indexing-model - add docs
  @inlinable
  public func index(
    _ i: Index, offsetBy n: Int, limitedBy limit: Index
  ) -> Index? {
    return _base.index(i, offsetBy: n, limitedBy: limit)
  }

  // TODO: swift-3-indexing-model - add docs
  @inlinable
  public func distance(from start: Index, to end: Index) -> Int {
    return _base.distance(from:start, to: end)
  }

}

extension LazyCollection : BidirectionalCollection
  where Base : BidirectionalCollection {
  @inlinable
  public func index(before i: Index) -> Index {
    return _base.index(before: i)
  }
}

extension LazyCollection : RandomAccessCollection
  where Base : RandomAccessCollection {}

/// Augment `self` with lazy methods such as `map`, `filter`, etc.
extension Collection {
  /// A view onto this collection that provides lazy implementations of
  /// normally eager operations, such as `map` and `filter`.
  ///
  /// Use the `lazy` property when chaining operations to prevent
  /// intermediate operations from allocating storage, or when you only
  /// need a part of the final collection to avoid unnecessary computation.
  @inlinable
  public var lazy: LazyCollection<Self> {
    return LazyCollection(_base: self)
  }
}

extension Slice: LazySequenceProtocol where Base: LazySequenceProtocol { }
extension Slice: LazyCollectionProtocol where Base: LazyCollectionProtocol { }
extension ReversedCollection: LazySequenceProtocol where Base: LazySequenceProtocol { }
extension ReversedCollection: LazyCollectionProtocol where Base: LazyCollectionProtocol { }
