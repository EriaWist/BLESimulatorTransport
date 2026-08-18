import Foundation

public final class CBPeripheralManager: NSObject, @unchecked Sendable {
    public weak var delegate: CBPeripheralManagerDelegate?
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isAdvertising = false

    private final class Session {
        let peer: TCPPeer
        var central: CBCentral
        var negotiatedATTMTU: Int
        var connected = false
        var subscriptions = Set<UUID>()

        init(peer: TCPPeer, attMTU: Int) {
            self.peer = peer
            self.negotiatedATTMTU = attMTU
            self.central = CBCentral(
                identifier: UUID(),
                maximumUpdateValueLength: BLELimits.maximumAttributePayload(forATTMTU: attMTU)
            )
        }
    }

    private enum PendingATT {
        case read(peer: TCPPeer, request: CBATTRequest)
        case write(peer: TCPPeer, request: CBATTRequest)
    }

    private let configuration: BluetoothMockConfiguration
    private let delegateQueue: DispatchQueue
    private let managerQueue = DispatchQueue(label: "BluetoothMock.peripheral.manager")
    private let peripheralIdentifier: UUID
    private var server: TCPServer?
    private var services: [CBMutableService] = []
    private var advertisement: WireAdvertisement?
    private var sessions: [UUID: Session] = [:]
    private var pendingATT: [UUID: PendingATT] = [:]

    public init(
        delegate: CBPeripheralManagerDelegate?,
        queue: DispatchQueue?,
        options: [String: Any]? = nil
    ) {
        let configuration = BluetoothMockConfiguration(options: options)
        self.delegate = delegate
        self.delegateQueue = queue ?? .main
        self.configuration = configuration
        self.peripheralIdentifier = configuration.peripheralIdentifier ?? UUID()
        super.init()
        managerQueue.async { [weak self] in
            guard let self else { return }
            self.state = .poweredOn
            self.callDelegate { $0.peripheralManagerDidUpdateState(self) }
        }
    }

    deinit {
        server?.stop()
    }

