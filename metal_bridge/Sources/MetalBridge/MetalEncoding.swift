import Metal
import MetalKit
import QuartzCore

// MARK: - Begin Render Pass

/// Begin a render pass targeting a render target (one or more color textures + optional depth).
///
/// - Parameters:
///   - cmdBufHandle: Handle to a MetalCommandBufferWrapper.
///   - rtHandle: Handle to a MetalRenderTargetWrapper.
///   - loadAction: Load action for color/depth attachments (MetalLoadAction raw value).
///   - storeAction: Store action for color/depth attachments (MetalStoreAction raw value).
///   - clearR/G/B/A: Clear color components (used when loadAction == clear).
///   - clearDepth: Clear depth value (used when loadAction == clear).
/// - Returns: Handle to a MetalRenderEncoderWrapper.
@_cdecl("metal_begin_render_pass")
public func metal_begin_render_pass(
    _ cmdBufHandle: UInt64,
    _ rtHandle: UInt64,
    _ loadAction: UInt32,
    _ storeAction: UInt32,
    _ clearR: Float,
    _ clearG: Float,
    _ clearB: Float,
    _ clearA: Float,
    _ clearDepth: Double
) -> UInt64 {
    guard let cmdBufWrapper: MetalCommandBufferWrapper = registry.get(cmdBufHandle) else {
        fatalError("metal_begin_render_pass: Invalid command buffer handle \(cmdBufHandle).")
    }

    guard let rtWrapper: MetalRenderTargetWrapper = registry.get(rtHandle) else {
        fatalError("metal_begin_render_pass: Invalid render target handle \(rtHandle).")
    }

    guard let mtlLoadAction = MetalLoadAction(rawValue: loadAction) else {
        fatalError("metal_begin_render_pass: Invalid load action \(loadAction).")
    }

    guard let mtlStoreAction = MetalStoreAction(rawValue: storeAction) else {
        fatalError("metal_begin_render_pass: Invalid store action \(storeAction).")
    }

    let descriptor = MTLRenderPassDescriptor()

    // Configure color attachments.
    for i in 0..<rtWrapper.colorTextures.count {
        descriptor.colorAttachments[i].texture = rtWrapper.colorTextures[i]
        descriptor.colorAttachments[i].loadAction = toMTLLoadAction(mtlLoadAction)
        descriptor.colorAttachments[i].storeAction = toMTLStoreAction(mtlStoreAction)

        if mtlLoadAction == .clear {
            descriptor.colorAttachments[i].clearColor = MTLClearColor(
                red: Double(clearR),
                green: Double(clearG),
                blue: Double(clearB),
                alpha: Double(clearA)
            )
        }
    }

    // Configure depth attachment if present.
    if let depthTexture = rtWrapper.depthTexture {
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = mtlLoadAction == .clear ? .clear : toMTLLoadAction(mtlLoadAction)
        descriptor.depthAttachment.storeAction = toMTLStoreAction(mtlStoreAction)
        descriptor.depthAttachment.clearDepth = clearDepth
    }

    guard let encoder = cmdBufWrapper.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        fatalError("metal_begin_render_pass: Failed to create render command encoder.")
    }

    let wrapper = MetalRenderEncoderWrapper(encoder: encoder)
    return registry.insert(wrapper)
}

// MARK: - Begin Render Pass (Drawable)

/// Begin a render pass targeting the current drawable texture (for final on-screen output).
///
/// - Parameters:
///   - cmdBufHandle: Handle to a MetalCommandBufferWrapper (must have a drawable).
///   - loadAction: Load action for the color attachment.
///   - clearR/G/B/A: Clear color components.
/// - Returns: Handle to a MetalRenderEncoderWrapper.
@_cdecl("metal_begin_render_pass_drawable")
public func metal_begin_render_pass_drawable(
    _ cmdBufHandle: UInt64,
    _ loadAction: UInt32,
    _ clearR: Float,
    _ clearG: Float,
    _ clearB: Float,
    _ clearA: Float
) -> UInt64 {
    guard let cmdBufWrapper: MetalCommandBufferWrapper = registry.get(cmdBufHandle) else {
        fatalError("metal_begin_render_pass_drawable: Invalid command buffer handle \(cmdBufHandle).")
    }

    guard let drawable = cmdBufWrapper.drawable else {
        fatalError("metal_begin_render_pass_drawable: Command buffer has no drawable.")
    }

    guard let mtlLoadAction = MetalLoadAction(rawValue: loadAction) else {
        fatalError("metal_begin_render_pass_drawable: Invalid load action \(loadAction).")
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = toMTLLoadAction(mtlLoadAction)
    descriptor.colorAttachments[0].storeAction = .store

    if mtlLoadAction == .clear {
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearR),
            green: Double(clearG),
            blue: Double(clearB),
            alpha: Double(clearA)
        )
    }

    guard let encoder = cmdBufWrapper.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        fatalError("metal_begin_render_pass_drawable: Failed to create render command encoder.")
    }

    let wrapper = MetalRenderEncoderWrapper(encoder: encoder)
    return registry.insert(wrapper)
}

