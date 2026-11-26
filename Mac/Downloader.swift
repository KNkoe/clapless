import Foundation

/// Brings takes from the iPhone, one checked piece at a time, while recording or afterwards.
/// Anything interrupted carries on from the last good piece. A take counts as done only when the
/// whole of it matches the phone's checksum and `camera.mov` has been written and counted.
final class Downloader: @unchecked Sendable {
    struct Progress: Equatable {
        var received: Int
        var listed: Int            // bytes the phone has made so far
        var recording: Bool        // the phone is still adding to it
        var checking: Bool
        var bytesPerSecond: Double
        var problem: String?
    }

    private struct Job {
        var manifest: TakeManifest
        var held: Set<Int> = []
        var looked: Set<Int> = []  // segments already checked on disk
        var failures = 0
        var problem: String?
    }

    private let library: TakeLibrary
    private let client: PhoneClient
    private let queue = DispatchQueue(label: "clapless.mac.download")
    private var jobs: [String: Job] = [:]
    private var link: FramedLink?
    private var linkQueue: DispatchQueue?    // a link is only touched on its own queue
    private var opening = false
    private var linked = false
    private var asking: (take: String, segment: SegmentInfo)?
    private var assembling: String?
    private var lastData = Date()
    private var retryAfter = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var arrivals: [(at: Date, bytes: Int)] = []     // the last few seconds, for the speed shown
    private var partial: (take: String, bytes: Int)?
    private var reportedAt = Date.distantPast

    // Called on the main queue.
    var onProgress: ((String, Progress?) -> Void)?

    init(library: TakeLibrary, client: PhoneClient) {
        self.library = library
        self.client = client
    }

    /// Pick up transfers that were unfinished when the app last closed.
    func start() {
        queue.async { [self] in
            for record in library.all() where record.camera == nil {
                if let manifest = library.incoming(record.take).readManifest() { accept(manifest) }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.beat() }
            timer.resume()
            self.timer = timer
        }
    }

    func linkChanged(_ up: Bool) {
        queue.async { [self] in
            linked = up
            if up { retryAfter = .distantPast } else { drop() }
            next()
        }
    }

    func offer(_ manifest: TakeManifest) {
        queue.async { [self] in
            accept(manifest)
            next()
        }
    }

    /// The phone says it cannot supply something that was asked for.
    private func refused(_ why: String) {
        guard let asked = asking else { return }
        fail(asked.take, why)
    }

    private func accept(_ manifest: TakeManifest) {
        let take = manifest.takeID
        guard isSafeTakeID(take) else { return }
        if let camera = library.record(take)?.camera {
            // Already here. Tell the phone again in case the message was lost.
            if let sha = manifest.sha256, sha == camera.phoneSha256 {
                client.send(.takeVerified(takeID: take, sha256: sha))
            }
            return
        }
        do {
            if library.record(take) == nil {
                try library.create(take, created: manifest.created, status: .transferring)
            }
            let directory = library.incoming(take)
            try directory.create()
            if let old = jobs[take]?.manifest, old.segments.count > manifest.segments.count { return }
            try directory.write(manifest)
        } catch {
            report(take, problem: "Could not save on the Mac: \(error.localizedDescription)")
            return
        }
        var job = jobs[take] ?? Job(manifest: manifest)
        job.manifest = manifest
        for segment in manifest.segments where !job.looked.contains(segment.index) {
            job.looked.insert(segment.index)
            if library.incoming(take).holds(segment) { job.held.insert(segment.index) }
        }
        jobs[take] = job
        report(take)
    }

    private func beat() {
        if asking != nil, Date().timeIntervalSince(lastData) > 12 { drop() }
        next()
    }

    private func drop() {
        asking = nil
        partial = nil
        opening = false
        let old = link, oldQueue = linkQueue
        link = nil
        oldQueue?.async { old?.close() }
        retryAfter = Date().addingTimeInterval(1)
    }

