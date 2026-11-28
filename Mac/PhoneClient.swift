import Foundation
import Network

struct FoundPhone: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let endpoint: NWEndpoint
}

/// The Mac's side of the network: finds the paired iPhone with Bonjour, keeps one encrypted
/// control link to it (reconnecting by itself), and runs pairing.
final class PhoneClient {
    struct Quality: Equatable {
        var roundTripMs: Double
        var clockOffset: Double      // phone clock minus Mac clock, from the quickest recent ping
        var clockRoundTripMs: Double
    }

    private let queue = DispatchQueue(label: "clapless.mac.link")
    private let name = Host.current().localizedName ?? "Mac"
    static var directLinkWanted: Bool { UserDefaults.standard.object(forKey: "directLink") as? Bool ?? true }
    private var peerToPeer = PhoneClient.directLinkWanted
    private var tryDirect = true       // after a direct attempt fails, one goes through the router

    private var browser: NWBrowser?
    private var pairBrowser: NWBrowser?
    private var found: [NWBrowser.Result] = []
    private var record: PairRecord? = PairStore.load().first
    private var control: FramedLink?
    private var linked = false
    private var held = false           // disconnected on purpose: do not reconnect
    private var endpoint: NWEndpoint?
    private var attempt = 0
    private var pinger: DispatchSourceTimer?
    private var pingID = 0
    private var samples: [(rtt: Double, offset: Double)] = []
    private var pairLink: FramedLink?
    private var pairing: PairingSession?
    private var opening: [ObjectIdentifier: FramedLink] = [:]   // keeps a new file link alive until it connects

    // All called on the main queue.
    var onLink: ((Bool) -> Void)?
    var onMessage: ((PhoneMessage) -> Void)?
    var onPreview: ((Data, Double?) -> Void)?       // the picture, and how many seconds old it is
    var onQuality: ((Quality) -> Void)?
    var onPairingCandidates: (([FoundPhone]) -> Void)?
    var onPairing: ((PairingSession.Phase?) -> Void)?
    var onPaired: ((String?) -> Void)?
    var onProblem: ((String?) -> Void)?
    var onRoute: ((String) -> Void)?     // which network interface carries the link

    /// With the direct link on, the two devices talk to each other without going through the router.
    private func parameters(for target: NWEndpoint) -> NWParameters {
        let parameters = LinkParameters.secure(record.map { [$0] } ?? [], peerToPeer: peerToPeer)
        if peerToPeer, tryDirect, let direct = found.first(where: { $0.endpoint == target })?.interfaces
            .first(where: { $0.name.hasPrefix("awdl") }) {
            parameters.requiredInterface = direct
        }
        return parameters
    }

    func setDirectLink(_ on: Bool) {
        queue.async { [self] in
            guard on != peerToPeer else { return }
            peerToPeer = on
            UserDefaults.standard.set(on, forKey: "directLink")
            browser?.cancel()
            found = []
            control?.close()
            browser = browseForPhone()
        }
    }

    private func browseForPhone() -> NWBrowser {
        browse(Clapless.service) { [weak self] results in
            self?.found = Array(results)
            self?.connectIfNeeded()
        }
    }

    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    func start() {
        queue.async { [self] in
            let paired = record?.peerName
            main { self.onPaired?(paired) }
            browser = browseForPhone()
            pairBrowser = browse(Clapless.pairService) { [weak self] results in
                let phones = results.compactMap { result -> FoundPhone? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return FoundPhone(name: name, endpoint: result.endpoint)
                }
                self?.main { self?.onPairingCandidates?(phones) }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.beat() }
            timer.resume()
            pinger = timer
        }
    }

