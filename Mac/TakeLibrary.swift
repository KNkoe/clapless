import Foundation

/// The take folders under ~/Movies/Clapless. Safe to use from any queue.
final class TakeLibrary: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var records: [String: TakeRecord] = [:]

    /// Called on the main queue with every take, newest first.
    var onChange: (([TakeRecord]) -> Void)?

    init(root: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clapless")) {
        self.root = root
    }

    func folder(_ take: String) -> URL { root.appendingPathComponent(take) }
    /// Pieces of the camera file while they are on their way.
    func incoming(_ take: String) -> TakeDirectory { TakeDirectory(url: folder(take).appendingPathComponent(".incoming")) }

    func load() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        lock.withLock {
            for folder in folders {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("take.json")),
                      let record = try? Coding.decoder.decode(TakeRecord.self, from: data),
                      record.take == folder.lastPathComponent else { continue }
                records[record.take] = record
            }
        }
        // A take still marked as recording was cut off: the app quit or the Mac stopped.
        for record in all() where record.status == .recording {
            update(record.take) {
                $0.status = .transferring
                $0.warn("Clapless on the Mac closed during this take")
            }
        }
        publish()
    }

    func all() -> [TakeRecord] {
        lock.withLock { records.values.sorted { $0.created > $1.created } }
    }

    func record(_ take: String) -> TakeRecord? {
        lock.withLock { records[take] }
    }

    @discardableResult
    func create(_ take: String, created: Date, status: TakeRecord.Status) throws -> TakeRecord {
        try FileManager.default.createDirectory(at: folder(take), withIntermediateDirectories: true)
        let record = TakeRecord(take: take, created: created, status: status)
        try lock.withLock {
            try write(record)
            records[take] = record
        }
        publish()
        return record
    }

    func update(_ take: String, _ change: (inout TakeRecord) -> Void) {
        lock.withLock {
            guard var record = records[take] else { return }
            change(&record)
            records[take] = record
            do { try write(record) } catch { NSLog("Clapless: could not save take.json for \(take): \(error)") }
        }
        publish()
    }

    private func write(_ record: TakeRecord) throws {
        try TakeRecord.encoder.encode(record)
            .write(to: folder(record.take).appendingPathComponent("take.json"), options: .atomic)
    }

    private func publish() {
        let list = all()
        DispatchQueue.main.async { self.onChange?(list) }
    }
}
