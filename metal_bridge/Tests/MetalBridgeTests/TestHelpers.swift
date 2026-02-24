import XCTest
import Metal
@testable import MetalBridge

/// Get a Metal device for testing, or skip the test if unavailable.
func makeTestDevice() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("No Metal device available on this machine.")
    }
    return device
}

/// Create a MetalDeviceWrapper for tests (no window/layer needed).
func makeTestDeviceWrapper() throws -> MetalDeviceWrapper {
    let device = try makeTestDevice()
    guard let queue = device.makeCommandQueue() else {
        throw XCTSkip("Failed to create command queue.")
    }
    return MetalDeviceWrapper(device: device, commandQueue: queue, layer: nil)
}

/// Set up globalDevice for tests that need it. Call from setUp().
func setUpGlobalDevice() throws {
    if globalDevice == nil {
        globalDevice = try makeTestDeviceWrapper()
    }
}

/// Clear globalDevice. Call from tearDown() if needed.
func tearDownGlobalDevice() {
    globalDevice = nil
}

/// Minimal valid MSL source for pipeline tests.
func trivialMSLSource() -> String {
    """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
    };

    vertex VertexOut trivial_vertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(0, 0, 0, 1);
        return out;
    }

    fragment float4 trivial_fragment(VertexOut in [[stage_in]]) {
        return float4(1, 0, 0, 1);
    }
    """
}

/// Minimal compute MSL source.
func trivialComputeMSLSource() -> String {
    """
    #include <metal_stdlib>
    using namespace metal;

    kernel void trivial_compute(device float* output [[buffer(0)]],
                                 uint tid [[thread_position_in_grid]]) {
        output[tid] = float(tid) * 2.0;
    }
    """
}
