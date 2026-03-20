# Biome system: climate-driven biome classification with Whittaker-diagram approach
#
# Generates temperature and moisture maps from noise, classifies biomes,
# and produces blended splatmaps for smooth biome transitions.

"""
    BiomeType

Enumeration of biome categories for terrain classification.
"""
@enum BiomeType begin
    BIOME_OCEAN
    BIOME_BEACH
    BIOME_DESERT
    BIOME_SAVANNA
    BIOME_GRASSLAND
    BIOME_TEMPERATE_FOREST
    BIOME_BOREAL_FOREST
    BIOME_TUNDRA
    BIOME_SNOW
    BIOME_SWAMP
    BIOME_TROPICAL_FOREST
    BIOME_MOUNTAIN
    BIOME_CUSTOM
end

"""
    BiomeDef

Definition of a single biome with climate ranges, terrain modifiers, and visual properties.
"""
struct BiomeDef
    biome_type::BiomeType
    name::String
    # Climate ranges (normalized 0..1)
    temperature_min::Float32
    temperature_max::Float32
    moisture_min::Float32
    moisture_max::Float32
    elevation_min::Float32
    elevation_max::Float32
    # Terrain modifiers
    height_scale::Float32           # Multiplier on base heightmap
    height_offset::Float32          # Added to base height (world units)
    noise_frequency_scale::Float32  # Local detail frequency modifier
    # Visual properties
    terrain_layers::Vector{TerrainLayer}
    # Vegetation density multiplier (used in Phase 6)
    vegetation_density::Float32
    # Biome transition blend width (normalized, 0..1)
    blend_width::Float32

    BiomeDef(biome_type::BiomeType, name::String;
             temperature_min::Float32 = 0.0f0, temperature_max::Float32 = 1.0f0,
             moisture_min::Float32 = 0.0f0, moisture_max::Float32 = 1.0f0,
             elevation_min::Float32 = 0.0f0, elevation_max::Float32 = 1.0f0,
             height_scale::Float32 = 1.0f0, height_offset::Float32 = 0.0f0,
             noise_frequency_scale::Float32 = 1.0f0,
             terrain_layers::Vector{TerrainLayer} = TerrainLayer[],
             vegetation_density::Float32 = 1.0f0,
             blend_width::Float32 = 0.05f0
    ) = new(biome_type, name, temperature_min, temperature_max,
            moisture_min, moisture_max, elevation_min, elevation_max,
            height_scale, height_offset, noise_frequency_scale,
            terrain_layers, vegetation_density, blend_width)
end

"""
    BiomeMap

Computed biome classification data for a terrain region.
"""
struct BiomeMap
    temperature::Matrix{Float32}
    moisture::Matrix{Float32}
    biome_ids::Matrix{Int}                  # Index into biome_defs vector
    blend_weights::Array{Float32, 3}        # (x, z, max_blend_biomes) — weights for blending
    blend_indices::Array{Int, 3}            # (x, z, max_blend_biomes) — biome indices for blending
    max_blend_biomes::Int
end

const MAX_BLEND_BIOMES = 4

"""
    classify_biome(temp, moisture, elevation, biome_defs) -> Int

Find the best-matching biome index using Whittaker-diagram classification.
Returns the index into `biome_defs` of the biome whose climate ranges best match.
"""
function classify_biome(temp::Float32, moisture::Float32, elevation::Float32,
                        biome_defs::Vector{BiomeDef})::Int
    best_idx = 1
    best_score = -Inf32

    for (idx, bd) in enumerate(biome_defs)
        # Check if point falls within biome's climate envelope
        in_temp = bd.temperature_min <= temp <= bd.temperature_max
        in_moist = bd.moisture_min <= moisture <= bd.moisture_max
        in_elev = bd.elevation_min <= elevation <= bd.elevation_max

        if in_temp && in_moist && in_elev
            # Score by how centrally the point falls in the biome's ranges
            tc = 1.0f0 - 2.0f0 * abs(temp - (bd.temperature_min + bd.temperature_max) / 2.0f0) /
                 max(bd.temperature_max - bd.temperature_min, 0.001f0)
            mc = 1.0f0 - 2.0f0 * abs(moisture - (bd.moisture_min + bd.moisture_max) / 2.0f0) /
                 max(bd.moisture_max - bd.moisture_min, 0.001f0)
            ec = 1.0f0 - 2.0f0 * abs(elevation - (bd.elevation_min + bd.elevation_max) / 2.0f0) /
                 max(bd.elevation_max - bd.elevation_min, 0.001f0)
            score = tc + mc + ec
            if score > best_score
                best_score = score
                best_idx = idx
            end
        end
    end

    return best_idx
end

