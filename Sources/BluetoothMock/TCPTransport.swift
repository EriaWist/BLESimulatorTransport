import Foundation
@preconcurrency import Network

enum TCPPeerState {
    case ready
    case failed(Error)
    case cancelled
}

struct TCPTransmissionPolicy: Equatable, Sendable {
    let latencyMilliseconds: Int
    let fragmentSize: Int?
    let disconnectAfterSentFrames: Int?

    init(latencyMilliseconds: Int, fragmentSize: Int?, disconnectAfterSentFrames: Int?) {
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.fragmentSize = fragmentSize.flatMap { $0 > 0 ? $0 : nil }
        self.disconnectAfterSentFrames = disconnectAfterSentFrames.flatMap { $0 > 0 ? $0 : nil }
    }

    func fragments(of frame: Data) -> [Data] {
        guard let fragmentSize, frame.count > fragmentSize else { return [frame] }
        return stride(from: 0, to: frame.count, by: fragmentSize).map { offset in
            frame.subdata(in: offset..<min(offset + fragmentSize, frame.count))
        }
    }

    func shouldDisconnect(afterSentFrames count: Int) -> Bool {
        disconnectAfterSentFrames.map { count >= $0 } ?? false
    }
}

final class TCPPeer: @unchecked Sendable {
    let id = UUID()
    let remoteEndpoint: NWEndpoint

    var onStateChange: ((TCPPeerState) -> Void)?
    var onMessage: ((BLEWireMessage) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let transmissionPolicy: TCPTransmissionPolicy
    private var decoder = BLEFrameDecoder()
    private var pendingFrames: [Data] = []
    private var isSendingFrame = false
    private var sentFrameCount = 0

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        latencyMilliseconds: Int,
        fragmentSize: Int? = nil,
        disconnectAfterSentFrames: Int? = nil
    ) {
        self.connection = connection
        self.remoteEndpoint = connection.endpoint
        self.queue = queue
        self.transmissionPolicy = TCPTransmissionPolicy(
            latencyMilliseconds: latencyMilliseconds,
            fragmentSize: fragmentSize,
            disconnectAfterSentFrames: disconnectAfterSentFrames
        )
    }

    convenience init(
        host: String,
        port: UInt16,
        queue: DispatchQueue,
        latencyMilliseconds: Int,
        fragmentSize: Int? = nil,
        disconnectAfterSentFrames: Int? = nil
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
            latencyMilliseconds: latencyMilliseconds,
            fragmentSize: fragmentSize,
            disconnectAfterSentFrames: disconnectAfterSentFrames
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
            queue.async { [weak self] in
                guard let self else { return }
                self.pendingFrames.append(data)
                self.sendNextFrameIfNeeded()
            }
        } catch {
            onStateChange?(.failed(error))
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func sendNextFrameIfNeeded() {
        guard !isSendingFrame, !pendingFrames.isEmpty else { return }
        isSendingFrame = true
        let frame = pendingFrames.removeFirst()
        let delay = DispatchTimeInterval.milliseconds(transmissionPolicy.latencyMilliseconds)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.send(fragments: self.transmissionPolicy.fragments(of: frame), at: 0)
        }
    }

    private func send(fragments: [Data], at index: Int) {
        connection.send(content: fragments[index], completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.isSendingFrame = false
                    self.onStateChange?(.failed(error))
                    return
                }
                let nextIndex = index + 1
                if nextIndex < fragments.count {
                    self.send(fragments: fragments, at: nextIndex)
                    return
                }
                self.sentFrameCount += 1
                self.isSendingFrame = false
                if self.transmissionPolicy.shouldDisconnect(afterSentFrames: self.sentFrameCount) {
                    self.pendingFrames.removeAll()
                    self.connection.cancel()
                } else {
                    self.sendNextFrameIfNeeded()
                }
            }
        })
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
    private let transmissionPolicy: TCPTransmissionPolicy
    private var listener: NWListener?
    private var peers: [UUID: TCPPeer] = [:]

    init(
        port: UInt16,
        queue: DispatchQueue,
        latencyMilliseconds: Int,
        fragmentSize: Int? = nil,
        disconnectAfterSentFrames: Int? = nil
    ) {
        self.port = port
        self.queue = queue
        self.transmissionPolicy = TCPTransmissionPolicy(
            latencyMilliseconds: latencyMilliseconds,
            fragmentSize: fragmentSize,
            disconnectAfterSentFrames: disconnectAfterSentFrames
        )
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
                latencyMilliseconds: self.transmissionPolicy.latencyMilliseconds,
                fragmentSize: self.transmissionPolicy.fragmentSize,
                disconnectAfterSentFrames: self.transmissionPolicy.disconnectAfterSentFrames
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
