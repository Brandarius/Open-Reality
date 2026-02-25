# Post-processing effect stories
# Higher tolerance since post-fx can vary more across GPUs

visual_story("postfx_bloom",
    () -> scene([
        _test_camera(position=Vec3d(0, 1.5, 4)),
        _test_sun(intensity=3.0f0),
        # Bright emissive sphere to trigger bloom
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(
                color=RGB{Float32}(1.0, 0.8, 0.5),
                emissive_factor=Vec3f(5.0, 3.0, 1.0),
                roughness=0.3f0
            ),
            transform(position=Vec3d(0, 0.6, 0))
        ]),
        _test_floor()
    ]);
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.5f0,
        tone_mapping=TONEMAP_ACES
    ),
    per_channel_threshold=3,
    max_diff_fraction=0.01
)

visual_story("postfx_dof",
    () -> scene([
        _test_camera(position=Vec3d(0, 2, 6)),
        _test_sun(),
        # Near object (in focus)
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.9, 0.2, 0.2), roughness=0.4f0),
            transform(position=Vec3d(-1, 0.5, 2))
        ]),
        # Far object (out of focus)
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(color=RGB{Float32}(0.2, 0.5, 0.9), roughness=0.4f0),
            transform(position=Vec3d(1, 0.6, -4))
        ]),
        _test_floor(width=15.0f0)
    ]);
    post_process=PostProcessConfig(
        dof_enabled=true,
        dof_focus_distance=8.0f0,
        dof_focus_range=3.0f0,
        dof_bokeh_radius=4.0f0,
        tone_mapping=TONEMAP_ACES
    ),
    per_channel_threshold=3,
    max_diff_fraction=0.01
)

visual_story("postfx_vignette",
    () -> scene([
        _test_camera(),
        _test_sun(),
        entity([
            sphere_mesh(radius=0.8f0),
            MaterialComponent(color=RGB{Float32}(0.7, 0.7, 0.8), roughness=0.3f0, metallic=0.5f0),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ]);
    post_process=PostProcessConfig(
        vignette_enabled=true,
        vignette_intensity=0.6f0,
        vignette_radius=0.7f0,
        vignette_softness=0.4f0,
        tone_mapping=TONEMAP_ACES
    ),
    per_channel_threshold=3,
    max_diff_fraction=0.01
)

visual_story("postfx_color_grading",
    () -> scene([
        _test_camera(),
        _test_sun(),
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.8, 0.4, 0.2), roughness=0.5f0),
            transform(position=Vec3d(0, 0.5, 0))
        ]),
        _test_floor()
    ]);
    post_process=PostProcessConfig(
        color_grading_enabled=true,
        color_grading_brightness=0.1f0,
        color_grading_contrast=1.3f0,
        color_grading_saturation=1.5f0,
        tone_mapping=TONEMAP_ACES
    ),
    per_channel_threshold=3,
    max_diff_fraction=0.01
)
