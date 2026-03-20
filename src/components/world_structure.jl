# World structure component: definitions for procedural structure/POI placement

"""
    StructureType

Category of procedurally placed world structures.
"""
@enum StructureType begin
    STRUCTURE_VILLAGE
    STRUCTURE_DUNGEON
    STRUCTURE_LANDMARK
    STRUCTURE_RUIN
    STRUCTURE_CAMP
    STRUCTURE_TOWER
    STRUCTURE_CUSTOM
end

"""
    StructureDef

Definition of a structure type for procedural placement.
"""
struct StructureDef
    structure_type::StructureType
    name::String
    prefab_path::String                     # Path to prefab/scene file to instantiate
    min_spacing::Float32                    # Minimum world-space distance from other structures
    biome_filter::Vector{BiomeType}         # Allowed biomes (empty = all)
    min_flatness::Float32                   # Minimum terrain flatness (0=any, 1=perfectly flat)
    rarity::Float32                         # Probability threshold (0=never, 1=always)
    flatten_radius::Float32                 # Flatten terrain around placement (world units)
    footprint::Vec2f                        # Structure footprint for flatness check

    StructureDef(structure_type::StructureType, name::String, prefab_path::String;
                 min_spacing::Float32 = 200.0f0,
                 biome_filter::Vector{BiomeType} = BiomeType[],
                 min_flatness::Float32 = 0.6f0,
                 rarity::Float32 = 0.3f0,
                 flatten_radius::Float32 = 20.0f0,
                 footprint::Vec2f = Vec2f(30.0f0, 30.0f0)
    ) = new(structure_type, name, prefab_path, min_spacing, biome_filter,
            min_flatness, rarity, flatten_radius, footprint)
end

"""
    WorldStructureComponent <: Component

Component for procedural structure/POI placement.
"""
struct WorldStructureComponent <: Component
    definitions::Vector{StructureDef}
    spawn_radius::Float32           # How far from player to spawn structure entities
    despawn_radius::Float32         # When to remove structure entities (keep placement data)

    WorldStructureComponent(;
        definitions::Vector{StructureDef} = StructureDef[],
        spawn_radius::Float32 = 300.0f0,
        despawn_radius::Float32 = 400.0f0
    ) = new(definitions, spawn_radius, despawn_radius)
end
