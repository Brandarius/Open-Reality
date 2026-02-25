# Light components

"""
    PointLightComponent <: Component

A point light that emits light in all directions.
"""
struct PointLightComponent <: Component
    color::RGB{Float32}
    intensity::Float32
    range::Float32
    cast_shadows::Bool
    shadow_resolution::Int

    PointLightComponent(;
        color::RGB{Float32} = RGB{Float32}(1.0, 1.0, 1.0),
        intensity::Float32 = 1.0f0,
        range::Float32 = 10.0f0,
        cast_shadows::Bool = false,
        shadow_resolution::Int = 512
    ) = new(color, intensity, range, cast_shadows, shadow_resolution)
end

"""
    DirectionalLightComponent <: Component

A directional light (like the sun).
"""
struct DirectionalLightComponent <: Component
    color::RGB{Float32}
    intensity::Float32
    direction::Vec3f

    DirectionalLightComponent(;
        color::RGB{Float32} = RGB{Float32}(1.0, 1.0, 1.0),
        intensity::Float32 = 1.0f0,
        direction::Vec3f = Vec3f(0, -1, 0)
    ) = new(color, intensity, direction)
end

"""
    SpotLightComponent <: Component

A spot light that emits light in a cone. Uses inner/outer cone angles
for smooth falloff at the edges.
"""
struct SpotLightComponent <: Component
    color::RGB{Float32}
    intensity::Float32
    range::Float32
    direction::Vec3f        # Cone direction (world-space, normalized)
    inner_cone::Float32     # Inner cone half-angle in radians (full intensity)
    outer_cone::Float32     # Outer cone half-angle in radians (falloff to zero)
    cast_shadows::Bool
    shadow_resolution::Int

    SpotLightComponent(;
        color::RGB{Float32} = RGB{Float32}(1.0, 1.0, 1.0),
        intensity::Float32 = 1.0f0,
        range::Float32 = 10.0f0,
        direction::Vec3f = Vec3f(0, -1, 0),
        inner_cone::Float32 = Float32(π/6),   # 30° total cone
        outer_cone::Float32 = Float32(π/4),   # 45° total cone
        cast_shadows::Bool = false,
        shadow_resolution::Int = 1024
    ) = new(color, intensity, range, normalize(direction), inner_cone, outer_cone, cast_shadows, shadow_resolution)
end

"""
    IBLComponent <: Component

Image-Based Lighting component.
Provides environmental lighting and reflections from an HDR environment map.
Only one IBL component should be active in a scene at a time.
"""
struct IBLComponent <: Component
    environment_path::String  # Path to HDR environment map
    intensity::Float32        # Global intensity multiplier
    enabled::Bool            # Toggle IBL on/off

    IBLComponent(;
        environment_path::String = "",
        intensity::Float32 = 1.0f0,
        enabled::Bool = true
    ) = new(environment_path, intensity, enabled)
end
