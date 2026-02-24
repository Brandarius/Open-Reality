import Metal

// MARK: - Compute Pipeline Wrapper

final class MetalComputePipelineWrapper {
    let pipelineState: MTLComputePipelineState
    init(pipelineState: MTLComputePipelineState) { self.pipelineState = pipelineState }
}

// MARK: - Compute Encoder Wrapper

final class MetalComputeEncoderWrapper {
    let encoder: MTLComputeCommandEncoder
    init(encoder: MTLComputeCommandEncoder) { self.encoder = encoder }
}

// MARK: - Create Compute Pipeline

/// Compile MSL source and create a compute pipeline state.
///
/// - Parameters:
///   - mslSource: Metal Shading Language source code.
///   - functionName: Name of the kernel function.
/// - Returns: Handle to a MetalComputePipelineWrapper, or 0 on failure.
@_cdecl("metal_create_compute_pipeline")
public func metal_create_compute_pipeline(
    _ mslSource: UnsafePointer<CChar>,
    _ functionName: UnsafePointer<CChar>
) -> UInt64 {
    guard let deviceWrapper = globalDevice else {
        print("[MetalCompute] ERROR: No global device set.")
        return 0
    }

    let source = String(cString: mslSource)
    let funcName = String(cString: functionName)

    guard let library = try? deviceWrapper.device.makeLibrary(source: source, options: nil) else {
        print("[MetalCompute] ERROR: Failed to compile MSL source.")
        return 0
    }

    guard let function = library.makeFunction(name: funcName) else {
        print("[MetalCompute] ERROR: Function '\(funcName)' not found in MSL source.")
        return 0
    }

    guard let pipelineState = try? deviceWrapper.device.makeComputePipelineState(function: function) else {
        print("[MetalCompute] ERROR: Failed to create compute pipeline state for '\(funcName)'.")
        return 0
    }

    let wrapper = MetalComputePipelineWrapper(pipelineState: pipelineState)
    return registry.insert(wrapper)
}

// MARK: - Destroy Compute Pipeline

@_cdecl("metal_destroy_compute_pipeline")
public func metal_destroy_compute_pipeline(_ handle: UInt64) {
    registry.remove(handle)
}

// MARK: - Begin Compute Pass

/// Create a compute command encoder from a command buffer.
///
/// - Parameter cmdBufHandle: Handle to a MetalCommandBufferWrapper.
/// - Returns: Handle to a MetalComputeEncoderWrapper.
@_cdecl("metal_begin_compute_pass")
public func metal_begin_compute_pass(_ cmdBufHandle: UInt64) -> UInt64 {
    guard let cmdBufWrapper: MetalCommandBufferWrapper = registry.get(cmdBufHandle) else {
        fatalError("metal_begin_compute_pass: Invalid command buffer handle \(cmdBufHandle).")
    }

    guard let encoder = cmdBufWrapper.commandBuffer.makeComputeCommandEncoder() else {
        fatalError("metal_begin_compute_pass: Failed to create compute command encoder.")
    }

    let wrapper = MetalComputeEncoderWrapper(encoder: encoder)
    return registry.insert(wrapper)
}

// MARK: - End Compute Pass

@_cdecl("metal_end_compute_pass")
public func metal_end_compute_pass(_ encoderHandle: UInt64) {
    guard let wrapper: MetalComputeEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalCompute] ERROR: Invalid compute encoder handle \(encoderHandle)")
        return
    }

    wrapper.encoder.endEncoding()
    registry.remove(encoderHandle)
}

// MARK: - Set Compute Buffer

@_cdecl("metal_set_compute_buffer")
public func metal_set_compute_buffer(_ encoderHandle: UInt64, _ bufferHandle: UInt64, _ offset: Int, _ index: Int32) {
    guard let encoderWrapper: MetalComputeEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalCompute] ERROR: Invalid compute encoder handle \(encoderHandle)")
        return
    }

    guard let bufferWrapper: MetalBufferWrapper = registry.get(bufferHandle) else {
        print("[MetalCompute] ERROR: Invalid buffer handle \(bufferHandle)")
        return
    }

    encoderWrapper.encoder.setBuffer(bufferWrapper.buffer, offset: offset, index: Int(index))
}

// MARK: - Set Compute Texture

@_cdecl("metal_set_compute_texture")
public func metal_set_compute_texture(_ encoderHandle: UInt64, _ textureHandle: UInt64, _ index: Int32) {
    guard let encoderWrapper: MetalComputeEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalCompute] ERROR: Invalid compute encoder handle \(encoderHandle)")
        return
    }

    guard let textureWrapper: MetalTextureWrapper = registry.get(textureHandle) else {
        print("[MetalCompute] ERROR: Invalid texture handle \(textureHandle)")
        return
    }

    encoderWrapper.encoder.setTexture(textureWrapper.texture, index: Int(index))
}

// MARK: - Dispatch Threads

/// Dispatch compute work with explicit threadgroup sizes.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalComputeEncoderWrapper.
///   - pipelineHandle: Handle to a MetalComputePipelineWrapper (needed for threadExecutionWidth).
///   - gridX/Y/Z: Total number of threads in each dimension.
///   - groupX/Y/Z: Threads per threadgroup in each dimension.
@_cdecl("metal_dispatch_threadgroups")
public func metal_dispatch_threadgroups(
    _ encoderHandle: UInt64,
    _ pipelineHandle: UInt64,
    _ gridX: Int32, _ gridY: Int32, _ gridZ: Int32,
    _ groupX: Int32, _ groupY: Int32, _ groupZ: Int32
) {
    guard let encoderWrapper: MetalComputeEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalCompute] ERROR: Invalid compute encoder handle \(encoderHandle)")
        return
    }

    guard let pipelineWrapper: MetalComputePipelineWrapper = registry.get(pipelineHandle) else {
        print("[MetalCompute] ERROR: Invalid compute pipeline handle \(pipelineHandle)")
        return
    }

    encoderWrapper.encoder.setComputePipelineState(pipelineWrapper.pipelineState)

    let threadsPerThreadgroup = MTLSize(width: Int(groupX), height: Int(groupY), depth: Int(groupZ))
    let threadgroupsPerGrid = MTLSize(
        width: (Int(gridX) + Int(groupX) - 1) / Int(groupX),
        height: (Int(gridY) + Int(groupY) - 1) / Int(groupY),
        depth: (Int(gridZ) + Int(groupZ) - 1) / Int(groupZ)
    )

    encoderWrapper.encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
}
