# World seed system: deterministic, reproducible seed derivation for procedural generation
#
# All procedural systems (noise, biomes, vegetation, structures) derive sub-seeds
# from a single master WorldSeed, ensuring entire worlds are reproducible from one value.

"""
    WorldSeed

Master seed for deterministic world generation. Constructable from an integer or string.
All downstream procedural systems derive their seeds from this via `derive_seed`.
"""
struct WorldSeed
    master::UInt64

    WorldSeed(seed::Integer) = new(UInt64(seed))
    WorldSeed(seed::String) = new(_hash_string_seed(seed))
end

"""
    _hash_string_seed(s::String) -> UInt64

Deterministic string-to-seed conversion using a custom mixer.
Does not use Julia's `hash()` to ensure cross-version reproducibility.
"""
function _hash_string_seed(s::String)::UInt64
    h = UInt64(0x517cc1b727220a95)  # arbitrary initialization constant
    for byte in codeunits(s)
        h = xor(h * UInt64(6364136223846793005) + UInt64(1442695040888963407), UInt64(byte))
    end
    return h
end

"""
    derive_seed(ws::WorldSeed, domain::String, coords::Int...) -> UInt64

Derive a deterministic sub-seed for a specific domain and coordinates.
The same inputs always produce the same output, regardless of call order.

# Examples
```julia
ws = WorldSeed(12345)
terrain_seed = derive_seed(ws, "terrain", 3, 7)        # Chunk (3,7) terrain
biome_seed   = derive_seed(ws, "biome", 3, 7)          # Chunk (3,7) biome
veg_seed     = derive_seed(ws, "vegetation", 3, 7)     # Chunk (3,7) vegetation
```
"""
function derive_seed(ws::WorldSeed, domain::String, coords::Int...)::UInt64
    h = ws.master
    # Mix in domain string
    for byte in codeunits(domain)
        h = xor(h * UInt64(6364136223846793005) + UInt64(1442695040888963407), UInt64(byte))
    end
    # Mix in coordinates
    for c in coords
        h = xor(h * UInt64(6364136223846793005) + UInt64(1442695040888963407), reinterpret(UInt64, Int64(c)))
    end
    # Final avalanche mix
    h = xor(h, h >> 33)
    h *= UInt64(0xff51afd7ed558ccd)
    h = xor(h, h >> 33)
    h *= UInt64(0xc4ceb9fe1a85ec53)
    h = xor(h, h >> 33)
    return h
end

"""
    seed_to_int(seed::UInt64) -> Int

Convert a derived UInt64 seed to a regular Int for use with existing noise functions.
"""
function seed_to_int(seed::UInt64)::Int
    return Int(seed & UInt64(0x7FFFFFFFFFFFFFFF))
end
