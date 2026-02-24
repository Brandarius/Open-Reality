# Metal UI rendering — overlay pass with blend and no depth

# ---- UI Renderer State ----

mutable struct MetalUIRenderer
    pipeline::UInt64          # standard textured UI pipeline
    font_pipeline::UInt64     # font atlas pipeline (R channel as alpha)
    vertex_buffer::UInt64
    vertex_capacity::Int      # in bytes
    sampler::UInt64
    initialized::Bool

    MetalUIRenderer() = new(UInt64(0), UInt64(0), UInt64(0), 0, UInt64(0), false)
end

# ---- UI Uniforms (must match MSL UIUniforms) ----

struct MetalUIUniforms
    projection::NTuple{16, Float32}  # orthographic projection
    has_texture::Int32
    is_font::Int32
    _pad1::Float32
    _pad2::Float32
end

# ---- Initialization ----

function metal_init_ui_renderer!(renderer::MetalUIRenderer, device_handle::UInt64)
    if renderer.initialized
        return nothing
    end

    # Compile standard UI pipeline (blend enabled, no depth, single BGRA8 color attachment)
    ui_msl = _load_msl_shader("ui.metal")
    renderer.pipeline = metal_get_or_create_pipeline(ui_msl, "ui_vertex", "ui_fragment";
        num_color_attachments=Int32(1),
        color_formats=UInt32[MTL_PIXEL_FORMAT_BGRA8_UNORM],
        depth_format=UInt32(0),
        blend_enabled=Int32(1))

    # Font pipeline uses the same shader with is_font=1 uniform
    renderer.font_pipeline = renderer.pipeline

    # Create initial dynamic vertex buffer (64KB)
    initial_capacity = 64 * 1024
    zero_data = zeros(UInt8, initial_capacity)
    GC.@preserve zero_data begin
        renderer.vertex_buffer = metal_create_buffer(device_handle, pointer(zero_data),
                                                      initial_capacity, "ui_vertices")
    end
    renderer.vertex_capacity = initial_capacity

    # Create sampler (linear filtering, clamp to edge)
    renderer.sampler = metal_create_sampler(device_handle, Int32(1), Int32(1), Int32(0), Int32(1))

    renderer.initialized = true
    @info "Metal UI renderer initialized"
    return nothing
end

# ---- Shutdown ----

function metal_shutdown_ui_renderer!(renderer::MetalUIRenderer)
    if renderer.vertex_buffer != UInt64(0)
        metal_destroy_buffer(renderer.vertex_buffer)
        renderer.vertex_buffer = UInt64(0)
    end
    # Pipeline is managed by the global pipeline cache
    renderer.pipeline = UInt64(0)
    renderer.font_pipeline = UInt64(0)
    renderer.vertex_capacity = 0
    renderer.initialized = false
    return nothing
end

# ---- UI Rendering ----

