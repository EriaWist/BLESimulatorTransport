import Foundation

open class CBService: NSObject, @unchecked Sendable {
    public let uuid: CBUUID
    public let isPrimary: Bool
    public var includedServices: [CBService]?
    public var characteristics: [CBCharacteristic]? {
        didSet { characteristics?.forEach { $0.service = self } }
    }
    internal let mockIdentifier: UUID

    internal init(type: CBUUID, primary: Bool, mockIdentifier: UUID) {
        self.uuid = type
        self.isPrimary = primary
        self.mockIdentifier = mockIdentifier
        super.init()
    }
}

public final class CBMutableService: CBService, @unchecked Sendable {
    public init(type: CBUUID, primary: Bool) {
        super.init(type: type, primary: primary, mockIdentifier: UUID())
    }
}

open class CBCharacteristic: NSObject, @unchecked Sendable {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var value: Data?
    public internal(set) var descriptors: [CBDescriptor]?
    public internal(set) weak var service: CBService?
    public internal(set) var isNotifying = false
    public let permissions: CBAttributePermissions
    internal let mockIdentifier: UUID

    internal init(
        type: CBUUID,
        properties: CBCharacteristicProperties,
        value: Data?,
        permissions: CBAttributePermissions,
        mockIdentifier: UUID
    ) {
        self.uuid = type
        self.properties = properties
        self.value = value
        self.permissions = permissions
        self.mockIdentifier = mockIdentifier
        super.init()
    }
}

public final class CBMutableCharacteristic: CBCharacteristic, @unchecked Sendable {
    public init(
        type: CBUUID,
        properties: CBCharacteristicProperties,
        value: Data?,
        permissions: CBAttributePermissions
    ) {
        super.init(
            type: type,
            properties: properties,
            value: value,
            permissions: permissions,
            mockIdentifier: UUID()
        )
    }

    public func setValue(_ value: Data?) {
        self.value = value
    }
}

open class CBDescriptor: NSObject, @unchecked Sendable {
    public let uuid: CBUUID
    public var value: Any?
    internal let mockIdentifier: UUID

    internal init(type: CBUUID, value: Any?, mockIdentifier: UUID) {
        self.uuid = type
        self.value = value
        self.mockIdentifier = mockIdentifier
        super.init()
    }
}

public final class CBMutableDescriptor: CBDescriptor, @unchecked Sendable {
    public init(type: CBUUID, value: Any?) {
        super.init(type: type, value: value, mockIdentifier: UUID())
    }
}

public final class CBCentral: NSObject, @unchecked Sendable {
    public let identifier: UUID
    public internal(set) var maximumUpdateValueLength: Int

    internal init(identifier: UUID, maximumUpdateValueLength: Int) {
        self.identifier = identifier
        self.maximumUpdateValueLength = maximumUpdateValueLength
        super.init()
    }
}

public final class CBATTRequest: NSObject, @unchecked Sendable {
    public let central: CBCentral
    public let characteristic: CBCharacteristic
    public let offset: Int
    public var value: Data?

    internal let wireRequestID: UUID
    internal let expectsResponse: Bool

    internal init(
        central: CBCentral,
        characteristic: CBCharacteristic,
        offset: Int,
        value: Data?,
        wireRequestID: UUID,
        expectsResponse: Bool
    ) {
        self.central = central
        self.characteristic = characteristic
        self.offset = offset
        self.value = value
        self.wireRequestID = wireRequestID
        self.expectsResponse = expectsResponse
        super.init()
    }
}
