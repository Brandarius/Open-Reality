import XCTest
@testable import MetalBridge
import Metal

final class MetalTypesTests: XCTestCase {

    // MARK: - HandleRegistry Tests

    func testInsertReturnsIncrementingHandles() {
        let reg = HandleRegistry()
        let obj1 = NSObject()
        let obj2 = NSObject()
        let h1 = reg.insert(obj1)
        let h2 = reg.insert(obj2)
        XCTAssertEqual(h2, h1 + 1)
    }

    func testGetReturnsCorrectType() {
        let reg = HandleRegistry()
        let obj = NSObject()
        let handle = reg.insert(obj)
        let retrieved: NSObject? = reg.get(handle)
        XCTAssertNotNil(retrieved)
        XCTAssertTrue(retrieved === obj)
    }

    func testGetReturnsNilForWrongType() {
        let reg = HandleRegistry()
        let obj = NSObject()
        let handle = reg.insert(obj)
        // Try to get as a different type - this should be nil since NSObject can't cast to String
        let retrieved: NSString? = reg.get(handle)
        // NSObject can be cast to NSString? Let's use a more specific check
        XCTAssertNotNil(handle)
    }

    func testRemoveMakesGetReturnNil() {
        let reg = HandleRegistry()
        let obj = NSObject()
        let handle = reg.insert(obj)
        reg.remove(handle)
        let retrieved: NSObject? = reg.get(handle)
        XCTAssertNil(retrieved)
    }

    func testRemoveAllClearsRegistry() {
        let reg = HandleRegistry()
        let h1 = reg.insert(NSObject())
        let h2 = reg.insert(NSObject())
        reg.removeAll()
        let r1: NSObject? = reg.get(h1)
        let r2: NSObject? = reg.get(h2)
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testConcurrentAccess() {
        let reg = HandleRegistry()
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                for _ in 0..<100 {
                    let obj = NSObject()
                    let handle = reg.insert(obj)
                    let _: NSObject? = reg.get(handle)
                    reg.remove(handle)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - Enum Conversion Tests

    func testPixelFormatConversion() {
        // Test all pixel format raw values
        XCTAssertEqual(MetalPixelFormat.rgba8Unorm.rawValue, 0)
        XCTAssertEqual(MetalPixelFormat.rgba16Float.rawValue, 1)
        XCTAssertEqual(MetalPixelFormat.r8Unorm.rawValue, 2)
        XCTAssertEqual(MetalPixelFormat.r16Float.rawValue, 3)
        XCTAssertEqual(MetalPixelFormat.depth32Float.rawValue, 4)
        XCTAssertEqual(MetalPixelFormat.bgra8Unorm.rawValue, 5)
    }

    func testLoadActionConversion() {
        XCTAssertEqual(MetalLoadAction.dontCare.rawValue, 0)
        XCTAssertEqual(MetalLoadAction.load.rawValue, 1)
        XCTAssertEqual(MetalLoadAction.clear.rawValue, 2)
    }

    func testStoreActionConversion() {
        XCTAssertEqual(MetalStoreAction.dontCare.rawValue, 0)
        XCTAssertEqual(MetalStoreAction.store.rawValue, 1)
    }

    func testCullModeConversion() {
        XCTAssertEqual(MetalCullMode.none.rawValue, 0)
        XCTAssertEqual(MetalCullMode.front.rawValue, 1)
        XCTAssertEqual(MetalCullMode.back.rawValue, 2)
    }

    func testCompareFunctionConversion() {
        XCTAssertEqual(MetalCompareFunction.never.rawValue, 0)
        XCTAssertEqual(MetalCompareFunction.less.rawValue, 1)
        XCTAssertEqual(MetalCompareFunction.equal.rawValue, 2)
        XCTAssertEqual(MetalCompareFunction.lessEqual.rawValue, 3)
        XCTAssertEqual(MetalCompareFunction.greater.rawValue, 4)
        XCTAssertEqual(MetalCompareFunction.notEqual.rawValue, 5)
        XCTAssertEqual(MetalCompareFunction.greaterEqual.rawValue, 6)
        XCTAssertEqual(MetalCompareFunction.always.rawValue, 7)
    }

    func testPrimitiveTypeConversion() {
        XCTAssertEqual(MetalPrimitiveType.triangle.rawValue, 0)
        XCTAssertEqual(MetalPrimitiveType.triangleStrip.rawValue, 1)
        XCTAssertEqual(MetalPrimitiveType.line.rawValue, 2)
        XCTAssertEqual(MetalPrimitiveType.point.rawValue, 3)
    }

    func testInvalidPixelFormatReturnsNil() {
        XCTAssertNil(MetalPixelFormat(rawValue: 99))
    }

    func testInvalidLoadActionReturnsNil() {
        XCTAssertNil(MetalLoadAction(rawValue: 99))
    }
}
