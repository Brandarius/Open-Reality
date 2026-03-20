# Terrain component: heightmap-based terrain with splatmap multi-texturing

"""
    HeightmapSourceType

How the heightmap data is generated.
"""
@enum HeightmapSourceType HEIGHTMAP_IMAGE HEIGHTMAP_PERLIN HEIGHTMAP_FLAT HEIGHTMAP_SIMPLEX HEIGHTMAP_RIDGED HEIGHTMAP_CUSTOM

"""
    HeightmapSource

Specifies where heightmap data comes from.
"""
struct HeightmapSource
    source_type::HeightmapSourceType
    image_path::String          # Used when source_type == HEIGHTMAP_IMAGE
    perlin_octaves::Int         # FBM noise octaves (HEIGHTMAP_PERLIN)
    perlin_frequency::Float32   # Base noise frequency (HEIGHTMAP_PERLIN)
    perlin_persistence::Float32 # Amplitude decay per octave
    perlin_seed::Int            # Random seed
    world_seed::Union{WorldSeed, Nothing}  # Master seed (overrides perlin_seed when set)

    HeightmapSource(;
        source_type::HeightmapSourceType = HEIGHTMAP_PERLIN,
        image_path::String = "",
        perlin_octaves::Int = 6,
        perlin_frequency::Float32 = 0.01f0,
        perlin_persistence::Float32 = 0.5f0,
        perlin_seed::Int = 42,
        world_seed::Union{WorldSeed, Nothing} = nothing
    ) = new(source_type, image_path, perlin_octaves, perlin_frequency, perlin_persistence, perlin_seed, world_seed)
end

"""
    TerrainLayer

One texture layer for terrain splatmap blending.
"""
struct TerrainLayer
    albedo_path::String
    normal_path::String
    uv_scale::Float32

    TerrainLayer(;
        albedo_path::String = "",
        normal_path::String = "",
        uv_scale::Float32 = 10.0f0
    ) = new(albedo_path, normal_path, uv_scale)
end

"""
    TerrainComponent <: Component

Terrain entity component. Defines a heightmap-based terrain with up to 4 splatmap texture layers.
"""
struct TerrainComponent <: Component
    heightmap::HeightmapSource
    terrain_size::Vec2f         # World-space X, Z dimensions
    max_height::Float32         # Maximum height above ground
    chunk_size::Int             # Vertices per chunk edge
    num_lod_levels::Int         # Number of LOD levels per chunk
    splatmap_path::String       # RGBA splatmap image (4 channel = 4 layers)
    layers::Vector{TerrainLayer}

    TerrainComponent(;
        heightmap::HeightmapSource = HeightmapSource(),
        terrain_size::Vec2f = Vec2f(256.0f0, 256.0f0),
        max_height::Float32 = 50.0f0,
        chunk_size::Int = 33,
        num_lod_levels::Int = 3,
        splatmap_path::String = "",
        layers::Vector{TerrainLayer} = TerrainLayer[]
    ) = new(heightmap, terrain_size, max_height, chunk_size, num_lod_levels, splatmap_path, layers)
end
