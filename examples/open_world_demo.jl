# Open World Demo
# Demonstrates the full procedural world generation pipeline:
# - World seed for reproducible worlds
# - Biome system with temperature/moisture-driven classification
# - Hydraulic erosion for realistic terrain
# - Infinite chunk streaming around the player
# - Procedural vegetation placement
# - Structure/POI placement

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# ---- World Generation Config ----

# Single seed controls the entire world
world_seed = WorldSeed("open_reality_demo_2024")

# Configure the world generator
world_gen = WorldGeneratorConfig(
    seed=world_seed,
    biome_defs=default_biome_defs(),
    # Climate noise (large-scale biome distribution)
    temperature_frequency=0.002,
    temperature_octaves=4,
    moisture_frequency=0.003,
    moisture_octaves=4,
    # Base terrain noise
    base_frequency=0.008,
    base_octaves=6,
    base_persistence=0.5,
    base_max_height=60.0f0,
    # Erosion for natural valleys and ridges
    erosion_enabled=true,
    erosion_params=ErosionParams(
        num_droplets=50000,
        inertia=0.05f0,
        sediment_capacity=4.0f0,
        erosion_speed=0.3f0,
        deposition_speed=0.3f0,
        evaporation_speed=0.01f0,
        gravity=4.0f0,
        max_droplet_lifetime=30,
        erosion_radius=3
    )
)

# Streaming config for infinite world
streaming = StreamingConfig(
    load_radius=6,          # Load chunks within 6 chunks of player
    unload_radius=10,       # Unload beyond 10 chunks
    max_loads_per_frame=2,  # Budget: 2 chunk loads per frame
    max_uploads_per_frame=2,
    chunk_world_size=64.0f0,    # Each chunk is 64x64 world units
    chunk_resolution=33         # 33x33 vertices per chunk
)

# Vegetation definitions
vegetation = VegetationComponent(
    definitions=[
        # Trees in forests and grasslands
        VegetationDef(VEG_TREE, "Pine", "";
            density=0.01f0,
            min_slope=0.0f0, max_slope=0.6f0,
            min_altitude=0.1f0, max_altitude=0.7f0,
            scale_min=0.8f0, scale_max=1.5f0,
            biome_filter=[BIOME_TEMPERATE_FOREST, BIOME_BOREAL_FOREST],
            cluster_radius=10.0f0, cluster_density=3.0f0
        ),
        # Scattered rocks on mountains
        VegetationDef(VEG_ROCK, "Boulder", "";
            density=0.005f0,
            min_slope=0.2f0, max_slope=1.2f0,
            min_altitude=0.4f0, max_altitude=1.0f0,
            scale_min=0.5f0, scale_max=2.0f0,
            rotation_random=true,
            biome_filter=[BIOME_MOUNTAIN, BIOME_TUNDRA]
        ),
        # Grass in grasslands and forests
        VegetationDef(VEG_GRASS, "Grass", "";
            density=0.5f0,
            min_slope=0.0f0, max_slope=0.4f0,
            min_altitude=0.05f0, max_altitude=0.5f0,
            scale_min=0.7f0, scale_max=1.0f0,
            biome_filter=[BIOME_GRASSLAND, BIOME_SAVANNA, BIOME_TEMPERATE_FOREST]
        ),
    ],
    scatter_radius=150.0f0,
    fade_distance=130.0f0
)

# Structure definitions
structures = WorldStructureComponent(
    definitions=[
        StructureDef(STRUCTURE_TOWER, "Watchtower", "";
            min_spacing=400.0f0,
            biome_filter=[BIOME_GRASSLAND, BIOME_SAVANNA],
            min_flatness=0.7f0,
            rarity=0.2f0,
            flatten_radius=15.0f0,
            footprint=Vec2f(10.0f0, 10.0f0)
        ),
        StructureDef(STRUCTURE_RUIN, "Ancient Ruin", "";
            min_spacing=600.0f0,
            biome_filter=[BIOME_DESERT, BIOME_MOUNTAIN],
            min_flatness=0.5f0,
            rarity=0.15f0,
            flatten_radius=25.0f0,
            footprint=Vec2f(20.0f0, 20.0f0)
        ),
        StructureDef(STRUCTURE_CAMP, "Campsite", "";
            min_spacing=250.0f0,
            biome_filter=[BIOME_TEMPERATE_FOREST, BIOME_BOREAL_FOREST],
            min_flatness=0.6f0,
            rarity=0.25f0,
            flatten_radius=10.0f0,
            footprint=Vec2f(8.0f0, 8.0f0)
        ),
    ],
    spawn_radius=250.0f0,
    despawn_radius=350.0f0
)

# ---- Create the World Entity ----

world_entity = entity([
    TerrainComponent(
        terrain_size=Vec2f(64.0f0, 64.0f0),   # Per-chunk size (matches streaming config)
        max_height=60.0f0,
        chunk_size=33,
        num_lod_levels=3
    ),
    WorldGeneratorComponent(
        config=world_gen,
        streaming=streaming
    ),
    vegetation,
    structures,
    transform()
])

# ---- Scene Setup ----

s = scene([
    # Player starts at world origin, high enough to be above terrain
    create_player(position=Vec3d(0, 80, 0)),

    # Sunlight (warm, angled to show terrain relief)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -0.8, -0.4),
            color=RGB{Float32}(1.0, 0.95, 0.9),
            intensity=3.0f0
        )
    ]),

    # Ambient fill light
    entity([
        DirectionalLightComponent(
            direction=Vec3f(-0.3, -0.2, 0.5),
            color=RGB{Float32}(0.4, 0.5, 0.7),
            intensity=0.5f0
        )
    ]),

    world_entity,
])

@info "Open World Demo"
@info "  Seed: \"open_reality_demo_2024\""
@info "  Biomes: $(length(default_biome_defs())) types"
@info "  Streaming: $(streaming.load_radius) chunk load radius, $(streaming.chunk_world_size)m chunks"
@info "  Erosion: $(world_gen.erosion_params.num_droplets) droplets per chunk"
@info "  Vegetation: $(length(vegetation.definitions)) types"
@info "  Structures: $(length(structures.definitions)) types"
@info "  Walk around to explore the infinite procedurally generated world!"

render(s, post_process=PostProcessConfig(
    bloom_enabled=true,
    bloom_intensity=0.1f0,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true,
    fog_enabled=true,
    fog_mode=FOG_EXPONENTIAL2,
    fog_density=0.003f0,
    fog_color=RGB{Float32}(0.7, 0.8, 0.95),
    vignette_enabled=true,
    vignette_intensity=0.2f0
))
