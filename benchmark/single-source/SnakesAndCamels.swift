// import Foundation

extension StringProtocol {
    func titlecased() -> String {
        guard let f = first.map(String.init) else { return "" }
        var result = ""
        result += f.uppercased()
        result += dropFirst()
        return result
    }
}


extension String {
    func camelCasedEagerSplit() -> String {
        let fields = split(separator: "_")
        let head = (fields.first ?? "")
        let tail = fields.dropFirst().map({ $0.titlecased() }).joined()
        return head + tail
    }

    func snakeCasedEagerSplit() -> String {
        var snake = ""
        var i = startIndex
        while let j = self[i...].dropFirst().index(where: { $0.isUppercase }) {
            snake += self[i..<j].lowercased()
            snake += "_"
            i = j
        }
        snake += self[i...].lowercased()
        return snake
    }
}

extension Character {
    var isUppercase: Bool {
        return self >= "A" && self <= "Z"
    }
}

let snake = "some_snake_case_variable"

@inline(never)
public func run_CamelCasedEager(_ N: Int) {
  for _ in 1...N*200 {
    _ = snake.camelCasedEagerSplit()
  }
}


let camel = "someCamelCasedVariable"

@inline(never)
public func run_SnakeCasedEager(_ N: Int) {
  for _ in 1...N*200 {
    _ = camel.snakeCasedEagerSplit()
  }
}



struct LazySplit<Base: Collection> where Base.SubSequence: Collection {
    let base: Base
    let separator: (Base.Element) -> Bool
    var dropSeparator = true
}

extension LazySplit: Collection {
    
    struct Index: Comparable {
        let start: Base.Index, end: Base.Index
        static func ==(lhs: Index, rhs: Index) -> Bool { return lhs.start == rhs.start }
        static func < (lhs: Index, rhs: Index) -> Bool { return lhs.start < rhs.start }
    }
    
    private func nextEnd(from: Base.Index) -> Base.Index {
        let i = dropSeparator ? from : base.index(after: from)
        return base[i...].index(where: separator) ?? base.endIndex
    }
    
    var startIndex: Index { return Index(start: base.startIndex, end: nextEnd(from: base.startIndex)) }
    var endIndex: Index { return Index(start: base.endIndex, end: base.endIndex) }
    subscript(i: Index) -> Base.SubSequence { return base[i.start..<i.end] }
    
    func index(after: Index) -> Index {
        guard after.end != base.endIndex else { return endIndex }
        let i = dropSeparator ? base.index(after: after.end) : after.end
        let j = nextEnd(from: i)
        return Index(start: i, end: j)
    }
}

extension LazyCollectionProtocol
where Elements.Element: Equatable, Elements.SubSequence: Collection {
    func split(separator: Elements.Element, dropSeparator: Bool = true) -> LazySplit<Elements> {
        return LazySplit(base: self.elements, separator: { $0 == separator }, dropSeparator: dropSeparator)
    }
}

extension LazyCollectionProtocol
where Elements.SubSequence: Collection {
    func split(dropSeparator: Bool = true, where: @escaping (Elements.Element)->Bool) -> LazySplit<Elements> {
        return LazySplit(base: self.elements, separator: `where`, dropSeparator: dropSeparator)
    }
}

extension String {
    func camelCasedLazySplit() -> String {
        let fields = lazy.split(separator: "_")
        let head = (fields.first ?? "")
        let tail = fields.dropFirst().map({ $0.titlecased() }).joined()
        return head + tail
    }
    
    func snakeCasedLazySplit() -> String {
      return lazy.split(dropSeparator: false, where: { $0.isUppercase }).map({$0.lowercased()}).joined(separator: "_")
    }
}

@inline(never)
public func run_CamelCasedLazy(_ N: Int) {
  for _ in 1...N*200 {
    _ = snake.camelCasedLazySplit()
  }
}

@inline(never)
public func run_SnakeCasedLazy(_ N: Int) {
  for _ in 1...N*200 {
    _ = camel.snakeCasedLazySplit()
  }
}


