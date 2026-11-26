import Darwin
import Foundation

/// The command line's way in: a socket file only this user account can open. It is not on the network.
/// One line of JSON in (`{"cmd": "status"}`), one line of JSON out.
final class ControlSocket {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clapless")
    static var path: String { folder.appendingPathComponent("control.sock").path }

    typealias Handler = (_ command: String, _ argument: String?, _ reply: @escaping ([String: Any]) -> Void) -> Void

    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "clapless.control", attributes: .concurrent)
    private var source: DispatchSourceRead?

    /// `handler` is called on the main queue.
    func start(handler: @escaping Handler) {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.folder.path)
        } catch {
            NSLog("Clapless: no folder for the command socket: \(error)")
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(Self.path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard descriptor >= 0, bound == 0, chmod(Self.path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            NSLog("Clapless: the command socket could not be opened (\(errno))")
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(self.descriptor, nil, nil)
            if client >= 0 { self.queue.async { Self.serve(client, handler) } }
        }
        source.resume()
        self.source = source
    }

    private static func serve(_ client: Int32, _ handler: @escaping Handler) {
        var user: uid_t = 0, group: gid_t = 0
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard getpeereid(client, &user, &group) == 0, user == getuid() else {
            close(client)
            return
        }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while line.count < 4096, !line.contains(10) {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            line.append(contentsOf: buffer[0..<n])
        }
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        guard let command = request?["cmd"] as? String else {
            close(client)
            return
        }
        DispatchQueue.main.async {
            handler(command, request?["arg"] as? String) { reply in
                var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
                data.append(10)
                DispatchQueue.global().async {
                    data.withUnsafeBytes { raw in
                        var sent = 0
                        while sent < raw.count {
                            let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                            if n <= 0 { break }
                            sent += n
                        }
                    }
                    close(client)
                }
            }
        }
    }
}
