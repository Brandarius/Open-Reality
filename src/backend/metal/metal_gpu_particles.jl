# Metal GPU compute-based particle system
# Uses 5 pipeline stages: emit, simulate, compact, indirect-fill, render

# ---- Shader Pipelines ----

mutable struct MetalGPUParticleShaders
    emit_pipeline::UInt64
    simulate_pipeline::UInt64
    compact_pipeline::UInt64
    indirect_pipeline::UInt64
    render_pipeline::UInt64
    initialized::Bool

    MetalGPUParticleShaders() = new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), false)
end

# ---- Per-Emitter GPU State ----

mutable struct MetalGPUParticleEmitter
    particle_buffer::UInt64       # particle data (pos+lifetime, vel+max_lifetime, size, color = 64 bytes each)
    alive_indices::UInt64         # buffer of alive particle indices
    dead_indices::UInt64          # buffer of dead particle indices
    counter_buffer::UInt64        # atomic counters (alive_count, dead_count, emit_count)
    indirect_buffer::UInt64       # MTLDrawPrimitivesIndirectArguments
    max_particles::Int

    MetalGPUParticleEmitter(; max_particles::Int=10000) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), max_particles)
end

# ---- Emit Parameters (passed to compute kernel via buffer) ----

struct MetalParticleEmitParams
    position::NTuple{4, Float32}       # xyz + pad
    velocity_min::NTuple{4, Float32}   # xyz + pad
    velocity_max::NTuple{4, Float32}   # xyz + pad
    color::NTuple{4, Float32}          # rgba
    lifetime::Float32
    size_start::Float32
    size_end::Float32
    emit_count::Int32
    seed::UInt32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

# ---- Simulate Parameters ----

struct MetalParticleSimParams
    dt::Float32
    gravity::Float32
    max_particles::Int32
    _pad1::Float32
end

# ---- Render Uniforms ----

struct MetalParticleRenderUniforms
    view_proj::NTuple{16, Float32}
    cam_right::NTuple{4, Float32}
    cam_up::NTuple{4, Float32}
end

# ---- Initialization ----

const PARTICLE_COMPUTE_GROUP_SIZE = 64

function metal_init_gpu_particle_shaders!(shaders::MetalGPUParticleShaders, device_handle::UInt64)
    if shaders.initialized
        return nothing
    end

    # Compile emit compute pipeline
    emit_msl = _load_msl_shader("particle_emit.metal")
    shaders.emit_pipeline = metal_create_compute_pipeline(emit_msl, "particle_emit")

    # Compile simulate compute pipeline
    simulate_msl = _load_msl_shader("particle_simulate.metal")
    shaders.simulate_pipeline = metal_create_compute_pipeline(simulate_msl, "particle_simulate")

    # Compile compact compute pipeline
    compact_msl = _load_msl_shader("particle_compact.metal")
    shaders.compact_pipeline = metal_create_compute_pipeline(compact_msl, "particle_compact")

    # Compile indirect argument fill compute pipeline
    indirect_msl = _load_msl_shader("particle_indirect.metal")
    shaders.indirect_pipeline = metal_create_compute_pipeline(indirect_msl, "particle_fill_indirect")

    # Compile render pipeline (vertex + fragment for billboards, blend enabled)
    render_msl = _load_msl_shader("particle_render.metal")
    shaders.render_pipeline = metal_get_or_create_pipeline(render_msl, "particle_vertex", "particle_fragment";
        num_color_attachments=Int32(1),
        color_formats=UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT],
        depth_format=MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        blend_enabled=Int32(1))

    shaders.initialized = true
    @info "Metal GPU particle shaders initialized"
    return nothing
end

function metal_shutdown_gpu_particle_shaders!(shaders::MetalGPUParticleShaders)
    if shaders.emit_pipeline != UInt64(0)
        metal_destroy_compute_pipeline(shaders.emit_pipeline)
        shaders.emit_pipeline = UInt64(0)
    end
    if shaders.simulate_pipeline != UInt64(0)
        metal_destroy_compute_pipeline(shaders.simulate_pipeline)
        shaders.simulate_pipeline = UInt64(0)
    end
    if shaders.compact_pipeline != UInt64(0)
        metal_destroy_compute_pipeline(shaders.compact_pipeline)
        shaders.compact_pipeline = UInt64(0)
    end
    if shaders.indirect_pipeline != UInt64(0)
        metal_destroy_compute_pipeline(shaders.indirect_pipeline)
        shaders.indirect_pipeline = UInt64(0)
    end
    # Render pipeline is managed by the global pipeline cache
    shaders.render_pipeline = UInt64(0)
    shaders.initialized = false
    return nothing