// MARK: - End Render Pass

/// End a render pass and release the encoder handle.
///
/// - Parameter encoderHandle: Handle to a MetalRenderEncoderWrapper.
@_cdecl("metal_end_render_pass")
public func metal_end_render_pass(_ encoderHandle: UInt64) {
    guard let wrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    wrapper.encoder.endEncoding()
    registry.remove(encoderHandle)
}

// MARK: - Pipeline State

/// Set the render pipeline state on an encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - pipelineHandle: Handle to a MetalRenderPipelineWrapper.
@_cdecl("metal_set_render_pipeline")
public func metal_set_render_pipeline(_ encoderHandle: UInt64, _ pipelineHandle: UInt64) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let pipelineWrapper: MetalRenderPipelineWrapper = registry.get(pipelineHandle) else {
        print("[MetalEncoding] ERROR: Invalid pipeline handle \(pipelineHandle)")
        return
    }

    encoderWrapper.encoder.setRenderPipelineState(pipelineWrapper.pipelineState)
}

// MARK: - Vertex Buffer

/// Bind a vertex buffer to a specific index on the encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - bufferHandle: Handle to a MetalBufferWrapper.
///   - offset: Byte offset into the buffer.
///   - index: Buffer index in the vertex shader argument table.
@_cdecl("metal_set_vertex_buffer")
public func metal_set_vertex_buffer(_ encoderHandle: UInt64, _ bufferHandle: UInt64, _ offset: Int, _ index: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let bufferWrapper: MetalBufferWrapper = registry.get(bufferHandle) else {
        print("[MetalEncoding] ERROR: Invalid buffer handle \(bufferHandle)")
        return
    }

    encoderWrapper.encoder.setVertexBuffer(bufferWrapper.buffer, offset: offset, index: Int(index))
}

// MARK: - Fragment Buffer

/// Bind a fragment buffer to a specific index on the encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - bufferHandle: Handle to a MetalBufferWrapper.
///   - offset: Byte offset into the buffer.
///   - index: Buffer index in the fragment shader argument table.
@_cdecl("metal_set_fragment_buffer")
public func metal_set_fragment_buffer(_ encoderHandle: UInt64, _ bufferHandle: UInt64, _ offset: Int, _ index: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let bufferWrapper: MetalBufferWrapper = registry.get(bufferHandle) else {
        print("[MetalEncoding] ERROR: Invalid buffer handle \(bufferHandle)")
        return
    }

    encoderWrapper.encoder.setFragmentBuffer(bufferWrapper.buffer, offset: offset, index: Int(index))
}

// MARK: - Fragment Texture

/// Bind a texture to a specific index in the fragment shader.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - textureHandle: Handle to a MetalTextureWrapper.
///   - index: Texture index in the fragment shader argument table.
@_cdecl("metal_set_fragment_texture")
public func metal_set_fragment_texture(_ encoderHandle: UInt64, _ textureHandle: UInt64, _ index: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let textureWrapper: MetalTextureWrapper = registry.get(textureHandle) else {
        print("[MetalEncoding] ERROR: Invalid texture handle \(textureHandle)")
        return
    }

    encoderWrapper.encoder.setFragmentTexture(textureWrapper.texture, index: Int(index))
}

// MARK: - Vertex Texture

