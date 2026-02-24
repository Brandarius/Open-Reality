import XCTest
import Metal
@testable import MetalBridge

final class MetalEncodingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testRenderPassLifecycle() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Create a render target
        var formats: [UInt32] = [0]
        let rtHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 64, 64, 1, ptr.baseAddress!, 0, 0, "encoding_test")
        }
        XCTAssertNotEqual(rtHandle, 0)

        // Create command buffer
        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        // Begin + end render pass
        let encoderHandle = metal_begin_render_pass(cmdBufHandle, rtHandle, 2, 1, 0, 0, 0, 1, 1.0)
        XCTAssertNotEqual(encoderHandle, 0)

        metal_set_viewport(encoderHandle, 0, 0, 64, 64, 0, 1)
        metal_end_render_pass(encoderHandle)

        // Verify encoder was removed from registry
        let retrieved: MetalRenderEncoderWrapper? = registry.get(encoderHandle)
        XCTAssertNil(retrieved)

        cmdBuf.commit()

        registry.remove(cmdBufHandle)
        metal_destroy_render_target(rtHandle)
    }

    func testSetPipelineAndDraw() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Create render target
        var formats: [UInt32] = [5] // BGRA8
        let rtHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 64, 64, 1, ptr.baseAddress!, 0, 0, "draw_test")
        }

        // Create pipeline
        let msl = trivialMSLSource()
        let pipelineHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(msl, "trivial_vertex", "trivial_fragment",
                                          1, ptr.baseAddress!, 0, 0)
        }
        XCTAssertNotEqual(pipelineHandle, 0)

        // Create command buffer
        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_render_pass(cmdBufHandle, rtHandle, 2, 1, 0, 0, 0, 1, 1.0)
        metal_set_render_pipeline(encoderHandle, pipelineHandle)
        metal_set_viewport(encoderHandle, 0, 0, 64, 64, 0, 1)
        metal_draw_primitives(encoderHandle, 0, 0, 3) // triangle
        metal_end_render_pass(encoderHandle)

        cmdBuf.commit()

        registry.remove(cmdBufHandle)
        metal_destroy_render_target(rtHandle)
        metal_destroy_render_pipeline(pipelineHandle)
    }

    func testScissorRect() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [0]
        let rtHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 128, 128, 1, ptr.baseAddress!, 0, 0, "scissor_test")
        }

        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_render_pass(cmdBufHandle, rtHandle, 2, 1, 0, 0, 0, 1, 1.0)
        metal_set_viewport(encoderHandle, 0, 0, 128, 128, 0, 1)
        metal_set_scissor_rect(encoderHandle, 10, 10, 50, 50)
        metal_end_render_pass(encoderHandle)

        cmdBuf.commit()

        registry.remove(cmdBufHandle)
        metal_destroy_render_target(rtHandle)
    }

    func testCullModeSettings() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [0]
        let rtHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 64, 64, 1, ptr.baseAddress!, 0, 0, "cull_test")
        }

        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_render_pass(cmdBufHandle, rtHandle, 2, 1, 0, 0, 0, 1, 1.0)

        // Test all cull modes
        metal_set_cull_mode(encoderHandle, 0) // none
        metal_set_cull_mode(encoderHandle, 1) // front
        metal_set_cull_mode(encoderHandle, 2) // back

        metal_end_render_pass(encoderHandle)
        cmdBuf.commit()

        registry.remove(cmdBufHandle)
        metal_destroy_render_target(rtHandle)
    }
}
