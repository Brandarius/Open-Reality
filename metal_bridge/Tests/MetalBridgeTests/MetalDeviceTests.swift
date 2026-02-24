import XCTest
import Metal
@testable import MetalBridge

final class MetalDeviceTests: XCTestCase {

    func testSystemDefaultDeviceExists() throws {
        let device = try makeTestDevice()
        XCTAssertNotNil(device)
        XCTAssertFalse(device.name.isEmpty)
    }

    func testDeviceWrapperCreation() throws {
        let wrapper = try makeTestDeviceWrapper()
        XCTAssertNotNil(wrapper.device)
        XCTAssertNotNil(wrapper.commandQueue)
        XCTAssertNil(wrapper.layer) // No layer in headless mode
    }

    func testCommandQueueCanCreateCommandBuffer() throws {
        let wrapper = try makeTestDeviceWrapper()
        let cmdBuf = wrapper.commandQueue.makeCommandBuffer()
        XCTAssertNotNil(cmdBuf)
    }
}
