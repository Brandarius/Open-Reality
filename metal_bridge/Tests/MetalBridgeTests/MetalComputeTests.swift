import XCTest
import Metal
@testable import MetalBridge

final class MetalComputeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? setUpGlobalDevice()
    }

    func testCreateComputePipeline() throws {
        try setUpGlobalDevice()

        let msl = trivialComputeMSLSource()
        let handle = metal_create_compute_pipeline(msl, "trivial_compute")
        XCTAssertNotEqual(handle, 0)

        metal_destroy_compute_pipeline(handle)
    }

    func testCreateComputePipelineInvalidSource() throws {
        try setUpGlobalDevice()

        let handle = metal_create_compute_pipeline("invalid MSL", "kernel_func")
        XCTAssertEqual(handle, 0)
    }

    func testCreateComputePipelineWrongFunction() throws {
        try setUpGlobalDevice()

        let msl = trivialComputeMSLSource()
        let handle = metal_create_compute_pipeline(msl, "nonexistent_kernel")
        XCTAssertEqual(handle, 0)
    }

    func testComputePassLifecycle() throws {
        try setUpGlobalDevice()

        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_compute_pass(cmdBufHandle)
        XCTAssertNotEqual(encoderHandle, 0)

        metal_end_compute_pass(encoderHandle)

        // Verify encoder was removed from registry
        let retrieved: MetalComputeEncoderWrapper? = registry.get(encoderHandle)
        XCTAssertNil(retrieved)

        cmdBuf.commit()
        registry.remove(cmdBufHandle)
    }

    func testComputeDispatch() throws {
        try setUpGlobalDevice()
        let deviceHandle = registry.insert(globalDevice!)
        defer { registry.remove(deviceHandle) }

        // Create compute pipeline
        let msl = trivialComputeMSLSource()
        let pipelineHandle = metal_create_compute_pipeline(msl, "trivial_compute")
        XCTAssertNotEqual(pipelineHandle, 0)

        // Create output buffer (16 floats)
        let bufferHandle = metal_create_buffer(deviceHandle, nil, 16 * MemoryLayout<Float>.stride, "compute_output")
        XCTAssertNotEqual(bufferHandle, 0)

        // Dispatch compute
        let cmdBuf = globalDevice!.commandQueue.makeCommandBuffer()!
        let cmdBufWrapper = MetalCommandBufferWrapper(commandBuffer: cmdBuf)
        let cmdBufHandle = registry.insert(cmdBufWrapper)

        let encoderHandle = metal_begin_compute_pass(cmdBufHandle)
        metal_set_compute_buffer(encoderHandle, bufferHandle, 0, 0)
        metal_dispatch_threadgroups(encoderHandle, pipelineHandle, 16, 1, 1, 16, 1, 1)
        metal_end_compute_pass(encoderHandle)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Verify output
        guard let bufferWrapper: MetalBufferWrapper = registry.get(bufferHandle) else {
            XCTFail("Buffer not in registry")
            return
        }

        let contents = bufferWrapper.buffer.contents().bindMemory(to: Float.self, capacity: 16)
        for i in 0..<16 {
            XCTAssertEqual(contents[i], Float(i) * 2.0, accuracy: 0.001,
                           "Compute output[\(i)] should be \(Float(i) * 2.0)")
        }

        registry.remove(cmdBufHandle)
        metal_destroy_buffer(bufferHandle)
        metal_destroy_compute_pipeline(pipelineHandle)
    }

    func testDestroyComputePipelineRemovesFromRegistry() throws {
        try setUpGlobalDevice()

        let msl = trivialComputeMSLSource()
        let handle = metal_create_compute_pipeline(msl, "trivial_compute")
        XCTAssertNotEqual(handle, 0)

        metal_destroy_compute_pipeline(handle)
        let retrieved: MetalComputePipelineWrapper? = registry.get(handle)
        XCTAssertNil(retrieved)
    }
}
