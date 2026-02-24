# Metal bridge FFI — ccall wrappers for every @_cdecl function in the Swift bridge

# Path to the compiled Metal bridge dylib
const METAL_BRIDGE_LIB = let
    env_path = get(ENV, "OPENREALITY_METAL_LIB", "")
    if !isempty(env_path) && isfile(env_path)
        env_path
    else
        joinpath(@__DIR__, "..", "..", "..", "metal_bridge", ".build", "release", "libMetalBridge.dylib")
    end
end

function _metal_lib()
    if !isfile(METAL_BRIDGE_LIB)
        error("Metal bridge library not found at $METAL_BRIDGE_LIB. Run `swift build -c release` in metal_bridge/")
    end
    return METAL_BRIDGE_LIB
end

# ==================================================================
# Device lifecycle
# ==================================================================

function metal_init(nswindow::Ptr{Cvoid}, width::Int32, height::Int32)::UInt64
    ccall((:metal_init, _metal_lib()), UInt64, (Ptr{Cvoid}, Int32, Int32), nswindow, width, height)
end

function metal_shutdown(device_handle::UInt64)
    ccall((:metal_shutdown, _metal_lib()), Cvoid, (UInt64,), device_handle)
end

function metal_resize(device_handle::UInt64, width::Int32, height::Int32)
    ccall((:metal_resize, _metal_lib()), Cvoid, (UInt64, Int32, Int32), device_handle, width, height)
end

function metal_begin_frame(device_handle::UInt64)::UInt64
    ccall((:metal_begin_frame, _metal_lib()), UInt64, (UInt64,), device_handle)
end

function metal_end_frame(cmd_buf_handle::UInt64)
    ccall((:metal_end_frame, _metal_lib()), Cvoid, (UInt64,), cmd_buf_handle)
end

# ==================================================================
# Render pipeline (shader)
# ==================================================================

function metal_create_render_pipeline(msl_source::String, vertex_func::String, fragment_func::String,
                                       num_color_attachments::Int32, color_formats::Vector{UInt32},
                                       depth_format::UInt32, blend_enabled::Int32)::UInt64
    ccall((:metal_create_render_pipeline, _metal_lib()), UInt64,
          (Cstring, Cstring, Cstring, Int32, Ptr{UInt32}, UInt32, Int32),
          msl_source, vertex_func, fragment_func, num_color_attachments,
          color_formats, depth_format, blend_enabled)
end

function metal_destroy_render_pipeline(handle::UInt64)
    ccall((:metal_destroy_render_pipeline, _metal_lib()), Cvoid, (UInt64,), handle)
end

function metal_create_depth_stencil_state(device_handle::UInt64, depth_compare::UInt32, depth_write::Int32)::UInt64
    ccall((:metal_create_depth_stencil_state, _metal_lib()), UInt64,
          (UInt64, UInt32, Int32), device_handle, depth_compare, depth_write)
end

function metal_create_sampler(device_handle::UInt64, min_filter::Int32, mag_filter::Int32,
                               mip_filter::Int32, address_mode::Int32)::UInt64
    ccall((:metal_create_sampler, _metal_lib()), UInt64,
          (UInt64, Int32, Int32, Int32, Int32),
          device_handle, min_filter, mag_filter, mip_filter, address_mode)
end

# ==================================================================
# Buffers
# ==================================================================

function metal_create_buffer(device_handle::UInt64, data::Ptr, length::Int, label::String)::UInt64
    ccall((:metal_create_buffer, _metal_lib()), UInt64,
          (UInt64, Ptr{Cvoid}, Int, Cstring), device_handle, data, length, label)
end

function metal_update_buffer(buffer_handle::UInt64, data::Ptr, offset::Int, length::Int)
    ccall((:metal_update_buffer, _metal_lib()), Cvoid,
          (UInt64, Ptr{Cvoid}, Int, Int), buffer_handle, data, offset, length)
end

function metal_destroy_buffer(handle::UInt64)
    ccall((:metal_destroy_buffer, _metal_lib()), Cvoid, (UInt64,), handle)
end

function metal_get_buffer_length(buffer_handle::UInt64)::Int
    ccall((:metal_get_buffer_length, _metal_lib()), Int, (UInt64,), buffer_handle)
