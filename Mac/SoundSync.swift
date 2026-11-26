import Foundation

/// Lines a take's camera up with its Mac microphone by sound, using the editing skill's own script
/// so the app and the editor can never disagree. Everything runs on this Mac.
final class SoundSync: @unchecked Sendable {
    private let library: TakeLibrary
    private let queue = DispatchQueue(label: "clapless.sync", qos: .utility)
    private var waiting: Set<String> = []

    init(library: TakeLibrary) {
        self.library = library
    }

    /// Match every finished take that has not been tried yet.
    func catchUp(_ takes: [TakeRecord]) {
        for take in takes where take.status == .ready && take.camera != nil && take.mic != nil
            && take.sync?.tried != true {
            run(take.take, again: false)
        }
    }

    func run(_ id: String, again: Bool = true) {
        queue.async { [self] in
            guard !waiting.contains(id) else { return }
            waiting.insert(id)
            queue.async { [self] in
                defer { waiting.remove(id) }
                if again || library.record(id)?.sync?.tried != true { match(id) }
            }
        }
    }

    private func match(_ id: String) {
        guard let take = library.record(id), let camera = take.camera, let mic = take.mic else { return }
        let folder = library.folder(id)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".claude/skills/panel-reel/scripts/sync_camera.py").resolvingSymlinksInPath()
        let tools = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        guard FileManager.default.fileExists(atPath: script.path),
              let uv = tools.map({ $0 + "/uv" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return save(id, failed: "Sound matching needs the panel-reel skill and uv on this Mac")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", "--no-project", "--with", "numpy", "python", "-I", script.path,
                             folder.appendingPathComponent(camera.file).path, folder.appendingPathComponent(mic.file).path]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (tools + ["/usr/bin", "/bin"]).joined(separator: ":")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return save(id, failed: "Sound matching could not start: \(error.localizedDescription)")
        }
        let limit = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: limit)
        // Both pipes are drained while it runs, so neither can fill up and stall it.
        var complaint = Data()
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) { complaint = errors.fileHandleForReading.readDataToEndOfFile() }
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        limit.cancel()
        guard process.terminationStatus == 0, let found = try? JSONDecoder().decode(Match.self, from: answer) else {
            let last = String(decoding: complaint, as: UTF8.self).split(separator: "\n").last.map(String.init)
            return save(id, failed: last ?? "Sound matching failed")
        }
        library.update(id) { record in
            var sync = record.sync ?? TakeRecord.Sync()
            sync.method = "sound"
            sync.tried = true
            sync.matchedBySound = true
            sync.videoOffset = found.video_offset
            sync.videoDrift = found.video_drift
            sync.matchedPoints = found.matched_points
            sync.points = found.points
            sync.worstMs = found.worst_ms
            sync.driftMeasured = found.drift_measured
            sync.weak = found.weak
            sync.note = found.weak ? "The sound match is weak: check lip sync before relying on it" : nil
            record.sync = sync
        }
    }

    private struct Match: Decodable {
        var video_offset: Double
        var video_drift: Double
        var matched_points: Int
        var points: Int
        var worst_ms: Double
        var drift_measured: Bool
        var weak: Bool
    }

    private func save(_ id: String, failed why: String) {
        library.update(id) { record in
            var sync = record.sync ?? TakeRecord.Sync()
            sync.tried = true
            sync.matchedBySound = false
            sync.note = why
            record.sync = sync
        }
    }
}
