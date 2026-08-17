import Foundation

public enum BLELimits {
    public static let minimumATTMTU = 23
    public static let maximumATTMTU = 517
    public static let maximumAttributeValueLength = 512
    public static let legacyAdvertisingPayloadLength = 31
    public static let legacyAdvertisingFlagsLength = 3

    public static func maximumAttributePayload(forATTMTU mtu: Int) -> Int {
        min(min(max(mtu, minimumATTMTU), maximumATTMTU) - 3, maximumAttributeValueLength)
    }

    public static func validateAttributeValue(_ data: Data) throws {
        guard data.count <= maximumAttributeValueLength else {
            throw BluetoothMockError.attributeValueTooLong(
                actual: data.count,
                maximum: maximumAttributeValueLength
            )
        }
    }

    public static func validatePacketPayload(_ data: Data, attMTU: Int) throws {
        let maximum = maximumAttributePayload(forATTMTU: attMTU)
        guard data.count <= maximum else {
            throw BluetoothMockError.packetExceedsMTU(actual: data.count, maximum: maximum)
        }
        try validateAttributeValue(data)
    }

    /// Conservative encoding size for a legacy connectable advertisement.
    public static func legacyAdvertisingSize(_ advertisementData: [String: Any]) throws -> Int {
        let supportedKeys: Set<String> = [
            CBAdvertisementDataLocalNameKey,
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataManufacturerDataKey,
            CBAdvertisementDataTxPowerLevelKey,
            CBAdvertisementDataIsConnectable,
            CBAdvertisementDataServiceDataKey
        ]
        if let unsupported = advertisementData.keys.first(where: { !supportedKeys.contains($0) }) {
            throw BluetoothMockError.operationNotSupported(
                "Advertising key \(unsupported) is not supported by the legacy advertisement mock."
            )
        }

        // A normal connectable LE advertisement reserves three bytes for the Flags AD structure.
        var size = legacyAdvertisingFlagsLength

        if let rawName = advertisementData[CBAdvertisementDataLocalNameKey] {
            guard let localName = rawName as? String else {
                throw BluetoothMockError.protocolViolation("Local name must be a String")
            }
            size += 2 + localName.lengthOfBytes(using: .utf8)
        }

        if let rawUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] {
            guard let serviceUUIDs = rawUUIDs as? [CBUUID] else {
                throw BluetoothMockError.protocolViolation("Service UUIDs must be [CBUUID]")
            }
            guard serviceUUIDs.allSatisfy(\.isValid) else {
                throw BluetoothMockError.invalidUUID(
                    serviceUUIDs.first(where: { !$0.isValid })?.uuidString ?? ""
                )
            }
            let grouped = Dictionary(grouping: serviceUUIDs, by: \.encodedByteCount)
            for (uuidByteCount, values) in grouped {
                size += 2 + (uuidByteCount * values.count)
            }
        }

        if let rawManufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] {
            guard let manufacturerData = rawManufacturerData as? Data else {
                throw BluetoothMockError.protocolViolation("Manufacturer data must be Data")
            }
            guard manufacturerData.count >= 2 else {
                throw BluetoothMockError.operationNotSupported(
                    "Manufacturer data must begin with the two-byte Bluetooth Company Identifier."
                )
            }
            size += 2 + manufacturerData.count
        }

        if let rawTxPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] {
            guard let txPower = rawTxPower as? NSNumber else {
                throw BluetoothMockError.protocolViolation("TX power must be NSNumber")
            }
            guard (-127...127).contains(txPower.intValue) else {
                throw BluetoothMockError.operationNotSupported("TX power must fit in a signed BLE byte.")
            }
            size += 3
        }

        if let rawServiceData = advertisementData[CBAdvertisementDataServiceDataKey] {
            guard let serviceData = rawServiceData as? [CBUUID: Data] else {
                throw BluetoothMockError.protocolViolation("Service data must be [CBUUID: Data]")
            }
            for (uuid, data) in serviceData {
                guard uuid.isValid else { throw BluetoothMockError.invalidUUID(uuid.uuidString) }
                size += 2 + uuid.encodedByteCount + data.count
            }
        }

        guard size <= legacyAdvertisingPayloadLength else {
            throw BluetoothMockError.advertisingDataTooLong(
                actual: size,
                maximum: legacyAdvertisingPayloadLength
            )
        }
        return size
    }
}

public enum BluetoothMockError: Error, Equatable, LocalizedError {
    case invalidPort(UInt16)
    case invalidUUID(String)
    case advertisingDataTooLong(actual: Int, maximum: Int)
    case attributeValueTooLong(actual: Int, maximum: Int)
    case packetExceedsMTU(actual: Int, maximum: Int)
    case operationNotSupported(String)
    case notConnected
    case transport(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "TCP port \(port) is invalid."
        case .invalidUUID(let uuid):
            return "\(uuid) is not a 16-bit, 32-bit, or 128-bit Bluetooth UUID."
        case .advertisingDataTooLong(let actual, let maximum):
            return "Advertising payload is \(actual) bytes; legacy BLE allows \(maximum)."
        case .attributeValueTooLong(let actual, let maximum):
            return "Attribute value is \(actual) bytes; BLE allows \(maximum)."
        case .packetExceedsMTU(let actual, let maximum):
            return "Packet payload is \(actual) bytes; the negotiated ATT MTU allows \(maximum)."
        case .operationNotSupported(let message):
            return message
        case .notConnected:
            return "The mock peripheral is not connected."
        case .transport(let message):
            return "TCP transport error: \(message)"
        case .protocolViolation(let message):
            return "BluetoothMock protocol violation: \(message)"
        }
    }
}