    private func browse(_ type: String, changed: @escaping (Set<NWBrowser.Result>) -> Void) -> NWBrowser {
        let parameters = NWParameters()
        parameters.includePeerToPeer = peerToPeer
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in changed(results) }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .waiting(let error) = state {
                self.main { self.onProblem?("Allow Clapless under Local Network in System Settings (\(error)).") }
            }
        }
        browser.start(queue: queue)
        return browser
    }

    /// Once a second: ping, and give up on a link that has gone quiet.
    private func beat() {
        if let control {
            if Date().timeIntervalSince(control.lastReceived) > (linked ? 5 : 8) {
                control.close("quiet")
            } else if linked {
                pingID += 1
                control.send(message: MacMessage.ping(id: pingID, sent: HostClock.now))
            }
        } else {
            connectIfNeeded()
        }
    }

    /// Tell the iPhone this is on purpose, so it stops and closes, then stay away.
    func disconnect() {
        queue.async { [self] in
            held = true
            guard let link = control else { return }
            guard linked else { return link.close() }
            link.send(message: MacMessage.disconnect)
            // A moment for the message to leave before the connection goes.
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self, weak link] in
                if self?.held == true { link?.close("disconnected") }
            }
        }
    }

    func reconnect() {
        queue.async { [self] in
            held = false
            control?.close()     // one that has already said goodbye is no use
            tryDirect = true
            connectIfNeeded()
        }
    }

    private func connectIfNeeded() {
        guard !held, control == nil, record != nil, !found.isEmpty else { return }
        // Another iPhone with Clapless would refuse our key, so try each in turn.
        let target = found[attempt % found.count].endpoint
        attempt += 1
        let link = FramedLink(NWConnection(to: target, using: parameters(for: target)), queue: queue)
        link.onReady = { [weak self, weak link] in
            guard let self else { return }
            link?.send(message: MacMessage.hello(name: self.name, version: Clapless.version, role: .control))
        }
        link.onFrame = { [weak self] type, data in self?.receive(type, data, from: target) }
        link.onClose = { [weak self, weak link] _ in
            guard let self, self.control === link else { return }
            self.control = nil
            self.tryDirect = self.linked ? true : !self.tryDirect
            self.endpoint = nil
            self.samples = []
            if self.linked {
                self.linked = false
                self.main { self.onLink?(false) }
            }
        }
        control = link
        link.start()
    }

    private func receive(_ type: FrameType, _ data: Data, from target: NWEndpoint) {
        if type == .preview {
            guard let frame = Framing.parsePreview(data) else { return }
            control?.send(message: MacMessage.previewShown)
            let age = samples.min { $0.rtt < $1.rtt }.map { HostClock.now - (frame.captured - $0.offset) }
            main { self.onPreview?(frame.jpeg, age) }
            return
        }
        guard type == .message, let message = try? Coding.decoder.decode(PhoneMessage.self, from: data) else { return }
        switch message {
        case .hello(_, let version):
            guard version == Clapless.version else {
                main { self.onProblem?("The Mac and iPhone apps are different versions. Reinstall both.") }
                return
            }
            linked = true
            endpoint = target
            let name = Self.interfaceName(control?.connection.currentPath)
            main {
                self.onRoute?(name)
                self.onProblem?(nil)
                self.onLink?(true)
            }
        case .pong(_, let sent, let received, let replied):
            let arrived = HostClock.now
            let rtt = (arrived - sent) - (replied - received)
            let offset = ((received - sent) + (replied - arrived)) / 2
            samples.append((rtt, offset))
            if samples.count > 40 { samples.removeFirst() }
            // Only recent pings: the two clocks drift apart, so an old quick one goes stale.
            let best = samples.min { $0.rtt < $1.rtt }!
            let latest = samples.suffix(8).map(\.rtt).sorted()
            let quality = Quality(roundTripMs: latest[latest.count / 2] * 1000, clockOffset: best.offset,
                                  clockRoundTripMs: best.rtt * 1000)
            main { self.onQuality?(quality) }
        default:
            main { self.onMessage?(message) }
        }
    }

    private static func interfaceName(_ path: NWPath?) -> String {
        if case .hostPort(let host, _) = path?.localEndpoint {
            if case .ipv6(let address) = host, let found = address.interface { return found.name }
            if case .ipv4(let address) = host, let found = address.interface { return found.name }
        }
        return path?.availableInterfaces.first?.name ?? "unknown"
    }

    func send(_ message: MacMessage) {
        queue.async { if self.linked { self.control?.send(message: message) } }
    }

    /// A second encrypted link for file bytes, to the same phone.
    func openBulk(completion: @escaping (FramedLink?, DispatchQueue) -> Void) {
        queue.async { [self] in
            guard linked, record != nil, let endpoint else { return completion(nil, queue) }
            let link = FramedLink(NWConnection(to: endpoint, using: parameters(for: endpoint)), queue: queue)
            let key = ObjectIdentifier(link)
            opening[key] = link
            var delivered = false
            link.onReady = { [weak self, weak link] in
                guard let self, let link else { return }
                delivered = true
                defer { self.opening[key] = nil }
                link.send(message: MacMessage.hello(name: self.name, version: Clapless.version, role: .bulk))
                completion(link, self.queue)
            }
            link.onClose = { [weak self] _ in
                self?.opening[key] = nil
                if !delivered, let self { completion(nil, self.queue) }
            }
            link.start()
            // A phone that has just left the network would otherwise be waited for indefinitely.
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.opening[key]?.close("no answer") }
        }
    }

    // MARK: - Pairing

    func pair(with phone: FoundPhone) {
        queue.async { [self] in
            pairLink?.close()
            let link = FramedLink(NWConnection(to: phone.endpoint, using: LinkParameters.pairing(peerToPeer: peerToPeer)),
                                  queue: queue)
            let session = PairingSession(role: .mac, name: name) { [weak link] in link?.send(message: $0) }
            session.onPhase = { [weak self] phase in
                guard let self else { return }
                if case .done(let new) = phase {
                    guard PairStore.save([new]) else {
                        self.main { self.onPairing?(.failed("Could not save the pairing in the Keychain.")) }
                        return
                    }
                    self.record = new
                    self.held = false
                    self.control?.close()
                    self.main { self.onPaired?(new.peerName) }
                }
                self.main { self.onPairing?(phase) }
                if case .done = phase { self.endPairing() }
                if case .failed = phase { self.endPairing() }
            }
            link.onReady = { [weak session] in session?.start() }
            link.onFrame = { [weak session] type, data in
                guard type == .message, data.count < 4096,
                      let message = try? Coding.decoder.decode(PairMessage.self, from: data) else { return }
                session?.receive(message)
            }
            link.onClose = { [weak self, weak session] reason in
                guard let self, let session, self.pairing === session else { return }
                self.pairing = nil
                self.pairLink = nil
                self.main { self.onPairing?(.failed("The iPhone closed the pairing. \(reason ?? "")")) }
            }
            pairLink = link
            pairing = session
            main { self.onPairing?(.exchanging) }
            link.start()
        }
    }

    private func endPairing() {
        let link = pairLink
        pairing = nil
        pairLink = nil
        queue.asyncAfter(deadline: .now() + 0.5) { link?.close() }
    }

    func confirmPairing() { queue.async { self.pairing?.confirm() } }

    func cancelPairing() {
        queue.async { [self] in
            pairing?.cancel("Cancelled on the Mac.")
            main { self.onPairing?(nil) }
        }
    }

    func forget() {
        queue.async { [self] in
            PairStore.save([])
            record = nil
            control?.close()
            main { self.onPaired?(nil) }
        }
    }
}
