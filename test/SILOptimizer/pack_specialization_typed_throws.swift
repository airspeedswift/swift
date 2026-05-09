// RUN: %target-swift-frontend %s -emit-sil -O -swift-version 6 -target %target-swift-5.9-abi-triple -o /dev/null

// REQUIRES: swift_in_compiler

// rdar://(typed-throws-pack-spec) — bug-3-instance-pack-expand-release.
//
// PackSpecialization built the new function signature by iterating
// `convention.results`, which includes the error result. After
// GenericSpecializer converted `@error_indirect E` to `@error E` (E =
// Never), the error slot got appended to the new direct results while
// `createSpecializedFunctionDeclaration` separately preserved it as
// `@error`, producing `(@owned Result, @owned Never, @error Never)`.
// Downstream passes (CSE on this minimal repro, SILCombine on the
// production case) tripped the `cast<Ty>()` assertion in `Casting.h:578`
// walking the malformed SIL.

public struct Product<each Element> {
    public let values: (repeat each Element)

    @inlinable
    public init(_ values: repeat each Element) {
        self.values = (repeat each values)
    }
}

extension Product {
    @inlinable
    public consuming func map<each NewElement, E: Swift.Error>(
        _ transforms: repeat (each Element) throws(E) -> each NewElement
    ) throws(E) -> Product<repeat each NewElement> {
        Product<repeat each NewElement>(
            repeat try (each transforms)(each values)
        )
    }
}

@inlinable
public func _instantiate() -> Product<Int, String, Bool>? {
    let triple = Product(1, "hi", true)
    return try? triple.map(
        { (x: Int) -> Int in x + 1 },
        { (s: String) -> String in s.uppercased() },
        { (b: Bool) -> Bool in !b }
    )
}