"""
    _compute_biome_blend_weights(temp, moisture, elevation, biome_defs) -> (indices, weights)

Compute blend weights for the top N closest biomes at a given point.
"""
function _compute_biome_blend_weights(temp::Float32, moisture::Float32, elevation::Float32,
                                      biome_defs::Vector{BiomeDef})
    scores = Vector{Tuple{Int, Float32}}()

    for (idx, bd) in enumerate(biome_defs)
        # Distance from biome center (lower = better match)
        tc = (temp - (bd.temperature_min + bd.temperature_max) / 2.0f0) /
             max(bd.temperature_max - bd.temperature_min, 0.001f0)
        mc = (moisture - (bd.moisture_min + bd.moisture_max) / 2.0f0) /
             max(bd.moisture_max - bd.moisture_min, 0.001f0)
        ec = (elevation - (bd.elevation_min + bd.elevation_max) / 2.0f0) /
             max(bd.elevation_max - bd.elevation_min, 0.001f0)
        dist = sqrt(tc^2 + mc^2 + ec^2)
        # Convert distance to weight (inverse, with blend_width falloff)
        weight = max(0.0f0, 1.0f0 - dist / max(bd.blend_width * 10.0f0, 0.1f0))
        if weight > 0.0f0
            push!(scores, (idx, weight))
        end
    end

    # Sort by weight descending, take top MAX_BLEND_BIOMES
    sort!(scores, by=x -> -x[2])
    n = min(MAX_BLEND_BIOMES, length(scores))
    if n == 0
        return ([1], [1.0f0])
    end

    indices = [scores[i][1] for i in 1:n]
    weights = [scores[i][2] for i in 1:n]

    # Normalize weights
    total = sum(weights)
    if total > 0.0f0
        weights ./= total
    else
        weights[1] = 1.0f0
    end

    return (indices, weights)
end

"""
    generate_biome_map(seed::WorldSeed, biome_defs, res_x, res_z;
                       temperature_frequency, temperature_octaves,
                       moisture_frequency, moisture_octaves) -> BiomeMap

Generate temperature/moisture maps from noise, classify biomes, compute blend weights.
"""
function generate_biome_map(seed::WorldSeed, biome_defs::Vector{BiomeDef},
                            res_x::Int, res_z::Int;
                            temperature_frequency::Float64 = 0.005,
                            temperature_octaves::Int = 4,
                            moisture_frequency::Float64 = 0.007,
                            moisture_octaves::Int = 4)::BiomeMap
    temp_seed = derive_seed(seed, "temperature")
    moist_seed = derive_seed(seed, "moisture")

    temperature = Matrix{Float32}(undef, res_x + 1, res_z + 1)
    moisture = Matrix{Float32}(undef, res_x + 1, res_z + 1)
    biome_ids = Matrix{Int}(undef, res_x + 1, res_z + 1)
    blend_weights = zeros(Float32, res_x + 1, res_z + 1, MAX_BLEND_BIOMES)
    blend_indices = ones(Int, res_x + 1, res_z + 1, MAX_BLEND_BIOMES)

    for iz in 0:res_z, ix in 0:res_x
        # Generate climate values from noise (mapped to [0, 1])
        t = Float32(simplex_fbm_2d(Float64(ix), Float64(iz);
                                    octaves=temperature_octaves,
                                    frequency=temperature_frequency,
                                    seed=temp_seed) * 0.5 + 0.5)
        m = Float32(simplex_fbm_2d(Float64(ix), Float64(iz);
                                    octaves=moisture_octaves,
                                    frequency=moisture_frequency,
                                    seed=moist_seed) * 0.5 + 0.5)
        t = clamp(t, 0.0f0, 1.0f0)
        m = clamp(m, 0.0f0, 1.0f0)

        temperature[ix + 1, iz + 1] = t
        moisture[ix + 1, iz + 1] = m

        # Classify biome (elevation set to 0.5 default; will be updated after heightmap)
        biome_ids[ix + 1, iz + 1] = classify_biome(t, m, 0.5f0, biome_defs)

        # Compute blend weights
        idxs, wts = _compute_biome_blend_weights(t, m, 0.5f0, biome_defs)
        for k in 1:min(length(idxs), MAX_BLEND_BIOMES)
            blend_indices[ix + 1, iz + 1, k] = idxs[k]
            blend_weights[ix + 1, iz + 1, k] = wts[k]
        end
    end

    return BiomeMap(temperature, moisture, biome_ids, blend_weights, blend_indices, MAX_BLEND_BIOMES)
end