/// Bind a texture to a specific index in the vertex shader.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - textureHandle: Handle to a MetalTextureWrapper.
///   - index: Texture index in the vertex shader argument table.
@_cdecl("metal_set_vertex_texture")
public func metal_set_vertex_texture(_ encoderHandle: UInt64, _ textureHandle: UInt64, _ index: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let textureWrapper: MetalTextureWrapper = registry.get(textureHandle) else {
        print("[MetalEncoding] ERROR: Invalid texture handle \(textureHandle)")
        return
    }

    encoderWrapper.encoder.setVertexTexture(textureWrapper.texture, index: Int(index))
}

// MARK: - Fragment Sampler

/// Bind a sampler state to a specific index in the fragment shader.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - samplerHandle: Handle to a MetalSamplerWrapper.
///   - index: Sampler index in the fragment shader argument table.
@_cdecl("metal_set_fragment_sampler")
public func metal_set_fragment_sampler(_ encoderHandle: UInt64, _ samplerHandle: UInt64, _ index: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let samplerWrapper: MetalSamplerWrapper = registry.get(samplerHandle) else {
        print("[MetalEncoding] ERROR: Invalid sampler handle \(samplerHandle)")
        return
    }

    encoderWrapper.encoder.setFragmentSamplerState(samplerWrapper.state, index: Int(index))
}

// MARK: - Depth Stencil State

/// Set the depth/stencil state on an encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - stateHandle: Handle to a MetalDepthStencilWrapper.
@_cdecl("metal_set_depth_stencil_state")
public func metal_set_depth_stencil_state(_ encoderHandle: UInt64, _ stateHandle: UInt64) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let depthStencilWrapper: MetalDepthStencilWrapper = registry.get(stateHandle) else {
        print("[MetalEncoding] ERROR: Invalid depth stencil handle \(stateHandle)")
        return
    }

    encoderWrapper.encoder.setDepthStencilState(depthStencilWrapper.state)
}

// MARK: - Cull Mode

/// Set the face culling mode on an encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - mode: Cull mode (MetalCullMode raw value).
@_cdecl("metal_set_cull_mode")
public func metal_set_cull_mode(_ encoderHandle: UInt64, _ mode: UInt32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let cullMode = MetalCullMode(rawValue: mode) else {
        print("[MetalEncoding] ERROR: Invalid cull mode \(mode)")
        return
    }

    encoderWrapper.encoder.setCullMode(toMTLCullMode(cullMode))
}

// MARK: - Viewport

/// Set the viewport on an encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - x/y: Origin of the viewport.
///   - width/height: Dimensions of the viewport.
///   - znear/zfar: Depth range.
@_cdecl("metal_set_viewport")
public func metal_set_viewport(
    _ encoderHandle: UInt64,
    _ x: Double,
    _ y: Double,
    _ width: Double,
    _ height: Double,
    _ znear: Double,
    _ zfar: Double
) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    let viewport = MTLViewport(
        originX: x,
        originY: y,
        width: width,
        height: height,
        znear: znear,
        zfar: zfar
    )

    encoderWrapper.encoder.setViewport(viewport)
}

// MARK: - Draw Indexed

/// Issue an indexed draw call.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - primitiveType: Primitive type (MetalPrimitiveType raw value).
///   - indexCount: Number of indices to draw.
///   - indexBufferHandle: Handle to a MetalBufferWrapper containing index data.
///   - indexBufferOffset: Byte offset into the index buffer.
@_cdecl("metal_draw_indexed")
public func metal_draw_indexed(
    _ encoderHandle: UInt64,
    _ primitiveType: UInt32,
    _ indexCount: Int32,
    _ indexBufferHandle: UInt64,
    _ indexBufferOffset: Int
) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let indexBufferWrapper: MetalBufferWrapper = registry.get(indexBufferHandle) else {
        print("[MetalEncoding] ERROR: Invalid index buffer handle \(indexBufferHandle)")
        return
    }

    guard let primType = MetalPrimitiveType(rawValue: primitiveType) else {
        print("[MetalEncoding] ERROR: Invalid primitive type \(primitiveType)")
        return
    }

    encoderWrapper.encoder.drawIndexedPrimitives(
        type: toMTLPrimitiveType(primType),
        indexCount: Int(indexCount),
        indexType: .uint32,
        indexBuffer: indexBufferWrapper.buffer,
        indexBufferOffset: indexBufferOffset
    )
}

