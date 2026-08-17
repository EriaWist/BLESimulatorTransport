import Foundation

/// Helpers for application protocols that intentionally span multiple GATT writes or notifications.
/// BluetoothMock never silently fragments a single CoreBluetooth operation because the real API
/// requires the application to respect `maximumWriteValueLength(for:)` as well.
public enum BLEPacketizer {
    public static func fragments(_ data: Data, attMTU: Int) throws -> [Data] {
        let clampedMTU = min(max(attMTU, BLELimits.minimumATTMTU), BLELimits.maximumATTMTU)
        let payloadLength = BLELimits.maximumAttributePayload(forATTMTU: clampedMTU)
        guard !data.isEmpty else { return [Data()] }

        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + payloadLength, data.count)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}