end

# ==================================================================
# Textures
# ==================================================================

function metal_create_texture_2d(device_handle::UInt64, width::Int32, height::Int32,
                                  format::UInt32, mipmapped::Int32, usage::Int32, label::String)::UInt64
    ccall((:metal_create_texture_2d, _metal_lib()), UInt64,
          (UInt64, Int32, Int32, UInt32, Int32, Int32, Cstring),
          device_handle, width, height, format, mipmapped, usage, label)
end

function metal_upload_texture_2d(texture_handle::UInt64, data::Ptr,
                                  width::Int32, height::Int32, bytes_per_pixel::Int32)
    ccall((:metal_upload_texture_2d, _metal_lib()), Cvoid,
          (UInt64, Ptr{Cvoid}, Int32, Int32, Int32),
          texture_handle, data, width, height, bytes_per_pixel)
end

function metal_create_texture_cube(device_handle::UInt64, size::Int32, format::UInt32,
                                    mipmapped::Int32, label::String)::UInt64
    ccall((:metal_create_texture_cube, _metal_lib()), UInt64,
          (UInt64, Int32, UInt32, Int32, Cstring),
          device_handle, size, format, mipmapped, label)
end

function metal_upload_texture_cube_face(texture_handle::UInt64, face::Int32, data::Ptr,
                                         size::Int32, bytes_per_pixel::Int32)
    ccall((:metal_upload_texture_cube_face, _metal_lib()), Cvoid,
          (UInt64, Int32, Ptr{Cvoid}, Int32, Int32),
          texture_handle, face, data, size, bytes_per_pixel)
end

function metal_destroy_texture(handle::UInt64)
    ccall((:metal_destroy_texture, _metal_lib()), Cvoid, (UInt64,), handle)
end

# ==================================================================
# Render targets (framebuffers)
# ==================================================================

function metal_create_render_target(device_handle::UInt64, width::Int32, height::Int32,
                                     num_color::Int32, color_formats::Vector{UInt32},
                                     has_depth::Int32, depth_format::UInt32, label::String)::UInt64
    ccall((:metal_create_render_target, _metal_lib()), UInt64,
          (UInt64, Int32, Int32, Int32, Ptr{UInt32}, Int32, UInt32, Cstring),
          device_handle, width, height, num_color, color_formats, has_depth, depth_format, label)
end

function metal_get_rt_color_texture(rt_handle::UInt64, index::Int32)::UInt64
    ccall((:metal_get_rt_color_texture, _metal_lib()), UInt64,
          (UInt64, Int32), rt_handle, index)
end

function metal_get_rt_depth_texture(rt_handle::UInt64)::UInt64
    ccall((:metal_get_rt_depth_texture, _metal_lib()), UInt64, (UInt64,), rt_handle)
end

function metal_resize_render_target(rt_handle::UInt64, width::Int32, height::Int32)
    ccall((:metal_resize_render_target, _metal_lib()), Cvoid,
          (UInt64, Int32, Int32), rt_handle, width, height)
end

function metal_destroy_render_target(handle::UInt64)
    ccall((:metal_destroy_render_target, _metal_lib()), Cvoid, (UInt64,), handle)
end

# ==================================================================
# Render pass encoding
# ==================================================================

function metal_begin_render_pass(cmd_buf_handle::UInt64, rt_handle::UInt64,
                                  load_action::UInt32, store_action::UInt32,
                                  clear_r::Float32, clear_g::Float32,
                                  clear_b::Float32, clear_a::Float32,
                                  clear_depth::Float64)::UInt64
    ccall((:metal_begin_render_pass, _metal_lib()), UInt64,
          (UInt64, UInt64, UInt32, UInt32, Float32, Float32, Float32, Float32, Float64),
          cmd_buf_handle, rt_handle, load_action, store_action,
          clear_r, clear_g, clear_b, clear_a, clear_depth)
end

function metal_begin_render_pass_drawable(cmd_buf_handle::UInt64, load_action::UInt32,
                                           clear_r::Float32, clear_g::Float32,
                                           clear_b::Float32, clear_a::Float32)::UInt64
    ccall((:metal_begin_render_pass_drawable, _metal_lib()), UInt64,
          (UInt64, UInt32, Float32, Float32, Float32, Float32),
          cmd_buf_handle, load_action, clear_r, clear_g, clear_b, clear_a)
