# Metal Motion Blur pass implementation
# Pipeline: velocity buffer computation -> directional blur along velocity vectors

# ---- Motion Blur Uniforms ----

struct MetalMotionBlurUniforms
    inv_view_proj::NTuple{16, Float32}
    prev_view_proj::NTuple{16, Float32}
    max_velocity::Float32
    num_samples::Int32
    intensity::Float32
    screen_width::Float32
end

# ---- Motion Blur Pass Type ----

"""
    MetalMotionBlurPass <: AbstractMotionBlurPass

Metal camera-based motion blur: velocity buffer from reprojection + directional blur.
"""
mutable struct MetalMotionBlurPass <: AbstractMotionBlurPass
    velocity_rt::UInt64       # RGBA16F (full res) — RG channels store velocity
    velocity_texture::UInt64
    blur_rt::UInt64           # RGBA16F (full res)
    blur_texture::UInt64
    velocity_pipeline::UInt64
    blur_pipeline::UInt64
    prev_view_proj::Mat4f
    width::Int
    height::Int

    MetalMotionBlurPass(; width::Int=1280, height::Int=720) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
            Mat4f(I), width, height)
end

get_width(mb::MetalMotionBlurPass) = mb.width
get_height(mb::MetalMotionBlurPass) = mb.height

# ---- Create ----

function metal_create_motion_blur_pass!(pass::MetalMotionBlurPass, device_handle::UInt64,
                                         width::Int, height::Int)
    pass.width = width
    pass.height = height

    color_formats_rgba16 = UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT]

    # Velocity render target (RGBA16F, full resolution — RG stores velocity, BA unused)
    pass.velocity_rt = metal_create_render_target(device_handle, Int32(width), Int32(height),
        Int32(1), color_formats_rgba16, Int32(0), UInt32(0), "mb_velocity")
    pass.velocity_texture = metal_get_rt_color_texture(pass.velocity_rt, Int32(0))

    # Blur render target (RGBA16F, full resolution)
    pass.blur_rt = metal_create_render_target(device_handle, Int32(width), Int32(height),
        Int32(1), color_formats_rgba16, Int32(0), UInt32(0), "mb_blur")
    pass.blur_texture = metal_get_rt_color_texture(pass.blur_rt, Int32(0))

    # Pipelines
    velocity_msl = _load_msl_shader("motion_blur_velocity.metal")
    pass.velocity_pipeline = metal_get_or_create_pipeline(velocity_msl,
        "mb_quad_vertex", "mb_velocity_fragment";
        num_color_attachments=Int32(1), color_formats=color_formats_rgba16,
        depth_format=UInt32(0), blend_enabled=Int32(0))

    blur_msl = _load_msl_shader("motion_blur_blur.metal")
    pass.blur_pipeline = metal_get_or_create_pipeline(blur_msl,
        "mb_quad_vertex", "mb_blur_fragment";
        num_color_attachments=Int32(1), color_formats=color_formats_rgba16,
        depth_format=UInt32(0), blend_enabled=Int32(0))

    pass.prev_view_proj = Mat4f(I)

    return pass
end

# ---- Destroy ----

function metal_destroy_motion_blur_pass!(pass::MetalMotionBlurPass)
    pass.velocity_rt != UInt64(0) && metal_destroy_render_target(pass.velocity_rt)
    pass.blur_rt != UInt64(0) && metal_destroy_render_target(pass.blur_rt)
    pass.velocity_rt = UInt64(0)
    pass.velocity_texture = UInt64(0)
    pass.blur_rt = UInt64(0)
    pass.blur_texture = UInt64(0)
    pass.velocity_pipeline = UInt64(0)
    pass.blur_pipeline = UInt64(0)
    return nothing
end

# ---- Resize ----

function metal_resize_motion_blur_pass!(pass::MetalMotionBlurPass, device_handle::UInt64,
                                         width::Int, height::Int)
    pass.width = width
    pass.height = height

    if pass.velocity_rt != UInt64(0)
        metal_resize_render_target(pass.velocity_rt, Int32(width), Int32(height))
        pass.velocity_texture = metal_get_rt_color_texture(pass.velocity_rt, Int32(0))
    end
    if pass.blur_rt != UInt64(0)
        metal_resize_render_target(pass.blur_rt, Int32(width), Int32(height))
        pass.blur_texture = metal_get_rt_color_texture(pass.blur_rt, Int32(0))
    end

    return nothing
end

# ---- Render ----

function metal_render_motion_blur!(pass::MetalMotionBlurPass, backend, scene_texture::UInt64,
                                    depth_texture::UInt64, view_proj::Mat4f,
                                    config::PostProcessConfig, cmd_buf_handle::UInt64)
    width = pass.width
    height = pass.height

    inv_vp = Mat4f(inv(view_proj))

    quad_buf = backend.deferred_pipeline.quad_vertex_buffer
    sampler_h = metal_create_sampler(backend.device_handle, Int32(1), Int32(1), Int32(0), Int32(0))

    # ---- Pass 1: Velocity buffer computation ----
    velocity_uniforms = MetalMotionBlurUniforms(
        ntuple(i -> inv_vp[i], 16),
        ntuple(i -> pass.prev_view_proj[i], 16),
        config.motion_blur_max_velocity,
        Int32(config.motion_blur_samples),
        config.motion_blur_intensity,
        Float32(width)
    )
    velocity_buf = _create_uniform_buffer(backend.device_handle, velocity_uniforms, "mb_velocity_uniforms")

    encoder = metal_begin_render_pass(cmd_buf_handle, pass.velocity_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.velocity_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(width), Float64(height), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_buffer(encoder, velocity_buf, 0, Int32(1))
    metal_set_fragment_texture(encoder, depth_texture, Int32(0))
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # ---- Pass 2: Directional blur along velocity vectors ----
    blur_uniforms = MetalMotionBlurUniforms(
        ntuple(i -> inv_vp[i], 16),
        ntuple(i -> pass.prev_view_proj[i], 16),
        config.motion_blur_max_velocity,
        Int32(config.motion_blur_samples),
        config.motion_blur_intensity,
        Float32(width)
    )
    blur_buf = _create_uniform_buffer(backend.device_handle, blur_uniforms, "mb_blur_uniforms")

    encoder = metal_begin_render_pass(cmd_buf_handle, pass.blur_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.blur_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(width), Float64(height), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_buffer(encoder, blur_buf, 0, Int32(1))
    metal_set_fragment_texture(encoder, scene_texture, Int32(0))
    metal_set_fragment_texture(encoder, pass.velocity_texture, Int32(1))
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # Update previous view-projection for next frame
    pass.prev_view_proj = view_proj

    # Clean up uniform buffers
    metal_destroy_buffer(velocity_buf)
    metal_destroy_buffer(blur_buf)

    return pass.blur_texture
end

# ---- Abstract backend interface ----

function backend_create_motion_blur_pass!(backend::MetalBackend, width::Int, height::Int)
    mb = MetalMotionBlurPass(width=width, height=height)
    metal_create_motion_blur_pass!(mb, backend.device_handle, width, height)
    return mb
end