    private func next() {
        guard asking == nil else { return }
        let waiting = jobs.values.filter { $0.problem == nil }.sorted { $0.manifest.created < $1.manifest.created }
        if assembling == nil, let job = waiting.first(where: {
            $0.manifest.complete && $0.held.count == $0.manifest.segments.count
        }) {
            assemble(job.manifest)
        }
        // The phone gave up on a take: say so rather than wait for ever.
        for job in waiting where !job.manifest.complete && job.manifest.endReason != nil
            && job.held.count == job.manifest.segments.count {
            fail(job.manifest.takeID, "the iPhone could not finish it (\(job.manifest.endReason ?? ""))")
        }
        guard linked, Date() >= retryAfter else { return }
        for job in waiting {
            guard let segment = job.manifest.segments.first(where: { !job.held.contains($0.index) }) else { continue }
            if let free = freeBytes(), free < Int64(segment.bytes) + 500_000_000 {
                report(job.manifest.takeID, problem: "The Mac is nearly full")
                return
            }
            guard let link, let linkQueue else { return open() }
            asking = (job.manifest.takeID, segment)
            lastData = Date()
            let request = MacMessage.fetch(takeID: job.manifest.takeID, index: segment.index)
            linkQueue.async { link.send(message: request) }
            return
        }
    }

    private func open() {
        guard !opening else { return }
        opening = true
        client.openBulk { [weak self] new, linkQueue in
            guard let self else { return }
            if let new {
                // Both are set here, on the link's own queue, before any frame can arrive.
                new.onFrame = { [weak self, weak new] type, data in
                    self?.queue.async { self?.receive(type, data, from: new) }
                }
                new.onClose = { [weak self, weak new] _ in
                    self?.queue.async {
                        guard let self, self.link === new else { return }
                        self.link = nil
                        self.drop()
                    }
                }
            }
            self.queue.async {
                guard self.opening else {
                    if let new { linkQueue.async { new.close() } }
                    return
                }
                self.opening = false
                if let new {
                    self.link = new
                    self.linkQueue = linkQueue
                    self.next()
                } else {
                    self.retryAfter = Date().addingTimeInterval(2)
                }
            }
        }
    }

    private func receive(_ type: FrameType, _ data: Data, from source: FramedLink?) {
        guard source === link, let asked = asking else { return }
        lastData = Date()
        if type == .message, case .refused(let why) = try? Coding.decoder.decode(PhoneMessage.self, from: data) {
            return refused(why)
        }
        guard type == .chunk, let (header, bytes) = Framing.parseChunk(data), header.takeID == asked.take else { return }
        arrivals.append((Date(), bytes.count))
        do {
            guard try library.incoming(asked.take).append(header, bytes, expecting: asked.segment) else {
                partial = (asked.take, header.offset + bytes.count)
                if Date().timeIntervalSince(reportedAt) > 0.2 { report(asked.take) }
                return
            }
            partial = nil
            jobs[asked.take]?.held.insert(asked.segment.index)
            jobs[asked.take]?.failures = 0
            asking = nil
            report(asked.take)
            next()
        } catch {
            jobs[asked.take]?.failures += 1
            if jobs[asked.take]?.failures ?? 0 >= 4 { fail(asked.take, error.localizedDescription) }
            drop()
        }
    }

    private func fail(_ take: String, _ why: String) {
        jobs[take]?.problem = why
        asking = nil
        library.update(take) {
            $0.status = .failed
            $0.warn("Transfer failed: \(why). The iPhone still has its copy.")
        }
        report(take)
    }

