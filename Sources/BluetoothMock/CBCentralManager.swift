import Foundation

public final class CBCentralManager: NSObject, @unchecked Sendable {
    public weak var delegate: CBCentralManagerDelegate?
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false

    private enum PendingOperation {
        case services(CBPeripheral)
        case characteristics(CBPeripheral, CBService)
        case read(CBPeripheral, CBCharacteristic)
        case write(CBPeripheral, CBCharacteristic)
        case subscribe(CBPeripheral, CBCharacteristic, Bool)
    }

    private let configuration: BluetoothMockConfiguration
    private let delegateQueue: DispatchQueue
    private let managerQueue = DispatchQueue(label: "BluetoothMock.central.manager")
    private let centralIdentifier = UUID()
    private var client: TCPPeer?
    private var scanFilter: [CBUUID]?
    private var allowDuplicateDiscoveries = false
    private var hasReportedDiscovery = false
    private var remotePeripheral: CBPeripheral?
    private var pendingOperations: [UUID: PendingOperation] = [:]
    private var retryGeneration = 0

    public init(
        delegate: CBCentralManagerDelegate?,
        queue: DispatchQueue?,
        options: [String: Any]? = nil
    ) {
        self.delegate = delegate
        self.delegateQueue = queue ?? .main
        self.configuration = BluetoothMockConfiguration(options: options)
        super.init()
        managerQueue.async { [weak self] in
            guard let self else { return }
            self.state = .poweredOn
            self.callDelegate { $0.centralManagerDidUpdateState(self) }
        }
    }

    deinit {
        client?.cancel()
    }

