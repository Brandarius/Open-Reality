# Material variation stories — tests PBR across metallic/roughness range

for (m, r) in [(0.0f0, 0.1f0), (0.0f0, 0.9f0), (1.0f0, 0.1f0), (1.0f0, 0.9f0)]
    m_label = m == 0.0f0 ? "dielectric" : "metallic"
    r_label = r < 0.5f0 ? "smooth" : "rough"

    visual_story("material_$(m_label)_$(r_label)",
        () -> scene([
            _test_camera(position=Vec3d(0, 1.5, 3)),
            _test_sun(),
            entity([
                sphere_mesh(radius=0.8f0),
                MaterialComponent(
                    color=RGB{Float32}(0.8, 0.3, 0.3),
                    metallic=m,
                    roughness=r
                ),
                transform(position=Vec3d(0, 0.8, 0))
            ]),
            _test_floor()
        ])
    )
end

# Emissive material
@visual_story "material_emissive" begin
    scene([
        _test_camera(position=Vec3d(0, 1.5, 3)),
        _test_sun(intensity=0.5f0),  # Low ambient so emissive is visible
        entity([
            sphere_mesh(radius=0.8f0),
            MaterialComponent(
                color=RGB{Float32}(0.1, 0.1, 0.1),
                emissive_factor=Vec3f(3.0, 1.0, 0.3),
                roughness=0.5f0
            ),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ])
end

# Clearcoat material
@visual_story "material_clearcoat" begin
    scene([
        _test_camera(position=Vec3d(0, 1.5, 3)),
        _test_sun(),
        entity([
            sphere_mesh(radius=0.8f0),
            MaterialComponent(
                color=RGB{Float32}(0.6, 0.1, 0.1),
                metallic=0.8f0,
                roughness=0.6f0,
                clearcoat=1.0f0,
                clearcoat_roughness=0.1f0
            ),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ])
end
