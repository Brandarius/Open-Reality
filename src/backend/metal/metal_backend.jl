# Metal backend implementation

"""
    MetalBackend <: AbstractBackend

Metal rendering backend with deferred rendering, PBR pipeline, cascaded shadow maps,
frustum culling, transparency, and post-processing. macOS only.
"""
mutable struct MetalBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    device_handle::UInt64
    width::Int
    height::Int

    # Rendering pipeline
    deferred_pipeline::Union{MetalDeferredPipeline, Nothing}
    forward_pipeline::UInt64  # PBR forward pipeline handle (for transparent objects)
    use_deferred::Bool

    # Resources
    gpu_cache::MetalGPUResourceCache
    texture_cache::MetalTextureCache
    bounds_cache::Dict{EntityID, BoundingSphere}

    # Shadows
    csm::Union{MetalCascadedShadowMap, Nothing}

    # Post-processing
    post_process::Union{MetalPostProcessPipeline, Nothing}

    # Per-frame state
    cmd_buf_handle::UInt64

    # Depth stencil states (cached)
    ds_less_write::UInt64
    ds_always_nowrite::UInt64

    # Default sampler
    default_sampler::UInt64
    shadow_sampler::UInt64

    # Instancing
    instance_buffer::Union{MetalInstanceBuffer, Nothing}

    # Terrain
    terrain_caches::Dict{EntityID, MetalTerrainGPUCache}

    # UI
    ui_renderer::Union{MetalUIRenderer, Nothing}

    # Particles
    gpu_particle_shaders::Union{MetalGPUParticleShaders, Nothing}
    particle_renderer::Union{MetalParticleRendererState, Nothing}

    MetalBackend(; post_process_config::PostProcessConfig = PostProcessConfig(), use_deferred::Bool = true) = new(
        false, nothing, InputState(), UInt64(0), 1280, 720,
        nothing, UInt64(0), use_deferred,
        MetalGPUResourceCache(), MetalTextureCache(), Dict{EntityID, BoundingSphere}(),
        nothing,
        MetalPostProcessPipeline(config=post_process_config),
        UInt64(0),
        UInt64(0), UInt64(0),
        UInt64(0), UInt64(0),
        nothing,
        Dict{EntityID, MetalTerrainGPUCache}(),
        nothing,
        nothing, nothing
    )
end

# ==================================================================
# Core Lifecycle
# ==================================================================

