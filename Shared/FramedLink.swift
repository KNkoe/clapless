import Foundation
import Network
import Security

enum FrameType: UInt8 {
    case message = 1   // JSON
    case preview = 2   // one JPEG frame
    case chunk = 3     // [4-byte header length][JSON ChunkHeader][bytes]
}

/// Frames on the wire: 4-byte payload length, 1-byte type, payload.
enum Framing {
    static let maximumPayload = 8 * 1024 * 1024

    static func header(type: FrameType, length: Int) -> Data {
        var big = UInt32(length).bigEndian
        var out = Data(bytes: &big, count: 4)
        out.append(type.rawValue)
        return out
    }

    static func parse(header: Data) -> (type: FrameType, length: Int)? {
        let bytes = [UInt8](header)
        guard bytes.count == 5, let type = FrameType(rawValue: bytes[4]) else { return nil }
        let length = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        return length <= maximumPayload ? (type, length) : nil
    }

    /// A preview frame: when it was captured (phone clock, 8 bytes), then the JPEG.
    static func preview(_ jpeg: Data, captured: Double) -> Data {
        var bits = captured.bitPattern.bigEndian
        var out = Data(bytes: &bits, count: 8)
        out.append(jpeg)
        return out
    }

    static func parsePreview(_ payload: Data) -> (captured: Double, jpeg: Data)? {
        guard payload.count > 8 else { return nil }
        let bits = payload.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (Double(bitPattern: bits), Data(payload.dropFirst(8)))
    }

    static func chunk(_ header: ChunkHeader, _ bytes: Data) throws -> Data {
        let json = try Coding.encoder.encode(header)
        var big = UInt32(json.count).bigEndian
        var out = Data(bytes: &big, count: 4)
        out.append(json)
        out.append(bytes)
        return out
    }

    static func parseChunk(_ payload: Data) -> (ChunkHeader, Data)? {
        guard payload.count >= 4 else { return nil }
        let start = payload.startIndex
        let length = payload[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, payload.count >= 4 + length,
              let header = try? Coding.decoder.decode(ChunkHeader.self, from: payload[start + 4..<start + 4 + length])
        else { return nil }
        return (header, Data(payload[(start + 4 + length)...]))
    }
}

/// One connection that sends and receives whole frames. All callbacks arrive on `queue`.
final class FramedLink {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    var onReady: (() -> Void)?
    var onFrame: ((FrameType, Data) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var lastReceived = Date()

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.onReady?()
                self.receiveHeader()
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close(nil)
            // A refused TLS key shows up here and would otherwise retry for ever.
            case .waiting(let error): if case .tls = error { self.close(error.localizedDescription) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onFrame = nil
        onReady = nil
        handler?(reason)
    }

    func send(_ type: FrameType, _ payload: Data, then: ((Bool) -> Void)? = nil) {
        guard !closed else { then?(false); return }
        var frame = Framing.header(type: type, length: payload.count)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error.localizedDescription) }
            then?(error == nil)
        })
    }

    func send<T: Encodable>(message: T, then: ((Bool) -> Void)? = nil) {
        guard let data = try? Coding.encoder.encode(message) else { then?(false); return }
        send(.message, data, then: then)
    }

    private func receiveHeader() {
        receive(exactly: 5) { [weak self] header in
            guard let self else { return }
            guard let (type, length) = Framing.parse(header: header) else { self.close("bad frame"); return }
            if length == 0 {
                self.onFrame?(type, Data())
                self.receiveHeader()
                return
            }
            self.receive(exactly: length) { [weak self] payload in
                self?.onFrame?(type, payload)
                self?.receiveHeader()
            }
        }
    }

    private func receive(exactly count: Int, then: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, finished, error in
            guard let self, !self.closed else { return }
            if let data, data.count == count {
                self.lastReceived = Date()
                then(data)
            } else if let error {
                self.close(error.localizedDescription)
            } else if finished {
                self.close(nil)
            } else {
                self.close("short read")
            }
        }
    }
}

/// How connections are secured. Everything after pairing is TLS with the 256-bit key made while pairing:
/// a connection without that key cannot get through the handshake, so there is no open control port.
enum LinkParameters {
    private static func tcp() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        options.keepaliveIdle = 5
        options.keepaliveInterval = 2
        options.keepaliveCount = 3
        options.connectionTimeout = 8
        return options
    }

    static func secure(_ records: [PairRecord], peerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for record in records {
            let key = record.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(record.id.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: tcp())
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }

    /// Only for pairing: public keys travel here, and nothing secret or controllable.
    static func pairing(peerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: tcp())
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }
}
