import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: - Parle access passes
//
// Who may transcribe on the server is decided by keys that live in Secure
// Enclaves and never leave them:
//
//   • Owner key  — on the owner's Mac only. P-256, Secure Enclave, and every use
//                  requires Touch ID (.biometryCurrentSet). winpc trusts only
//                  this key's public half.
//   • Device key — one per Mac that runs Parle. P-256, Secure Enclave, no
//                  prompt. Signs every transcription request.
//
// Granting access:
//   1. The other Mac shows an *access request* code (its name + device public key).
//   2. the owner pastes it into the admin app, approves with Touch ID, and Parle signs
//      a *pass* that binds that request's device key.
//   3. The other Mac pastes the pass. Each request it sends carries the pass and
//      a fresh device-key signature over (time, nonce, SHA-256 of the audio), so
//      a copied pass is useless on any other Mac and requests cannot be replayed.
//
// Revocation is a Touch ID–signed list sent to winpc; only the owner key can
// produce one.

enum ParlePassError: LocalizedError {
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case invalidCode
    case notOwner
    case accessControl
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable: "This Mac has no Secure Enclave."
        case .keychain(let status): "Keychain error \(status)."
        case .invalidCode: "That code isn't a valid Parle code."
        case .notOwner: "This Mac isn't the owner of the PC."
        case .accessControl: "Couldn't set up Touch ID protection for the key."
        case .userCancelled: "Touch ID was cancelled."
        }
    }
}

/// An access request shown on the Mac that wants PC access.
struct ParleAccessRequest: Codable, Equatable {
    var v = 1
    let name: String
    /// Device public key, X9.63 uncompressed, base64url.
    let device: String

    static let prefix = "parle-request:"

    var code: String { Self.prefix + ParleCodec.encodeJSON(self) }

    init(name: String, device: String) {
        self.name = name
        self.device = device
    }

    init(code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix),
            let value: ParleAccessRequest = ParleCodec.decodeJSON(String(trimmed.dropFirst(Self.prefix.count)))
        else { throw ParlePassError.invalidCode }
        self = value
    }
}

/// The signed body of a pass.
struct ParlePassPayload: Codable, Equatable {
    var v = 1
    let id: String
    let name: String
    /// Device public key this pass is bound to (X9.63, base64url).
    let device: String
    /// Issued-at, seconds since 1970.
    let iat: Int
    /// Optional expiry, seconds since 1970.
    let exp: Int?
    /// Base URLs of the PC, tried in order (Tailscale first).
    let urls: [String]
}

/// A pass: payload + owner signature. Text form: `parle-pass:<payload>.<signature>`.
struct ParlePass: Equatable {
    let payload: ParlePassPayload
    let payloadPart: String
    let signaturePart: String

    static let prefix = "parle-pass:"

    var code: String { Self.prefix + payloadPart + "." + signaturePart }

    init(code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { throw ParlePassError.invalidCode }
        let parts = trimmed.dropFirst(Self.prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload: ParlePassPayload = ParleCodec.decodeJSON(String(parts[0])) else {
            throw ParlePassError.invalidCode
        }
        self.payload = payload
        self.payloadPart = String(parts[0])
        self.signaturePart = String(parts[1])
    }

    fileprivate init(payload: ParlePassPayload, payloadPart: String, signaturePart: String) {
        self.payload = payload
        self.payloadPart = payloadPart
        self.signaturePart = signaturePart
    }

    var isExpired: Bool {
        guard let exp = payload.exp else { return false }
        return Date().timeIntervalSince1970 >= Double(exp)
    }
}

enum ParleCodec {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return base64url((try? encoder.encode(value)) ?? Data())
    }

    static func decodeJSON<T: Decodable>(_ string: String) -> T? {
        guard let data = data(base64url: string) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Keys

enum ParleKeys {
    private static let service = "com.jaydenghiyam.FreeFlow.keys"
    private static let deviceAccount = "device-key"

    // Device key ---------------------------------------------------------------

    /// This Mac's device key, created on first use.
    static func deviceKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw ParlePassError.secureEnclaveUnavailable }
        if let blob = try readBlob(account: deviceAccount) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        }
        var error: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &error)
        else { throw ParlePassError.accessControl }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try writeBlob(key.dataRepresentation, account: deviceAccount)
        return key
    }

    static func devicePublicKeyString() throws -> String {
        ParleCodec.base64url(try deviceKey().publicKey.x963Representation)
    }

    // Keychain blobs (the Secure Enclave–wrapped key handles) ------------------

    private static func readBlob(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ParlePassError.keychain(status) }
        return result as? Data
    }

    private static func writeBlob(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ParlePassError.keychain(status) }
    }
}

// MARK: - Holding and using a pass

enum ParlePassStore {
    private static let service = "com.jaydenghiyam.FreeFlow.pass"
    private static let account = "pc-pass"

    static var current: ParlePass? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, let code = String(data: data, encoding: .utf8)
        else { return nil }
        return try? ParlePass(code: code)
    }

    /// Stores a pass after checking it is bound to *this* Mac's device key.
    static func install(code: String) throws -> ParlePass {
        let pass = try ParlePass(code: code)
        guard pass.payload.device == (try ParleKeys.devicePublicKeyString()) else {
            throw ParlePassError.invalidCode
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(pass.code.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ParlePassError.keychain(status) }
        return pass
    }

    static func remove() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
    }

    /// Headers proving this request comes from the pass holder's own Mac.
    static func authorizationHeaders(for body: Data) throws -> [String: String] {
        guard let pass = current else { throw ParlePassError.notOwner }
        let time = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("parle-v1\n\(time)\n\(nonce)\n\(digest)".utf8)
        let signature = try ParleKeys.deviceKey().signature(for: message).derRepresentation
        return [
            "X-Parle-Pass": pass.code,
            "X-Parle-Time": time,
            "X-Parle-Nonce": nonce,
            "X-Parle-Signature": ParleCodec.base64url(signature),
        ]
    }
}
