# UI rendering stories
# These use the UI callback to render immediate-mode UI elements

visual_story("ui_text_label",
    () -> scene([
        _test_camera(),
        _test_sun(),
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.5f0),
            transform(position=Vec3d(0, 0.5, 0))
        ]),
        _test_floor()
    ]);
    per_channel_threshold=3,
    max_diff_fraction=0.01
)

visual_story("ui_button_widget",
    () -> scene([
        _test_camera(),
        _test_sun(),
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(color=RGB{Float32}(0.3, 0.6, 0.8), roughness=0.4f0),
            transform(position=Vec3d(0, 0.6, 0))
        ]),
        _test_floor()
    ]);
    per_channel_threshold=3,
    max_diff_fraction=0.01
)
