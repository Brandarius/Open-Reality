import XCTest
import Metal
@testable import MetalBridge

final class MetalTextureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testCreateTexture2DRGBA8() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 256, 256, 0, 0, 1, "test_rgba8")
        XCTAssertNotEqual(handle, 0)

        guard let wrapper: MetalTextureWrapper = registry.get(handle) else {
            XCTFail("Texture not in registry")
            return
        }
        XCTAssertEqual(wrapper.texture.width, 256)
        XCTAssertEqual(wrapper.texture.height, 256)

        metal_destroy_texture(handle)
    }

    func testCreateTexture2DRGBA16F() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 128, 128, 1, 0, 1, "test_rgba16f")
        XCTAssertNotEqual(handle, 0)

        metal_destroy_texture(handle)
    }

    func testMipmappedTexture() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 256, 256, 0, 1, 1, "mip_test")
        XCTAssertNotEqual(handle, 0)

        guard let wrapper: MetalTextureWrapper = registry.get(handle) else {
            XCTFail("Texture not in registry")
            return
        }
        // 256 -> log2(256) + 1 = 9 mip levels
        XCTAssertGreaterThan(wrapper.texture.mipmapLevelCount, 1)

        metal_destroy_texture(handle)
    }

    func testUploadTexture2D() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 4, 4, 0, 0, 1, "upload_test")
        XCTAssertNotEqual(handle, 0)

        // Upload 4x4 RGBA data
        var pixels = [UInt8](repeating: 255, count: 4 * 4 * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            metal_upload_texture_2d(handle, ptr.baseAddress!, 4, 4, 4)
        }

        // No crash means success
        metal_destroy_texture(handle)
    }

    func testCreateTextureCube() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_cube(deviceHandle, 64, 0, 0, "cube_test")
        XCTAssertNotEqual(handle, 0)

        guard let wrapper: MetalTextureWrapper = registry.get(handle) else {
            XCTFail("Cube texture not in registry")
            return
        }
        XCTAssertEqual(wrapper.texture.textureType, .typeCube)

        metal_destroy_texture(handle)
    }

    func testUploadTextureCubeFaces() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_cube(deviceHandle, 16, 0, 0, "cube_upload_test")
        XCTAssertNotEqual(handle, 0)

        var pixels = [UInt8](repeating: 128, count: 16 * 16 * 4)
        for face: Int32 in 0..<6 {
            pixels.withUnsafeMutableBufferPointer { ptr in
                metal_upload_texture_cube_face(handle, face, ptr.baseAddress!, 16, 4)
            }
        }

        metal_destroy_texture(handle)
    }

    func testDestroyTextureRemovesFromRegistry() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_texture_2d(deviceHandle, 32, 32, 0, 0, 1, "destroy_test")
        XCTAssertNotEqual(handle, 0)

        metal_destroy_texture(handle)

        let retrieved: MetalTextureWrapper? = registry.get(handle)
        XCTAssertNil(retrieved)
    }
}
