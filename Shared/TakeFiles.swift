import CryptoKit
import Foundation

enum TakeFileError: Error, LocalizedError, Equatable {
    case badChunk(String)
    case badSegment(Int)
    case incomplete
    case badTotal

    var errorDescription: String? {
        switch self {
        case .badChunk(let why): return "A piece of the take arrived wrong: \(why)"
        case .badSegment(let i): return "Segment \(i) does not match its checksum"
        case .incomplete: return "The take is not complete yet"
        case .badTotal: return "The joined take does not match the phone's checksum"
        }
    }
}

/// SHA-256 built up a segment at a time.
struct RunningHash {
    private var hash = SHA256()
    mutating func add(_ data: Data) { hash.update(data: data) }
    var hex: String { Data(hash.finalize()).hex }
}

enum Hashing {
    static func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }

    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hash.update(data: piece) }
        return Data(hash.finalize()).hex
    }
}

/// A take on disk: numbered segments plus manifest.json. The phone writes one while it records;
/// the Mac rebuilds the same one from what it downloads, and can carry on after any interruption.
struct TakeDirectory {
    let url: URL

    var manifestURL: URL { url.appendingPathComponent("manifest.json") }
    func segmentURL(_ index: Int) -> URL { url.appendingPathComponent(String(format: "segment-%05d.m4s", index)) }
    func partialURL(_ index: Int) -> URL { segmentURL(index).appendingPathExtension("partial") }

    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func readManifest() -> TakeManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? Coding.decoder.decode(TakeManifest.self, from: data)
    }

    func write(_ manifest: TakeManifest) throws {
        try Coding.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    /// Phone side: keep a segment the moment the encoder hands it over.
    func store(segment data: Data, index: Int) throws -> SegmentInfo {
        try data.write(to: segmentURL(index), options: .atomic)
        return SegmentInfo(index: index, bytes: data.count, sha256: Hashing.sha256(data))
    }

    /// True when this segment is on disk with the right size and checksum.
    func holds(_ segment: SegmentInfo) -> Bool {
        let file = segmentURL(segment.index)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        guard size == segment.bytes else { return false }
        return (try? Hashing.sha256(file: file)) == segment.sha256
    }

    /// Mac side: append one downloaded piece. Returns true once the whole segment is here and checks out.
    func append(_ header: ChunkHeader, _ bytes: Data, expecting segment: SegmentInfo) throws -> Bool {
        guard header.index == segment.index, header.total == segment.bytes else {
            throw TakeFileError.badChunk("it is for a different segment")
        }
        let partial = partialURL(segment.index)
        if header.offset == 0 { try Data().write(to: partial) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let have = try handle.seekToEnd()
        guard have == UInt64(header.offset), header.offset + bytes.count <= segment.bytes else {
            throw TakeFileError.badChunk("it is out of order")
        }
        try handle.write(contentsOf: bytes)
        guard header.offset + bytes.count == segment.bytes else { return false }
        try handle.synchronize()
        guard try Hashing.sha256(file: partial) == segment.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw TakeFileError.badSegment(segment.index)
        }
        if FileManager.default.fileExists(atPath: segmentURL(segment.index).path) {
            try FileManager.default.removeItem(at: segmentURL(segment.index))
        }
        try FileManager.default.moveItem(at: partial, to: segmentURL(segment.index))
        return true
    }

    /// Phone side, after the app was cut off mid-take: close the take around the segments that
    /// reached the disk whole, so it can still be sent. Returns nil when there is nothing to save.
    func salvage() -> TakeManifest? {
        guard var manifest = readManifest(), !manifest.complete else { return nil }
        var kept: [SegmentInfo] = []
        var hash = RunningHash()
        for segment in manifest.segments {
            guard segment.index == kept.count, holds(segment),
                  let data = try? Data(contentsOf: segmentURL(segment.index)) else { break }
            kept.append(segment)
            hash.add(data)
        }
        guard kept.count >= 2 else { return nil }     // the first is only the header
        manifest.segments = kept
        manifest.sha256 = hash.hex
        manifest.complete = true
        manifest.endReason = manifest.endReason ?? "Clapless closed during the take; the end may be missing"
        manifest.seconds = min(manifest.seconds, Double(kept.count - 1) * TakeRecorder.segmentSeconds)
        manifest.frames = min(manifest.frames, Int((manifest.seconds * Double(manifest.camera.fps)).rounded()))
        guard (try? write(manifest)) != nil else { return nil }
        return manifest
    }

    /// Join the segments in order into one file and check it against the phone's checksum of the whole take.
    func join(_ manifest: TakeManifest, to output: URL) throws {
        guard manifest.complete, let expected = manifest.sha256,
              manifest.segments.map(\.index) == Array(0..<manifest.segments.count), !manifest.segments.isEmpty
        else { throw TakeFileError.incomplete }
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        var hash = SHA256()
        do {
            for segment in manifest.segments {
                let data = try Data(contentsOf: segmentURL(segment.index))
                guard data.count == segment.bytes, Hashing.sha256(data) == segment.sha256 else {
                    throw TakeFileError.badSegment(segment.index)
                }
                hash.update(data: data)
                try handle.write(contentsOf: data)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard Data(hash.finalize()).hex == expected, try Hashing.sha256(file: output) == expected else {
            throw TakeFileError.badTotal
        }
    }
}
