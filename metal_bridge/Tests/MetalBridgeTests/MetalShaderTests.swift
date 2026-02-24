import XCTest
import Metal
@testable import MetalBridge

final class MetalShaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testCreateRenderPipelineValid() throws {
        try setUpGlobalDevice()

        let msl = trivialMSLSource()
        var formats: [UInt32] = [5] // BGRA8
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(msl, "trivial_vertex", "trivial_fragment",
                                          1, ptr.baseAddress!, 0, 0)
        }
        XCTAssertNotEqual(handle, 0)
        metal_destroy_render_pipeline(handle)
    }

    func testCreateRenderPipelineInvalidMSL() throws {
        try setUpGlobalDevice()

        let badMSL = "this is not valid MSL"
        var formats: [UInt32] = [5]
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(badMSL, "vertex_main", "fragment_main",
                                          1, ptr.baseAddress!, 0, 0)
        }
        XCTAssertEqual(handle, 0)
    }

    func testCreateRenderPipelineWrongFunctionName() throws {
        try setUpGlobalDevice()

        let msl = trivialMSLSource()
        var formats: [UInt32] = [5]
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(msl, "nonexistent_vertex", "nonexistent_fragment",
                                          1, ptr.baseAddress!, 0, 0)
        }
        XCTAssertEqual(handle, 0)
    }

    func testCreateDepthStencilState() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Less compare, depth write enabled
        let handle = metal_create_depth_stencil_state(deviceHandle, 1, 1)
        XCTAssertNotEqual(handle, 0)
    }

    func testCreateDepthStencilStateAlways() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Always compare, depth write disabled
        let handle = metal_create_depth_stencil_state(deviceHandle, 7, 0)
        XCTAssertNotEqual(handle, 0)
    }

    func testCreateSampler() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Linear filter, clamp address mode
        let handle = metal_create_sampler(deviceHandle, 1, 1, 1, 0)
        XCTAssertNotEqual(handle, 0)
    }

    func testDestroyPipelineRemovesFromRegistry() throws {
        try setUpGlobalDevice()

        let msl = trivialMSLSource()
        var formats: [UInt32] = [5]
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_pipeline(msl, "trivial_vertex", "trivial_fragment",
                                          1, ptr.baseAddress!, 0, 0)
        }
        XCTAssertNotEqual(handle, 0)

        metal_destroy_render_pipeline(handle)
        let retrieved: MetalRenderPipelineWrapper? = registry.get(handle)
        XCTAssertNil(retrieved)
    }
}
