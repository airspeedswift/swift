// A resilient module: Ref is address-only to its clients.
public struct Ref: ~Escapable {
  public let raw: UInt
  @_lifetime(immortal) public init(_ r: UInt) { raw = r }
}
public struct Holder {
  let n: UInt
  public init(_ n: UInt) { self.n = n }
  public var child: Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n) } }
  public subscript(i: UInt) -> Ref { @_lifetime(borrow self) yielding borrow { yield Ref(n &+ i) } }
}
