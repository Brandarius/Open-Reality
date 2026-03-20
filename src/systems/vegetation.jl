# Vegetation system: per-frame vegetation chunk streaming around the player
#
# Generates vegetation for chunks near the player, removes distant vegetation.
# Uses the chunk streaming system's active chunks for height/biome data.

"""
    update_vegetation!(cam_pos::Vec3f)

Per-frame vegetation update: generate/remove vegetation chunks based on camera position.
"""
function update_vegetation!(cam_pos::Vec3f)
    # Process all entities with both WorldGeneratorComponent and VegetationComponent
    iterate_components(VegetationComponent) do entity_id, veg_comp
        wg = get_component(entity_id, WorldGeneratorComponent)
        if wg === nothing
            return
        end

        config = wg.config
        streaming = wg.streaming

        if streaming === nothing
            return
        end

        chunk_world_size = streaming.chunk_world_size
        scatter_chunks = max(1, round(Int, veg_comp.scatter_radius / chunk_world_size))

        # Get or create vegetation data for this entity
        if !haskey(_VEGETATION_DATA, entity_id)
            _VEGETATION_DATA[entity_id] = Dict{ChunkCoord, VegetationChunkData}()
        end
        veg_data = _VEGETATION_DATA[entity_id]

        # Get streaming system for terrain data
        streaming_sys = get(_STREAMING_SYSTEMS, entity_id, nothing)
        if streaming_sys === nothing
            return
        end

        # Determine center chunk
        center = _world_to_chunk_coord(cam_pos, chunk_world_size)

        # Generate vegetation for nearby chunks that have terrain data
        for dz in -scatter_chunks:scatter_chunks, dx in -scatter_chunks:scatter_chunks
            coord = (center[1] + dx, center[2] + dz)

            # Skip if already generated
            if haskey(veg_data, coord)
                continue
            end

            # Need terrain data for this chunk
            sc = get(streaming_sys.active_chunks, coord, nothing)
            if sc === nothing || sc.data === nothing
                continue
            end

            # Generate vegetation
            chunk_veg = generate_vegetation_for_chunk(
                coord, veg_comp.definitions, config.seed,
                chunk_world_size,
                sc.data.heightmap_patch, sc.data.normal_patch,
                config.base_max_height,
                sc.data.biome_ids, config.biome_defs
            )
            veg_data[coord] = chunk_veg
        end

        # Remove vegetation for distant chunks
        unload_dist_sq = (scatter_chunks + 2)^2
        coords_to_remove = ChunkCoord[]
        for (coord, _) in veg_data
            dx = coord[1] - center[1]
            dz = coord[2] - center[2]
            if dx * dx + dz * dz > unload_dist_sq
                push!(coords_to_remove, coord)
            end
        end
        for coord in coords_to_remove
            delete!(veg_data, coord)
        end
    end
end
