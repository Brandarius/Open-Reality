# LOD system stories

@visual_story "lod_sphere_close" begin
    # High-detail sphere at close range (should use LOD 0)
    scene([
        _test_camera(position=Vec3d(0, 1.5, 3)),
        _test_sun(),
        entity([
            sphere_mesh(radius=0.8f0, segments=32, rings=16),
            MaterialComponent(color=RGB{Float32}(0.6, 0.3, 0.8), metallic=0.5f0, roughness=0.3f0),
            LODComponent(levels=[
                LODLevel(mesh=sphere_mesh(radius=0.8f0, segments=32, rings=16), max_distance=5.0f0),
                LODLevel(mesh=sphere_mesh(radius=0.8f0, segments=16, rings=8), max_distance=15.0f0),
                LODLevel(mesh=sphere_mesh(radius=0.8f0, segments=8, rings=4), max_distance=50.0f0)
            ]),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ])
end
