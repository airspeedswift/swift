// RUN: %target-typecheck-verify-swift -enable-library-evolution

@frozen public enum Exhaustive {} // no-warning

@frozen enum NotPublic {} // expected-warning {{@frozen has no effect on non-public enums}} {{1-9=}}

internal enum Outer {
  @frozen public enum ButThisIsOK {} // no-warning
}

@frozen @usableFromInline enum NotPublicButVersioned {} // no-warning