// MARK: - Draw Primitives

/// Issue a non-indexed draw call.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - primitiveType: Primitive type (MetalPrimitiveType raw value).
///   - vertexStart: First vertex to draw.
///   - vertexCount: Number of vertices to draw.
@_cdecl("metal_draw_primitives")
public func metal_draw_primitives(_ encoderHandle: UInt64, _ primitiveType: UInt32, _ vertexStart: Int32, _ vertexCount: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let primType = MetalPrimitiveType(rawValue: primitiveType) else {
        print("[MetalEncoding] ERROR: Invalid primitive type \(primitiveType)")
        return
    }

    encoderWrapper.encoder.drawPrimitives(
        type: toMTLPrimitiveType(primType),
        vertexStart: Int(vertexStart),
        vertexCount: Int(vertexCount)
    )
}

// MARK: - Scissor Rect

/// Set the scissor rectangle on an encoder.
///
/// - Parameters:
///   - encoderHandle: Handle to a MetalRenderEncoderWrapper.
///   - x/y: Origin of the scissor rectangle.
///   - width/height: Dimensions of the scissor rectangle.
@_cdecl("metal_set_scissor_rect")
public func metal_set_scissor_rect(_ encoderHandle: UInt64, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    let scissorRect = MTLScissorRect(
        x: Int(x),
        y: Int(y),
        width: Int(width),
        height: Int(height)
    )

    encoderWrapper.encoder.setScissorRect(scissorRect)
}

// MARK: - Draw Indexed Instanced

/// Issue an indexed instanced draw call.
@_cdecl("metal_draw_indexed_instanced")
public func metal_draw_indexed_instanced(
    _ encoderHandle: UInt64,
    _ primitiveType: UInt32,
    _ indexCount: Int32,
    _ indexBufferHandle: UInt64,
    _ indexBufferOffset: Int,
    _ instanceCount: Int32
) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let indexBufferWrapper: MetalBufferWrapper = registry.get(indexBufferHandle) else {
        print("[MetalEncoding] ERROR: Invalid index buffer handle \(indexBufferHandle)")
        return
    }

    guard let primType = MetalPrimitiveType(rawValue: primitiveType) else {
        print("[MetalEncoding] ERROR: Invalid primitive type \(primitiveType)")
        return
    }

    encoderWrapper.encoder.drawIndexedPrimitives(
        type: toMTLPrimitiveType(primType),
        indexCount: Int(indexCount),
        indexType: .uint32,
        indexBuffer: indexBufferWrapper.buffer,
        indexBufferOffset: indexBufferOffset,
        instanceCount: Int(instanceCount)
    )
}

// MARK: - Draw Primitives Indirect

/// Issue an indirect draw call (for GPU particles).
@_cdecl("metal_draw_primitives_indirect")
public func metal_draw_primitives_indirect(
    _ encoderHandle: UInt64,
    _ primitiveType: UInt32,
    _ indirectBufferHandle: UInt64,
    _ indirectBufferOffset: Int
) {
    guard let encoderWrapper: MetalRenderEncoderWrapper = registry.get(encoderHandle) else {
        print("[MetalEncoding] ERROR: Invalid encoder handle \(encoderHandle)")
        return
    }

    guard let indirectBufferWrapper: MetalBufferWrapper = registry.get(indirectBufferHandle) else {
        print("[MetalEncoding] ERROR: Invalid indirect buffer handle \(indirectBufferHandle)")
        return
    }

    guard let primType = MetalPrimitiveType(rawValue: primitiveType) else {
        print("[MetalEncoding] ERROR: Invalid primitive type \(primitiveType)")
        return
    }

    encoderWrapper.encoder.drawPrimitives(
        type: toMTLPrimitiveType(primType),
        indirectBuffer: indirectBufferWrapper.buffer,
        indirectBufferOffset: indirectBufferOffset
    )
}

// MARK: - Begin Render Pass (Cube Face)