function metal_render_ui!(renderer::MetalUIRenderer, backend, ctx, cmd_buf::UInt64)
    if !renderer.initialized
        return nothing
    end

    # Collect draw commands from UI context
    draw_lists = ctx.draw_lists
    if isempty(draw_lists)
        return nothing
    end

    # Build interleaved vertex data: pos2 + uv2 + color4 = 8 floats per vertex
    total_vertices = 0
    for dl in draw_lists
        total_vertices += length(dl.vertices)
    end

    if total_vertices == 0
        return nothing
    end

    vertex_data_size = total_vertices * 8 * sizeof(Float32)

    # Grow vertex buffer if needed
    if vertex_data_size > renderer.vertex_capacity
        if renderer.vertex_buffer != UInt64(0)
            metal_destroy_buffer(renderer.vertex_buffer)
        end
        new_capacity = max(vertex_data_size, renderer.vertex_capacity * 2)
        zero_data = zeros(UInt8, new_capacity)
        GC.@preserve zero_data begin
            renderer.vertex_buffer = metal_create_buffer(backend.device_handle, pointer(zero_data),
                                                          new_capacity, "ui_vertices")
        end
        renderer.vertex_capacity = new_capacity
    end

    # Pack vertex data into a flat Float32 array
    vertex_data = Vector{Float32}(undef, total_vertices * 8)
    offset = 0
    for dl in draw_lists
        for v in dl.vertices
            idx = offset * 8
            vertex_data[idx + 1] = v.pos[1]
            vertex_data[idx + 2] = v.pos[2]
            vertex_data[idx + 3] = v.uv[1]
            vertex_data[idx + 4] = v.uv[2]
            vertex_data[idx + 5] = v.color[1]
            vertex_data[idx + 6] = v.color[2]
            vertex_data[idx + 7] = v.color[3]
            vertex_data[idx + 8] = v.color[4]
            offset += 1
        end
    end

    # Upload vertex data to GPU buffer
    GC.@preserve vertex_data begin
        metal_update_buffer(renderer.vertex_buffer, pointer(vertex_data), 0, vertex_data_size)
    end

    # Begin render pass on the drawable with load=LOAD to preserve previous rendering
    encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_LOAD,
                                                0.0f0, 0.0f0, 0.0f0, 1.0f0)

    # Set pipeline state
    metal_set_render_pipeline(encoder, renderer.pipeline)

    # No depth test for UI
    ds_state = metal_create_depth_stencil_state(backend.device_handle, MTL_COMPARE_ALWAYS, Int32(0))
    metal_set_depth_stencil_state(encoder, ds_state)
    metal_set_cull_mode(encoder, MTL_CULL_NONE)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(backend.width), Float64(backend.height), 0.0, 1.0)

    # Build orthographic projection matrix (screen-space: 0,0 top-left to width,height bottom-right)
    w = Float32(backend.width)
    h = Float32(backend.height)
    ortho = (
        2.0f0/w,  0.0f0,    0.0f0, 0.0f0,
        0.0f0,   -2.0f0/h,  0.0f0, 0.0f0,
        0.0f0,    0.0f0,   -1.0f0, 0.0f0,
       -1.0f0,    1.0f0,    0.0f0, 1.0f0
    )

    # Bind vertex buffer
    metal_set_vertex_buffer(encoder, renderer.vertex_buffer, 0, Int32(0))

    # Render each draw command
    global_vertex_offset = 0
    for dl in draw_lists
        for cmd in dl.commands
            # Determine texture state
            has_tex = cmd.texture_handle != UInt64(0) ? Int32(1) : Int32(0)
            is_font_tex = cmd.is_font ? Int32(1) : Int32(0)

            uniforms = MetalUIUniforms(ortho, has_tex, is_font_tex, 0.0f0, 0.0f0)
            uniform_buf = _create_uniform_buffer(backend.device_handle, uniforms, "ui_uniforms")
            metal_set_vertex_buffer(encoder, uniform_buf, 0, Int32(1))
            metal_set_fragment_buffer(encoder, uniform_buf, 0, Int32(1))

            # Bind texture if present
            if cmd.texture_handle != UInt64(0)
                metal_set_fragment_texture(encoder, cmd.texture_handle, Int32(0))
                metal_set_fragment_sampler(encoder, renderer.sampler, Int32(0))
            end

            # Apply scissor clipping
            sx = Int32(max(0, cmd.clip_rect[1]))
            sy = Int32(max(0, cmd.clip_rect[2]))
            sw = Int32(max(0, cmd.clip_rect[3] - cmd.clip_rect[1]))
            sh = Int32(max(0, cmd.clip_rect[4] - cmd.clip_rect[2]))
            metal_set_scissor_rect(encoder, sx, sy, sw, sh)

            # Draw the command's vertex range
            vertex_start = Int32(global_vertex_offset + cmd.vertex_offset)
            vertex_count = Int32(cmd.vertex_count)
            metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, vertex_start, vertex_count)

            metal_destroy_buffer(uniform_buf)
        end
        global_vertex_offset += length(dl.vertices)
    end

    metal_end_render_pass(encoder)
    return nothing
end
