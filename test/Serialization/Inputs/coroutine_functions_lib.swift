public struct Ref: ~Escapable {
  public let raw: Int
  @_lifetime(immortal) public init(_ r: Int) { raw = r }
}
public struct E: Error { public init() {} }
extension Ref {
  @_lifetime(borrow self, copy a)
  @yield_once public func call(_ a: Ref) throws yields (Ref) -> () {
    if a.raw < 0 { throw E() }
    yield Ref(raw &+ a.raw)
  }
}
@yield_once public func gen<T>(_ x: T) yields (T) -> () { yield x }
