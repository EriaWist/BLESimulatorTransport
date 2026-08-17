import XCTest
@testable import BluetoothMock

final class WireProtocolTests: XCTestCase {
    func testFrameDecoderHandlesTCPFragmentationAndCoalescing() throws {
        let first = BLEWireMessage(payload: .hello(WireHello(
            role: .central,
            identifier: UUID(),
            attMTU: 247
        )))
        let second = BLEWireMessage(payload: .write(WireWrite(
            characteristicIdentifier: UUID(),
            data: Data([1, 2, 3]),
            type: .withResponse
        )))
        let firstFrame = try BLEFrameCodec.encode(first)
        let secondFrame = try BLEFrameCodec.encode(second)

        var decoder = BLEFrameDecoder()
        XCTAssertTrue(try decoder.append(firstFrame.prefix(2)).isEmpty)

        var remainderAndNext = Data(firstFrame.dropFirst(2))
        remainderAndNext.append(secondFrame)
        XCTAssertEqual(try decoder.append(remainderAndNext), [first, second])
    }

    func testWireAdvertisementRoundTripsCoreBluetoothKeys() throws {
        let source: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Mock Sensor",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180D")],
            CBAdvertisementDataManufacturerDataKey: Data([0x34, 0x12, 0x01]),
            CBAdvertisementDataIsConnectable: NSNumber(value: true)
        ]
        let wire = WireAdvertisement(advertisementData: source)
        let decoded = try JSONDecoder().decode(
            WireAdvertisement.self,
            from: JSONEncoder().encode(wire)
        )

        XCTAssertEqual(decoded, wire)
        XCTAssertEqual(decoded.advertisementData[CBAdvertisementDataLocalNameKey] as? String, "Mock Sensor")
        XCTAssertEqual(decoded.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], [CBUUID(string: "180D")])
    }
}
