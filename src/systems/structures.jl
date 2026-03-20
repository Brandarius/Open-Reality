# Structure system: per-frame structure generation and entity spawn/despawn
#
# Generates structure placements for chunks near the player,
# spawns/despawns structure entities based on proximity.

"""
    update_structures!(cam_pos::Vec3f)

Per-frame structure update: generate placements for new chunks,
spawn/despawn structure entities based on player distance.
"""
function update_structures!(cam_pos::Vec3f)
    iterate_components(WorldStructureComponent) do entity_id, struct_comp
        wg = get_component(entity_id, WorldGeneratorComponent)
        if wg === nothing || wg.streaming === nothing
            return
        end

        config = wg.config
        streaming = wg.streaming
        chunk_world_size = streaming.chunk_world_size

        # Get or create structure registry
        if !haskey(_STRUCTURE_REGISTRIES, entity_id)
            _STRUCTURE_REGISTRIES[entity_id] = StructureRegistry(
                Dict{ChunkCoord, Vector{PlacedStructure}}(),
                Vec3f[]
            )
        end
        registry = _STRUCTURE_REGISTRIES[entity_id]

        # Get streaming system
        streaming_sys = get(_STREAMING_SYSTEMS, entity_id, nothing)
        if streaming_sys === nothing
            return
        end

        center = _world_to_chunk_coord(cam_pos, chunk_world_size)
        struct_chunks = max(1, round(Int, struct_comp.spawn_radius / chunk_world_size))

        # Generate structure placements for chunks that have terrain data
        for dz in -struct_chunks:struct_chunks, dx in -struct_chunks:struct_chunks
            coord = (center[1] + dx, center[2] + dz)

            # Skip if already generated
            if haskey(registry.by_chunk, coord)
                continue
            end

            # Need terrain data
            sc = get(streaming_sys.active_chunks, coord, nothing)
            if sc === nothing || sc.data === nothing
                continue
            end

            placements = generate_structures_for_chunk(
                coord, struct_comp.definitions, config.seed,
                chunk_world_size,
                sc.data.heightmap_patch,
                sc.data.biome_ids, config.biome_defs,
                registry.all_positions
            )

            registry.by_chunk[coord] = placements
            for p in placements
                push!(registry.all_positions, p.world_position)
            end
        end

        # Spawn/despawn structure entities based on distance
        spawn_r_sq = struct_comp.spawn_radius * struct_comp.spawn_radius
        despawn_r_sq = struct_comp.despawn_radius * struct_comp.despawn_radius

        for (_, placements) in registry.by_chunk
            for placed in placements
                dx = cam_pos[1] - placed.world_position[1]
                dz = cam_pos[3] - placed.world_position[3]
                dist_sq = dx * dx + dz * dz

                if !placed.spawned && dist_sq < spawn_r_sq
                    # Spawn structure entities
                    _spawn_structure!(placed, struct_comp.definitions)
                elseif placed.spawned && dist_sq > despawn_r_sq
                    # Despawn structure entities
                    _despawn_structure!(placed)
                end
            end
        end
    end
end

"""
    _spawn_structure!(placed::PlacedStructure, defs::Vector{StructureDef})

Instantiate ECS entities for a structure.
"""
function _spawn_structure!(placed::PlacedStructure, defs::Vector{StructureDef})
    if placed.def_index < 1 || placed.def_index > length(defs)
        return
    end

    sdef = defs[placed.def_index]
    # Create a simple marker entity at the structure position
    # (Full prefab instantiation would use the prefab system when available)
    eid = create_entity!()
    add_component!(eid, TransformComponent(
        position=placed.world_position,
        rotation=Quaterniond(cos(placed.rotation_y / 2.0), 0.0, sin(placed.rotation_y / 2.0), 0.0)
    ))
    push!(placed.entity_ids, eid)
    placed.spawned = true
end

"""
    _despawn_structure!(placed::PlacedStructure)

Remove ECS entities for a structure (keep placement record).
"""
function _despawn_structure!(placed::PlacedStructure)
    for eid in placed.entity_ids
        try
            destroy_entity!(eid)
        catch
        end
    end
    empty!(placed.entity_ids)
    placed.spawned = false
end