"""
    update_biome_map_elevation!(biome_map::BiomeMap, heightmap::Matrix{Float32},
                                max_height::Float32, biome_defs::Vector{BiomeDef})

Re-classify biomes after heightmap is generated, incorporating elevation data.
"""
function update_biome_map_elevation!(biome_map::BiomeMap, heightmap::Matrix{Float32},
                                     max_height::Float32, biome_defs::Vector{BiomeDef})
    rows, cols = size(heightmap)
    for iz in 1:cols, ix in 1:rows
        elev = max_height > 0.0f0 ? heightmap[ix, iz] / max_height : 0.5f0
        elev = clamp(elev, 0.0f0, 1.0f0)
        t = biome_map.temperature[ix, iz]
        m = biome_map.moisture[ix, iz]

        biome_map.biome_ids[ix, iz] = classify_biome(t, m, elev, biome_defs)

        idxs, wts = _compute_biome_blend_weights(t, m, elev, biome_defs)
        # Reset blend data
        for k in 1:MAX_BLEND_BIOMES
            biome_map.blend_indices[ix, iz, k] = 1
            biome_map.blend_weights[ix, iz, k] = 0.0f0
        end
        for k in 1:min(length(idxs), MAX_BLEND_BIOMES)
            biome_map.blend_indices[ix, iz, k] = idxs[k]
            biome_map.blend_weights[ix, iz, k] = wts[k]
        end
    end
end

"""
    modulate_heightmap_by_biome!(heightmap::Matrix{Float32}, biome_map::BiomeMap,
                                 biome_defs::Vector{BiomeDef})

Apply per-biome height_scale and height_offset to the heightmap.
Uses blend weights for smooth transitions between biomes.
"""
function modulate_heightmap_by_biome!(heightmap::Matrix{Float32}, biome_map::BiomeMap,
                                      biome_defs::Vector{BiomeDef})
    rows, cols = size(heightmap)
    for iz in 1:cols, ix in 1:rows
        h = heightmap[ix, iz]
        new_h = 0.0f0
        total_w = 0.0f0
        for k in 1:MAX_BLEND_BIOMES
            w = biome_map.blend_weights[ix, iz, k]
            if w > 0.0f0
                bd = biome_defs[biome_map.blend_indices[ix, iz, k]]
                new_h += (h * bd.height_scale + bd.height_offset) * w
                total_w += w
            end
        end
        heightmap[ix, iz] = total_w > 0.0f0 ? new_h / total_w : h
    end
end

"""
    generate_biome_splatmap(biome_map::BiomeMap, biome_defs::Vector{BiomeDef},
                            res_x::Int, res_z::Int) -> Matrix{NTuple{4, Float32}}

Generate a biome-aware RGBA splatmap. Each biome's primary terrain layer
maps to one of the 4 splatmap channels. Blend weights create smooth transitions.
"""
function generate_biome_splatmap(biome_map::BiomeMap, biome_defs::Vector{BiomeDef},
                                 res_x::Int, res_z::Int)::Matrix{NTuple{4, Float32}}
    splatmap = Matrix{NTuple{4, Float32}}(undef, res_x + 1, res_z + 1)

    # Map each biome to a splatmap channel (0-3) based on biome type
    biome_channel = Dict{BiomeType, Int}(
        BIOME_GRASSLAND => 1, BIOME_TEMPERATE_FOREST => 1, BIOME_SAVANNA => 1,
        BIOME_TROPICAL_FOREST => 1, BIOME_SWAMP => 1,
        BIOME_MOUNTAIN => 2, BIOME_BOREAL_FOREST => 2, BIOME_TUNDRA => 2,
        BIOME_OCEAN => 3, BIOME_BEACH => 3, BIOME_DESERT => 3,
        BIOME_SNOW => 4,
        BIOME_CUSTOM => 1
    )

    for iz in 1:(res_z + 1), ix in 1:(res_x + 1)
        channels = [0.0f0, 0.0f0, 0.0f0, 0.0f0]
        for k in 1:MAX_BLEND_BIOMES
            w = biome_map.blend_weights[ix, iz, k]
            if w > 0.0f0
                bd = biome_defs[biome_map.blend_indices[ix, iz, k]]
                ch = get(biome_channel, bd.biome_type, 1)
                channels[ch] += w
            end
        end
        # Normalize
        total = sum(channels)
        if total > 0.0f0
            channels ./= total
        else
            channels[1] = 1.0f0
        end
        splatmap[ix, iz] = (channels[1], channels[2], channels[3], channels[4])
    end

    return splatmap
end

