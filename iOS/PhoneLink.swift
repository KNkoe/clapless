import Foundation
import Network

/// The phone's side of the network: it advertises itself, lets only paired Macs in, and while the
/// person is pairing, runs the code-comparison exchange with one new Mac at a time.
final class PhoneLink {
    private let queue = DispatchQueue(label: "clapless.phone.link")
    private let name: String
    private let takes: URL

    private var listener: NWListener?
    private var pairListener: NWListener?
    private var control: FramedLink?
    private var pending: [ObjectIdentifier: FramedLink] = [:]   // connected, role not yet told
    private var bulk: [ObjectIdentifier: FramedLink] = [:]
    private var pairLink: FramedLink?
    private var pairing: PairingSession?
    private var previewsUnseen: [Date] = []     // sent, and not yet confirmed by the Mac
    private var heartbeat: DispatchSourceTimer?

    // Called on the main queue.
    var onMac: ((String?) -> Void)?
    var onCommand: ((MacMessage) -> Void)?
    var onPairing: ((PairingSession.Phase?) -> Void)?
    var onProblem: ((String) -> Void)?
    var onSent: ((String, Int) -> Void)?     // a whole segment of a take has left for the Mac

    init(name: String, takes: URL) {
        self.name = name
        self.takes = takes
    }

    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    // MARK: - Paired connections

