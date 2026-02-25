# Basic PBR geometry stories

# Helper: standard test camera looking at origin from angle
function _test_camera(; position=Vec3d(0, 2, 5))
    return entity([
        CameraComponent(fov=60.0f0, near=0.1f0, far=100.0f0, aspect=1.0f0, active=true),
        transform(position=position, rotation=_look_at_rotation(position, Vec3d(0, 0, 0)))
    ])
end

# Helper: compute rotation quaternion to look from `from` toward `target`
function _look_at_rotation(from::Vec3d, target::Vec3d)
    dir = target - from
    dir = dir / sqrt(sum(dir .^ 2))  # normalize

    # Pitch angle (looking down)
    pitch = asin(-dir[2])
    # Yaw angle
    yaw = atan(dir[1], dir[3])

    # Construct quaternion from Euler: first yaw (Y), then pitch (X)
    cy = cos(yaw / 2); sy = sin(yaw / 2)
    cp = cos(pitch / 2); sp = sin(pitch / 2)

    # Y rotation * X rotation (ZYX convention adapted)
    w = cy * cp
    x = cy * sp
    y = sy * cp
    z = -sy * sp

    return Quaterniond(w, x, y, z)
end

# Helper: standard sun light
function _test_sun(; direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)
    return entity([DirectionalLightComponent(direction=direction, intensity=intensity)])
end

# Helper: gray floor
function _test_floor(; width=10.0f0)
    return entity([
        plane_mesh(width=width, depth=width),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform()
    ])
end

# --- Stories ---

@visual_story "pbr_red_cube" begin
    scene([
        _test_camera(),
        _test_sun(),
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1), metallic=0.9f0, roughness=0.1f0),
            transform(position=Vec3d(0, 0.5, 0))
        ]),
        _test_floor()
    ])
end

@visual_story "pbr_green_sphere" begin
    scene([
        _test_camera(position=Vec3d(0, 1.5, 3)),
        _test_sun(),
        entity([
            sphere_mesh(radius=0.8f0),
            MaterialComponent(color=RGB{Float32}(0.2, 0.8, 0.2), metallic=0.0f0, roughness=0.4f0),
            transform(position=Vec3d(0, 0.8, 0))
        ]),
        _test_floor()
    ])
end

@visual_story "pbr_multi_object" begin
    scene([
        _test_camera(position=Vec3d(0, 3, 6)),
        _test_sun(),
        # Red cube left
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1), metallic=0.9f0, roughness=0.1f0),
            transform(position=Vec3d(-2, 0.5, 0))
        ]),
        # Blue cube right
        entity([
            cube_mesh(),
            MaterialComponent(color=RGB{Float32}(0.1, 0.3, 0.9), metallic=0.0f0, roughness=0.8f0),
            transform(position=Vec3d(2, 0.5, 0))
        ]),
        # Green sphere center
        entity([
            sphere_mesh(radius=0.6f0),
            MaterialComponent(color=RGB{Float32}(0.2, 0.8, 0.2), metallic=0.3f0, roughness=0.4f0),
            transform(position=Vec3d(0, 0.6, 0))
        ]),
        _test_floor()
    ])
end