end

# ---- Emitter Buffer Allocation ----

function metal_create_gpu_emitter!(emitter::MetalGPUParticleEmitter, device_handle::UInt64)
    n = emitter.max_particles

    # Particle buffer: 64 bytes per particle (4 x float4)
    particle_size = n * 64
    particle_data = zeros(UInt8, particle_size)
    GC.@preserve particle_data begin
        emitter.particle_buffer = metal_create_buffer(device_handle, pointer(particle_data),
                                                       particle_size, "gpu_particles")
    end

    # Alive indices buffer: uint32 per particle
    index_size = n * sizeof(UInt32)
    index_data = zeros(UInt8, index_size)
    GC.@preserve index_data begin
        emitter.alive_indices = metal_create_buffer(device_handle, pointer(index_data),
                                                     index_size, "alive_indices")
    end

    # Dead indices buffer: initialize with all indices (all particles start dead)
    dead_data = Vector{UInt32}(undef, n)
    for i in 1:n
        dead_data[i] = UInt32(i - 1)
    end
    GC.@preserve dead_data begin
        emitter.dead_indices = metal_create_buffer(device_handle, pointer(dead_data),
                                                    index_size, "dead_indices")
    end

    # Counter buffer: 3 atomic uints (alive_count=0, dead_count=max_particles, emit_count=0)
    counter_data = UInt32[0, UInt32(n), 0]
    GC.@preserve counter_data begin
        emitter.counter_buffer = metal_create_buffer(device_handle, pointer(counter_data),
                                                      3 * sizeof(UInt32), "particle_counters")
    end

    # Indirect draw args buffer: 4 uints (vertexCount, instanceCount, vertexStart, baseInstance)
    indirect_data = UInt32[0, 1, 0, 0]
    GC.@preserve indirect_data begin
        emitter.indirect_buffer = metal_create_buffer(device_handle, pointer(indirect_data),
                                                       4 * sizeof(UInt32), "particle_indirect")
    end

    @info "Metal GPU particle emitter created" max_particles=n
    return nothing
end

function metal_destroy_gpu_emitter!(emitter::MetalGPUParticleEmitter)
    for field in (:particle_buffer, :alive_indices, :dead_indices, :counter_buffer, :indirect_buffer)
        handle = getfield(emitter, field)
        if handle != UInt64(0)
            metal_destroy_buffer(handle)
            setfield!(emitter, field, UInt64(0))
        end
    end
    return nothing
end

# ---- Emission (Compute) ----

function metal_emit_particles!(emitter::MetalGPUParticleEmitter, shaders::MetalGPUParticleShaders,
                                cmd_buf::UInt64, emit_count::Int,
                                position::Vec3f, velocity_min::Vec3f, velocity_max::Vec3f,
                                lifetime::Float32, size_start::Float32, size_end::Float32,
                                color::NTuple{4, Float32})
    if !shaders.initialized || emit_count <= 0
        return nothing
    end

    params = MetalParticleEmitParams(
        (position[1], position[2], position[3], 0.0f0),
        (velocity_min[1], velocity_min[2], velocity_min[3], 0.0f0),
        (velocity_max[1], velocity_max[2], velocity_max[3], 0.0f0),
        color,
        lifetime, size_start, size_end,
        Int32(emit_count),
        UInt32(rand(UInt32)),
        0.0f0, 0.0f0, 0.0f0
    )

    param_buf = _create_uniform_buffer(UInt64(0), params, "emit_params")

    encoder = metal_begin_compute_pass(cmd_buf)

    metal_set_compute_buffer(encoder, emitter.particle_buffer, 0, Int32(0))
    metal_set_compute_buffer(encoder, emitter.dead_indices, 0, Int32(1))
    metal_set_compute_buffer(encoder, emitter.counter_buffer, 0, Int32(2))
    metal_set_compute_buffer(encoder, param_buf, 0, Int32(3))

    num_groups = Int32(cld(emit_count, PARTICLE_COMPUTE_GROUP_SIZE))
    metal_dispatch_threadgroups(encoder, shaders.emit_pipeline,
                                 num_groups, Int32(1), Int32(1),
                                 Int32(PARTICLE_COMPUTE_GROUP_SIZE), Int32(1), Int32(1))

    metal_end_compute_pass(encoder)
    metal_destroy_buffer(param_buf)

    return nothing
end

# ---- Simulation + Compaction + Indirect Fill (Compute) ----