    private func assemble(_ manifest: TakeManifest) {
        let take = manifest.takeID
        assembling = take
        report(take)
        let directory = library.incoming(take)
        let folder = library.folder(take)
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let joined = directory.url.appendingPathComponent("joined.mp4")
                try directory.join(manifest, to: joined)
                let movie = folder.appendingPathComponent("camera.mov")
                let seconds: Double
                if FileManager.default.fileExists(atPath: movie.path) {
                    // Written before an interruption: it only ever gets this name after being checked.
                    let expected = try await CameraFile.sampleCount(joined)
                    let found = try await CameraFile.sampleCount(movie)
                    guard expected == found else { throw CameraFile.Problem.samplesDiffer(expected, found) }
                    seconds = manifest.seconds
                } else {
                    seconds = try await CameraFile.make(from: joined, to: movie,
                                                        audioOffset: manifest.audioStartOffset).seconds
                }
                let bytes = try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int ?? 0
                let entry = TakeRecord.Camera(
                    file: "camera.mov", bytes: bytes, sha256: try Hashing.sha256(file: movie),
                    phoneSha256: manifest.sha256 ?? "", seconds: seconds, frames: manifest.frames,
                    droppedFrames: manifest.droppedFrames, firstFrameHostTime: manifest.firstFrameHostTime,
                    audioStartOffset: manifest.audioStartOffset, endReason: manifest.endReason, settings: manifest.camera)
                library.update(take) {
                    $0.camera = entry
                    if let reason = manifest.endReason { $0.warn("The iPhone ended the take: \(reason)") }
                    if manifest.droppedFrames > 0 { $0.warn("\(manifest.droppedFrames) camera frames were dropped") }
                    if let note = manifest.camera.note { $0.warn("Camera: \(note)") }
                    // While the Mac is still saving its microphone, that step finishes the take instead.
                    if $0.status != .recording {   // a take marked failed earlier is put right here too
                        $0.status = .transferring
                        $0.settle()
                    }
                    $0.estimateSync()
                }
                // These are this app's own working pieces; the iPhone keeps its original.
                try? FileManager.default.removeItem(at: directory.url)
                queue.async { [self] in
                    jobs[take] = nil
                    assembling = nil
                    client.send(.takeVerified(takeID: take, sha256: manifest.sha256 ?? ""))
                    report(take)
                    next()
                }
            } catch {
                queue.async { [self] in
                    assembling = nil
                    fail(take, error.localizedDescription)
                }
            }
        }
    }

    private func speed() -> Double {
        let now = Date()
        arrivals.removeAll { now.timeIntervalSince($0.at) > 3 }
        guard let first = arrivals.first else { return 0 }
        return Double(arrivals.reduce(0) { $0 + $1.bytes }) / max(1, now.timeIntervalSince(first.at))
    }

    private func report(_ take: String, problem: String? = nil) {
        reportedAt = Date()
        var progress: Progress?
        if let job = jobs[take] {
            let whole = job.manifest.segments.filter { job.held.contains($0.index) }.reduce(0) { $0 + $1.bytes }
            progress = Progress(
                received: whole + (partial?.take == take ? partial!.bytes : 0),
                listed: job.manifest.totalBytes, recording: !job.manifest.complete, checking: assembling == take,
                bytesPerSecond: speed(), problem: problem ?? job.problem)
        }
        DispatchQueue.main.async { self.onProgress?(take, progress) }
    }

    private func freeBytes() -> Int64? {
        let values = try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// How fast the iPhone can really send to this Mac, over the same encrypted link takes use.
final class SpeedTest: @unchecked Sendable {
    private var received = 0
    private var started: Date?
    private var link: FramedLink?
    private var done = false

    func run(client: PhoneClient, megabytes: Int, completion: @escaping (Result<Double, Error>) -> Void) {
        let total = megabytes << 20
        client.openBulk { [self] link, queue in
            func finish(_ result: Result<Double, Error>) {
                guard !done else { return }
                done = true
                self.link?.close()
                self.link = nil
                DispatchQueue.main.async { completion(result) }
            }
            guard let link else { return finish(.failure(RecorderError("No link to the iPhone."))) }
            self.link = link
            link.onClose = { _ in finish(.failure(RecorderError("The link closed during the test."))) }
            link.onFrame = { [self] type, data in
                guard type == .chunk, let (_, bytes) = Framing.parseChunk(data) else { return }
                if started == nil { started = Date() }
                received += bytes.count
                if received >= total, let started {
                    finish(.success(Double(received) * 8 / 1_000_000 / max(0.001, -started.timeIntervalSinceNow)))
                }
            }
            link.send(message: MacMessage.speedTest(bytes: total))
            queue.asyncAfter(deadline: .now() + 90) { finish(.failure(RecorderError("The test took too long."))) }
        }
    }
}
