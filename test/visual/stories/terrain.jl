# Terrain rendering story

visual_story("terrain_basic_patch",
    () -> scene([
        _test_camera(position=Vec3d(0, 15, 25)),
        _test_sun(direction=Vec3f(0.2, -1.0, -0.3), intensity=2.0f0),
        entity([
            TerrainComponent(
                heightmap=HeightmapSource(),  # Default Perlin noise
                terrain_size=Vec2f(64.0f0, 64.0f0),
                max_height=10.0f0,
                chunk_size=33,
                num_lod_levels=2
            ),
            transform(position=Vec3d(-32, 0, -32))
        ])
    ]);
    n_frames=5,  # Terrain needs more frames for chunk initialization
    per_channel_threshold=3,
    max_diff_fraction=0.02  # Terrain LOD can vary slightly
)
