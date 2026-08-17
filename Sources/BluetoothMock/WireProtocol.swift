import Foundation

struct WireHello: Codable, Equatable {
    enum Role: String, Codable { case central, peripheral }
    let role: Role
    let identifier: UUID
    let attMTU: Int
}

struct WireAdvertisement: Codable, Equatable {
    struct ServiceData: Codable, Equatable {
        let uuid: CBUUID
        let data: Data
    }

    var localName: String?
    var serviceUUIDs: [CBUUID]
    var manufacturerData: Data?
    var txPower: Int?
    var isConnectable: Bool
    var serviceData: [ServiceData]
    var rssi: Int

    init(advertisementData: [String: Any], rssi: Int = -45) {
        localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
            .map { ServiceData(uuid: $0.key, data: $0.value) }
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString } ?? []
        self.rssi = rssi
    }

    var advertisementData: [String: Any] {
        var value: [String: Any] = [CBAdvertisementDataIsConnectable: NSNumber(value: isConnectable)]
        if let localName { value[CBAdvertisementDataLocalNameKey] = localName }
        if !serviceUUIDs.isEmpty { value[CBAdvertisementDataServiceUUIDsKey] = serviceUUIDs }
        if let manufacturerData { value[CBAdvertisementDataManufacturerDataKey] = manufacturerData }
        if let txPower { value[CBAdvertisementDataTxPowerLevelKey] = NSNumber(value: txPower) }
        if !serviceData.isEmpty {
            value[CBAdvertisementDataServiceDataKey] = Dictionary(
                uniqueKeysWithValues: serviceData.map { ($0.uuid, $0.data) }
            )
        }
        return value
    }
}

struct WireService: Codable, Equatable {
    let identifier: UUID
    let uuid: CBUUID
    let isPrimary: Bool
}

struct WireCharacteristic: Codable, Equatable {
    let identifier: UUID
    let serviceIdentifier: UUID
    let uuid: CBUUID
    let properties: CBCharacteristicProperties
    let permissions: CBAttributePermissions
}

struct WireConnect: Codable, Equatable {
    let centralIdentifier: UUID
    let attMTU: Int
}

struct WireConnected: Codable, Equatable {
    let peripheralIdentifier: UUID
    let negotiatedATTMTU: Int
}

struct WireServiceQuery: Codable, Equatable {
    let uuids: [CBUUID]?
}

struct WireCharacteristicQuery: Codable, Equatable {
    let serviceIdentifier: UUID
    let uuids: [CBUUID]?
}

struct WireRead: Codable, Equatable {
    let characteristicIdentifier: UUID
    let offset: Int
}

struct WireWrite: Codable, Equatable {
    let characteristicIdentifier: UUID
    let data: Data
    let type: CBCharacteristicWriteType
}

struct WireSubscribe: Codable, Equatable {
    let characteristicIdentifier: UUID
    let enabled: Bool
}

struct WireResponse: Codable, Equatable {
    let result: CBATTError.Code
    let data: Data?
}

struct WireNotification: Codable, Equatable {
    let characteristicIdentifier: UUID
    let data: Data
}

enum WirePayload: Codable, Equatable {
    case hello(WireHello)
    case advertisement(WireAdvertisement)
    case stopAdvertising
    case connect(WireConnect)
    case connected(WireConnected)
    case disconnect(String?)
    case discoverServices(WireServiceQuery)
    case services([WireService])
    case discoverCharacteristics(WireCharacteristicQuery)
    case characteristics(serviceIdentifier: UUID, values: [WireCharacteristic])
    case read(WireRead)
    case readResponse(WireResponse)
    case write(WireWrite)
    case writeResponse(WireResponse)
    case subscribe(WireSubscribe)
    case subscribeResponse(WireResponse)
    case notification(WireNotification)
}

struct BLEWireMessage: Codable, Equatable {
    static let protocolVersion = 1

    let version: Int
    let id: UUID
    let replyTo: UUID?
    let payload: WirePayload

    init(id: UUID = UUID(), replyTo: UUID? = nil, payload: WirePayload) {
        version = Self.protocolVersion
        self.id = id
        self.replyTo = replyTo
        self.payload = payload
    }
}

enum BLEFrameCodec {
    static let maximumFrameLength = 1_048_576

    static func encode(_ message: BLEWireMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumFrameLength else {
            throw BluetoothMockError.protocolViolation("Frame is larger than \(maximumFrameLength) bytes")
        }
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }

    static func decode(_ payload: Data) throws -> BLEWireMessage {
        let message = try JSONDecoder().decode(BLEWireMessage.self, from: payload)
        guard message.version == BLEWireMessage.protocolVersion else {
            throw BluetoothMockError.protocolViolation(
                "Unsupported wire protocol version \(message.version)"
            )
        }
        return message
    }
}

struct BLEFrameDecoder {
    private var buffer = Data()

    mutating func append(_ incoming: Data) throws -> [BLEWireMessage] {
        buffer.append(incoming)
        var messages: [BLEWireMessage] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= BLEFrameCodec.maximumFrameLength else {
                throw BluetoothMockError.protocolViolation("Incoming TCP frame is too large")
            }
            let totalLength = 4 + Int(length)
            guard buffer.count >= totalLength else { break }
            let payload = buffer.subdata(in: 4..<totalLength)
            buffer.removeSubrange(0..<totalLength)
            messages.append(try BLEFrameCodec.decode(payload))
        }
        return messages
    }
}
