# World generator component: top-level configuration for procedural world generation

"""
    WorldGeneratorConfig

Complete configuration for procedural world generation.
Ties together seed, biomes, terrain noise, and erosion settings.
"""
struct WorldGeneratorConfig
    seed::WorldSeed
    biome_defs::Vector{BiomeDef}
    # Climate noise settings
    temperature_frequency::Float64
    temperature_octaves::Int
    moisture_frequency::Float64
    moisture_octaves::Int
    # Base terrain settings
    base_frequency::Float64
    base_octaves::Int
    base_persistence::Float64
    base_max_height::Float32
    # Erosion settings
    erosion_enabled::Bool
    erosion_params::Union{ErosionParams, Nothing}

    WorldGeneratorConfig(;
        seed::WorldSeed = WorldSeed(42),
        biome_defs::Vector{BiomeDef} = default_biome_defs(),
        temperature_frequency::Float64 = 0.005,
        temperature_octaves::Int = 4,
        moisture_frequency::Float64 = 0.007,
        moisture_octaves::Int = 4,
        base_frequency::Float64 = 0.01,
        base_octaves::Int = 6,
        base_persistence::Float64 = 0.5,
        base_max_height::Float32 = 50.0f0,
        erosion_enabled::Bool = false,
        erosion_params::Union{ErosionParams, Nothing} = nothing
    ) = new(seed, biome_defs,
            temperature_frequency, temperature_octaves,
            moisture_frequency, moisture_octaves,
            base_frequency, base_octaves, base_persistence, base_max_height,
            erosion_enabled, erosion_params)
end

"""
    StreamingConfig

Configuration for chunk streaming (infinite terrain).
"""
struct StreamingConfig
    load_radius::Int            # Chunks ahead of player to load
    unload_radius::Int          # Distance at which chunks are unloaded
    max_loads_per_frame::Int    # Async completions processed per frame
    max_uploads_per_frame::Int  # GPU uploads per frame
    chunk_world_size::Float32   # World-space size of one chunk edge
    chunk_resolution::Int       # Vertices per chunk edge

    StreamingConfig(;
        load_radius::Int = 8,
        unload_radius::Int = 12,
        max_loads_per_frame::Int = 4,
        max_uploads_per_frame::Int = 2,
        chunk_world_size::Float32 = 64.0f0,
        chunk_resolution::Int = 33
    ) = new(load_radius, unload_radius, max_loads_per_frame, max_uploads_per_frame,
            chunk_world_size, chunk_resolution)
end

"""
    WorldGeneratorComponent <: Component

Top-level component for procedural open world generation.
Attach this to a terrain entity to enable biomes, streaming, vegetation, and structures.
"""
struct WorldGeneratorComponent <: Component
    config::WorldGeneratorConfig
    streaming::Union{StreamingConfig, Nothing}

    WorldGeneratorComponent(;
        config::WorldGeneratorConfig = WorldGeneratorConfig(),
        streaming::Union{StreamingConfig, Nothing} = nothing
    ) = new(config, streaming)
end
