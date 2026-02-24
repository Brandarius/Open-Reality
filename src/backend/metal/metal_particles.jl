# Metal CPU-path particle rendering (fallback when GPU compute is unavailable)

# ---- CPU Particle Renderer State ----

mutable struct MetalParticleRendererState
    render_pipeline::UInt64
    vertex_buffer::UInt64
    vertex_capacity::Int
    initialized::Bool

    MetalParticleRendererState() = new(UInt64(0), UInt64(0), 0, false)
end

# ---- CPU Particle Render Uniforms ----

struct MetalCPUParticleUniforms
    view_proj::NTuple{16, Float32}
    cam_right::NTuple{4, Float32}
    cam_up::NTuple{4, Float32}
end

# ---- Initialization ----

function metal_init_particle_renderer!(state::MetalParticleRendererState, device_handle::UInt64)
    if state.initialized
        return nothing
    end

    # Compile CPU particle pipeline (blend enabled for alpha/additive blending)
    particle_msl = _load_msl_shader("particle_cpu.metal")
    state.render_pipeline = metal_get_or_create_pipeline(particle_msl, "cpu_particle_vertex", "cpu_particle_fragment";
        num_color_attachments=Int32(1),
        color_formats=UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT],
        depth_format=MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        blend_enabled=Int32(1))

    # Create initial dynamic vertex buffer (128KB)
    initial_capacity = 128 * 1024
    zero_data = zeros(UInt8, initial_capacity)
    GC.@preserve zero_data begin
        state.vertex_buffer = metal_create_buffer(device_handle, pointer(zero_data),
                                                    initial_capacity, "cpu_particle_vertices")
    end
    state.vertex_capacity = initial_capacity

    state.initialized = true
    @info "Metal CPU particle renderer initialized"
    return nothing
end

# ---- Shutdown ----

function metal_shutdown_particle_renderer!(state::MetalParticleRendererState)
    if state.vertex_buffer != UInt64(0)
        metal_destroy_buffer(state.vertex_buffer)
        state.vertex_buffer = UInt64(0)
    end
    # Pipeline is managed by the global pipeline cache
    state.render_pipeline = UInt64(0)
    state.vertex_capacity = 0
    state.initialized = false
    return nothing
end

# ---- CPU Particle Rendering ----