/// Begin a render pass targeting a specific face (and mip level) of a cube texture.
/// Used for IBL preprocessing: equirect-to-cubemap, irradiance convolution, prefilter.
///
/// - Parameters:
///   - cmdBufHandle: Handle to a MetalCommandBufferWrapper.
///   - cubeTextureHandle: Handle to a MetalTextureWrapper (must be a cube texture).
///   - face: Cube face index (0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z).
///   - mipLevel: Mip level to render to.
///   - loadAction: Load action for the color attachment.
///   - clearR/G/B/A: Clear color components.
/// - Returns: Handle to a MetalRenderEncoderWrapper.
@_cdecl("metal_begin_render_pass_cube_face")
public func metal_begin_render_pass_cube_face(
    _ cmdBufHandle: UInt64,
    _ cubeTextureHandle: UInt64,
    _ face: Int32,
    _ mipLevel: Int32,
    _ loadAction: UInt32,
    _ clearR: Float,
    _ clearG: Float,
    _ clearB: Float,
    _ clearA: Float
) -> UInt64 {
    guard let cmdBufWrapper: MetalCommandBufferWrapper = registry.get(cmdBufHandle) else {
        fatalError("metal_begin_render_pass_cube_face: Invalid command buffer handle \(cmdBufHandle).")
    }

    guard let textureWrapper: MetalTextureWrapper = registry.get(cubeTextureHandle) else {
        fatalError("metal_begin_render_pass_cube_face: Invalid cube texture handle \(cubeTextureHandle).")
    }

    guard let mtlLoadAction = MetalLoadAction(rawValue: loadAction) else {
        fatalError("metal_begin_render_pass_cube_face: Invalid load action \(loadAction).")
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = textureWrapper.texture
    descriptor.colorAttachments[0].slice = Int(face)
    descriptor.colorAttachments[0].level = Int(mipLevel)
    descriptor.colorAttachments[0].loadAction = toMTLLoadAction(mtlLoadAction)
    descriptor.colorAttachments[0].storeAction = .store

    if mtlLoadAction == .clear {
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearR),
            green: Double(clearG),
            blue: Double(clearB),
            alpha: Double(clearA)
        )
    }

    guard let encoder = cmdBufWrapper.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        fatalError("metal_begin_render_pass_cube_face: Failed to create render command encoder.")
    }

    let wrapper = MetalRenderEncoderWrapper(encoder: encoder)
    return registry.insert(wrapper)
}

// MARK: - Begin Render Pass (2D Texture)

/// Begin a render pass targeting a specific 2D texture directly (no render target wrapper).
/// Used for IBL BRDF LUT generation.
///
/// - Parameters:
///   - cmdBufHandle: Handle to a MetalCommandBufferWrapper.
///   - textureHandle: Handle to a MetalTextureWrapper (2D texture with renderTarget usage).
///   - loadAction: Load action for the color attachment.
///   - clearR/G/B/A: Clear color components.
/// - Returns: Handle to a MetalRenderEncoderWrapper.
@_cdecl("metal_begin_render_pass_texture")
public func metal_begin_render_pass_texture(
    _ cmdBufHandle: UInt64,
    _ textureHandle: UInt64,
    _ loadAction: UInt32,
    _ clearR: Float,
    _ clearG: Float,
    _ clearB: Float,
    _ clearA: Float
) -> UInt64 {
    guard let cmdBufWrapper: MetalCommandBufferWrapper = registry.get(cmdBufHandle) else {
        fatalError("metal_begin_render_pass_texture: Invalid command buffer handle \(cmdBufHandle).")
    }

    guard let textureWrapper: MetalTextureWrapper = registry.get(textureHandle) else {
        fatalError("metal_begin_render_pass_texture: Invalid texture handle \(textureHandle).")
    }

    guard let mtlLoadAction = MetalLoadAction(rawValue: loadAction) else {
        fatalError("metal_begin_render_pass_texture: Invalid load action \(loadAction).")
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = textureWrapper.texture
    descriptor.colorAttachments[0].loadAction = toMTLLoadAction(mtlLoadAction)
    descriptor.colorAttachments[0].storeAction = .store

    if mtlLoadAction == .clear {
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearR),
            green: Double(clearG),
            blue: Double(clearB),
            alpha: Double(clearA)
        )
    }

    guard let encoder = cmdBufWrapper.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        fatalError("metal_begin_render_pass_texture: Failed to create render command encoder.")
    }

    let wrapper = MetalRenderEncoderWrapper(encoder: encoder)
    return registry.insert(wrapper)
}
