# Shadow casting stories

@visual_story "shadow_single_cube" begin
    scene([
        _test_camera(position=Vec3d(3, 4, 5)),
        # Strong directional light to cast visible shadow
        entity([DirectionalLightComponent(
            direction=Vec3f(0.5, -1.0, -0.3),
            intensity=3.0f0
        )]),
        # Floating cube that casts shadow onto floor
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.7, 0.2, 0.2), roughness=0.5f0),
            transform(position=Vec3d(0, 2, 0))
        ]),
        _test_floor(width=15.0f0)
    ])
end

@visual_story "shadow_multi_cascade" begin
    scene([
        _test_camera(position=Vec3d(0, 5, 10)),
        entity([DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.5f0
        )]),
        # Near object
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.8, 0.3, 0.2), roughness=0.4f0),
            transform(position=Vec3d(-1, 0.5, 2))
        ]),
        # Mid object
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(color=RGB{Float32}(0.2, 0.6, 0.8), roughness=0.3f0),
            transform(position=Vec3d(1, 0.6, -2))
        ]),
        # Far object
        entity([
            cube_mesh(size=2.0f0),
            MaterialComponent(color=RGB{Float32}(0.3, 0.8, 0.3), roughness=0.5f0),
            transform(position=Vec3d(0, 1, -8))
        ]),
        _test_floor(width=25.0f0)
    ])
end