function initialize!(backend::MetalBackend;
                     width::Int=1280, height::Int=720, title::String="OpenReality")
    ensure_glfw_init!()

    # Create window WITHOUT OpenGL context (Metal uses its own layer)
    GLFW.WindowHint(GLFW.CLIENT_API, GLFW.NO_API)
    GLFW.WindowHint(GLFW.RESIZABLE, true)

    backend.window = Window(width=width, height=height, title=title)
    backend.window.handle = GLFW.CreateWindow(width, height, title)

    setup_input_callbacks!(backend.window, backend.input)
    setup_resize_callback!(backend.window, (w, h) -> begin
        nw, nh = Int(w), Int(h)
        backend.width = nw
        backend.height = nh
        metal_resize(backend.device_handle, Int32(nw), Int32(nh))
        if backend.deferred_pipeline !== nothing
            metal_resize_deferred_pipeline!(backend.deferred_pipeline, backend.device_handle, nw, nh)
        end
    end)

    # Get NSWindow handle from GLFW (not wrapped in Julia GLFW package, use direct ccall)
    nswindow = ccall((:glfwGetCocoaWindow, GLFW.libglfw), Ptr{Cvoid}, (GLFW.Window,), backend.window.handle)
    nswindow == C_NULL && error("glfwGetCocoaWindow returned NULL — Metal requires macOS with a Cocoa window")
    backend.device_handle = metal_init(nswindow, Int32(width), Int32(height))
    backend.width = width
    backend.height = height

    # Cache depth stencil states
    backend.ds_less_write = metal_create_depth_stencil_state(backend.device_handle, MTL_COMPARE_LESS, Int32(1))
    backend.ds_always_nowrite = metal_create_depth_stencil_state(backend.device_handle, MTL_COMPARE_ALWAYS, Int32(0))

    # Cache samplers
    backend.default_sampler = metal_create_sampler(backend.device_handle, Int32(1), Int32(1), Int32(1), Int32(0))
    backend.shadow_sampler = metal_create_sampler(backend.device_handle, Int32(1), Int32(1), Int32(0), Int32(0))

    # Initialize deferred rendering pipeline
    if backend.use_deferred
        backend.deferred_pipeline = MetalDeferredPipeline()
        metal_create_deferred_pipeline!(backend.deferred_pipeline, backend.device_handle, width, height)
        @info "Metal deferred rendering pipeline initialized"
    end

    # DOF and Motion Blur passes (inside deferred pipeline)
    if backend.use_deferred && backend.deferred_pipeline !== nothing
        dof = MetalDOFPass(width=width, height=height)
        metal_create_dof_pass!(dof, backend.device_handle, width, height)
        backend.deferred_pipeline.dof_pass = dof

        mblur = MetalMotionBlurPass(width=width, height=height)
        metal_create_motion_blur_pass!(mblur, backend.device_handle, width, height)
        backend.deferred_pipeline.motion_blur_pass = mblur
    end

    # Forward PBR pipeline (for transparent objects)
    pbr_msl = _load_msl_shader("pbr_forward.metal")
    backend.forward_pipeline = metal_get_or_create_pipeline(
        pbr_msl, "pbr_vertex", "pbr_fragment";
        num_color_attachments=Int32(1),
        color_formats=UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT],
        depth_format=MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        blend_enabled=Int32(1)
    )

    # Cascaded Shadow Maps
    backend.csm = MetalCascadedShadowMap(num_cascades=4, resolution=2048)
    metal_create_csm_rt!(backend.csm, backend.device_handle, 0.1f0, 150.0f0)

    # Post-processing
    if backend.post_process !== nothing
        metal_create_post_process_pipeline!(backend.post_process, backend.device_handle, width, height)
    end

    # UI Renderer
    backend.ui_renderer = MetalUIRenderer()
    metal_init_ui_renderer!(backend.ui_renderer, backend.device_handle)

    # Particle Renderer (CPU fallback)
    backend.particle_renderer = MetalParticleRendererState()
    metal_init_particle_renderer!(backend.particle_renderer, backend.device_handle)

    # GPU Particle Shaders (compute-based)
    backend.gpu_particle_shaders = MetalGPUParticleShaders()
    metal_init_gpu_particle_shaders!(backend.gpu_particle_shaders, backend.device_handle)

    backend.initialized = true
    @info "Metal backend initialized" width height
    return nothing
end

function shutdown!(backend::MetalBackend)
    if backend.deferred_pipeline !== nothing
        # Destroy DOF and motion blur passes
        if backend.deferred_pipeline.dof_pass !== nothing
            metal_destroy_dof_pass!(backend.deferred_pipeline.dof_pass)
            backend.deferred_pipeline.dof_pass = nothing
        end
        if backend.deferred_pipeline.motion_blur_pass !== nothing
            metal_destroy_motion_blur_pass!(backend.deferred_pipeline.motion_blur_pass)
            backend.deferred_pipeline.motion_blur_pass = nothing
        end
        metal_destroy_deferred_pipeline!(backend.deferred_pipeline)
        backend.deferred_pipeline = nothing
    end

    # Clean up instance buffer
    if backend.instance_buffer !== nothing
        destroy_metal_instance_buffer!(backend.instance_buffer)
        backend.instance_buffer = nothing
    end
    reset_metal_instance_buffer!()

    # Clean up terrain caches
    for (_, cache) in backend.terrain_caches
        metal_destroy_terrain_cache!(cache)
    end
    empty!(backend.terrain_caches)

    # Clean up UI renderer
    if backend.ui_renderer !== nothing
        metal_shutdown_ui_renderer!(backend.ui_renderer)
        backend.ui_renderer = nothing
    end

    # Clean up particle systems
    if backend.gpu_particle_shaders !== nothing
        metal_shutdown_gpu_particle_shaders!(backend.gpu_particle_shaders)
        backend.gpu_particle_shaders = nothing
    end
    if backend.particle_renderer !== nothing
        metal_shutdown_particle_renderer!(backend.particle_renderer)
        backend.particle_renderer = nothing
    end

    metal_destroy_all_meshes!(backend.gpu_cache)
    metal_destroy_all_textures!(backend.texture_cache)
    if backend.csm !== nothing
        metal_destroy_csm!(backend.csm)
        backend.csm = nothing
    end
    if backend.post_process !== nothing
        metal_destroy_post_process_pipeline!(backend.post_process)
        backend.post_process = nothing
    end
    metal_destroy_all_pipelines!()
    if backend.device_handle != UInt64(0)
        metal_shutdown(backend.device_handle)
        backend.device_handle = UInt64(0)
    end
    if backend.window !== nothing
        destroy_window!(backend.window)
        backend.window = nothing
    end
    glfw_terminate!()
    backend.initialized = false
    return nothing
