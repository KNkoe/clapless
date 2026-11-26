import CryptoKit
import Foundation
import Security

struct PairRecord: Codable, Equatable {
    var id: String       // names the key during the TLS handshake
    var key: Data        // 32 bytes, never sent over the network
    var peerName: String
    var pairedAt: Date
}

enum PairMessage: Codable, Equatable {
    case commit(name: String, commitment: Data)
    case reply(name: String, publicKey: Data, nonce: Data)
    case reveal(publicKey: Data, nonce: Data)
    case confirm(proof: Data)
    case abort(String)
}

enum PairRole: String {
    case mac, phone
}

/// Pairing by comparing a six-digit code on both screens, the way Bluetooth does it.
///
/// Each side makes a fresh key pair. The Mac first sends only a fingerprint of its key and reveals it
/// after the phone has answered, so someone in the middle cannot try keys until both codes happen to
/// match: they get one guess in a million. Nothing is saved until the person confirms on both screens
/// and each side has proved it holds the same key.
final class PairingSession {
    enum Phase: Equatable {
        case exchanging
        case compare(code: String, peer: String)
        case waitingForPeer(code: String, peer: String)
        case done(PairRecord)
        case failed(String)
    }

    let role: PairRole
    private let name: String
    private let send: (PairMessage) -> Void
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private let nonce = PairingSession.randomBytes(16)

    private var peerName = ""
    private var commitment: Data?
    private var peerPublic: Data?
    private var peerNonce: Data?
    private var secrets: (code: String, key: Data, id: String)?
    private var confirmedHere = false
    private var peerProved = false
    private var expecting: Int = 0   // enforces message order

    var onPhase: ((Phase) -> Void)?
    private(set) var phase: Phase = .exchanging {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }

    init(role: PairRole, name: String, send: @escaping (PairMessage) -> Void) {
        self.role = role
        self.name = name
        self.send = send
    }

    private var publicKey: Data { privateKey.publicKey.x963Representation }

    func start() {
        if role == .mac { send(.commit(name: name, commitment: Self.commit(publicKey, nonce))) }
    }

    func receive(_ message: PairMessage) {
        if case .failed = phase { return }
        if case .done = phase { return }
        switch (role, expecting, message) {
        case (.phone, 0, .commit(let name, let commitment)):
            peerName = String(name.prefix(60))
            self.commitment = commitment
            expecting = 1
            send(.reply(name: self.name, publicKey: publicKey, nonce: nonce))
        case (.phone, 1, .reveal(let key, let theirNonce)):
            guard Self.commit(key, theirNonce) == commitment else { return fail("The Mac changed its key. Nothing was paired.") }
            peerPublic = key
            peerNonce = theirNonce
            expecting = 2
            derive()
        case (.mac, 0, .reply(let name, let key, let theirNonce)):
            peerName = String(name.prefix(60))
            peerPublic = key
            peerNonce = theirNonce
            expecting = 2
            send(.reveal(publicKey: publicKey, nonce: nonce))
            derive()
        case (_, 2, .confirm(let proof)):
            guard let secrets, HMAC<SHA256>.isValidAuthenticationCode(
                proof, authenticating: Self.proofText(role == .mac ? .phone : .mac), using: SymmetricKey(data: secrets.key))
            else { return fail("The other device could not prove it has the same key.") }
            peerProved = true
            finishIfBothAgreed()
        case (_, _, .abort(let reason)):
            phase = .failed(reason)
        default:
            fail("Unexpected pairing message.")
        }
    }

    /// The person looked at both screens and the codes are the same.
    func confirm() {
        guard case .compare(let code, let peer) = phase, let secrets else { return }
        confirmedHere = true
        let proof = HMAC<SHA256>.authenticationCode(for: Self.proofText(role), using: SymmetricKey(data: secrets.key))
        phase = .waitingForPeer(code: code, peer: peer)
        send(.confirm(proof: Data(proof)))
        finishIfBothAgreed()
    }

    func cancel(_ reason: String = "Pairing was cancelled.") {
        send(.abort(reason))
        phase = .failed(reason)
    }

    private func fail(_ reason: String) {
        cancel(reason)
    }

    private func finishIfBothAgreed() {
        guard confirmedHere, peerProved, let secrets else { return }
        phase = .done(PairRecord(id: secrets.id, key: secrets.key, peerName: peerName, pairedAt: Date()))
    }

    private func derive() {
        guard let peerPublic, let peerNonce,
              let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublic),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: theirs)
        else { return fail("The other device sent a key that cannot be used.") }
        let mac = role == .mac ? (publicKey, nonce) : (peerPublic, peerNonce)
        let phone = role == .phone ? (publicKey, nonce) : (peerPublic, peerNonce)
        var transcript = SHA256()
        for part in [mac.0, phone.0, mac.1, phone.1] {
            var length = UInt32(part.count).bigEndian
            transcript.update(data: Data(bytes: &length, count: 4))
            transcript.update(data: part)
        }
        let salt = Data(transcript.finalize())
        func expand(_ label: String, _ count: Int) -> Data {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8),
                                           outputByteCount: count).withUnsafeBytes { Data($0) }
        }
        let number = expand("clapless code", 8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let secrets = (code: String(format: "%06llu", number), key: expand("clapless link key", 32),
                       id: expand("clapless link id", 12).hex)
        self.secrets = secrets
        phase = .compare(code: secrets.code, peer: peerName)
    }

    static func commit(_ publicKey: Data, _ nonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("clapless commit".utf8))
        hash.update(data: publicKey)
        hash.update(data: nonce)
        return Data(hash.finalize())
    }

    private static func proofText(_ role: PairRole) -> Data { Data("clapless confirm \(role.rawValue)".utf8) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Paired devices live in the Keychain, as one item.
enum PairStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.clapless.pairing",
        kSecAttrAccount as String: "pairs",
    ]

    static func load() -> [PairRecord] {
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return [] }
        return (try? Coding.decoder.decode([PairRecord].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ records: [PairRecord]) -> Bool {
        guard let data = try? Coding.encoder.encode(records) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
