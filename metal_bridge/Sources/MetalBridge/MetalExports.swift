// All @_cdecl functions must be marked `public` so the Swift compiler
// emits them as `external [no dead strip]` symbols. Without `public`,
// they get `private external` visibility and the linker dead-strips them
// in release builds since no Swift code calls them.
//
// This file is kept as a simple smoke-test entry point that Julia can call
// to verify the dylib loaded correctly.

@_cdecl("metal_bridge_exports")
public func metal_bridge_exports() -> Int32 {
    return 56  // number of exported FFI symbols
}