end

function metal_end_render_pass(encoder_handle::UInt64)
    ccall((:metal_end_render_pass, _metal_lib()), Cvoid, (UInt64,), encoder_handle)
end

function metal_set_render_pipeline(encoder_handle::UInt64, pipeline_handle::UInt64)
    ccall((:metal_set_render_pipeline, _metal_lib()), Cvoid,
          (UInt64, UInt64), encoder_handle, pipeline_handle)
end

function metal_set_vertex_buffer(encoder_handle::UInt64, buffer_handle::UInt64, offset::Int, index::Int32)
    ccall((:metal_set_vertex_buffer, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int, Int32), encoder_handle, buffer_handle, offset, index)
end

function metal_set_fragment_buffer(encoder_handle::UInt64, buffer_handle::UInt64, offset::Int, index::Int32)
    ccall((:metal_set_fragment_buffer, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int, Int32), encoder_handle, buffer_handle, offset, index)
end

function metal_set_fragment_texture(encoder_handle::UInt64, texture_handle::UInt64, index::Int32)
    ccall((:metal_set_fragment_texture, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int32), encoder_handle, texture_handle, index)
end

function metal_set_vertex_texture(encoder_handle::UInt64, texture_handle::UInt64, index::Int32)
    ccall((:metal_set_vertex_texture, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int32), encoder_handle, texture_handle, index)
end

function metal_set_fragment_sampler(encoder_handle::UInt64, sampler_handle::UInt64, index::Int32)
    ccall((:metal_set_fragment_sampler, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int32), encoder_handle, sampler_handle, index)
end

function metal_set_depth_stencil_state(encoder_handle::UInt64, state_handle::UInt64)
    ccall((:metal_set_depth_stencil_state, _metal_lib()), Cvoid,
          (UInt64, UInt64), encoder_handle, state_handle)
end

function metal_set_cull_mode(encoder_handle::UInt64, mode::UInt32)
    ccall((:metal_set_cull_mode, _metal_lib()), Cvoid, (UInt64, UInt32), encoder_handle, mode)
end

function metal_set_viewport(encoder_handle::UInt64, x::Float64, y::Float64,
                             width::Float64, height::Float64, znear::Float64, zfar::Float64)
    ccall((:metal_set_viewport, _metal_lib()), Cvoid,
          (UInt64, Float64, Float64, Float64, Float64, Float64, Float64),
          encoder_handle, x, y, width, height, znear, zfar)
end

function metal_draw_indexed(encoder_handle::UInt64, primitive_type::UInt32, index_count::Int32,
                             index_buffer_handle::UInt64, index_buffer_offset::Int)
    ccall((:metal_draw_indexed, _metal_lib()), Cvoid,
          (UInt64, UInt32, Int32, UInt64, Int),
          encoder_handle, primitive_type, index_count, index_buffer_handle, index_buffer_offset)
end

function metal_draw_primitives(encoder_handle::UInt64, primitive_type::UInt32,
                                vertex_start::Int32, vertex_count::Int32)
    ccall((:metal_draw_primitives, _metal_lib()), Cvoid,
          (UInt64, UInt32, Int32, Int32), encoder_handle, primitive_type, vertex_start, vertex_count)
end

function metal_set_scissor_rect(encoder_handle::UInt64, x::Int32, y::Int32, width::Int32, height::Int32)
    ccall((:metal_set_scissor_rect, _metal_lib()), Cvoid,
          (UInt64, Int32, Int32, Int32, Int32), encoder_handle, x, y, width, height)
end

# ==================================================================
# Blit operations
# ==================================================================

function metal_blit_texture(cmd_buf_handle::UInt64, src_texture_handle::UInt64, dst_texture_handle::UInt64)
    ccall((:metal_blit_texture, _metal_lib()), Cvoid,
          (UInt64, UInt64, UInt64), cmd_buf_handle, src_texture_handle, dst_texture_handle)
end

function metal_generate_mipmaps(cmd_buf_handle::UInt64, texture_handle::UInt64)
    ccall((:metal_generate_mipmaps, _metal_lib()), Cvoid,
          (UInt64, UInt64), cmd_buf_handle, texture_handle)