    func restart() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            dropAll()
            let records = PairStore.load()
            guard !records.isEmpty else { return }
            do {
                let new = try NWListener(using: LinkParameters.secure(records, peerToPeer: true))
                new.service = NWListener.Service(name: name, type: Clapless.service)
                new.newConnectionHandler = { [weak self] in self?.accept($0) }
                new.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        self?.main { self?.onProblem?("Network: \(error.localizedDescription)") }
                    }
                }
                new.start(queue: queue)
                listener = new
            } catch {
                main { self.onProblem?("Network: \(error.localizedDescription)") }
            }
            startHeartbeat()
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            endPairing(report: false)
            dropAll()
        }
    }

    private func dropAll() {
        heartbeat?.cancel()
        heartbeat = nil
        control?.close()
        control = nil
        pending.values.forEach { $0.close() }
        bulk.values.forEach { $0.close() }
        pending = [:]
        bulk = [:]
    }

    /// The Mac pings every second. A link that has gone quiet is dead, whatever TCP still thinks.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            if let control = self?.control, Date().timeIntervalSince(control.lastReceived) > 7 {
                control.close("quiet")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func accept(_ connection: NWConnection) {
        guard pending.count + bulk.count < 6 else { return connection.cancel() }
        let link = FramedLink(connection, queue: queue)
        let key = ObjectIdentifier(link)
        pending[key] = link
        link.onFrame = { [weak self, weak link] type, data in
            guard let self, let link, type == .message,
                  let message = try? Coding.decoder.decode(MacMessage.self, from: data) else { return }
            self.handle(message, from: link)
        }
        link.onClose = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.pending[key] = nil
            self.bulk[key] = nil
            if self.control === link {
                self.control = nil
                self.previewsUnseen = []
                self.main { self.onMac?(nil) }
            }
        }
        link.start()
    }

    private func handle(_ message: MacMessage, from link: FramedLink) {
        let key = ObjectIdentifier(link)
        if case .hello(let macName, let version, let role) = message {
            guard version == Clapless.version else {
                link.send(message: PhoneMessage.refused("The Mac and iPhone apps are different versions. Reinstall both."))
                return
            }
            pending[key] = nil
            if role == .control {
                let old = control
                control = link
                previewsUnseen = []
                old?.close("replaced")
                link.send(message: PhoneMessage.hello(name: name, version: Clapless.version))
                main { self.onMac?(macName) }
            } else {
                bulk[key] = link
            }
            return
        }
        guard pending[key] == nil else { return }   // nothing counts before hello
        if link === control {
            if case .ping(let id, let sent) = message {
                let received = HostClock.now
                link.send(message: PhoneMessage.pong(id: id, sent: sent, received: received, replied: HostClock.now))
                return
            }
            if case .previewShown = message {
                if !previewsUnseen.isEmpty { previewsUnseen.removeFirst() }
                return
            }
            main { self.onCommand?(message) }
        } else {
            serve(message, on: link)
        }
    }

    func send(_ message: PhoneMessage) {
        queue.async { self.control?.send(message: message) }
    }

    /// Preview frames are dropped, never queued: a new one goes only when the Mac has the last ones,
    /// so a slow network lowers the frame rate instead of building up delay.
    func sendPreview(_ jpeg: Data, captured: Double) {
        queue.async { [self] in
            guard let control else { return }
            previewsUnseen.removeAll { Date().timeIntervalSince($0) > 1 }     // a lost confirmation
            guard previewsUnseen.count < 2 else { return }
            previewsUnseen.append(Date())
            control.send(.preview, Framing.preview(jpeg, captured: captured))
        }
    }

    // MARK: - Files

    private static let chunkSize = 256 * 1024

    private func serve(_ message: MacMessage, on link: FramedLink) {
        switch message {
        case .fetch(let takeID, let index):
            guard isSafeTakeID(takeID) else { return link.close("bad take name") }
            let directory = TakeDirectory(url: takes.appendingPathComponent(takeID))
            guard let manifest = directory.readManifest(),
                  let segment = manifest.segments.first(where: { $0.index == index }),
                  let data = try? Data(contentsOf: directory.segmentURL(index), options: .mappedIfSafe),
                  data.count == segment.bytes
            else {
                link.send(message: PhoneMessage.refused("The iPhone no longer has part \(index) of \(takeID)."))
                return
            }
            stream(ChunkHeader(takeID: takeID, index: index, offset: 0, total: data.count), data, on: link)
        case .speedTest(let bytes):
            let total = min(max(bytes, 1), 512 << 20)
            let block = PairingSession.randomBytes(Self.chunkSize)
            speed(sent: 0, total: total, block: block, on: link)
        default:
            break
        }
    }

    private func stream(_ header: ChunkHeader, _ data: Data, on link: FramedLink) {
        guard header.offset < data.count else {
            return main { self.onSent?(header.takeID, header.index) }
        }
        let end = min(header.offset + Self.chunkSize, data.count)
        let piece = data.subdata(in: header.offset..<end)
        guard let payload = try? Framing.chunk(header, piece) else { return }
        link.send(.chunk, payload) { [weak self, weak link] sent in
            guard sent, let self, let link else { return }
            var next = header
            next.offset = end
            self.queue.async { self.stream(next, data, on: link) }
        }
    }

    private func speed(sent: Int, total: Int, block: Data, on link: FramedLink) {
        guard sent < total else { return }
        let piece = block.prefix(total - sent)
        let header = ChunkHeader(takeID: "", index: -1, offset: sent, total: total)
        guard let payload = try? Framing.chunk(header, Data(piece)) else { return }
        link.send(.chunk, payload) { [weak self, weak link] ok in
            guard ok, let self, let link else { return }
            self.queue.async { self.speed(sent: sent + piece.count, total: total, block: block, on: link) }
        }
    }

    // MARK: - Pairing

    /// Open the door for one new Mac, for two minutes.
    func startPairing() {
        queue.async { [self] in
            endPairing(report: false)
            do {
                let new = try NWListener(using: LinkParameters.pairing(peerToPeer: true))
                new.service = NWListener.Service(name: name, type: Clapless.pairService)
                new.newConnectionHandler = { [weak self] in self?.acceptPairing($0) }
                new.start(queue: queue)
                pairListener = new
                main { self.onPairing?(.exchanging) }
                queue.asyncAfter(deadline: .now() + 120) { [weak self, weak new] in
                    guard let self, let new, self.pairListener === new else { return }
                    self.finishPairing(.failed("Pairing timed out. Tap Pair again."))
                }
            } catch {
                main { self.onPairing?(.failed(error.localizedDescription)) }
            }
        }
    }

    private func acceptPairing(_ connection: NWConnection) {
        guard pairLink == nil else { return connection.cancel() }
        let link = FramedLink(connection, queue: queue)
        let session = PairingSession(role: .phone, name: name) { [weak link] in link?.send(message: $0) }
        session.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .done, .failed: self.finishPairing(phase)
            default: self.main { self.onPairing?(phase) }
            }
        }
        link.onFrame = { [weak session] type, data in
            guard type == .message, data.count < 4096,
                  let message = try? Coding.decoder.decode(PairMessage.self, from: data) else { return }
            session?.receive(message)
        }
        link.onClose = { [weak self, weak session] _ in
            guard let self, let session, self.pairing === session else { return }
            self.finishPairing(.failed("The Mac disconnected. Tap Pair again."))
        }
        pairLink = link
        pairing = session
        link.start()
    }

    func confirmPairing() { queue.async { self.pairing?.confirm() } }

    func cancelPairing() {
        queue.async { [self] in
            pairing?.cancel("Cancelled on the iPhone.")
            endPairing(report: true)
        }
    }

    private func finishPairing(_ phase: PairingSession.Phase) {
        if case .done(let record) = phase {
            // One Mac at a time: pairing a new one replaces the old.
            guard PairStore.save([record]) else {
                main { self.onPairing?(.failed("Could not save the pairing on the iPhone.")) }
                return endPairing(report: false)
            }
        }
        let link = pairLink
        pairing = nil
        pairLink = nil
        pairListener?.cancel()
        pairListener = nil
        // Leave a moment for the last message to leave before closing.
        queue.asyncAfter(deadline: .now() + 0.6) { link?.close() }
        main { self.onPairing?(phase) }
        if case .done = phase { restart() }
    }

    private func endPairing(report: Bool) {
        let link = pairLink
        pairing = nil
        pairLink = nil
        pairListener?.cancel()
        pairListener = nil
        queue.asyncAfter(deadline: .now() + 0.3) { link?.close() }
        if report { main { self.onPairing?(nil) } }
    }
}
