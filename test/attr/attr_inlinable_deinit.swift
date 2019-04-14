// RUN: %target-typecheck-verify-swift -enable-library-evolution

public class ResilientClass {
    @inlinable deinit {} // expected-error {{deinitializer can only be '@inlinable' if the class is '@frozen'}}
}

@frozen public class FixedLayoutClass {
    @inlinable deinit {}
}