function metal_render_particles_cpu!(state::MetalParticleRendererState, backend,
                                      pools, view::Mat4f, proj::Mat4f,
                                      cam_right::Vec3f, cam_up::Vec3f, cmd_buf::UInt64)
    if !state.initialized
        return nothing
    end

    # Build billboard vertex data from CPU particle pools
    # Vertex format: pos3 + uv2 + color4 = 9 floats per vertex, 6 vertices per quad
    total_particles = 0
    for pool in pools
        total_particles += pool.alive_count
    end

    if total_particles == 0
        return nothing
    end

    floats_per_vertex = 9
    vertices_per_particle = 6
    total_vertices = total_particles * vertices_per_particle
    vertex_data_size = total_vertices * floats_per_vertex * sizeof(Float32)

    # Grow vertex buffer if needed
    if vertex_data_size > state.vertex_capacity
        if state.vertex_buffer != UInt64(0)
            metal_destroy_buffer(state.vertex_buffer)
        end
        new_capacity = max(vertex_data_size, state.vertex_capacity * 2)
        zero_data = zeros(UInt8, new_capacity)
        GC.@preserve zero_data begin
            state.vertex_buffer = metal_create_buffer(backend.device_handle, pointer(zero_data),
                                                        new_capacity, "cpu_particle_vertices")
        end
        state.vertex_capacity = new_capacity
    end

    # Build interleaved vertex data
    vertex_data = Vector{Float32}(undef, total_vertices * floats_per_vertex)
    vi = 0  # vertex index

    for pool in pools
        for i in 1:pool.alive_count
            p = pool.particles[i]

            # Particle position, size, and color
            px, py, pz = p.position[1], p.position[2], p.position[3]
            t = p.lifetime / p.max_lifetime
            sz = p.size_start * (1.0f0 - t) + p.size_end * t
            half_size = sz * 0.5f0
            cr, cg, cb, ca = p.color[1], p.color[2], p.color[3], p.color[4] * (1.0f0 - t)

            # Billboard corners: right/up from camera
            rx = cam_right[1] * half_size
            ry = cam_right[2] * half_size
            rz = cam_right[3] * half_size
            ux = cam_up[1] * half_size
            uy = cam_up[2] * half_size
            uz = cam_up[3] * half_size

            # 4 corners: bottom-left, bottom-right, top-right, top-left
            blx = px - rx - ux; bly = py - ry - uy; blz = pz - rz - uz
            brx = px + rx - ux; bry = py + ry - uy; brz = pz + rz - uz
            trx = px + rx + ux; _try = py + ry + uy; trz = pz + rz + uz
            tlx = px - rx + ux; tly = py - ry + uy; tlz = pz - rz + uz

            # Triangle 1: BL, BR, TR
            base = vi * floats_per_vertex
            vertex_data[base + 1] = blx; vertex_data[base + 2] = bly; vertex_data[base + 3] = blz
            vertex_data[base + 4] = 0.0f0; vertex_data[base + 5] = 0.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1

            base = vi * floats_per_vertex
            vertex_data[base + 1] = brx; vertex_data[base + 2] = bry; vertex_data[base + 3] = brz
            vertex_data[base + 4] = 1.0f0; vertex_data[base + 5] = 0.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1

            base = vi * floats_per_vertex
            vertex_data[base + 1] = trx; vertex_data[base + 2] = _try; vertex_data[base + 3] = trz
            vertex_data[base + 4] = 1.0f0; vertex_data[base + 5] = 1.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1

            # Triangle 2: BL, TR, TL
            base = vi * floats_per_vertex
            vertex_data[base + 1] = blx; vertex_data[base + 2] = bly; vertex_data[base + 3] = blz
            vertex_data[base + 4] = 0.0f0; vertex_data[base + 5] = 0.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1

            base = vi * floats_per_vertex
            vertex_data[base + 1] = trx; vertex_data[base + 2] = _try; vertex_data[base + 3] = trz
            vertex_data[base + 4] = 1.0f0; vertex_data[base + 5] = 1.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1

            base = vi * floats_per_vertex
            vertex_data[base + 1] = tlx; vertex_data[base + 2] = tly; vertex_data[base + 3] = tlz
            vertex_data[base + 4] = 0.0f0; vertex_data[base + 5] = 1.0f0
            vertex_data[base + 6] = cr; vertex_data[base + 7] = cg; vertex_data[base + 8] = cb; vertex_data[base + 9] = ca
            vi += 1
        end
    end

    # Upload vertex data
    GC.@preserve vertex_data begin
        metal_update_buffer(state.vertex_buffer, pointer(vertex_data), 0, vertex_data_size)
    end

    vp = proj * view
    uniforms = MetalCPUParticleUniforms(
        ntuple(i -> vp[i], 16),
        (cam_right[1], cam_right[2], cam_right[3], 0.0f0),
        (cam_up[1], cam_up[2], cam_up[3], 0.0f0)
    )

    uniform_buf = _create_uniform_buffer(backend.device_handle, uniforms, "cpu_particle_uniforms")

    # Begin render pass on drawable, preserving previous content
    encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_LOAD,
                                                0.0f0, 0.0f0, 0.0f0, 1.0f0)

    metal_set_render_pipeline(encoder, state.render_pipeline)
    metal_set_depth_stencil_state(encoder, backend.ds_less_write)
    metal_set_cull_mode(encoder, MTL_CULL_NONE)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(backend.width), Float64(backend.height), 0.0, 1.0)

    # Bind buffers
    metal_set_vertex_buffer(encoder, state.vertex_buffer, 0, Int32(0))
    metal_set_vertex_buffer(encoder, uniform_buf, 0, Int32(1))

    # Draw all particle billboards
    metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(total_vertices))

    metal_end_render_pass(encoder)
    metal_destroy_buffer(uniform_buf)

    return nothing
end