end

# ==================================================================
# Abstract Backend Method Implementations
# ==================================================================

# ---- Shader operations ----

function backend_create_shader(backend::MetalBackend, vertex_src::String, fragment_src::String)
    # For Metal, both vertex and fragment are in the same MSL source.
    # fragment_src is used as the combined source.
    handle = metal_get_or_create_pipeline(fragment_src, "vertex_main", "fragment_main";
        num_color_attachments=Int32(1),
        color_formats=UInt32[MTL_PIXEL_FORMAT_BGRA8_UNORM],
        depth_format=MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        blend_enabled=Int32(0))
    return MetalShaderProgram(handle, "vertex_main", "fragment_main")
end

function backend_destroy_shader!(backend::MetalBackend, shader::MetalShaderProgram)
    # Pipeline states are cached and destroyed on shutdown
    return nothing
end

function backend_use_shader!(backend::MetalBackend, shader::MetalShaderProgram)
    # In Metal, pipeline state is set on the encoder, not globally
    # This is handled in the render passes directly
    return nothing
end

function backend_set_uniform!(backend::MetalBackend, shader::MetalShaderProgram, name::String, value)
    # In Metal, uniforms are buffer-based, not name-based
    # This is handled by the uniform buffer packing system
    return nothing
end

# ---- Mesh operations ----

function backend_upload_mesh!(backend::MetalBackend, entity_id, mesh)
    return metal_upload_mesh!(backend.gpu_cache, backend.device_handle, entity_id, mesh)
end

function backend_draw_mesh!(backend::MetalBackend, gpu_mesh::MetalGPUMesh)
    # Drawing requires an encoder handle — use render pass methods instead
    return nothing
end

function backend_destroy_mesh!(backend::MetalBackend, gpu_mesh::MetalGPUMesh)
    metal_destroy_mesh!(gpu_mesh)
    return nothing
end

# ---- Texture operations ----

function backend_upload_texture!(backend::MetalBackend, pixels::Vector{UInt8}, width::Int, height::Int, channels::Int)
    return metal_upload_texture_to_gpu(backend.device_handle, pixels, width, height, channels)
end

function backend_bind_texture!(backend::MetalBackend, texture::MetalGPUTexture, unit::Int)
    # In Metal, textures are bound on encoders — handled in render passes
    return nothing
end

function backend_destroy_texture!(backend::MetalBackend, texture::MetalGPUTexture)
    metal_destroy_texture!(texture)
    return nothing
end

# ---- Framebuffer operations ----

function backend_create_framebuffer!(backend::MetalBackend, width::Int, height::Int)
    rt = MetalRenderTarget(width=width, height=height)
    metal_create_render_target!(rt, backend.device_handle, width, height)
    return rt
end

function backend_bind_framebuffer!(backend::MetalBackend, fb::MetalRenderTarget)
    # In Metal, render targets are bound via render pass descriptors
    return nothing
end

function backend_unbind_framebuffer!(backend::MetalBackend)
    return nothing
end

function backend_destroy_framebuffer!(backend::MetalBackend, fb::MetalRenderTarget)
    metal_destroy_render_target!(fb)
    return nothing
end

# ---- G-Buffer ----

function backend_create_gbuffer!(backend::MetalBackend, width::Int, height::Int)
    gb = MetalGBuffer(width=width, height=height)
    metal_create_gbuffer!(gb, backend.device_handle, width, height)
    return gb
