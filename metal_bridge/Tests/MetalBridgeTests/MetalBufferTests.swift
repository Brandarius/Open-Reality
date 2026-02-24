import XCTest
import Metal
@testable import MetalBridge

final class MetalBufferTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testCreateBufferWithData() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        var data: [Float] = [1.0, 2.0, 3.0, 4.0]
        let handle = data.withUnsafeMutableBufferPointer { ptr in
            metal_create_buffer(deviceHandle, ptr.baseAddress!, data.count * MemoryLayout<Float>.stride, "test_buffer")
        }

        XCTAssertNotEqual(handle, 0)

        let length = metal_get_buffer_length(handle)
        XCTAssertEqual(length, data.count * MemoryLayout<Float>.stride)

        metal_destroy_buffer(handle)
    }

    func testCreateEmptyBuffer() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_buffer(deviceHandle, nil, 256, "empty_buffer")
        XCTAssertNotEqual(handle, 0)

        let length = metal_get_buffer_length(handle)
        XCTAssertGreaterThanOrEqual(length, 256)

        metal_destroy_buffer(handle)
    }

    func testUpdateBuffer() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Create buffer with initial data
        var initial: [Float] = [0.0, 0.0, 0.0, 0.0]
        let handle = initial.withUnsafeMutableBufferPointer { ptr in
            metal_create_buffer(deviceHandle, ptr.baseAddress!, initial.count * MemoryLayout<Float>.stride, "update_test")
        }
        XCTAssertNotEqual(handle, 0)

        // Update with new data
        var updated: [Float] = [1.0, 2.0, 3.0, 4.0]
        updated.withUnsafeMutableBufferPointer { ptr in
            metal_update_buffer(handle, ptr.baseAddress!, 0, updated.count * MemoryLayout<Float>.stride)
        }

        // Verify via MetalBufferWrapper
        guard let wrapper: MetalBufferWrapper = registry.get(handle) else {
            XCTFail("Buffer not found in registry")
            return
        }

        let contents = wrapper.buffer.contents().bindMemory(to: Float.self, capacity: 4)
        XCTAssertEqual(contents[0], 1.0)
        XCTAssertEqual(contents[1], 2.0)
        XCTAssertEqual(contents[2], 3.0)
        XCTAssertEqual(contents[3], 4.0)

        metal_destroy_buffer(handle)
    }

    func testDestroyBufferRemovesFromRegistry() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        let handle = metal_create_buffer(deviceHandle, nil, 64, "destroy_test")
        XCTAssertNotEqual(handle, 0)

        metal_destroy_buffer(handle)

        let retrieved: MetalBufferWrapper? = registry.get(handle)
        XCTAssertNil(retrieved)
    }
}
