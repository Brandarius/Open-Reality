# Metal instanced rendering — instance buffer management

"""
    MetalInstanceBuffer

GPU buffer for per-instance transform data on the Metal backend.
Stores model matrices (float4x4) and normal matrix columns (3x float4) per instance.
Layout per instance: float4x4 model (16 floats) + 3x float4 normal columns (12 floats) = 28 floats.
Julia-side packing uses 25 floats (mat4 + mat3 column-major), then expands to the
Metal InstanceData struct layout (28 floats) for shader consumption.
"""
mutable struct MetalInstanceBuffer
    buffer_handle::UInt64
    capacity::Int    # Max instances currently allocated

    MetalInstanceBuffer() = new(UInt64(0), 0)
end

"""
    metal_upload_instance_data!(buf::MetalInstanceBuffer, device_handle::UInt64,
                                 models::Vector{Mat4f},
                                 normals::Vector{SMatrix{3,3,Float32,9}})

Upload per-instance transform data to a Metal buffer. Creates or resizes the buffer
as needed. Packs data in the InstanceData struct layout expected by the instanced
Metal shader: float4x4 model (16 floats) + 3x float4 normal columns (12 floats)
= 28 floats per instance.
"""
function metal_upload_instance_data!(buf::MetalInstanceBuffer, device_handle::UInt64,
                                      models::Vector{Mat4f},
                                      normals::Vector{SMatrix{3,3,Float32,9}})
    count = length(models)
    @assert count == length(normals)

    # Pack data matching Metal InstanceData struct:
    #   float4x4 model         (16 floats, column-major)
    #   float4   normal_col0   (4 floats — xyz used, w padding)
    #   float4   normal_col1   (4 floats — xyz used, w padding)
    #   float4   normal_col2   (4 floats — xyz used, w padding)
    # Total: 28 floats per instance
    floats_per_instance = 16 + 12
    data = Vector{Float32}(undef, count * floats_per_instance)

    for i in 1:count
        base = (i - 1) * floats_per_instance

        # Model matrix — column-major (matches Metal float4x4 layout)
        m = models[i]
        for col in 1:4, row in 1:4
            data[base + (col-1)*4 + row] = m[row, col]
        end

        # Normal matrix columns as float4 (xyz from mat3 column, w = 0)
        n = normals[i]
        for col in 1:3
            offset = 16 + (col-1)*4
            for row in 1:3
                data[base + offset + row] = n[row, col]
            end
            data[base + offset + 4] = 0.0f0  # w padding
        end
    end

    byte_count = count * floats_per_instance * sizeof(Float32)

    GC.@preserve data begin
        if buf.buffer_handle == UInt64(0)
            # Create new buffer with some headroom
            buf.capacity = max(count, 16)
            alloc_bytes = buf.capacity * floats_per_instance * sizeof(Float32)
            buf.buffer_handle = metal_create_buffer(device_handle, pointer(data), alloc_bytes,
                                                     "instance_data")
        elseif count > buf.capacity
            # Resize: destroy old buffer and create a larger one
            metal_destroy_buffer(buf.buffer_handle)
            buf.capacity = max(count, buf.capacity * 2, 16)
            alloc_bytes = buf.capacity * floats_per_instance * sizeof(Float32)
            buf.buffer_handle = metal_create_buffer(device_handle, pointer(data), alloc_bytes,
                                                     "instance_data")
        else
            # Update existing buffer in-place
            metal_update_buffer(buf.buffer_handle, pointer(data), 0, byte_count)
        end
    end

    return nothing
end

"""
    metal_draw_instanced!(encoder_handle::UInt64, gpu_mesh::MetalGPUMesh,
                           instance_buffer::MetalInstanceBuffer, instance_count::Int)

Bind mesh vertex buffers, bind the instance buffer at vertex buffer index 5,
and issue an instanced indexed draw call.
"""
function metal_draw_instanced!(encoder_handle::UInt64, gpu_mesh::MetalGPUMesh,
                                instance_buffer::MetalInstanceBuffer, instance_count::Int)
    # Bind mesh vertex buffers: positions=0, normals=1, uvs=2
    metal_set_vertex_buffer(encoder_handle, gpu_mesh.vertex_buffer, 0, Int32(0))
    if gpu_mesh.normal_buffer != UInt64(0)
        metal_set_vertex_buffer(encoder_handle, gpu_mesh.normal_buffer, 0, Int32(1))
    end
    if gpu_mesh.uv_buffer != UInt64(0)
        metal_set_vertex_buffer(encoder_handle, gpu_mesh.uv_buffer, 0, Int32(2))
    end

    # Bind instance data buffer at index 5
    metal_set_vertex_buffer(encoder_handle, instance_buffer.buffer_handle, 0, Int32(5))

    # Issue instanced indexed draw
    metal_draw_indexed_instanced(encoder_handle, MTL_PRIMITIVE_TRIANGLE,
                                  gpu_mesh.index_count, gpu_mesh.index_buffer,
                                  0, Int32(instance_count))
    return nothing
end

"""
    destroy_metal_instance_buffer!(buf::MetalInstanceBuffer)

Release GPU resources for the Metal instance buffer.
"""
function destroy_metal_instance_buffer!(buf::MetalInstanceBuffer)
    if buf.buffer_handle != UInt64(0)
        metal_destroy_buffer(buf.buffer_handle)
        buf.buffer_handle = UInt64(0)
    end
    buf.capacity = 0
    return nothing
end

# Global instance buffer (reused across frames)
const _METAL_INSTANCE_BUFFER = Ref{Union{MetalInstanceBuffer, Nothing}}(nothing)

"""
    get_metal_instance_buffer!() -> MetalInstanceBuffer

Get or create the global Metal instance buffer.
"""
function get_metal_instance_buffer!()
    if _METAL_INSTANCE_BUFFER[] === nothing
        _METAL_INSTANCE_BUFFER[] = MetalInstanceBuffer()
    end
    return _METAL_INSTANCE_BUFFER[]
end

"""
    reset_metal_instance_buffer!()

Destroy the global Metal instance buffer.
"""
function reset_metal_instance_buffer!()
    if _METAL_INSTANCE_BUFFER[] !== nothing
        destroy_metal_instance_buffer!(_METAL_INSTANCE_BUFFER[])
        _METAL_INSTANCE_BUFFER[] = nothing
    end
    return nothing
end

"""
    backend_draw_mesh_instanced!(backend::MetalBackend, gpu_mesh::MetalGPUMesh, instance_count::Int)

Issue an instanced draw call for the given GPU mesh on the Metal backend.
In the Metal deferred path, the actual instanced draw is performed during the
G-Buffer render pass; this method serves as the abstract backend entry point.
"""
function backend_draw_mesh_instanced!(backend::MetalBackend, gpu_mesh::MetalGPUMesh, instance_count::Int)
    # In Metal, instanced drawing requires an active render encoder.
    # The actual instanced draw is dispatched inside the render pass
    # (e.g., metal_render_gbuffer_pass!) which has access to the encoder.
    # This stub satisfies the abstract backend interface.
    return nothing
end