end

# ---- Shadow maps ----

function backend_create_shadow_map!(backend::MetalBackend, width::Int, height::Int)
    sm = MetalShadowMap(width=width, height=height)
    metal_create_shadow_map_rt!(sm, backend.device_handle)
    return sm
end

function backend_create_csm!(backend::MetalBackend, num_cascades::Int, resolution::Int, near::Float32, far::Float32)
    csm = MetalCascadedShadowMap(num_cascades=num_cascades, resolution=resolution)
    metal_create_csm_rt!(csm, backend.device_handle, near, far)
    return csm
end

# ---- IBL ----

function backend_create_ibl_environment!(backend::MetalBackend, path::String, intensity::Float32)
    ibl = MetalIBLEnvironment(intensity=intensity)
    cmd_buf = metal_begin_frame(backend.device_handle)
    metal_create_ibl_environment!(ibl, backend.device_handle, path, cmd_buf)
    metal_end_frame(cmd_buf)
    return ibl
end

# ---- Screen-space effects ----

function backend_create_ssr_pass!(backend::MetalBackend, width::Int, height::Int)
    ssr = MetalSSRPass(width=width, height=height)
    metal_create_ssr_pass!(ssr, backend.device_handle, width, height)
    return ssr
end

function backend_create_ssao_pass!(backend::MetalBackend, width::Int, height::Int)
    ssao = MetalSSAOPass(width=width, height=height)
    metal_create_ssao_pass!(ssao, backend.device_handle, width, height)
    return ssao
end

function backend_create_taa_pass!(backend::MetalBackend, width::Int, height::Int)
    taa = MetalTAAPass(width=width, height=height)
    metal_create_taa_pass!(taa, backend.device_handle, width, height)
    return taa
end

# ---- Post-processing ----

function backend_create_post_process!(backend::MetalBackend, width::Int, height::Int, config)
    pp = MetalPostProcessPipeline(config=config)
    metal_create_post_process_pipeline!(pp, backend.device_handle, width, height)
    return pp
end

# ---- Render state operations ----

function backend_set_viewport!(backend::MetalBackend, x::Int, y::Int, width::Int, height::Int)
    # Viewport is set on the encoder per render pass
    return nothing
end

function backend_clear!(backend::MetalBackend; color::Bool=true, depth::Bool=true)
    # Clearing is handled via render pass load actions in Metal
    return nothing
end

function backend_set_depth_test!(backend::MetalBackend; enabled::Bool=true, write::Bool=true)
    # Depth state is set per render pass via depth stencil state objects
    return nothing
end

function backend_set_blend!(backend::MetalBackend; enabled::Bool=false)
    # Blend state is baked into pipeline state objects
    return nothing
end

function backend_set_cull_face!(backend::MetalBackend; enabled::Bool=true, front::Bool=false)
    # Cull mode is set on the encoder per render pass
    return nothing
end

function backend_swap_buffers!(backend::MetalBackend)
    # In Metal, presentation is handled by metal_end_frame
    return nothing
end

function backend_draw_fullscreen_quad!(backend::MetalBackend, quad_handle)
    # Fullscreen quads are drawn directly in render passes
    return nothing
end

function backend_blit_framebuffer!(backend::MetalBackend, src, dst, width::Int, height::Int;
                                    color::Bool=false, depth::Bool=false)
    # Blitting in Metal is done via blit encoders in render passes
    return nothing
end

# ---- Windowing / event loop ----

function backend_should_close(backend::MetalBackend)
    backend.window === nothing && return true
    return should_close(backend.window)
end

function backend_poll_events!(backend::MetalBackend)
    poll_events!()
    return nothing
end

function backend_get_time(::MetalBackend)
    return get_time()
end

function backend_capture_cursor!(backend::MetalBackend)
    backend.window !== nothing && capture_cursor!(backend.window)
    return nothing
end

function backend_release_cursor!(backend::MetalBackend)
    backend.window !== nothing && release_cursor!(backend.window)
    return nothing
end

function backend_is_key_pressed(backend::MetalBackend, key)
    return is_key_pressed(backend.input, key)
end

function backend_get_input(backend::MetalBackend)
    return backend.input
end

