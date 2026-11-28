import Foundation

/// Deleting a take, on either device.
enum TakeRemoval {
    /// What the take's folder takes up, hidden working pieces included.
    static func size(of folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Remove one take folder from `root`. Only a plain take name is accepted, so nothing outside
    /// `root`, nor `root` itself, can be reached. A folder that has already gone counts as removed.
    static func remove(_ take: String, from root: URL, toTrash: Bool = false) throws {
        guard isSafeTakeID(take) else { throw RecorderError("That is not a take name.") }
        let folder = root.appendingPathComponent(take)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if toTrash {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// Takes deleted on the Mac whose copy on the iPhone has not been confirmed gone yet. It is kept on
/// disk, so a delete made while the phone is away still happens when it comes back.
struct DeletedTakes {
    let file: URL

    func all() -> Set<String> {
        guard let data = try? Data(contentsOf: file),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.filter(isSafeTakeID))
    }

    func add(_ take: String) throws { try write(all().union([take])) }
    func remove(_ take: String) throws { try write(all().subtracting([take])) }

    private func write(_ names: Set<String>) throws {
        try JSONEncoder().encode(names.sorted()).write(to: file, options: .atomic)
    }
}
