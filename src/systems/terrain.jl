# Terrain system: per-frame terrain update (initialization, LOD, culling)
# Supports both fixed-size terrain and streaming world generation.

# Default chunk LOD distances (meters from camera)
const DEFAULT_CHUNK_LOD_DISTANCES = Float32[50.0, 120.0, 250.0]

"""
    update_terrain!(cam_pos::Vec3f, frustum::Frustum)

Per-frame terrain update: initialize new terrains, update chunk LODs.
Supports both fixed-size terrain and streaming world generation.
Called from the render loop before rendering.
"""
function update_terrain!(cam_pos::Vec3f, frustum::Frustum)
    iterate_components(TerrainComponent) do entity_id, comp
        # Check if this entity has a WorldGeneratorComponent (streaming/biome pipeline)
        wg = get_component(entity_id, WorldGeneratorComponent)

        if wg !== nothing
            # World generator pipeline
            if wg.streaming !== nothing
                # Streaming mode
                if !haskey(_STREAMING_TERRAIN_CACHE, entity_id)
                    @info "Initializing streaming world generator" entity_id=entity_id
                    initialize_world_generator!(entity_id, wg, comp)
                end

                # Update chunk streaming
                streaming_sys = get(_STREAMING_SYSTEMS, entity_id, nothing)
                if streaming_sys !== nothing
                    update_chunk_streaming!(streaming_sys, cam_pos)
                end
            else
                # Non-streaming world generator (fixed-size with biomes/erosion)
                if !haskey(_TERRAIN_CACHE, entity_id)
                    @info "Initializing world generator (fixed)" entity_id=entity_id
                    initialize_world_generator!(entity_id, wg, comp)
                end

                td = get(_TERRAIN_CACHE, entity_id, nothing)
                if td !== nothing
                    lod_distances = _build_lod_distances(comp)
                    update_terrain_lod!(td, cam_pos, lod_distances)
                end
            end
        else
            # Classic terrain pipeline (no world generator)
            if !haskey(_TERRAIN_CACHE, entity_id)
                @info "Initializing terrain" entity_id=entity_id
                initialize_terrain!(entity_id, comp)
            end

            td = _TERRAIN_CACHE[entity_id]
            lod_distances = _build_lod_distances(comp)
            update_terrain_lod!(td, cam_pos, lod_distances)
        end
    end
end

"""
    _build_lod_distances(comp::TerrainComponent) -> Vector{Float32}

Build LOD distance thresholds from terrain component settings.
"""
function _build_lod_distances(comp::TerrainComponent)::Vector{Float32}
    if comp.num_lod_levels <= length(DEFAULT_CHUNK_LOD_DISTANCES)
        return DEFAULT_CHUNK_LOD_DISTANCES[1:comp.num_lod_levels]
    else
        dists = Float32[]
        for i in 1:comp.num_lod_levels
            push!(dists, Float32(50.0 * (2.5 ^ (i - 1))))
        end
        return dists
    end
end

"""
    get_terrain_data(entity_id::EntityID) -> Union{TerrainData, Nothing}

Retrieve cached terrain data for an entity.
"""
function get_terrain_data(entity_id::EntityID)
    return get(_TERRAIN_CACHE, entity_id, nothing)
end