# ==================================================================
# Main Render Frame
# ==================================================================

function render_frame!(backend::MetalBackend, scene::Scene)
    if !backend.initialized
        error("Metal backend not initialized")
    end

    # Find active camera
    camera_id = find_active_camera()
    if camera_id === nothing
        # Clear screen
        cmd_buf = metal_begin_frame(backend.device_handle)
        encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_CLEAR,
                                                     0.1f0, 0.1f0, 0.1f0, 1.0f0)
        metal_end_render_pass(encoder)
        metal_end_frame(cmd_buf)
        return nothing
    end

    view = get_view_matrix(camera_id)
    proj = get_projection_matrix(camera_id)
    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    # Begin frame (acquire drawable + command buffer)
    cmd_buf = metal_begin_frame(backend.device_handle)
    backend.cmd_buf_handle = cmd_buf

    # ---- Check for IBL and create if needed ----
    if backend.deferred_pipeline !== nothing
        ibl_entities = entities_with_component(IBLComponent)
        if !isempty(ibl_entities) && backend.deferred_pipeline.ibl_env === nothing
            ibl_comp = get_component(ibl_entities[1], IBLComponent)
            if ibl_comp.enabled
                @info "Creating Metal IBL environment" path=ibl_comp.environment_path
                ibl_env = MetalIBLEnvironment(intensity=ibl_comp.intensity)
                metal_create_ibl_environment!(ibl_env, backend.device_handle,
                                               ibl_comp.environment_path, cmd_buf)
                backend.deferred_pipeline.ibl_env = ibl_env
            end
        end
    end

    # ---- Cascaded Shadow Map pass ----
    has_shadows = false
    if backend.csm !== nothing
        dir_entities = entities_with_component(DirectionalLightComponent)
        if !isempty(dir_entities)
            light = get_component(dir_entities[1], DirectionalLightComponent)
            metal_render_csm_passes!(backend, backend.csm, view, proj, light.direction, cmd_buf)
            has_shadows = true
        end
    end

    # ---- Frustum culling + entity classification ----
    vp = proj * view
    frustum = extract_frustum(vp)

    opaque_entities = Tuple{EntityID, MeshComponent, Mat4f, SMatrix{3,3,Float32,9}}[]
    transparent_entities = Tuple{EntityID, MeshComponent, Mat4f, SMatrix{3,3,Float32,9}, Float32}[]

    iterate_components(MeshComponent) do entity_id, mesh
        isempty(mesh.indices) && return

        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)

        bs = get!(backend.bounds_cache, entity_id) do
            bounding_sphere_from_mesh(mesh)
        end
        world_center, world_radius = transform_bounding_sphere(bs, model)
        if !is_sphere_in_frustum(frustum, world_center, world_radius)
            return
        end

        model3 = SMatrix{3, 3, Float32, 9}(
            model[1,1], model[2,1], model[3,1],
            model[1,2], model[2,2], model[3,2],
            model[1,3], model[2,3], model[3,3]
        )
        normal_matrix = SMatrix{3, 3, Float32, 9}(transpose(inv(model3)))

        material = get_component(entity_id, MaterialComponent)
        is_transparent = material !== nothing && (material.opacity < 1.0f0 || material.alpha_cutoff > 0.0f0)

        if is_transparent
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            dist_sq = dx*dx + dy*dy + dz*dz
            push!(transparent_entities, (entity_id, mesh, model, normal_matrix, dist_sq))
        else
            push!(opaque_entities, (entity_id, mesh, model, normal_matrix))
        end
    end

    # Collect lights
    light_data = collect_lights()

    # ==================================================================
    # DEFERRED RENDERING PATH
    # ==================================================================
    if backend.use_deferred && backend.deferred_pipeline !== nothing
        pipeline = backend.deferred_pipeline

        # G-Buffer pass
        metal_render_gbuffer_pass!(backend, pipeline, opaque_entities, view, proj, cam_pos, cmd_buf)

        # Deferred lighting pass
        metal_render_deferred_lighting_pass!(backend, pipeline, cam_pos, view, proj,
                                              light_data, cmd_buf)

        # SSAO
        if pipeline.ssao_pass !== nothing
            metal_render_ssao!(pipeline.ssao_pass, backend, pipeline.gbuffer, proj, cmd_buf)
        end

        # SSR
        if pipeline.ssr_pass !== nothing && pipeline.lighting_rt !== nothing
            lighting_tex = pipeline.lighting_rt.color_texture_handles[1]
            metal_render_ssr!(pipeline.ssr_pass, backend, pipeline.gbuffer,
                              lighting_tex, view, proj, cam_pos, cmd_buf)
        end

        # TAA
        final_color_texture = pipeline.lighting_rt.color_texture_handles[1]
        if pipeline.taa_pass !== nothing
            final_color_texture = metal_render_taa!(pipeline.taa_pass, backend,
                                                      final_color_texture,
                                                      pipeline.gbuffer.depth,
                                                      view, proj, cmd_buf)
        end

        # Depth of Field (between TAA and post-processing)
        if pipeline.dof_pass !== nothing && backend.post_process !== nothing &&
           backend.post_process.config.dof_enabled
            final_color_texture = metal_render_dof!(pipeline.dof_pass, backend,
                                                      final_color_texture,
                                                      pipeline.gbuffer.depth,
                                                      backend.post_process.config, cmd_buf)
        end

        # Motion Blur (after DOF, before post-processing)
        if pipeline.motion_blur_pass !== nothing && backend.post_process !== nothing &&
           backend.post_process.config.motion_blur_enabled
            final_color_texture = metal_render_motion_blur!(pipeline.motion_blur_pass, backend,
                                                              final_color_texture,
                                                              pipeline.gbuffer.depth,
                                                              vp, backend.post_process.config, cmd_buf)
        end

        # Post-processing (bloom + tone mapping + gamma) → drawable
        if backend.post_process !== nothing
            metal_run_post_process!(backend.post_process, backend, final_color_texture,
                                     cmd_buf, backend.width, backend.height)
        else
            # Simple blit to drawable
            encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_CLEAR,
                                                         0.0f0, 0.0f0, 0.0f0, 1.0f0)
            blit_msl = _load_msl_shader("blit.metal")
            blit_pipeline = metal_get_or_create_pipeline(blit_msl, "blit_vertex", "blit_fragment";
                num_color_attachments=Int32(1),
                color_formats=UInt32[MTL_PIXEL_FORMAT_BGRA8_UNORM],
                depth_format=UInt32(0), blend_enabled=Int32(0))
            metal_set_render_pipeline(encoder, blit_pipeline)
            metal_set_viewport(encoder, 0.0, 0.0, Float64(backend.width), Float64(backend.height), 0.0, 1.0)
            metal_set_vertex_buffer(encoder, pipeline.quad_vertex_buffer, 0, Int32(0))
            metal_set_fragment_texture(encoder, final_color_texture, Int32(0))
            metal_set_fragment_sampler(encoder, backend.default_sampler, Int32(0))
            metal_draw_primitives(encoder, MTL_PRIMITIVE_TRIANGLE, Int32(0), Int32(6))
            metal_end_render_pass(encoder)
        end

        # UI Rendering (after post-processing, on top of everything)
        if backend.ui_renderer !== nothing && backend.ui_renderer.initialized
            ui_ctx = get_ui_context()
            if ui_ctx !== nothing
                metal_render_ui!(backend.ui_renderer, backend, ui_ctx, cmd_buf)
            end
        end

    # ==================================================================
    # FORWARD RENDERING PATH
    # ==================================================================
    else
        encoder = metal_begin_render_pass_drawable(cmd_buf, MTL_LOAD_CLEAR,
                                                     0.1f0, 0.1f0, 0.1f0, 1.0f0)
        metal_set_render_pipeline(encoder, backend.forward_pipeline)
        metal_set_depth_stencil_state(encoder, backend.ds_less_write)
        metal_set_cull_mode(encoder, MTL_CULL_BACK)
        metal_set_viewport(encoder, 0.0, 0.0, Float64(backend.width), Float64(backend.height), 0.0, 1.0)

        # Per-frame uniforms
        frame_uniforms = pack_per_frame(view, proj, cam_pos, Float32(time()))
        frame_buf = _create_uniform_buffer(backend.device_handle, frame_uniforms, "frame")
        metal_set_vertex_buffer(encoder, frame_buf, 0, Int32(3))
        metal_set_fragment_buffer(encoder, frame_buf, 0, Int32(3))

        # Light uniforms
        light_uniforms = pack_lights(light_data)
        light_buf = _create_uniform_buffer(backend.device_handle, light_uniforms, "lights")
        metal_set_fragment_buffer(encoder, light_buf, 0, Int32(6))

        # Shadow uniforms
        shadow_uniforms = if has_shadows && backend.csm !== nothing
            pack_shadow_uniforms(backend.csm, true)
        else
            MetalShadowUniforms(ntuple(_ -> ntuple(_ -> 0.0f0, 16), 4),
                                 ntuple(_ -> 0.0f0, 5), Int32(0), Int32(0), 0.0f0)
        end
        shadow_buf = _create_uniform_buffer(backend.device_handle, shadow_uniforms, "shadows")
        metal_set_fragment_buffer(encoder, shadow_buf, 0, Int32(7))

        # Bind CSM depth textures
        if has_shadows && backend.csm !== nothing
            for i in 1:backend.csm.num_cascades
                metal_set_fragment_texture(encoder, backend.csm.cascade_depth_textures[i], Int32(9 + i))
            end
        end

        metal_set_fragment_sampler(encoder, backend.default_sampler, Int32(0))
        metal_set_fragment_sampler(encoder, backend.shadow_sampler, Int32(1))

        # Render opaque entities
        for (entity_id, mesh, model, normal_matrix) in opaque_entities
            material = get_component(entity_id, MaterialComponent)
            if material === nothing
                material = MaterialComponent()
            end

            obj_uniforms = pack_per_object(model, normal_matrix)
            obj_buf = _create_uniform_buffer(backend.device_handle, obj_uniforms, "obj")
            metal_set_vertex_buffer(encoder, obj_buf, 0, Int32(4))
            metal_set_fragment_buffer(encoder, obj_buf, 0, Int32(4))

            mat_uniforms = pack_material(material)
            mat_buf = _create_uniform_buffer(backend.device_handle, mat_uniforms, "mat")
            metal_set_fragment_buffer(encoder, mat_buf, 0, Int32(5))

            metal_bind_material_textures!(encoder, material, backend.texture_cache, backend.device_handle)

            gpu_mesh = metal_get_or_upload_mesh!(backend.gpu_cache, backend.device_handle, entity_id, mesh)
            metal_draw_mesh!(encoder, gpu_mesh)

            metal_destroy_buffer(obj_buf)
            metal_destroy_buffer(mat_buf)
        end

        # Render transparent entities (back-to-front)
        if !isempty(transparent_entities)
            sort!(transparent_entities, by=x -> -x[5])
            metal_set_cull_mode(encoder, MTL_CULL_NONE)

            for (entity_id, mesh, model, normal_matrix, _) in transparent_entities
                material = get_component(entity_id, MaterialComponent)
                if material === nothing continue end

                obj_uniforms = pack_per_object(model, normal_matrix)
                obj_buf = _create_uniform_buffer(backend.device_handle, obj_uniforms, "obj_t")
                metal_set_vertex_buffer(encoder, obj_buf, 0, Int32(4))
                metal_set_fragment_buffer(encoder, obj_buf, 0, Int32(4))

                mat_uniforms = pack_material(material)
                mat_buf = _create_uniform_buffer(backend.device_handle, mat_uniforms, "mat_t")
                metal_set_fragment_buffer(encoder, mat_buf, 0, Int32(5))

                metal_bind_material_textures!(encoder, material, backend.texture_cache, backend.device_handle)

                gpu_mesh = metal_get_or_upload_mesh!(backend.gpu_cache, backend.device_handle, entity_id, mesh)
                metal_draw_mesh!(encoder, gpu_mesh)

                metal_destroy_buffer(obj_buf)
                metal_destroy_buffer(mat_buf)
            end
        end

        metal_end_render_pass(encoder)
        metal_destroy_buffer(frame_buf)
        metal_destroy_buffer(light_buf)
        metal_destroy_buffer(shadow_buf)
    end

    # Present frame
    metal_end_frame(cmd_buf)

    return nothing
end
