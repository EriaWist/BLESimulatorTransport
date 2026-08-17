import Foundation

public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"
public let CBAdvertisementDataServiceUUIDsKey = "kCBAdvDataServiceUUIDs"
public let CBAdvertisementDataManufacturerDataKey = "kCBAdvDataManufacturerData"
public let CBAdvertisementDataTxPowerLevelKey = "kCBAdvDataTxPowerLevel"
public let CBAdvertisementDataIsConnectable = "kCBAdvDataIsConnectable"
public let CBAdvertisementDataServiceDataKey = "kCBAdvDataServiceData"
public let CBAdvertisementDataOverflowServiceUUIDsKey = "kCBAdvDataOverflowServiceUUIDs"
public let CBAdvertisementDataSolicitedServiceUUIDsKey = "kCBAdvDataSolicitedServiceUUIDs"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "CBCentralManagerScanOptionAllowDuplicatesKey"
public let CBCentralManagerScanOptionSolicitedServiceUUIDsKey = "CBCentralManagerScanOptionSolicitedServiceUUIDsKey"
public let CBConnectPeripheralOptionNotifyOnConnectionKey = "CBConnectPeripheralOptionNotifyOnConnectionKey"
public let CBConnectPeripheralOptionNotifyOnDisconnectionKey = "CBConnectPeripheralOptionNotifyOnDisconnectionKey"
public let CBConnectPeripheralOptionNotifyOnNotificationKey = "CBConnectPeripheralOptionNotifyOnNotificationKey"
public let CBCentralManagerOptionShowPowerAlertKey = "CBCentralManagerOptionShowPowerAlertKey"
public let CBCentralManagerOptionRestoreIdentifierKey = "CBCentralManagerOptionRestoreIdentifierKey"
public let CBPeripheralManagerOptionShowPowerAlertKey = "CBPeripheralManagerOptionShowPowerAlertKey"
public let CBPeripheralManagerOptionRestoreIdentifierKey = "CBPeripheralManagerOptionRestoreIdentifierKey"

public struct CBUUID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let uuidString: String

    public init(string: String) {
        uuidString = Self.normalize(string)
    }

    public init(data: Data) {
        uuidString = data.map { String(format: "%02X", $0) }.joined()
    }

    public var data: Data {
        let compact = uuidString.replacingOccurrences(of: "-", with: "")
        guard compact.count.isMultiple(of: 2) else { return Data() }
        var output = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { return Data() }
            output.append(byte)
            index = end
        }
        return output
    }

    public var description: String { uuidString }

    var encodedByteCount: Int {
        switch uuidString.replacingOccurrences(of: "-", with: "").count {
        case 4: return 2
        case 8: return 4
        default: return 16
        }
    }

    var isValid: Bool {
        let compact = uuidString.replacingOccurrences(of: "-", with: "")
        guard [4, 8, 32].contains(compact.count) else { return false }
        return compact.allSatisfy(\.isHexDigit)
    }

    private static func normalize(_ value: String) -> String {
        let uppercase = value.uppercased()
        let compact = uppercase.replacingOccurrences(of: "-", with: "")
        guard compact.count == 32, compact.allSatisfy(\.isHexDigit) else { return uppercase }
        return [8, 4, 4, 4, 12].reduce(into: (parts: [String](), index: compact.startIndex)) { result, length in
            let end = compact.index(result.index, offsetBy: length)
            result.parts.append(String(compact[result.index..<end]))
            result.index = end
        }.parts.joined(separator: "-")
    }
}

public enum CBManagerState: Int, Codable, Sendable {
    case unknown = 0
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum CBPeripheralState: Int, Codable, Sendable {
    case disconnected = 0
    case connecting
    case connected
    case disconnecting
}

public struct CBCharacteristicProperties: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let broadcast = Self(rawValue: 0x01)
    public static let read = Self(rawValue: 0x02)
    public static let writeWithoutResponse = Self(rawValue: 0x04)
    public static let write = Self(rawValue: 0x08)
    public static let notify = Self(rawValue: 0x10)
    public static let indicate = Self(rawValue: 0x20)
    public static let authenticatedSignedWrites = Self(rawValue: 0x40)
    public static let extendedProperties = Self(rawValue: 0x80)
    public static let notifyEncryptionRequired = Self(rawValue: 0x100)
    public static let indicateEncryptionRequired = Self(rawValue: 0x200)
}

public struct CBAttributePermissions: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let readable = Self(rawValue: 0x01)
    public static let writeable = Self(rawValue: 0x02)
    public static let readEncryptionRequired = Self(rawValue: 0x04)
    public static let writeEncryptionRequired = Self(rawValue: 0x08)
}

public enum CBCharacteristicWriteType: Int, Codable, Sendable {
    case withResponse
    case withoutResponse
}

public struct CBATTError {
    public enum Code: Int, Codable, Error, Sendable {
        case success = 0x00
        case invalidHandle = 0x01
        case readNotPermitted = 0x02
        case writeNotPermitted = 0x03
        case invalidPdu = 0x04
        case insufficientAuthentication = 0x05
        case requestNotSupported = 0x06
        case invalidOffset = 0x07
        case insufficientAuthorization = 0x08
        case prepareQueueFull = 0x09
        case attributeNotFound = 0x0A
        case attributeNotLong = 0x0B
        case insufficientEncryptionKeySize = 0x0C
        case invalidAttributeValueLength = 0x0D
        case unlikelyError = 0x0E
        case insufficientEncryption = 0x0F
        case unsupportedGroupType = 0x10
        case insufficientResources = 0x11
    }
}
