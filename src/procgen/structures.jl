# Structure/POI placement: procedural placement of villages, dungeons, landmarks, etc.
#
# Structures are placed during world generation using Poisson disk sampling
# with biome/flatness/spacing constraints. Entity spawning/despawning is
# managed per-frame based on player proximity.

"""
    PlacedStructure

A procedurally placed structure in the world (persistent record).
"""
mutable struct PlacedStructure
    def_index::Int
    chunk_coord::ChunkCoord
    world_position::Vec3f
    rotation_y::Float32
    spawned::Bool
    entity_ids::Vector{EntityID}
end

"""
    StructureRegistry

Global registry of all placed structures, indexed by chunk.
"""
mutable struct StructureRegistry
    by_chunk::Dict{ChunkCoord, Vector{PlacedStructure}}
    all_positions::Vector{Vec3f}     # For spacing checks
end

# Global structure registries (entity_id → StructureRegistry)
const _STRUCTURE_REGISTRIES = Dict{EntityID, StructureRegistry}()

function reset_structure_registries!()
    empty!(_STRUCTURE_REGISTRIES)
end

"""
    _compute_terrain_flatness(heightmap::Matrix{Float32}, hx::Int, hz::Int,
                               radius::Int, cell_size::Float32) -> Float32

Compute terrain flatness at a point (0=very steep, 1=perfectly flat).
Measures height variance in a radius around the point.
"""
function _compute_terrain_flatness(heightmap::Matrix{Float32}, hx::Int, hz::Int,
                                    radius::Int, cell_size::Float32)::Float32
    rows, cols = size(heightmap)
    center_h = heightmap[clamp(hx, 1, rows), clamp(hz, 1, cols)]
    max_diff = 0.0f0

    for dz in -radius:radius, dx in -radius:radius
        if dx == 0 && dz == 0
            continue
        end
        sx = clamp(hx + dx, 1, rows)
        sz = clamp(hz + dz, 1, cols)
        diff = abs(heightmap[sx, sz] - center_h)
        max_diff = max(max_diff, diff)
    end

    # Normalize by expected height change over the radius
    expected_max = cell_size * Float32(radius) * 2.0f0
    flatness = 1.0f0 - clamp(max_diff / max(expected_max, 0.01f0), 0.0f0, 1.0f0)
    return flatness
end

"""
    generate_structures_for_chunk(coord::ChunkCoord, defs::Vector{StructureDef},
                                  seed::WorldSeed, chunk_world_size::Float32,
                                  heightmap::Matrix{Float32},
                                  biome_ids::Union{Matrix{Int}, Nothing},
                                  biome_defs::Vector{BiomeDef},
                                  existing_positions::Vector{Vec3f}) -> Vector{PlacedStructure}

Generate structure placements for a single chunk. Pure function.
Uses Poisson-like sampling with spacing, biome, and flatness constraints.
"""
function generate_structures_for_chunk(coord::ChunkCoord,
                                        defs::Vector{StructureDef},
                                        seed::WorldSeed,
                                        chunk_world_size::Float32,
                                        heightmap::Matrix{Float32},
                                        biome_ids::Union{Matrix{Int}, Nothing},
                                        biome_defs::Vector{BiomeDef},
                                        existing_positions::Vector{Vec3f})::Vector{PlacedStructure}
    structures = PlacedStructure[]
    cx, cz = coord
    rows, cols = size(heightmap)
    cell_size = chunk_world_size / Float32(rows - 1)
    origin_x = Float32(cx) * chunk_world_size
    origin_z = Float32(cz) * chunk_world_size

    for (def_idx, sdef) in enumerate(defs)
        struct_seed = derive_seed(seed, "structure", cx, cz, def_idx)
        rng = struct_seed

        # Number of candidates to try (based on rarity and chunk size)
        max_candidates = max(1, round(Int, sdef.rarity * 3.0f0))

        for candidate in 1:max_candidates
            rng = xor(rng * UInt64(6364136223846793005) + UInt64(1442695040888963407),
                       UInt64(candidate))

            # Random position within chunk
            local_x = Float32(rng & 0xFFFF) / 65536.0f0 * chunk_world_size
            rng = xor(rng * UInt64(6364136223846793005), UInt64(0xABCD))
            local_z = Float32(rng & 0xFFFF) / 65536.0f0 * chunk_world_size

            world_x = origin_x + local_x
            world_z = origin_z + local_z

            # Rarity check
            rng = xor(rng * UInt64(6364136223846793005), UInt64(0x1234))
            rarity_roll = Float32(rng & 0xFFFF) / 65536.0f0
            if rarity_roll > sdef.rarity
                continue
            end

            # Heightmap lookup
            hx = clamp(round(Int, local_x / cell_size) + 1, 1, rows)
            hz = clamp(round(Int, local_z / cell_size) + 1, 1, cols)
            height = heightmap[hx, hz]

            # Flatness check
            flat_radius = max(1, round(Int, sdef.footprint[1] / cell_size / 2.0f0))
            flatness = _compute_terrain_flatness(heightmap, hx, hz, flat_radius, cell_size)
            if flatness < sdef.min_flatness
                continue
            end

            # Biome filter
            if !isempty(sdef.biome_filter) && biome_ids !== nothing
                bix = clamp(hx, 1, size(biome_ids, 1))
                biz = clamp(hz, 1, size(biome_ids, 2))
                biome_id = biome_ids[bix, biz]
                if biome_id >= 1 && biome_id <= length(biome_defs)
                    bt = biome_defs[biome_id].biome_type
                    if !(bt in sdef.biome_filter)
                        continue
                    end
                end
            end

            # Minimum spacing check against all existing structures
            pos = Vec3f(world_x, height, world_z)
            too_close = false
            for existing_pos in existing_positions
                dx = pos[1] - existing_pos[1]
                dz = pos[3] - existing_pos[3]
                dist_sq = dx * dx + dz * dz
                if dist_sq < sdef.min_spacing * sdef.min_spacing
                    too_close = true
                    break
                end
            end
            # Also check against structures placed in this call
            for placed in structures
                dx = pos[1] - placed.world_position[1]
                dz = pos[3] - placed.world_position[3]
                dist_sq = dx * dx + dz * dz
                if dist_sq < sdef.min_spacing * sdef.min_spacing
                    too_close = true
                    break
                end
            end
            if too_close
                continue
            end

            # Random rotation
            rng = xor(rng * UInt64(6364136223846793005), UInt64(0xFEED))
            rot_y = Float32(rng & 0xFFFF) / 65536.0f0 * 2.0f0 * Float32(π)

            push!(structures, PlacedStructure(
                def_idx, coord, pos, rot_y, false, EntityID[]
            ))
        end
    end

    return structures
end

"""
    flatten_terrain_around_structure!(heightmap::Matrix{Float32}, hx::Int, hz::Int,
                                      radius::Int, target_height::Float32)

Smooth the heightmap around a structure placement point for a flat foundation.
"""
function flatten_terrain_around_structure!(heightmap::Matrix{Float32}, hx::Int, hz::Int,
                                           radius::Int, target_height::Float32)
    rows, cols = size(heightmap)
    for dz in -radius:radius, dx in -radius:radius
        sx = clamp(hx + dx, 1, rows)
        sz = clamp(hz + dz, 1, cols)
        dist = sqrt(Float32(dx * dx + dz * dz))
        blend = clamp(dist / Float32(radius), 0.0f0, 1.0f0)
        # Smooth blend from target_height at center to original at edge
        heightmap[sx, sz] = target_height * (1.0f0 - blend) + heightmap[sx, sz] * blend
    end
end
