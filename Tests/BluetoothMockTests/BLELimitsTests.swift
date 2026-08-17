import XCTest
@testable import BluetoothMock

final class BLELimitsTests: XCTestCase {
    func testDefaultMTUAllowsTwentyBytePayload() throws {
        XCTAssertEqual(BLELimits.maximumAttributePayload(forATTMTU: 23), 20)
        XCTAssertNoThrow(try BLELimits.validatePacketPayload(Data(repeating: 0, count: 20), attMTU: 23))
        XCTAssertThrowsError(try BLELimits.validatePacketPayload(Data(repeating: 0, count: 21), attMTU: 23))
    }

    func testBLEMaximumsAreEnforced() throws {
        XCTAssertEqual(BLELimits.maximumAttributePayload(forATTMTU: 517), 512)
        XCTAssertNoThrow(try BLELimits.validateAttributeValue(Data(repeating: 0, count: 512)))
        XCTAssertThrowsError(try BLELimits.validateAttributeValue(Data(repeating: 0, count: 513)))
    }

    func testConfigurationClampsATTMTU() {
        XCTAssertEqual(BluetoothMockConfiguration(attMTU: 1).attMTU, 23)
        XCTAssertEqual(BluetoothMockConfiguration(attMTU: 9_999).attMTU, 517)
    }

    func testLegacyAdvertisingPayloadLimit() throws {
        let valid = [CBAdvertisementDataLocalNameKey: String(repeating: "A", count: 26)]
        XCTAssertEqual(try BLELimits.legacyAdvertisingSize(valid), 31)

        let invalid = [CBAdvertisementDataLocalNameKey: String(repeating: "A", count: 27)]
        XCTAssertThrowsError(try BLELimits.legacyAdvertisingSize(invalid)) { error in
            XCTAssertEqual(
                error as? BluetoothMockError,
                .advertisingDataTooLong(actual: 32, maximum: 31)
            )
        }
    }

    func testPacketizerUsesNegotiatedPayload() throws {
        let packets = try BLEPacketizer.fragments(Data(repeating: 7, count: 45), attMTU: 23)
        XCTAssertEqual(packets.map(\.count), [20, 20, 5])
    }
}
