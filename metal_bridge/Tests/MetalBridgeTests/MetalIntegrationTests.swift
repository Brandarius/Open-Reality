import XCTest
import Metal
@testable import MetalBridge

final class MetalIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testBridgeExportsCount() {
        let count = metal_bridge_exports()
        XCTAssertEqual(count, 56, "Expected 56 exported symbols (46 original + 10 new)")
    }

    func testFullRenderPipeline() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // 1. Create render target
        var formats: [UInt32] = [5] // BGRA8
        let rtHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 128, 128, 1, ptr.baseAddress!, 1, 4, "integration_test")
        }
        XCTAssertNotEqual(rtHandle, 0)

        // 2. Create pipeline
        let msl = trivialMSLSource()
        let pipelineHandle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(msl, "trivial_vertex", "trivial_fragment",
                                          1, ptr.baseAddress!, 4, 0)
        }
        XCTAssertNotEqual(pipelineHandle, 0)

        // 3. Create depth stencil state
        let dsHandle = metal_create_depth_stencil_state(deviceHandle, 1, 1)
        XCTAssertNotEqual(dsHandle, 0)

        // 4. Create sampler
        let samplerHandle = metal_create_sampler(deviceHandle, 1, 1, 1, 0)
        XCTAssertNotEqual(samplerHandle, 0)

        // 5. Create a buffer for vertex data
        var vertices: [Float] = [
            0.0, 0.5, 0.0,
            -0.5, -0.5, 0.0,
            0.5, -0.5, 0.0
        ]
        let vertexBuf = vertices.withUnsafeMutableBufferPointer { ptr in
            metal_create_buffer(deviceHandle, ptr.baseAddress!,
                                vertices.count * MemoryLayout<Float>.stride, "vertices")
        }
        XCTAssertNotEqual(vertexBuf, 0)

        // 6. Create texture
        let texHandle = metal_create_texture_2d(deviceHandle, 4, 4, 0, 0, 1, "integration_tex")
        XCTAssertNotEqual(texHandle, 0)

        // 7. Execute a render pass
        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_render_pass(cmdBufHandle, rtHandle, 2, 1, 0, 0, 0, 1, 1.0)
        metal_set_render_pipeline(encoderHandle, pipelineHandle)
        metal_set_depth_stencil_state(encoderHandle, dsHandle)
        metal_set_cull_mode(encoderHandle, 2) // back
        metal_set_viewport(encoderHandle, 0, 0, 128, 128, 0, 1)
        metal_set_vertex_buffer(encoderHandle, vertexBuf, 0, 0)
        metal_set_fragment_texture(encoderHandle, texHandle, 0)
        metal_set_fragment_sampler(encoderHandle, samplerHandle, 0)
        metal_draw_primitives(encoderHandle, 0, 0, 3) // triangle
        metal_end_render_pass(encoderHandle)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Cleanup
        registry.remove(cmdBufHandle)
        metal_destroy_buffer(vertexBuf)
        metal_destroy_texture(texHandle)
        metal_destroy_render_target(rtHandle)
        metal_destroy_render_pipeline(pipelineHandle)
    }
}