function metal_simulate_particles!(emitter::MetalGPUParticleEmitter, shaders::MetalGPUParticleShaders,
                                    cmd_buf::UInt64, dt::Float32)
    if !shaders.initialized
        return nothing
    end

    n = emitter.max_particles
    num_groups = Int32(cld(n, PARTICLE_COMPUTE_GROUP_SIZE))
    group_size = Int32(PARTICLE_COMPUTE_GROUP_SIZE)

    # Step 1: Simulate — apply physics, age particles
    sim_params = MetalParticleSimParams(dt, -9.81f0, Int32(n), 0.0f0)
    sim_buf = _create_uniform_buffer(UInt64(0), sim_params, "sim_params")

    encoder = metal_begin_compute_pass(cmd_buf)

    metal_set_compute_buffer(encoder, emitter.particle_buffer, 0, Int32(0))
    metal_set_compute_buffer(encoder, emitter.counter_buffer, 0, Int32(1))
    metal_set_compute_buffer(encoder, sim_buf, 0, Int32(2))

    metal_dispatch_threadgroups(encoder, shaders.simulate_pipeline,
                                 num_groups, Int32(1), Int32(1),
                                 group_size, Int32(1), Int32(1))

    metal_end_compute_pass(encoder)
    metal_destroy_buffer(sim_buf)

    # Step 2: Compact — rebuild alive index list
    encoder = metal_begin_compute_pass(cmd_buf)

    metal_set_compute_buffer(encoder, emitter.particle_buffer, 0, Int32(0))
    metal_set_compute_buffer(encoder, emitter.alive_indices, 0, Int32(1))
    metal_set_compute_buffer(encoder, emitter.dead_indices, 0, Int32(2))
    metal_set_compute_buffer(encoder, emitter.counter_buffer, 0, Int32(3))

    metal_dispatch_threadgroups(encoder, shaders.compact_pipeline,
                                 num_groups, Int32(1), Int32(1),
                                 group_size, Int32(1), Int32(1))

    metal_end_compute_pass(encoder)

    # Step 3: Fill indirect draw arguments
    encoder = metal_begin_compute_pass(cmd_buf)

    metal_set_compute_buffer(encoder, emitter.counter_buffer, 0, Int32(0))
    metal_set_compute_buffer(encoder, emitter.indirect_buffer, 0, Int32(1))

    metal_dispatch_threadgroups(encoder, shaders.indirect_pipeline,
                                 Int32(1), Int32(1), Int32(1),
                                 Int32(1), Int32(1), Int32(1))

    metal_end_compute_pass(encoder)

    return nothing
end

# ---- Rendering (Indirect Draw) ----

function metal_render_gpu_particles!(emitter::MetalGPUParticleEmitter, shaders::MetalGPUParticleShaders,
                                      backend, view::Mat4f, proj::Mat4f,
                                      cam_right::Vec3f, cam_up::Vec3f, cmd_buf::UInt64)
    if !shaders.initialized || shaders.render_pipeline == UInt64(0)
        return nothing
    end

    vp = proj * view

    render_uniforms = MetalParticleRenderUniforms(
        ntuple(i -> vp[i], 16),
        (cam_right[1], cam_right[2], cam_right[3], 0.0f0),
        (cam_up[1], cam_up[2], cam_up[3], 0.0f0)
    )

    uniform_buf = _create_uniform_buffer(backend.device_handle, render_uniforms, "particle_render")

    # Begin render pass (assumes a target is already configured or use drawable)
    encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_LOAD,
                                                0.0f0, 0.0f0, 0.0f0, 1.0f0)

    metal_set_render_pipeline(encoder, shaders.render_pipeline)
    metal_set_depth_stencil_state(encoder, backend.ds_less_write)
    metal_set_cull_mode(encoder, MTL_CULL_NONE)
    metal_set_viewport(encoder, 0.0, 0.0, Float64(backend.width), Float64(backend.height), 0.0, 1.0)

    # Bind buffers
    metal_set_vertex_buffer(encoder, emitter.particle_buffer, 0, Int32(0))
    metal_set_vertex_buffer(encoder, emitter.alive_indices, 0, Int32(1))
    metal_set_vertex_buffer(encoder, uniform_buf, 0, Int32(2))
    metal_set_vertex_buffer(encoder, emitter.counter_buffer, 0, Int32(3))

    # Indirect draw: billboard quads (6 vertices per particle)
    metal_draw_primitives_indirect(encoder, MTL_PRIMITIVE_TRIANGLE,
                                    emitter.indirect_buffer, 0)

    metal_end_render_pass(encoder)
    metal_destroy_buffer(uniform_buf)

    return nothing
end