end

# ==================================================================
# Cube-face and direct-texture render passes (IBL)
# ==================================================================

function metal_begin_render_pass_cube_face(cmd_buf_handle::UInt64, cube_texture_handle::UInt64,
                                            face::Int32, mip_level::Int32, load_action::UInt32,
                                            clear_r::Float32, clear_g::Float32,
                                            clear_b::Float32, clear_a::Float32)::UInt64
    ccall((:metal_begin_render_pass_cube_face, _metal_lib()), UInt64,
          (UInt64, UInt64, Int32, Int32, UInt32, Float32, Float32, Float32, Float32),
          cmd_buf_handle, cube_texture_handle, face, mip_level, load_action,
          clear_r, clear_g, clear_b, clear_a)
end

function metal_begin_render_pass_texture(cmd_buf_handle::UInt64, texture_handle::UInt64,
                                          load_action::UInt32,
                                          clear_r::Float32, clear_g::Float32,
                                          clear_b::Float32, clear_a::Float32)::UInt64
    ccall((:metal_begin_render_pass_texture, _metal_lib()), UInt64,
          (UInt64, UInt64, UInt32, Float32, Float32, Float32, Float32),
          cmd_buf_handle, texture_handle, load_action,
          clear_r, clear_g, clear_b, clear_a)
end

# ==================================================================
# Instanced + indirect draw calls
# ==================================================================

function metal_draw_indexed_instanced(encoder_handle::UInt64, primitive_type::UInt32,
                                       index_count::Int32, index_buffer_handle::UInt64,
                                       index_buffer_offset::Int, instance_count::Int32)
    ccall((:metal_draw_indexed_instanced, _metal_lib()), Cvoid,
          (UInt64, UInt32, Int32, UInt64, Int, Int32),
          encoder_handle, primitive_type, index_count, index_buffer_handle,
          index_buffer_offset, instance_count)
end

function metal_draw_primitives_indirect(encoder_handle::UInt64, primitive_type::UInt32,
                                         indirect_buffer_handle::UInt64, indirect_buffer_offset::Int)
    ccall((:metal_draw_primitives_indirect, _metal_lib()), Cvoid,
          (UInt64, UInt32, UInt64, Int),
          encoder_handle, primitive_type, indirect_buffer_handle, indirect_buffer_offset)
end

# ==================================================================
# Compute shaders
# ==================================================================

function metal_create_compute_pipeline(msl_source::String, function_name::String)::UInt64
    ccall((:metal_create_compute_pipeline, _metal_lib()), UInt64,
          (Cstring, Cstring), msl_source, function_name)
end

function metal_destroy_compute_pipeline(handle::UInt64)
    ccall((:metal_destroy_compute_pipeline, _metal_lib()), Cvoid, (UInt64,), handle)
end

function metal_begin_compute_pass(cmd_buf_handle::UInt64)::UInt64
    ccall((:metal_begin_compute_pass, _metal_lib()), UInt64, (UInt64,), cmd_buf_handle)
end

function metal_end_compute_pass(encoder_handle::UInt64)
    ccall((:metal_end_compute_pass, _metal_lib()), Cvoid, (UInt64,), encoder_handle)
end

function metal_set_compute_buffer(encoder_handle::UInt64, buffer_handle::UInt64, offset::Int, index::Int32)
    ccall((:metal_set_compute_buffer, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int, Int32), encoder_handle, buffer_handle, offset, index)
end

function metal_set_compute_texture(encoder_handle::UInt64, texture_handle::UInt64, index::Int32)
    ccall((:metal_set_compute_texture, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int32), encoder_handle, texture_handle, index)
end

function metal_dispatch_threadgroups(encoder_handle::UInt64, pipeline_handle::UInt64,
                                      grid_x::Int32, grid_y::Int32, grid_z::Int32,
                                      group_x::Int32, group_y::Int32, group_z::Int32)
    ccall((:metal_dispatch_threadgroups, _metal_lib()), Cvoid,
          (UInt64, UInt64, Int32, Int32, Int32, Int32, Int32, Int32),
          encoder_handle, pipeline_handle, grid_x, grid_y, grid_z, group_x, group_y, group_z)
end
