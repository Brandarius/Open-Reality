# Post-processing pipeline: backend-agnostic configuration types
# NOTE: OpenGL-specific types (PostProcessPipeline struct, GLSL shaders) moved to backend/opengl/

"""
    ToneMappingMode

Selectable tone mapping operator.
"""
@enum ToneMappingMode TONEMAP_REINHARD TONEMAP_ACES TONEMAP_UNCHARTED2

"""
    FogMode

Fog density function.
"""
@enum FogMode FOG_LINEAR FOG_EXPONENTIAL FOG_EXPONENTIAL2

"""
    PostProcessConfig

User-facing configuration for the post-processing pipeline.
"""
mutable struct PostProcessConfig
    bloom_enabled::Bool
    bloom_threshold::Float32
    bloom_intensity::Float32
    ssao_enabled::Bool
    ssao_radius::Float32
    ssao_samples::Int
    tone_mapping::ToneMappingMode
    fxaa_enabled::Bool
    gamma::Float32

    # Depth of Field
    dof_enabled::Bool
    dof_focus_distance::Float32
    dof_focus_range::Float32
    dof_bokeh_radius::Float32

    # Motion Blur
    motion_blur_enabled::Bool
    motion_blur_intensity::Float32
    motion_blur_samples::Int
    motion_blur_max_velocity::Float32

    # Vignette
    vignette_enabled::Bool
    vignette_intensity::Float32
    vignette_radius::Float32
    vignette_softness::Float32

    # Color Grading
    color_grading_enabled::Bool
    color_grading_brightness::Float32
    color_grading_contrast::Float32
    color_grading_saturation::Float32

    # Fog
    fog_enabled::Bool
    fog_mode::FogMode
    fog_color::Vec3f
    fog_density::Float32
    fog_start::Float32
    fog_end::Float32
    fog_height_enabled::Bool
    fog_height_falloff::Float32
    fog_height_offset::Float32

    PostProcessConfig(;
        bloom_enabled::Bool = false,
        bloom_threshold::Float32 = 1.0f0,
        bloom_intensity::Float32 = 0.3f0,
        ssao_enabled::Bool = false,
        ssao_radius::Float32 = 0.5f0,
        ssao_samples::Int = 16,
        tone_mapping::ToneMappingMode = TONEMAP_REINHARD,
        fxaa_enabled::Bool = false,
        gamma::Float32 = 2.2f0,
        dof_enabled::Bool = false,
        dof_focus_distance::Float32 = 10.0f0,
        dof_focus_range::Float32 = 5.0f0,
        dof_bokeh_radius::Float32 = 3.0f0,
        motion_blur_enabled::Bool = false,
        motion_blur_intensity::Float32 = 1.0f0,
        motion_blur_samples::Int = 8,
        motion_blur_max_velocity::Float32 = 40.0f0,
        vignette_enabled::Bool = false,
        vignette_intensity::Float32 = 0.4f0,
        vignette_radius::Float32 = 0.8f0,
        vignette_softness::Float32 = 0.5f0,
        color_grading_enabled::Bool = false,
        color_grading_brightness::Float32 = 0.0f0,
        color_grading_contrast::Float32 = 1.0f0,
        color_grading_saturation::Float32 = 1.0f0,
        fog_enabled::Bool = false,
        fog_mode::FogMode = FOG_EXPONENTIAL,
        fog_color::Vec3f = Vec3f(0.7f0, 0.7f0, 0.8f0),
        fog_density::Float32 = 0.02f0,
        fog_start::Float32 = 10.0f0,
        fog_end::Float32 = 200.0f0,
        fog_height_enabled::Bool = false,
        fog_height_falloff::Float32 = 0.1f0,
        fog_height_offset::Float32 = 0.0f0
    ) = new(bloom_enabled, bloom_threshold, bloom_intensity,
            ssao_enabled, ssao_radius, ssao_samples,
            tone_mapping, fxaa_enabled, gamma,
            dof_enabled, dof_focus_distance, dof_focus_range, dof_bokeh_radius,
            motion_blur_enabled, motion_blur_intensity, motion_blur_samples, motion_blur_max_velocity,
            vignette_enabled, vignette_intensity, vignette_radius, vignette_softness,
            color_grading_enabled, color_grading_brightness, color_grading_contrast, color_grading_saturation,
            fog_enabled, fog_mode, fog_color, fog_density, fog_start, fog_end,
            fog_height_enabled, fog_height_falloff, fog_height_offset)
end
