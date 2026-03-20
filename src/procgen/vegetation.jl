# Vegetation placement: procedural scattering of trees, grass, rocks, etc.
#
# Uses jittered grid sampling with biome/slope/altitude filtering.
# Instances are packed structs, NOT ECS entities (millions would be too many).
# Rendered via the existing instancing system.

"""
    VegetationInstance

A single placed vegetation instance. Packed struct for efficient storage.
"""
struct VegetationInstance
    position::Vec3f
    rotation_y::Float32     # Y-axis rotation angle (radians)
    scale::Float32
    def_index::Int          # Index into VegetationDef array
    normal::Vec3f           # Terrain normal at this position (for alignment)
end

"""
    VegetationChunkData

All vegetation instances for a single chunk.
"""
mutable struct VegetationChunkData
    coord::ChunkCoord
    instances::Vector{VegetationInstance}
    uploaded::Bool           # Whether GPU instance buffers are current
end

# Global vegetation data (entity_id → Dict{ChunkCoord, VegetationChunkData})
const _VEGETATION_DATA = Dict{EntityID, Dict{ChunkCoord, VegetationChunkData}}()

function reset_vegetation_data!()
    empty!(_VEGETATION_DATA)
end

"""
    generate_vegetation_for_chunk(coord::ChunkCoord, defs::Vector{VegetationDef},
                                  seed::WorldSeed, chunk_world_size::Float32,
                                  heightmap::Matrix{Float32}, normals::Matrix{Vec3f},
                                  max_height::Float32,
                                  biome_ids::Union{Matrix{Int}, Nothing},
                                  biome_defs::Vector{BiomeDef}) -> VegetationChunkData

Generate vegetation instances for a single chunk. Pure function, safe for background threads.
"""
function generate_vegetation_for_chunk(coord::ChunkCoord,
                                        defs::Vector{VegetationDef},
                                        seed::WorldSeed,
                                        chunk_world_size::Float32,
                                        heightmap::Matrix{Float32},
                                        normals::Matrix{Vec3f},
                                        max_height::Float32,
                                        biome_ids::Union{Matrix{Int}, Nothing},
                                        biome_defs::Vector{BiomeDef})::VegetationChunkData
    instances = VegetationInstance[]
    cx, cz = coord
    chunk_area = chunk_world_size * chunk_world_size
    rows, cols = size(heightmap)
    cell_size = chunk_world_size / Float32(rows - 1)
    origin_x = Float32(cx) * chunk_world_size
    origin_z = Float32(cz) * chunk_world_size

    for (def_idx, vdef) in enumerate(defs)
        veg_seed = derive_seed(seed, "vegetation", cx, cz, def_idx)
        rng = veg_seed

        # Expected instance count
        num_instances = round(Int, vdef.density * chunk_area)
        if num_instances <= 0
            continue
        end

        # Jittered grid: divide chunk into cells, place one candidate per cell
        grid_side = max(1, round(Int, sqrt(Float64(num_instances))))
        grid_cell = chunk_world_size / Float32(grid_side)

        for gz in 0:(grid_side - 1), gx in 0:(grid_side - 1)
            # Advance RNG
            rng = xor(rng * UInt64(6364136223846793005) + UInt64(1442695040888963407),
                       UInt64(gx * 7919 + gz * 6271 + def_idx))

            # Jittered position within grid cell
            jx = Float32(rng & 0xFFFF) / 65536.0f0
            rng = xor(rng * UInt64(6364136223846793005), UInt64(0xCAFEBABE))
            jz = Float32(rng & 0xFFFF) / 65536.0f0

            local_x = (Float32(gx) + jx) * grid_cell
            local_z = (Float32(gz) + jz) * grid_cell

            # Clamp to chunk bounds
            local_x = clamp(local_x, 0.0f0, chunk_world_size - 0.01f0)
            local_z = clamp(local_z, 0.0f0, chunk_world_size - 0.01f0)

            # Sample heightmap
            hx = clamp(round(Int, local_x / cell_size) + 1, 1, rows)
            hz = clamp(round(Int, local_z / cell_size) + 1, 1, cols)
            height = heightmap[hx, hz]
            normal = normals[hx, hz]

            # Altitude filter
            norm_alt = max_height > 0.0f0 ? height / max_height : 0.5f0
            if norm_alt < vdef.min_altitude || norm_alt > vdef.max_altitude
                continue
            end

            # Slope filter (angle of normal from vertical)
            slope = acos(clamp(normal[2], -1.0f0, 1.0f0))
            if slope < vdef.min_slope || slope > vdef.max_slope
                continue
            end

            # Biome filter
            if !isempty(vdef.biome_filter) && biome_ids !== nothing
                bix = clamp(hx, 1, size(biome_ids, 1))
                biz = clamp(hz, 1, size(biome_ids, 2))
                biome_id = biome_ids[bix, biz]
                if biome_id >= 1 && biome_id <= length(biome_defs)
                    bt = biome_defs[biome_id].biome_type
                    if !(bt in vdef.biome_filter)
                        continue
                    end
                end
            end

            # Clustering: offset position toward cluster center if enabled
            world_x = origin_x + local_x
            world_z = origin_z + local_z
            if vdef.cluster_radius > 0.0f0
                cluster_val = worley_noise_2d(Float64(world_x) * 0.05, Float64(world_z) * 0.05,
                                              derive_seed(seed, "veg_cluster", def_idx))
                if cluster_val > 0.6  # Outside cluster regions, skip some
                    rng = xor(rng * UInt64(6364136223846793005), UInt64(0xDEAD))
                    if Float32(rng & 0xFFFF) / 65536.0f0 > 1.0f0 / vdef.cluster_density
                        continue
                    end
                end
            end

            # Random scale
            rng = xor(rng * UInt64(6364136223846793005), UInt64(0xBEEF))
            scale_t = Float32(rng & 0xFFFF) / 65536.0f0
            scale = vdef.scale_min + scale_t * (vdef.scale_max - vdef.scale_min)

            # Random rotation
            rot_y = 0.0f0
            if vdef.rotation_random
                rng = xor(rng * UInt64(6364136223846793005), UInt64(0xFACE))
                rot_y = Float32(rng & 0xFFFF) / 65536.0f0 * 2.0f0 * Float32(π)
            end

            push!(instances, VegetationInstance(
                Vec3f(world_x, height, world_z),
                rot_y, scale, def_idx, normal
            ))
        end
    end

    return VegetationChunkData(coord, instances, false)
end

"""
    get_vegetation_instances_by_def(chunk_data::VegetationChunkData, def_index::Int) -> Vector{VegetationInstance}

Filter vegetation instances for a specific definition (for batched rendering).
"""
function get_vegetation_instances_by_def(chunk_data::VegetationChunkData,
                                          def_index::Int)::Vector{VegetationInstance}
    return filter(inst -> inst.def_index == def_index, chunk_data.instances)
end
