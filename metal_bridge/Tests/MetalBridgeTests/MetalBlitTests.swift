import XCTest
import Metal
@testable import MetalBridge

final class MetalBlitTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testBlitTexture() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Create src and dst textures (same size, same format)
        let srcHandle = metal_create_texture_2d(deviceHandle, 32, 32, 0, 0,
                                                  Int32(1 | 4), "blit_src") // shaderRead | renderTarget
        let dstHandle = metal_create_texture_2d(deviceHandle, 32, 32, 0, 0,
                                                  Int32(1 | 4), "blit_dst")
        XCTAssertNotEqual(srcHandle, 0)
        XCTAssertNotEqual(dstHandle, 0)

        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        metal_blit_texture(cmdBufHandle, srcHandle, dstHandle)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        registry.remove(cmdBufHandle)
        metal_destroy_texture(srcHandle)
        metal_destroy_texture(dstHandle)
    }

    func testGenerateMipmaps() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 64, 64, 0, 1,
                                               Int32(1 | 4), "mipmap_test")
        XCTAssertNotEqual(handle, 0)

        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        metal_generate_mipmaps(cmdBufHandle, handle)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        registry.remove(cmdBufHandle)
        metal_destroy_texture(handle)
    }
}
