# Instanced rendering story

@visual_story "instanced_cube_grid" begin
    entities = Any[
        _test_camera(position=Vec3d(0, 8, 12)),
        _test_sun()
    ]

    # 5x5 grid of cubes — tests instanced rendering batching
    for ix in -2:2, iz in -2:2
        push!(entities, entity([
            cube_mesh(size=0.8f0),
            MaterialComponent(
                color=RGB{Float32}(
                    Float32((ix + 2) / 4),
                    Float32(0.3),
                    Float32((iz + 2) / 4)
                ),
                metallic=0.5f0,
                roughness=0.4f0
            ),
            transform(position=Vec3d(ix * 2.0, 0.4, iz * 2.0))
        ]))
    end

    push!(entities, _test_floor(width=15.0f0))
    scene(entities)
end
