//===----------------------------------------------------------------------===//
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

/// A type that can represent a string as a collection of characters.
///
/// Do not declare new conformances to `StringProtocol`. Only the `String` and
/// `Substring` types in the standard library are valid conforming types.
public protocol StringProtocol
  : BidirectionalCollection,
  TextOutputStream, TextOutputStreamable,
  LosslessStringConvertible, ExpressibleByStringLiteral,
  Hashable, Comparable
  where Iterator.Element == Character, SubSequence : StringProtocol {

  associatedtype UTF8View : /*Bidirectional*/Collection
  where UTF8View.Element == UInt8 // Unicode.UTF8.CodeUnit

  associatedtype UTF16View : BidirectionalCollection
  where UTF16View.Element == UInt16 // Unicode.UTF16.CodeUnit

  associatedtype UnicodeScalarView : BidirectionalCollection
  where UnicodeScalarView.Element == Unicode.Scalar

  var utf8: UTF8View { get }
  var utf16: UTF16View { get }
  var unicodeScalars: UnicodeScalarView { get }

  func hasPrefix(_ prefix: String) -> Bool
  func hasSuffix(_ prefix: String) -> Bool

  func lowercased() -> String
  func uppercased() -> String

  /// Creates a string from the given Unicode code units in the specified
  /// encoding.
  ///
  /// - Parameters:
  ///   - codeUnits: A collection of code units encoded in the encoding
  ///     specified in `sourceEncoding`.
  ///   - sourceEncoding: The encoding in which `codeUnits` should be
  ///     interpreted.
  init<C: Collection, Encoding: Unicode.Encoding>(
    decoding codeUnits: C, as sourceEncoding: Encoding.Type
  )
    where C.Iterator.Element == Encoding.CodeUnit

  /// Creates a string from the null-terminated, UTF-8 encoded sequence of
  /// bytes at the given pointer.
  ///
  /// - Parameter nullTerminatedUTF8: A pointer to a sequence of contiguous,
  ///   UTF-8 encoded bytes ending just before the first zero byte.
  init(cString nullTerminatedUTF8: UnsafePointer<CChar>)

  /// Creates a string from the null-terminated sequence of bytes at the given
  /// pointer.
  ///
  /// - Parameters:
  ///   - nullTerminatedCodeUnits: A pointer to a sequence of contiguous code
  ///     units in the encoding specified in `sourceEncoding`, ending just
  ///     before the first zero code unit.
  ///   - sourceEncoding: The encoding in which the code units should be
  ///     interpreted.
  init<Encoding: Unicode.Encoding>(
    decodingCString nullTerminatedCodeUnits: UnsafePointer<Encoding.CodeUnit>,
    as sourceEncoding: Encoding.Type)

  /// Calls the given closure with a pointer to the contents of the string,
  /// represented as a null-terminated sequence of UTF-8 code units.
  ///
  /// The pointer passed as an argument to `body` is valid only during the
  /// execution of `withCString(_:)`. Do not store or return the pointer for
  /// later use.
  ///
  /// - Parameter body: A closure with a pointer parameter that points to a
  ///   null-terminated sequence of UTF-8 code units. If `body` has a return
  ///   value, that value is also used as the return value for the
  ///   `withCString(_:)` method. The pointer argument is valid only for the
  ///   duration of the method's execution.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  func withCString<Result>(
    _ body: (UnsafePointer<CChar>) throws -> Result) rethrows -> Result

  /// Calls the given closure with a pointer to the contents of the string,
  /// represented as a null-terminated sequence of code units.
  ///
  /// The pointer passed as an argument to `body` is valid only during the
  /// execution of `withCString(encodedAs:_:)`. Do not store or return the
  /// pointer for later use.
  ///
  /// - Parameters:
  ///   - body: A closure with a pointer parameter that points to a
  ///     null-terminated sequence of code units. If `body` has a return
  ///     value, that value is also used as the return value for the
  ///     `withCString(encodedAs:_:)` method. The pointer argument is valid
  ///     only for the duration of the method's execution.
  ///   - targetEncoding: The encoding in which the code units should be
  ///     interpreted.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  func withCString<Result, Encoding: Unicode.Encoding>(
    encodedAs targetEncoding: Encoding.Type,
    _ body: (UnsafePointer<Encoding.CodeUnit>) throws -> Result
  ) rethrows -> Result
}

extension StringProtocol {
  //@available(swift, deprecated: 3.2, obsoleted: 4.0, message: "Please use the StringProtocol itself")
  //public var characters: Self { return self }

  @available(swift, deprecated: 3.2, obsoleted: 4.0, renamed: "UTF8View.Index")
  public typealias UTF8Index = UTF8View.Index
  @available(swift, deprecated: 3.2, obsoleted: 4.0, renamed: "UTF16View.Index")
  public typealias UTF16Index = UTF16View.Index
  @available(swift, deprecated: 3.2, obsoleted: 4.0, renamed: "UnicodeScalarView.Index")
  public typealias UnicodeScalarIndex = UnicodeScalarView.Index
}

extension StringProtocol {
  // TODO(UTF8): Wean NSStringAPI.swift off of this
  public // @SPI(NSStringAPI.swift)
  var _ephemeralString: String {
    if let str = self as? String {
      return str
    }
    // TODO: Substring shared
    return String(self)
  }
}