"""
    default_biome_defs() -> Vector{BiomeDef}

Sensible default biome definitions for a typical game world.
"""
function default_biome_defs()::Vector{BiomeDef}
    return [
        BiomeDef(BIOME_OCEAN, "Ocean";
                 temperature_min=0.0f0, temperature_max=1.0f0,
                 moisture_min=0.0f0, moisture_max=1.0f0,
                 elevation_min=0.0f0, elevation_max=0.15f0,
                 height_scale=0.3f0, height_offset=-5.0f0),
        BiomeDef(BIOME_BEACH, "Beach";
                 temperature_min=0.3f0, temperature_max=1.0f0,
                 moisture_min=0.0f0, moisture_max=0.5f0,
                 elevation_min=0.1f0, elevation_max=0.2f0,
                 height_scale=0.5f0, vegetation_density=0.1f0),
        BiomeDef(BIOME_DESERT, "Desert";
                 temperature_min=0.7f0, temperature_max=1.0f0,
                 moisture_min=0.0f0, moisture_max=0.2f0,
                 elevation_min=0.15f0, elevation_max=0.6f0,
                 height_scale=0.8f0, noise_frequency_scale=0.5f0,
                 vegetation_density=0.05f0),
        BiomeDef(BIOME_SAVANNA, "Savanna";
                 temperature_min=0.6f0, temperature_max=1.0f0,
                 moisture_min=0.2f0, moisture_max=0.5f0,
                 elevation_min=0.15f0, elevation_max=0.5f0,
                 height_scale=0.7f0, vegetation_density=0.3f0),
        BiomeDef(BIOME_GRASSLAND, "Grassland";
                 temperature_min=0.3f0, temperature_max=0.7f0,
                 moisture_min=0.3f0, moisture_max=0.6f0,
                 elevation_min=0.15f0, elevation_max=0.5f0,
                 height_scale=0.6f0, vegetation_density=0.5f0),
        BiomeDef(BIOME_TEMPERATE_FOREST, "Temperate Forest";
                 temperature_min=0.3f0, temperature_max=0.7f0,
                 moisture_min=0.5f0, moisture_max=0.9f0,
                 elevation_min=0.15f0, elevation_max=0.6f0,
                 height_scale=0.9f0, vegetation_density=0.8f0),
        BiomeDef(BIOME_TROPICAL_FOREST, "Tropical Forest";
                 temperature_min=0.7f0, temperature_max=1.0f0,
                 moisture_min=0.6f0, moisture_max=1.0f0,
                 elevation_min=0.1f0, elevation_max=0.5f0,
                 height_scale=0.8f0, vegetation_density=1.0f0),
        BiomeDef(BIOME_SWAMP, "Swamp";
                 temperature_min=0.4f0, temperature_max=0.8f0,
                 moisture_min=0.8f0, moisture_max=1.0f0,
                 elevation_min=0.1f0, elevation_max=0.3f0,
                 height_scale=0.4f0, height_offset=-2.0f0,
                 vegetation_density=0.6f0),
        BiomeDef(BIOME_BOREAL_FOREST, "Boreal Forest";
                 temperature_min=0.1f0, temperature_max=0.4f0,
                 moisture_min=0.4f0, moisture_max=0.8f0,
                 elevation_min=0.2f0, elevation_max=0.7f0,
                 height_scale=1.0f0, vegetation_density=0.7f0),
        BiomeDef(BIOME_TUNDRA, "Tundra";
                 temperature_min=0.0f0, temperature_max=0.2f0,
                 moisture_min=0.1f0, moisture_max=0.5f0,
                 elevation_min=0.2f0, elevation_max=0.7f0,
                 height_scale=0.7f0, vegetation_density=0.1f0),
        BiomeDef(BIOME_SNOW, "Snow";
                 temperature_min=0.0f0, temperature_max=0.15f0,
                 moisture_min=0.3f0, moisture_max=1.0f0,
                 elevation_min=0.5f0, elevation_max=1.0f0,
                 height_scale=1.2f0, height_offset=5.0f0,
                 vegetation_density=0.0f0),
        BiomeDef(BIOME_MOUNTAIN, "Mountain";
                 temperature_min=0.0f0, temperature_max=0.5f0,
                 moisture_min=0.0f0, moisture_max=0.6f0,
                 elevation_min=0.65f0, elevation_max=1.0f0,
                 height_scale=1.5f0, height_offset=10.0f0,
                 noise_frequency_scale=1.5f0,
                 vegetation_density=0.15f0),
    ]
end

"""
    get_biome_at(biome_map::BiomeMap, ix::Int, iz::Int, biome_defs::Vector{BiomeDef}) -> BiomeDef

Retrieve the dominant biome definition at a grid position.
"""
function get_biome_at(biome_map::BiomeMap, ix::Int, iz::Int, biome_defs::Vector{BiomeDef})::BiomeDef
    idx = biome_map.biome_ids[ix, iz]
    return biome_defs[clamp(idx, 1, length(biome_defs))]
end
