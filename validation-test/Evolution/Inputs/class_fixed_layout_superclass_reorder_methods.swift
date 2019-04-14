public func getVersion() -> Int {
#if BEFORE
  return 0
#else
  return 1
#endif
}

#if BEFORE
@frozen
open class Base {
  public init() {}
  open func firstMethod() -> Int {
    return 1
  }
  open func secondMethod() -> Int {
    return 2
  }
  open func callOverriddenMethods() -> Int {
    return firstMethod() * 10 + secondMethod()
  }
}
#else
@frozen
open class Base {
  public init() {}
  open func secondMethod() -> Int {
    return 2
  }
  open func firstMethod() -> Int {
    return 1
  }
  open func callOverriddenMethods() -> Int {
    return firstMethod() * 10 + secondMethod()
  }
}
#endif

@frozen
public class Derived : Base {
  public override func firstMethod() -> Int {
    return 10
  }

  public override func secondMethod() -> Int {
    return 20
  }
}
