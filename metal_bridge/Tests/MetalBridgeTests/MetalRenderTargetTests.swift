import XCTest
import Metal
@testable import MetalBridge

final class MetalRenderTargetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testCreateRenderTargetSingleColor() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [0] // RGBA8
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 512, 512, 1, ptr.baseAddress!, 0, 0, "single_color")
        }
        XCTAssertNotEqual(handle, 0)

        let colorTex = metal_get_rt_color_texture(handle, 0)
        XCTAssertNotEqual(colorTex, 0)

        let depthTex = metal_get_rt_depth_texture(handle)
        XCTAssertEqual(depthTex, 0) // No depth

        metal_destroy_render_target(handle)
    }

    func testCreateRenderTarget4ColorPlusDepth() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [1, 1, 1, 0] // 3x RGBA16F + 1x RGBA8
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 256, 256, 4, ptr.baseAddress!, 1, 4, "gbuffer_test")
        }
        XCTAssertNotEqual(handle, 0)

        for i: Int32 in 0..<4 {
            let tex = metal_get_rt_color_texture(handle, i)
            XCTAssertNotEqual(tex, 0, "Color texture \(i) should be valid")
        }

        let depthTex = metal_get_rt_depth_texture(handle)
        XCTAssertNotEqual(depthTex, 0)

        metal_destroy_render_target(handle)
    }

    func testResizeRenderTarget() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [0]
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 128, 128, 1, ptr.baseAddress!, 1, 4, "resize_test")
        }
        XCTAssertNotEqual(handle, 0)

        metal_resize_render_target(handle, 256, 256)

        guard let wrapper: MetalRenderTargetWrapper = registry.get(handle) else {
            XCTFail("Render target not in registry after resize")
            return
        }
        XCTAssertEqual(wrapper.colorTextures.first?.width, 256)
        XCTAssertEqual(wrapper.colorTextures.first?.height, 256)

        metal_destroy_render_target(handle)
    }

    func testDestroyRenderTarget() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var formats: [UInt32] = [0]
        let handle = formats.withUnsafeMutableBufferPointer { ptr in
            metal_create_render_target(deviceHandle, 64, 64, 1, ptr.baseAddress!, 0, 0, "destroy_test")
        }
        XCTAssertNotEqual(handle, 0)

        metal_destroy_render_target(handle)
        let retrieved: MetalRenderTargetWrapper? = registry.get(handle)
        XCTAssertNil(retrieved)
    }
}
