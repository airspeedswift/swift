public struct EmptyResilientStruct {
  public init() {}

  public var computed: Int {
    return 1337
  }

  public mutating func mutate() {}
}

public var emptyGlobal = EmptyResilientStruct()

@frozen public var fixedLayoutGlobal = EmptyResilientStruct()
