import Foundation

/// Keys accepted in the `options` dictionary of the mock central and peripheral managers.
public enum BluetoothMockOption {
    /// TCP host used by a central. Defaults to `127.0.0.1`.
    public static let tcpHost = "BluetoothMock.tcpHost"
    /// TCP port shared by the two simulator apps. Defaults to `7799`.
    public static let tcpPort = "BluetoothMock.tcpPort"
    /// ATT MTU advertised by this endpoint. It is clamped to the BLE range 23...517.
    public static let attMTU = "BluetoothMock.attMTU"
    /// Artificial one-way transport latency, in milliseconds. Defaults to zero.
    public static let latencyMilliseconds = "BluetoothMock.latencyMilliseconds"
    /// Maximum bytes placed in each TCP send. Positive values intentionally fragment frames.
    public static let tcpFragmentSize = "BluetoothMock.tcpFragmentSize"
    /// Cancels this endpoint after sending the given number of complete wire frames.
    public static let disconnectAfterSentFrames = "BluetoothMock.disconnectAfterSentFrames"
    /// Simulated discovery RSSI. Defaults to -45 dBm and is clamped to -127...20.
    public static let rssi = "BluetoothMock.rssi"
    /// Stable UUID used by a peripheral manager. Accepts `UUID` or a UUID string.
    public static let peripheralIdentifier = "BluetoothMock.peripheralIdentifier"
    /// Whether a peripheral should answer reads/writes directly from characteristic values.
    /// Defaults to `false`, matching CoreBluetooth delegate-driven request handling.
    public static let automaticATTResponses = "BluetoothMock.automaticATTResponses"
}

public struct BluetoothMockConfiguration: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var attMTU: Int
    public var latencyMilliseconds: Int
    public var tcpFragmentSize: Int?
    public var disconnectAfterSentFrames: Int?
    public var rssi: Int
    public var peripheralIdentifier: UUID?
    public var automaticATTResponses: Bool

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 7_799,
        attMTU: Int = BLELimits.minimumATTMTU,
        latencyMilliseconds: Int = 0,
        tcpFragmentSize: Int? = nil,
        disconnectAfterSentFrames: Int? = nil,
        rssi: Int = -45,
        peripheralIdentifier: UUID? = nil,
        automaticATTResponses: Bool = false
    ) {
        self.host = host
        self.port = port
        self.attMTU = min(max(attMTU, BLELimits.minimumATTMTU), BLELimits.maximumATTMTU)
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.tcpFragmentSize = tcpFragmentSize.flatMap { $0 > 0 ? $0 : nil }
        self.disconnectAfterSentFrames = disconnectAfterSentFrames.flatMap { $0 > 0 ? $0 : nil }
        self.rssi = min(max(rssi, -127), 20)
        self.peripheralIdentifier = peripheralIdentifier
        self.automaticATTResponses = automaticATTResponses
    }

    init(options: [String: Any]?) {
        let host = options?[BluetoothMockOption.tcpHost] as? String ?? "127.0.0.1"
        let portNumber = options?[BluetoothMockOption.tcpPort] as? NSNumber
        let mtuNumber = options?[BluetoothMockOption.attMTU] as? NSNumber
        let latencyNumber = options?[BluetoothMockOption.latencyMilliseconds] as? NSNumber
        let fragmentSizeNumber = options?[BluetoothMockOption.tcpFragmentSize] as? NSNumber
        let disconnectAfterNumber = options?[BluetoothMockOption.disconnectAfterSentFrames] as? NSNumber
        let rssiNumber = options?[BluetoothMockOption.rssi] as? NSNumber
        let automaticNumber = options?[BluetoothMockOption.automaticATTResponses] as? NSNumber
        let configuredIdentifier = options?[BluetoothMockOption.peripheralIdentifier] as? UUID
            ?? (options?[BluetoothMockOption.peripheralIdentifier] as? String).flatMap(UUID.init(uuidString:))

        self.init(
            host: host,
            port: UInt16(clamping: portNumber?.intValue ?? 7_799),
            attMTU: mtuNumber?.intValue ?? BLELimits.minimumATTMTU,
            latencyMilliseconds: latencyNumber?.intValue ?? 0,
            tcpFragmentSize: fragmentSizeNumber?.intValue,
            disconnectAfterSentFrames: disconnectAfterNumber?.intValue,
            rssi: rssiNumber?.intValue ?? -45,
            peripheralIdentifier: configuredIdentifier,
            automaticATTResponses: automaticNumber?.boolValue ?? false
        )
    }
}
