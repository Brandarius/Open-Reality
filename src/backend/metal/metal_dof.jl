# Metal Depth of Field (DOF) pass implementation
# Pipeline: CoC computation -> separable bokeh blur (H+V) -> composite

# ---- DOF Uniforms ----

struct MetalDOFUniforms
    focus_distance::Float32
    focus_range::Float32
    bokeh_radius::Float32
    horizontal::Int32
    near_plane::Float32
    far_plane::Float32
    _pad1::Float32
    _pad2::Float32
end

# ---- DOF Pass Type ----

"""
    MetalDOFPass <: AbstractDOFPass

Metal depth-of-field pass: CoC computation -> separable bokeh blur -> composite.
"""
mutable struct MetalDOFPass <: AbstractDOFPass
    coc_rt::UInt64          # R16F render target (full res)
    coc_texture::UInt64
    blur_h_rt::UInt64       # RGBA16F (half res)
    blur_h_texture::UInt64
    blur_v_rt::UInt64       # RGBA16F (half res)
    blur_v_texture::UInt64
    coc_pipeline::UInt64
    blur_pipeline::UInt64
    composite_pipeline::UInt64
    width::Int
    height::Int

    MetalDOFPass(; width::Int=1280, height::Int=720) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
            UInt64(0), UInt64(0), UInt64(0), width, height)
end

get_width(dof::MetalDOFPass) = dof.width
get_height(dof::MetalDOFPass) = dof.height

# ---- Create ----

function metal_create_dof_pass!(pass::MetalDOFPass, device_handle::UInt64, width::Int, height::Int)
    pass.width = width
    pass.height = height

    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    # CoC render target (R16F, full resolution)
    color_formats_r16 = UInt32[MTL_PIXEL_FORMAT_R16_FLOAT]
    pass.coc_rt = metal_create_render_target(device_handle, Int32(width), Int32(height),
        Int32(1), color_formats_r16, Int32(0), UInt32(0), "dof_coc")
    pass.coc_texture = metal_get_rt_color_texture(pass.coc_rt, Int32(0))

    # Horizontal blur render target (RGBA16F, half resolution)
    color_formats_rgba16 = UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT]
    pass.blur_h_rt = metal_create_render_target(device_handle, Int32(half_w), Int32(half_h),
        Int32(1), color_formats_rgba16, Int32(0), UInt32(0), "dof_blur_h")
    pass.blur_h_texture = metal_get_rt_color_texture(pass.blur_h_rt, Int32(0))

    # Vertical blur render target (RGBA16F, half resolution)
    pass.blur_v_rt = metal_create_render_target(device_handle, Int32(half_w), Int32(half_h),
        Int32(1), color_formats_rgba16, Int32(0), UInt32(0), "dof_blur_v")
    pass.blur_v_texture = metal_get_rt_color_texture(pass.blur_v_rt, Int32(0))

    # Pipelines
    coc_msl = _load_msl_shader("dof_coc.metal")
    pass.coc_pipeline = metal_get_or_create_pipeline(coc_msl, "dof_quad_vertex", "dof_coc_fragment";
        num_color_attachments=Int32(1), color_formats=color_formats_r16,
        depth_format=UInt32(0), blend_enabled=Int32(0))

    blur_msl = _load_msl_shader("dof_blur.metal")
    pass.blur_pipeline = metal_get_or_create_pipeline(blur_msl, "dof_quad_vertex", "dof_blur_fragment";
        num_color_attachments=Int32(1), color_formats=color_formats_rgba16,
        depth_format=UInt32(0), blend_enabled=Int32(0))

    composite_msl = _load_msl_shader("dof_composite.metal")
    pass.composite_pipeline = metal_get_or_create_pipeline(composite_msl, "dof_quad_vertex", "dof_composite_fragment";
        num_color_attachments=Int32(1), color_formats=color_formats_rgba16,
        depth_format=UInt32(0), blend_enabled=Int32(0))

    return pass
end

# ---- Destroy ----

function metal_destroy_dof_pass!(pass::MetalDOFPass)
    pass.coc_rt != UInt64(0) && metal_destroy_render_target(pass.coc_rt)
    pass.blur_h_rt != UInt64(0) && metal_destroy_render_target(pass.blur_h_rt)
    pass.blur_v_rt != UInt64(0) && metal_destroy_render_target(pass.blur_v_rt)
    pass.coc_rt = UInt64(0)
    pass.coc_texture = UInt64(0)
    pass.blur_h_rt = UInt64(0)
    pass.blur_h_texture = UInt64(0)
    pass.blur_v_rt = UInt64(0)
    pass.blur_v_texture = UInt64(0)
    pass.coc_pipeline = UInt64(0)
    pass.blur_pipeline = UInt64(0)
    pass.composite_pipeline = UInt64(0)
    return nothing
end

# ---- Resize ----

