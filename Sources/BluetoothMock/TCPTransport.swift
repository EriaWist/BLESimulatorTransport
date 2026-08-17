import Foundation
@preconcurrency import Network

enum TCPPeerState {
    case ready
    case failed(Error)
    case cancelled
}

final class TCPPeer: @unchecked Sendable {
    let id = UUID()
    let remoteEndpoint: NWEndpoint

    var onStateChange: ((TCPPeerState) -> Void)?
    var onMessage: ((BLEWireMessage) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let latency: DispatchTimeInterval
    private var decoder = BLEFrameDecoder()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        latencyMilliseconds: Int
    ) {
        self.connection = connection
        self.remoteEndpoint = connection.endpoint
        self.queue = queue
        self.latency = .milliseconds(max(0, latencyMilliseconds))
    }

    convenience init(
        host: String,
        port: UInt16,
        queue: DispatchQueue,
        latencyMilliseconds: Int
    ) throws {
        guard port > 0, let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw BluetoothMockError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.init(
            connection: NWConnection(
                host: NWEndpoint.Host(host),
                port: networkPort,
                using: parameters
            ),
            queue: queue,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
            case .failed(let error):
                self.onStateChange?(.failed(error))
            case .cancelled:
                self.onStateChange?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextChunk()
    }

    func send(_ message: BLEWireMessage) {
        do {
            let data = try BLEFrameCodec.encode(message)
            queue.asyncAfter(deadline: .now() + latency) { [weak self] in
                self?.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { self?.onStateChange?(.failed(error)) }
                })
            }
        } catch {
            onStateChange?(.failed(error))
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try self.decoder.append(data)
                    messages.forEach { self.onMessage?($0) }
                } catch {
                    self.onStateChange?(.failed(error))
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.onStateChange?(.failed(error))
                return
            }
            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }
            self.receiveNextChunk()
        }
    }
}

final class TCPServer: @unchecked Sendable {
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPeerReady: ((TCPPeer) -> Void)?
    var onPeerClosed: ((TCPPeer) -> Void)?
    var onMessage: ((TCPPeer, BLEWireMessage) -> Void)?

    private let port: UInt16
    private let queue: DispatchQueue
    private let latencyMilliseconds: Int
    private var listener: NWListener?
    private var peers: [UUID: TCPPeer] = [:]

    init(port: UInt16, queue: DispatchQueue, latencyMilliseconds: Int) {
        self.port = port
        self.queue = queue
        self.latencyMilliseconds = latencyMilliseconds
    }

    func start() throws {
        guard port > 0, let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw BluetoothMockError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: networkPort
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.onFailure?(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard Self.isLoopback(connection.endpoint) else {
                connection.cancel()
                return
            }
            let peer = TCPPeer(
                connection: connection,
                queue: self.queue,
                latencyMilliseconds: self.latencyMilliseconds
            )
            self.peers[peer.id] = peer
            peer.onMessage = { [weak self, weak peer] message in
                guard let self, let peer else { return }
                self.onMessage?(peer, message)
            }
            peer.onStateChange = { [weak self, weak peer] state in
                guard let self, let peer else { return }
                switch state {
                case .ready:
                    self.onPeerReady?(peer)
                case .failed, .cancelled:
                    if self.peers.removeValue(forKey: peer.id) != nil {
                        self.onPeerClosed?(peer)
                    }
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let currentPeers = peers.values
        peers.removeAll()
        currentPeers.forEach { $0.cancel() }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "localhost"
            || value == "::1"
            || value == "127.0.0.1"
            || value.hasPrefix("127.")
            || value.contains("::ffff:127.")
    }
}