    public func add(_ service: CBMutableService) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.validate(service)
                self.services.append(service)
                self.callDelegate { $0.peripheralManager(self, didAdd: service, error: nil) }
            } catch {
                self.callDelegate { $0.peripheralManager(self, didAdd: service, error: error) }
            }
        }
    }

    public func remove(_ service: CBMutableService) {
        managerQueue.async { [weak self] in
            self?.services.removeAll { $0 === service }
        }
    }

    public func removeAllServices() {
        managerQueue.async { [weak self] in self?.services.removeAll() }
    }

    public func startAdvertising(_ advertisementData: [String: Any]?) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            let data = advertisementData ?? [:]
            do {
                _ = try BLELimits.legacyAdvertisingSize(data)
                self.advertisement = WireAdvertisement(
                    advertisementData: data,
                    rssi: self.configuration.rssi
                )
                self.isAdvertising = true
                if self.server == nil {
                    try self.startServer()
                } else {
                    self.broadcastAdvertisement()
                    self.callDelegate { $0.peripheralManagerDidStartAdvertising(self, error: nil) }
                }
            } catch {
                self.isAdvertising = false
                self.server?.stop()
                self.server = nil
                self.callDelegate { $0.peripheralManagerDidStartAdvertising(self, error: error) }
            }
        }
    }

    public func stopAdvertising() {
        managerQueue.async { [weak self] in
            guard let self else { return }
            self.isAdvertising = false
            self.sessions.values.forEach { $0.peer.send(BLEWireMessage(payload: .stopAdvertising)) }
        }
    }

    @discardableResult
    public func updateValue(
        _ value: Data,
        for characteristic: CBMutableCharacteristic,
        onSubscribedCentrals centrals: [CBCentral]?
    ) -> Bool {
        managerQueue.sync {
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                return false
            }
            let allowedIdentifiers = centrals.map { Set($0.map(\.identifier)) }
            let recipients = sessions.values.filter { session in
                session.connected
                    && session.subscriptions.contains(characteristic.mockIdentifier)
                    && (allowedIdentifiers?.contains(session.central.identifier) ?? true)
            }
            do {
                try BLELimits.validateAttributeValue(value)
                for recipient in recipients {
                    try BLELimits.validatePacketPayload(value, attMTU: recipient.negotiatedATTMTU)
                }
            } catch {
                return false
            }

            characteristic.setValue(value)
            let notification = WireNotification(
                characteristicIdentifier: characteristic.mockIdentifier,
                data: value
            )
            recipients.forEach {
                $0.peer.send(BLEWireMessage(payload: .notification(notification)))
            }
            return true
        }
    }

    public func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {
        managerQueue.async { [weak self, weak request] in
            guard let self, let request,
                  let pending = self.pendingATT.removeValue(forKey: request.wireRequestID) else { return }
            switch pending {
            case .read(let peer, _):
                var finalResult = result
                if result == .success, let value = request.value {
                    do { try BLELimits.validateAttributeValue(value) }
                    catch { finalResult = .invalidAttributeValueLength }
                }
                peer.send(BLEWireMessage(
                    replyTo: request.wireRequestID,
                    payload: .readResponse(WireResponse(
                        result: finalResult,
                        data: finalResult == .success ? request.value : nil
                    ))
                ))
            case .write(let peer, _):
                var finalResult = result
                if result == .success, let value = request.value {
                    do { try BLELimits.validateAttributeValue(value) }
                    catch { finalResult = .invalidAttributeValueLength }
                }
                if finalResult == .success,
                   let mutable = request.characteristic as? CBMutableCharacteristic {
                    mutable.setValue(request.value)
                }
                peer.send(BLEWireMessage(
                    replyTo: request.wireRequestID,
                    payload: .writeResponse(WireResponse(result: finalResult, data: nil))
                ))
            }
        }
    }

    private func startServer() throws {
        let server = TCPServer(
            port: configuration.port,
            queue: managerQueue,
            latencyMilliseconds: configuration.latencyMilliseconds,
            fragmentSize: configuration.tcpFragmentSize,
            disconnectAfterSentFrames: configuration.disconnectAfterSentFrames
        )
        self.server = server
        server.onReady = { [weak self] in
            guard let self else { return }
            self.broadcastAdvertisement()
            self.callDelegate { $0.peripheralManagerDidStartAdvertising(self, error: nil) }
        }
        server.onFailure = { [weak self] error in
            guard let self else { return }
            self.isAdvertising = false
            self.server?.stop()
            self.server = nil
            self.callDelegate {
                $0.peripheralManagerDidStartAdvertising(
                    self,
                    error: BluetoothMockError.transport(error.localizedDescription)
                )
            }
        }
        server.onPeerReady = { [weak self] peer in self?.peerDidConnect(peer) }
        server.onPeerClosed = { [weak self] peer in self?.peerDidClose(peer) }
        server.onMessage = { [weak self] peer, message in self?.handle(message, from: peer) }
        try server.start()
    }

    private func peerDidConnect(_ peer: TCPPeer) {
        let session = Session(peer: peer, attMTU: configuration.attMTU)
        sessions[peer.id] = session
        peer.send(BLEWireMessage(payload: .hello(WireHello(
            role: .peripheral,
            identifier: peripheralIdentifier,
            attMTU: configuration.attMTU
        ))))
        if isAdvertising, let advertisement {
            peer.send(BLEWireMessage(payload: .advertisement(advertisement)))
        }
    }

    private func peerDidClose(_ peer: TCPPeer) {
        guard let session = sessions.removeValue(forKey: peer.id) else { return }
        for characteristicID in session.subscriptions {
            if let characteristic = findCharacteristic(characteristicID) {
                callDelegate {
                    $0.peripheralManager(
                        self,
                        central: session.central,
                        didUnsubscribeFrom: characteristic
                    )
                }
            }
        }
        pendingATT = pendingATT.filter { _, pending in
            switch pending {
            case .read(let pendingPeer, _), .write(let pendingPeer, _):
                return pendingPeer !== peer
            }
        }
    }

    private func handle(_ message: BLEWireMessage, from peer: TCPPeer) {
        guard let session = sessions[peer.id] else { return }
        switch message.payload {
        case .hello(let hello) where hello.role == .central:
            session.negotiatedATTMTU = min(configuration.attMTU, hello.attMTU)
            session.central = CBCentral(
                identifier: hello.identifier,
                maximumUpdateValueLength: BLELimits.maximumAttributePayload(
                    forATTMTU: session.negotiatedATTMTU
                )
            )
        case .connect(let connect):
            guard isAdvertising || session.connected else {
                peer.send(BLEWireMessage(
                    replyTo: message.id,
                    payload: .disconnect("Peripheral is not advertising")
                ))
                return
            }
            session.negotiatedATTMTU = min(configuration.attMTU, connect.attMTU)
            session.central = CBCentral(
                identifier: connect.centralIdentifier,
                maximumUpdateValueLength: BLELimits.maximumAttributePayload(
                    forATTMTU: session.negotiatedATTMTU
                )
            )
            session.connected = true
            peer.send(BLEWireMessage(
                replyTo: message.id,
                payload: .connected(WireConnected(
                    peripheralIdentifier: peripheralIdentifier,
                    negotiatedATTMTU: session.negotiatedATTMTU
                ))
            ))
        case .disconnect(let reason):
            unsubscribeAll(session)
            session.connected = false
            peer.send(BLEWireMessage(replyTo: message.id, payload: .disconnect(reason)))
        case .discoverServices(let query):
            guard session.connected else {
                peer.send(BLEWireMessage(replyTo: message.id, payload: .services([])))
                return
            }
            let matches = services.filter { service in
                query.uuids?.contains(service.uuid) ?? true
            }.map {
                WireService(identifier: $0.mockIdentifier, uuid: $0.uuid, isPrimary: $0.isPrimary)
            }
            peer.send(BLEWireMessage(replyTo: message.id, payload: .services(matches)))
        case .discoverCharacteristics(let query):
            let service = services.first { $0.mockIdentifier == query.serviceIdentifier }
            let matches = service?.characteristics?.filter { characteristic in
                query.uuids?.contains(characteristic.uuid) ?? true
            }.map {
                WireCharacteristic(
                    identifier: $0.mockIdentifier,
                    serviceIdentifier: query.serviceIdentifier,
                    uuid: $0.uuid,
                    properties: $0.properties,
                    permissions: $0.permissions
                )
            } ?? []
            peer.send(BLEWireMessage(
                replyTo: message.id,
                payload: .characteristics(serviceIdentifier: query.serviceIdentifier, values: matches)
            ))
        case .read(let read):
            receiveRead(read, messageID: message.id, session: session)
        case .write(let write):
            receiveWrite(write, messageID: message.id, session: session)
        case .subscribe(let subscribe):
            receiveSubscription(subscribe, messageID: message.id, session: session)
        default:
            break
        }
    }

    private func receiveRead(_ read: WireRead, messageID: UUID, session: Session) {
        guard session.connected,
              let characteristic = findCharacteristic(read.characteristicIdentifier) else {
            sendReadError(.invalidHandle, replyTo: messageID, peer: session.peer)
            return
        }
        guard characteristic.properties.contains(.read), characteristic.permissions.contains(.readable) else {
            sendReadError(.readNotPermitted, replyTo: messageID, peer: session.peer)
            return
        }
        let currentValue = characteristic.value ?? Data()
        guard read.offset >= 0, read.offset <= currentValue.count else {
            sendReadError(.invalidOffset, replyTo: messageID, peer: session.peer)
            return
        }
        let request = CBATTRequest(
            central: session.central,
            characteristic: characteristic,
            offset: read.offset,
            value: currentValue.subdata(in: read.offset..<currentValue.count),
            wireRequestID: messageID,
            expectsResponse: true
        )
        if configuration.automaticATTResponses {
            session.peer.send(BLEWireMessage(
                replyTo: messageID,
                payload: .readResponse(WireResponse(result: .success, data: request.value))
            ))
        } else {
            pendingATT[messageID] = .read(peer: session.peer, request: request)
        }
        callDelegate { $0.peripheralManager(self, didReceiveRead: request) }
    }

    private func receiveWrite(_ write: WireWrite, messageID: UUID, session: Session) {
        guard session.connected,
              let characteristic = findCharacteristic(write.characteristicIdentifier) else {
            if write.type == .withResponse { sendWriteError(.invalidHandle, replyTo: messageID, peer: session.peer) }
            return
        }
        let supportsWrite = write.type == .withResponse
            ? characteristic.properties.contains(.write)
            : characteristic.properties.contains(.writeWithoutResponse)
        guard supportsWrite, characteristic.permissions.contains(.writeable) else {
            if write.type == .withResponse { sendWriteError(.writeNotPermitted, replyTo: messageID, peer: session.peer) }
            return
        }
        do {
            try BLELimits.validatePacketPayload(write.data, attMTU: session.negotiatedATTMTU)
        } catch {
            if write.type == .withResponse {
                sendWriteError(.invalidAttributeValueLength, replyTo: messageID, peer: session.peer)
            }
            return
        }

        let request = CBATTRequest(
            central: session.central,
            characteristic: characteristic,
            offset: 0,
            value: write.data,
            wireRequestID: messageID,
            expectsResponse: write.type == .withResponse
        )
        if write.type == .withoutResponse {
            characteristic.setValue(write.data)
        } else if configuration.automaticATTResponses {
            characteristic.setValue(write.data)
            session.peer.send(BLEWireMessage(
                replyTo: messageID,
                payload: .writeResponse(WireResponse(result: .success, data: nil))
            ))
        } else {
            pendingATT[messageID] = .write(peer: session.peer, request: request)
        }
        callDelegate { $0.peripheralManager(self, didReceiveWrite: [request]) }
    }

    private func receiveSubscription(_ subscribe: WireSubscribe, messageID: UUID, session: Session) {
        guard session.connected,
              let characteristic = findCharacteristic(subscribe.characteristicIdentifier) else {
            sendSubscribeError(.invalidHandle, replyTo: messageID, peer: session.peer)
            return
        }
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            sendSubscribeError(.requestNotSupported, replyTo: messageID, peer: session.peer)
            return
        }
        if subscribe.enabled {
            session.subscriptions.insert(characteristic.mockIdentifier)
            callDelegate {
                $0.peripheralManager(self, central: session.central, didSubscribeTo: characteristic)
            }
        } else {
            session.subscriptions.remove(characteristic.mockIdentifier)
            callDelegate {
                $0.peripheralManager(self, central: session.central, didUnsubscribeFrom: characteristic)
            }
        }
        session.peer.send(BLEWireMessage(
            replyTo: messageID,
            payload: .subscribeResponse(WireResponse(result: .success, data: nil))
        ))
    }

    private func unsubscribeAll(_ session: Session) {
        for identifier in session.subscriptions {
            guard let characteristic = findCharacteristic(identifier) else { continue }
            callDelegate {
                $0.peripheralManager(self, central: session.central, didUnsubscribeFrom: characteristic)
            }
        }
        session.subscriptions.removeAll()
    }

    private func findCharacteristic(_ identifier: UUID) -> CBMutableCharacteristic? {
        services
            .lazy
            .compactMap(\.characteristics)
            .flatMap { $0 }
            .first { $0.mockIdentifier == identifier } as? CBMutableCharacteristic
    }

    private func validate(_ service: CBMutableService) throws {
        guard service.uuid.isValid else { throw BluetoothMockError.invalidUUID(service.uuid.uuidString) }
        for characteristic in service.characteristics ?? [] {
            guard characteristic.uuid.isValid else {
                throw BluetoothMockError.invalidUUID(characteristic.uuid.uuidString)
            }
            if let value = characteristic.value { try BLELimits.validateAttributeValue(value) }
            if characteristic.properties.contains(.read), !characteristic.permissions.contains(.readable) {
                throw BluetoothMockError.operationNotSupported(
                    "Readable characteristic \(characteristic.uuid) must include .readable permission."
                )
            }
            if characteristic.properties.intersection([.write, .writeWithoutResponse]).isEmpty == false,
               !characteristic.permissions.contains(.writeable) {
                throw BluetoothMockError.operationNotSupported(
                    "Writable characteristic \(characteristic.uuid) must include .writeable permission."
                )
            }
        }
    }

    private func broadcastAdvertisement() {
        guard isAdvertising, let advertisement else { return }
        sessions.values.forEach {
            $0.peer.send(BLEWireMessage(payload: .advertisement(advertisement)))
        }
    }

    private func sendReadError(_ result: CBATTError.Code, replyTo: UUID, peer: TCPPeer) {
        peer.send(BLEWireMessage(
            replyTo: replyTo,
            payload: .readResponse(WireResponse(result: result, data: nil))
        ))
    }

    private func sendWriteError(_ result: CBATTError.Code, replyTo: UUID, peer: TCPPeer) {
        peer.send(BLEWireMessage(
            replyTo: replyTo,
            payload: .writeResponse(WireResponse(result: result, data: nil))
        ))
    }

    private func sendSubscribeError(_ result: CBATTError.Code, replyTo: UUID, peer: TCPPeer) {
        peer.send(BLEWireMessage(
            replyTo: replyTo,
            payload: .subscribeResponse(WireResponse(result: result, data: nil))
        ))
    }

    private func callDelegate(_ body: @escaping (CBPeripheralManagerDelegate) -> Void) {
        delegateQueue.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            body(delegate)
        }
    }
}
