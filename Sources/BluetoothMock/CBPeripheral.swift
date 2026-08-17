import Foundation

public final class CBPeripheral: NSObject, @unchecked Sendable {
    public let identifier: UUID
    public internal(set) var name: String?
    public internal(set) var state: CBPeripheralState = .disconnected
    public internal(set) var services: [CBService]?
    public weak var delegate: CBPeripheralDelegate?
    public var canSendWriteWithoutResponse: Bool { state == .connected }

    internal weak var manager: CBCentralManager?
    internal var negotiatedATTMTU: Int = BLELimits.minimumATTMTU

    internal init(identifier: UUID, name: String?, manager: CBCentralManager) {
        self.identifier = identifier
        self.name = name
        self.manager = manager
        super.init()
    }

    public func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        manager?.discoverServices(serviceUUIDs, for: self)
    }

    public func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        manager?.discoverCharacteristics(characteristicUUIDs, for: service, peripheral: self)
    }

    public func readValue(for characteristic: CBCharacteristic) {
        manager?.readValue(for: characteristic, peripheral: self)
    }

    public func writeValue(
        _ data: Data,
        for characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType
    ) {
        manager?.writeValue(data, for: characteristic, type: type, peripheral: self)
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        manager?.setNotifyValue(enabled, for: characteristic, peripheral: self)
    }

    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        BLELimits.maximumAttributePayload(forATTMTU: negotiatedATTMTU)
    }
}
