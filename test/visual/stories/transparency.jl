# Transparency stories

@visual_story "transparent_sphere_over_cube" begin
    scene([
        _test_camera(position=Vec3d(0, 2, 4)),
        _test_sun(),
        # Opaque red cube behind
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1), roughness=0.5f0),
            transform(position=Vec3d(0, 0.5, -1))
        ]),
        # Semi-transparent blue sphere in front
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(
                color=RGB{Float32}(0.2, 0.4, 0.9),
                opacity=0.5f0,
                roughness=0.2f0
            ),
            transform(position=Vec3d(0, 0.6, 1))
        ]),
        _test_floor()
    ])
end