function metal_resize_dof_pass!(pass::MetalDOFPass, device_handle::UInt64, width::Int, height::Int)
    pass.width = width
    pass.height = height

    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    if pass.coc_rt != UInt64(0)
        metal_resize_render_target(pass.coc_rt, Int32(width), Int32(height))
        pass.coc_texture = metal_get_rt_color_texture(pass.coc_rt, Int32(0))
    end
    if pass.blur_h_rt != UInt64(0)
        metal_resize_render_target(pass.blur_h_rt, Int32(half_w), Int32(half_h))
        pass.blur_h_texture = metal_get_rt_color_texture(pass.blur_h_rt, Int32(0))
    end
    if pass.blur_v_rt != UInt64(0)
        metal_resize_render_target(pass.blur_v_rt, Int32(half_w), Int32(half_h))
        pass.blur_v_texture = metal_get_rt_color_texture(pass.blur_v_rt, Int32(0))
    end

    return nothing
end

# ---- Render ----

function metal_render_dof!(pass::MetalDOFPass, backend, scene_texture::UInt64,
                            depth_texture::UInt64, config::PostProcessConfig,
                            cmd_buf_handle::UInt64)
    width = pass.width
    height = pass.height
    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    quad_buf = backend.deferred_pipeline.quad_vertex_buffer
    sampler_h = metal_create_sampler(backend.device_handle, Int32(1), Int32(1), Int32(0), Int32(0))

    # ---- Pass 1: CoC computation (full resolution) ----
    coc_uniforms = MetalDOFUniforms(
        config.dof_focus_distance,
        config.dof_focus_range,
        config.dof_bokeh_radius,
        Int32(0),
        0.1f0,    # near plane
        500.0f0,  # far plane
        0.0f0, 0.0f0
    )
    coc_buf = _create_uniform_buffer(backend.device_handle, coc_uniforms, "dof_coc_uniforms")

    encoder = metal_begin_render_pass(cmd_buf_handle, pass.coc_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.coc_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(width), Float64(height), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_buffer(encoder, coc_buf, 0, Int32(1))
    metal_set_fragment_texture(encoder, depth_texture, Int32(0))
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # ---- Pass 2: Horizontal blur (half resolution) ----
    blur_h_uniforms = MetalDOFUniforms(
        config.dof_focus_distance,
        config.dof_focus_range,
        config.dof_bokeh_radius,
        Int32(1),   # horizontal = true
        0.1f0, 500.0f0,
        0.0f0, 0.0f0
    )
    blur_h_buf = _create_uniform_buffer(backend.device_handle, blur_h_uniforms, "dof_blur_h_uniforms")

    encoder = metal_begin_render_pass(cmd_buf_handle, pass.blur_h_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.blur_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(half_w), Float64(half_h), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_buffer(encoder, blur_h_buf, 0, Int32(1))
    metal_set_fragment_texture(encoder, scene_texture, Int32(0))
    metal_set_fragment_texture(encoder, pass.coc_texture, Int32(1))
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # ---- Pass 3: Vertical blur (half resolution) ----
    blur_v_uniforms = MetalDOFUniforms(
        config.dof_focus_distance,
        config.dof_focus_range,
        config.dof_bokeh_radius,
        Int32(0),   # horizontal = false (vertical)
        0.1f0, 500.0f0,
        0.0f0, 0.0f0
    )
    blur_v_buf = _create_uniform_buffer(backend.device_handle, blur_v_uniforms, "dof_blur_v_uniforms")

    encoder = metal_begin_render_pass(cmd_buf_handle, pass.blur_v_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.blur_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(half_w), Float64(half_h), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_buffer(encoder, blur_v_buf, 0, Int32(1))
    metal_set_fragment_texture(encoder, pass.blur_h_texture, Int32(0))
    metal_set_fragment_texture(encoder, pass.coc_texture, Int32(1))
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # ---- Pass 4: Composite sharp + blurred (output to blur_h_rt, reused as composite target) ----
    # Reuse blur_h_rt as the composite output (full-res would be better but we keep half-res for perf)
    encoder = metal_begin_render_pass(cmd_buf_handle, pass.blur_h_rt,
                                       MTL_LOAD_CLEAR, MTL_STORE_STORE,
                                       0.0f0, 0.0f0, 0.0f0, 0.0f0, 1.0)
    metal_set_render_pipeline(encoder, pass.composite_pipeline)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(half_w), Float64(half_h), 0.0, 1.0)
    metal_set_vertex_buffer(encoder, quad_buf, 0, Int32(0))
    metal_set_fragment_texture(encoder, scene_texture, Int32(0))      # sharp
    metal_set_fragment_texture(encoder, pass.blur_v_texture, Int32(1)) # blurred
    metal_set_fragment_texture(encoder, pass.coc_texture, Int32(2))   # CoC
    metal_set_fragment_sampler(encoder, sampler_h, Int32(0))
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
    metal_end_render_pass(encoder)

    # Clean up uniform buffers
    metal_destroy_buffer(coc_buf)
    metal_destroy_buffer(blur_h_buf)
    metal_destroy_buffer(blur_v_buf)

    return pass.blur_h_texture
end

# ---- Abstract backend interface ----

function backend_create_dof_pass!(backend::MetalBackend, width::Int, height::Int)
    dof = MetalDOFPass(width=width, height=height)
    metal_create_dof_pass!(dof, backend.device_handle, width, height)
    return dof
end
