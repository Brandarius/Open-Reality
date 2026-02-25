# Lighting variation stories

@visual_story "directional_light_only" begin
    scene([
        _test_camera(),
        entity([DirectionalLightComponent(
            direction=Vec3f(0.5, -1.0, -0.3),
            intensity=2.5f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )]),
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.8, 0.8, 0.8), roughness=0.5f0),
            transform(position=Vec3d(0, 0.5, 0))
        ]),
        _test_floor()
    ])
end

@visual_story "point_light_warm" begin
    scene([
        _test_camera(),
        entity([
            PointLightComponent(
                color=RGB{Float32}(1.0, 0.8, 0.5),
                intensity=40.0f0,
                range=15.0f0
            ),
            transform(position=Vec3d(2, 3, 1))
        ]),
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.8, 0.8, 0.8), roughness=0.5f0),
            transform(position=Vec3d(0, 0.5, 0))
        ]),
        _test_floor()
    ])
end

@visual_story "multiple_lights" begin
    scene([
        _test_camera(position=Vec3d(0, 3, 6)),
        # Directional (ambient fill)
        entity([DirectionalLightComponent(direction=Vec3f(0, -1, 0), intensity=0.5f0)]),
        # Red point light left
        entity([
            PointLightComponent(color=RGB{Float32}(1.0, 0.2, 0.1), intensity=30.0f0, range=12.0f0),
            transform(position=Vec3d(-3, 2, 0))
        ]),
        # Blue point light right
        entity([
            PointLightComponent(color=RGB{Float32}(0.1, 0.3, 1.0), intensity=30.0f0, range=12.0f0),
            transform(position=Vec3d(3, 2, 0))
        ]),
        entity([
            sphere_mesh(radius=0.8f0),
            MaterialComponent(color=RGB{Float32}(0.9, 0.9, 0.9), metallic=0.5f0, roughness=0.3f0),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ])
end
