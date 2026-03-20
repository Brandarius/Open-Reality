# World generator: orchestrates the procedural generation pipeline
#
# Ties together world seed, noise, biomes, erosion, chunk streaming,
# vegetation, and structures into a unified generation pipeline.

"""
    StreamingTerrainData

Runtime terrain data for streaming worlds. Uses dynamic chunk dict instead of fixed matrix.
"""
mutable struct StreamingTerrainData
    entity_id::EntityID
    streaming_system::ChunkStreamingSystem
    initialized::Bool
end

# Global streaming terrain cache
const _STREAMING_TERRAIN_CACHE = Dict{EntityID, StreamingTerrainData}()

function reset_streaming_terrain_cache!()
    empty!(_STREAMING_TERRAIN_CACHE)
end

"""
    initialize_world_generator!(entity_id::EntityID, wg::WorldGeneratorComponent,
                                 terrain::TerrainComponent) -> StreamingTerrainData

Initialize the full world generation pipeline for an entity.
"""
function initialize_world_generator!(entity_id::EntityID,
                                      wg::WorldGeneratorComponent,
                                      terrain::TerrainComponent)
    if wg.streaming !== nothing
        # Streaming mode: create chunk streaming system
        system = create_chunk_streaming(
            wg.streaming, wg.config;
            num_lod_levels=terrain.num_lod_levels
        )
        _STREAMING_SYSTEMS[entity_id] = system

        std = StreamingTerrainData(entity_id, system, true)
        _STREAMING_TERRAIN_CACHE[entity_id] = std
        return std
    else
        # Non-streaming mode: generate entire terrain with biome/erosion pipeline
        _initialize_world_generator_fixed!(entity_id, wg, terrain)
        return nothing
    end
end

"""
    _initialize_world_generator_fixed!(entity_id, wg, terrain)

Generate a full fixed-size terrain with biomes and erosion (non-streaming mode).
"""
function _initialize_world_generator_fixed!(entity_id::EntityID,
                                             wg::WorldGeneratorComponent,
                                             terrain::TerrainComponent)
    config = wg.config

    chunks_x = max(1, round(Int, terrain.terrain_size[1] / Float32(terrain.chunk_size - 1)))
    chunks_z = max(1, round(Int, terrain.terrain_size[2] / Float32(terrain.chunk_size - 1)))
    res_x = chunks_x * (terrain.chunk_size - 1)
    res_z = chunks_z * (terrain.chunk_size - 1)

    # Generate base heightmap using world seed
    source = HeightmapSource(
        source_type=HEIGHTMAP_SIMPLEX,
        perlin_octaves=config.base_octaves,
        perlin_frequency=Float32(config.base_frequency),
        perlin_persistence=Float32(config.base_persistence),
        world_seed=config.seed
    )
    hm = generate_heightmap(source, res_x, res_z, config.base_max_height)

    # Generate biome map and modulate heightmap
    if !isempty(config.biome_defs)
        biome_map = generate_biome_map(config.seed, config.biome_defs, res_x, res_z;
                                        temperature_frequency=config.temperature_frequency,
                                        temperature_octaves=config.temperature_octaves,
                                        moisture_frequency=config.moisture_frequency,
                                        moisture_octaves=config.moisture_octaves)

        update_biome_map_elevation!(biome_map, hm, config.base_max_height, config.biome_defs)
        modulate_heightmap_by_biome!(hm, biome_map, config.biome_defs)
    end

    # Apply erosion
    if config.erosion_enabled && config.erosion_params !== nothing
        erosion_seed = derive_seed(config.seed, "erosion")
        erode_heightmap!(hm, config.erosion_params, erosion_seed)
    end

    cell_size_x = terrain.terrain_size[1] / Float32(res_x)
    cell_size_z = terrain.terrain_size[2] / Float32(res_z)
    normals = compute_terrain_normals(hm, cell_size_x, cell_size_z)

    origin_x = -terrain.terrain_size[1] / 2.0f0
    origin_z = -terrain.terrain_size[2] / 2.0f0

    chunks = Matrix{TerrainChunk}(undef, chunks_x, chunks_z)
    for cz in 1:chunks_z, cx in 1:chunks_x
        lod_meshes = MeshComponent[]
        for lod in 0:(terrain.num_lod_levels - 1)
            push!(lod_meshes, generate_chunk_mesh(hm, normals, cx, cz,
                                                   terrain.chunk_size, terrain.terrain_size,
                                                   origin_x, origin_z, lod))
        end

        start_x = (cx - 1) * (terrain.chunk_size - 1) + 1
        start_z = (cz - 1) * (terrain.chunk_size - 1) + 1
        end_x = min(start_x + terrain.chunk_size - 1, res_x + 1)
        end_z = min(start_z + terrain.chunk_size - 1, res_z + 1)

        min_h = Float32(Inf)
        max_h = Float32(-Inf)
        for iz in start_z:end_z, ix in start_x:end_x
            h = hm[ix, iz]
            min_h = min(min_h, h)
            max_h = max(max_h, h)
        end

        world_x0 = origin_x + Float32(start_x - 1) * cell_size_x
        world_z0 = origin_z + Float32(start_z - 1) * cell_size_z
        world_x1 = origin_x + Float32(end_x - 1) * cell_size_x
        world_z1 = origin_z + Float32(end_z - 1) * cell_size_z

        chunks[cx, cz] = TerrainChunk(cx, cz,
            Vec3f(world_x0, 0.0f0, world_z0),
            lod_meshes, 1,
            Vec3f(world_x0, min_h, world_z0),
            Vec3f(world_x1, max_h, world_z1))
    end

    td = TerrainData(entity_id, hm, normals, chunks, chunks_x, chunks_z, true)
    _TERRAIN_CACHE[entity_id] = td
end
