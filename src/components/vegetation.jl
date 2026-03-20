# Vegetation component: definitions for procedural foliage placement

"""
    VegetationType

Category of vegetation for rendering and behavior classification.
"""
@enum VegetationType begin
    VEG_TREE
    VEG_BUSH
    VEG_GRASS
    VEG_ROCK
    VEG_FLOWER
    VEG_CUSTOM
end

"""
    VegetationDef

Definition of a single vegetation type for procedural placement.
"""
struct VegetationDef
    veg_type::VegetationType
    name::String
    mesh_path::String                       # Path to mesh (loaded via asset system)
    density::Float32                        # Instances per square world unit
    min_slope::Float32                      # Minimum terrain slope (radians, 0 = flat)
    max_slope::Float32                      # Maximum terrain slope (radians)
    min_altitude::Float32                   # Normalized altitude range [0,1]
    max_altitude::Float32
    scale_min::Float32                      # Random scale range
    scale_max::Float32
    rotation_random::Bool                   # Random Y-axis rotation
    align_to_terrain::Bool                  # Align up-vector to terrain normal
    biome_filter::Vector{BiomeType}         # Only spawn in these biomes (empty = all)
    cluster_radius::Float32                 # 0 = uniform, >0 = clustered placement
    cluster_density::Float32                # Density multiplier within clusters

    VegetationDef(veg_type::VegetationType, name::String, mesh_path::String;
                  density::Float32 = 0.1f0,
                  min_slope::Float32 = 0.0f0,
                  max_slope::Float32 = 0.8f0,
                  min_altitude::Float32 = 0.0f0,
                  max_altitude::Float32 = 1.0f0,
                  scale_min::Float32 = 0.8f0,
                  scale_max::Float32 = 1.2f0,
                  rotation_random::Bool = true,
                  align_to_terrain::Bool = false,
                  biome_filter::Vector{BiomeType} = BiomeType[],
                  cluster_radius::Float32 = 0.0f0,
                  cluster_density::Float32 = 2.0f0
    ) = new(veg_type, name, mesh_path, density, min_slope, max_slope,
            min_altitude, max_altitude, scale_min, scale_max,
            rotation_random, align_to_terrain, biome_filter,
            cluster_radius, cluster_density)
end

"""
    VegetationComponent <: Component

Component for procedural vegetation placement around the player.
"""
struct VegetationComponent <: Component
    definitions::Vector{VegetationDef}
    scatter_radius::Float32         # How far from player to scatter (world units)
    fade_distance::Float32          # Distance at which instances fade out

    VegetationComponent(;
        definitions::Vector{VegetationDef} = VegetationDef[],
        scatter_radius::Float32 = 200.0f0,
        fade_distance::Float32 = 180.0f0
    ) = new(definitions, scatter_radius, fade_distance)
end