    public func scanForPeripherals(
        withServices serviceUUIDs: [CBUUID]?,
        options: [String: Any]? = nil
    ) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            self.scanFilter = serviceUUIDs
            self.allowDuplicateDiscoveries = (options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? NSNumber)?.boolValue ?? false
            self.hasReportedDiscovery = false
            self.isScanning = true
            self.retryGeneration += 1
            self.ensureTCPConnection(generation: self.retryGeneration)
        }
    }

    public func stopScan() {
        managerQueue.async { [weak self] in
            self?.isScanning = false
            self?.retryGeneration += 1
        }
    }

    public func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
        managerQueue.async { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard let client = self.client else {
                self.callDelegate {
                    $0.centralManager(self, didFailToConnect: peripheral, error: BluetoothMockError.notConnected)
                }
                return
            }
            peripheral.state = .connecting
            client.send(BLEWireMessage(payload: .connect(WireConnect(
                centralIdentifier: self.centralIdentifier,
                attMTU: self.configuration.attMTU
            ))))
        }
    }

    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        managerQueue.async { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            peripheral.state = .disconnecting
            self.client?.send(BLEWireMessage(payload: .disconnect(nil)))
        }
    }

    internal func discoverServices(_ uuids: [CBUUID]?, for peripheral: CBPeripheral) {
        enqueue(.services(peripheral), payload: .discoverServices(WireServiceQuery(uuids: uuids)))
    }

    internal func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService, peripheral: CBPeripheral) {
        enqueue(
            .characteristics(peripheral, service),
            payload: .discoverCharacteristics(WireCharacteristicQuery(
                serviceIdentifier: service.mockIdentifier,
                uuids: uuids
            ))
        )
    }

    internal func readValue(for characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        enqueue(
            .read(peripheral, characteristic),
            payload: .read(WireRead(characteristicIdentifier: characteristic.mockIdentifier, offset: 0))
        )
    }

    internal func writeValue(
        _ data: Data,
        for characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType,
        peripheral: CBPeripheral
    ) {
        managerQueue.async { [weak self, weak peripheral, weak characteristic] in
            guard let self, let peripheral, let characteristic else { return }
            do {
                try BLELimits.validatePacketPayload(data, attMTU: peripheral.negotiatedATTMTU)
                let payload = WirePayload.write(WireWrite(
                    characteristicIdentifier: characteristic.mockIdentifier,
                    data: data,
                    type: type
                ))
                if type == .withResponse {
                    self.enqueueNow(.write(peripheral, characteristic), payload: payload)
                } else {
                    self.client?.send(BLEWireMessage(payload: payload))
                }
            } catch {
                if type == .withResponse {
                    self.callPeripheralDelegate(peripheral) {
                        $0.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
                    }
                }
            }
        }
    }

    internal func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        enqueue(
            .subscribe(peripheral, characteristic, enabled),
            payload: .subscribe(WireSubscribe(
                characteristicIdentifier: characteristic.mockIdentifier,
                enabled: enabled
            ))
        )
    }

    private func enqueue(_ operation: PendingOperation, payload: WirePayload) {
        managerQueue.async { [weak self] in self?.enqueueNow(operation, payload: payload) }
    }

    private func enqueueNow(_ operation: PendingOperation, payload: WirePayload) {
        let message = BLEWireMessage(payload: payload)
        pendingOperations[message.id] = operation
        guard let client else {
            pendingOperations.removeValue(forKey: message.id)
            fail(operation, error: BluetoothMockError.notConnected)
            return
        }
        client.send(message)
    }

    private func ensureTCPConnection(generation: Int) {
        guard isScanning, client == nil, generation == retryGeneration else { return }
        do {
            let peer = try TCPPeer(
                host: configuration.host,
                port: configuration.port,
                queue: managerQueue,
                latencyMilliseconds: configuration.latencyMilliseconds
            )
            client = peer
            peer.onStateChange = { [weak self, weak peer] state in
                guard let self, let peer, self.client === peer else { return }
                switch state {
                case .ready:
                    peer.send(BLEWireMessage(payload: .hello(WireHello(
                        role: .central,
                        identifier: self.centralIdentifier,
                        attMTU: self.configuration.attMTU
                    ))))
                case .failed(let error):
                    self.handleTransportClosure(error: error, generation: generation)
                case .cancelled:
                    self.handleTransportClosure(error: nil, generation: generation)
                }
            }
            peer.onMessage = { [weak self] message in self?.handle(message) }
            peer.start()
        } catch {
            scheduleRetry(generation: generation)
        }
    }

    private func handleTransportClosure(error: Error?, generation: Int) {
        client = nil
        if let peripheral = remotePeripheral, peripheral.state == .connected || peripheral.state == .disconnecting {
            peripheral.state = .disconnected
            callDelegate {
                $0.centralManager(self, didDisconnectPeripheral: peripheral, error: error)
            }
        } else if let peripheral = remotePeripheral, peripheral.state == .connecting {
            peripheral.state = .disconnected
            callDelegate {
                $0.centralManager(self, didFailToConnect: peripheral, error: error)
            }
        }
        scheduleRetry(generation: generation)
    }

    private func scheduleRetry(generation: Int) {
        guard isScanning, generation == retryGeneration else { return }
        managerQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.ensureTCPConnection(generation: generation)
        }
    }

    private func handle(_ message: BLEWireMessage) {
        switch message.payload {
        case .hello(let hello) where hello.role == .peripheral:
            if remotePeripheral?.identifier != hello.identifier {
                remotePeripheral = CBPeripheral(identifier: hello.identifier, name: nil, manager: self)
                hasReportedDiscovery = false
            }
        case .advertisement(let advertisement):
            guard isScanning, advertisementMatchesFilter(advertisement) else { return }
            let peripheral = remotePeripheral ?? CBPeripheral(identifier: UUID(), name: advertisement.localName, manager: self)
            remotePeripheral = peripheral
            peripheral.name = advertisement.localName
            guard allowDuplicateDiscoveries || !hasReportedDiscovery else { return }
            hasReportedDiscovery = true
            callDelegate {
                $0.centralManager(
                    self,
                    didDiscover: peripheral,
                    advertisementData: advertisement.advertisementData,
                    rssi: NSNumber(value: advertisement.rssi)
                )
            }
        case .connected(let connected):
            guard let peripheral = remotePeripheral else { return }
            peripheral.negotiatedATTMTU = connected.negotiatedATTMTU
            peripheral.state = .connected
            callDelegate { $0.centralManager(self, didConnect: peripheral) }
        case .disconnect(let reason):
            guard let peripheral = remotePeripheral else { return }
            let wasConnecting = peripheral.state == .connecting
            peripheral.state = .disconnected
            let error = reason.map { BluetoothMockError.transport($0) }
            if wasConnecting {
                callDelegate { $0.centralManager(self, didFailToConnect: peripheral, error: error) }
            } else {
                callDelegate { $0.centralManager(self, didDisconnectPeripheral: peripheral, error: error) }
            }
        case .services(let services):
            guard let reply = message.replyTo,
                  case .services(let peripheral)? = pendingOperations.removeValue(forKey: reply) else { return }
            peripheral.services = services.map {
                CBService(type: $0.uuid, primary: $0.isPrimary, mockIdentifier: $0.identifier)
            }
            callPeripheralDelegate(peripheral) { $0.peripheral(peripheral, didDiscoverServices: nil) }
        case .characteristics(let serviceIdentifier, let values):
            guard let reply = message.replyTo,
                  case .characteristics(let peripheral, let service)? = pendingOperations.removeValue(forKey: reply),
                  service.mockIdentifier == serviceIdentifier else { return }
            service.characteristics = values.map {
                CBCharacteristic(
                    type: $0.uuid,
                    properties: $0.properties,
                    value: nil,
                    permissions: $0.permissions,
                    mockIdentifier: $0.identifier
                )
            }
            callPeripheralDelegate(peripheral) {
                $0.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
            }
        case .readResponse(let response):
            guard let reply = message.replyTo,
                  case .read(let peripheral, let characteristic)? = pendingOperations.removeValue(forKey: reply) else { return }
            if response.result == .success { characteristic.value = response.data }
            callPeripheralDelegate(peripheral) {
                $0.peripheral(
                    peripheral,
                    didUpdateValueFor: characteristic,
                    error: response.result == .success ? nil : response.result
                )
            }
        case .writeResponse(let response):
            guard let reply = message.replyTo,
                  case .write(let peripheral, let characteristic)? = pendingOperations.removeValue(forKey: reply) else { return }
            callPeripheralDelegate(peripheral) {
                $0.peripheral(
                    peripheral,
                    didWriteValueFor: characteristic,
                    error: response.result == .success ? nil : response.result
                )
            }
        case .subscribeResponse(let response):
            guard let reply = message.replyTo,
                  case .subscribe(let peripheral, let characteristic, let enabled)? = pendingOperations.removeValue(forKey: reply) else { return }
            if response.result == .success { characteristic.isNotifying = enabled }
            callPeripheralDelegate(peripheral) {
                $0.peripheral(
                    peripheral,
                    didUpdateNotificationStateFor: characteristic,
                    error: response.result == .success ? nil : response.result
                )
            }
        case .notification(let notification):
            guard let peripheral = remotePeripheral,
                  let characteristic = findCharacteristic(notification.characteristicIdentifier, in: peripheral) else { return }
            do {
                try BLELimits.validatePacketPayload(notification.data, attMTU: peripheral.negotiatedATTMTU)
                characteristic.value = notification.data
                callPeripheralDelegate(peripheral) {
                    $0.peripheral(peripheral, didUpdateValueFor: characteristic, error: nil)
                }
            } catch {
                callPeripheralDelegate(peripheral) {
                    $0.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
                }
            }
        default:
            break
        }
    }

    private func advertisementMatchesFilter(_ advertisement: WireAdvertisement) -> Bool {
        guard let scanFilter, !scanFilter.isEmpty else { return true }
        return scanFilter.contains { advertisement.serviceUUIDs.contains($0) }
    }

    private func findCharacteristic(_ identifier: UUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .lazy
            .compactMap(\.characteristics)
            .flatMap { $0 }
            .first { $0.mockIdentifier == identifier }
    }

    private func fail(_ operation: PendingOperation, error: Error) {
        switch operation {
        case .services(let peripheral):
            callPeripheralDelegate(peripheral) { $0.peripheral(peripheral, didDiscoverServices: error) }
        case .characteristics(let peripheral, let service):
            callPeripheralDelegate(peripheral) {
                $0.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
            }
        case .read(let peripheral, let characteristic):
            callPeripheralDelegate(peripheral) {
                $0.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
            }
        case .write(let peripheral, let characteristic):
            callPeripheralDelegate(peripheral) {
                $0.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
            }
        case .subscribe(let peripheral, let characteristic, _):
            callPeripheralDelegate(peripheral) {
                $0.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
            }
        }
    }

    private func callDelegate(_ body: @escaping (CBCentralManagerDelegate) -> Void) {
        delegateQueue.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            body(delegate)
        }
    }

    private func callPeripheralDelegate(
        _ peripheral: CBPeripheral,
        _ body: @escaping (CBPeripheralDelegate) -> Void
    ) {
        delegateQueue.async { [weak peripheral] in
            guard let peripheral, let delegate = peripheral.delegate else { return }
            body(delegate)
        }
    }
}
