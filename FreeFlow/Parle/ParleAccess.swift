import CryptoKit
import Foundation

/// Asks the server for access and picks up the approval when it arrives.
enum ParleAccessClient {
    enum RequestStatus: Equatable {
        case none
        case pending
        case approved
        case denied
    }

    static var defaultRequesterName: String {
        let full = NSFullUserName()
        return full.isEmpty ? (Host.current().localizedName ?? "Mac") : full
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    // Requester ------------------------------------------------------------------

    static func requestAccess(name: String) async throws {
        let body: [String: String] = [
            "name": name, "mac": macName, "device": try ParleKeys.devicePublicKeyString(),
        ]
        _ = try await send("/access/request", method: "POST", json: body, headers: try deviceHeaders("parle-request"))
    }

    /// Current status; when approved, also returns the pass.
    static func status() async throws -> (RequestStatus, String?) {
        let device = try ParleKeys.devicePublicKeyString()
        let data = try await send(
            "/access/status?device=\(device)", method: "GET", headers: try deviceHeaders("parle-status"))
        struct Reply: Decodable { let status: String; let pass: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        switch reply.status {
        case "pending": return (.pending, nil)
        case "approved": return (.approved, reply.pass)
        case "denied": return (.denied, nil)
        default: return (.none, nil)
        }
    }

    struct PassInfo: Decodable, Equatable {
        let wordsUsed: Int
        let wordsLimit: Int?
        let exp: Int?
        enum CodingKeys: String, CodingKey { case wordsUsed = "words_used", wordsLimit = "words_limit", exp }
    }

    /// Signed heartbeat: tells the owner this Mac is online and returns its limits.
    static func ping() async throws -> PassInfo {
        guard let pass = ParlePassStore.current else { throw ParlePCError.unreachable }
        var headers = try deviceHeaders("parle-ping")
        headers["X-Parle-Pass"] = pass.code
        let data = try await send("/access/ping", method: "POST", body: Data("{}".utf8), headers: headers)
        return try JSONDecoder().decode(PassInfo.self, from: data)
    }

    // Invites ---------------------------------------------------------------------

    /// What the invite screen says. It comes from the server, so the app holds none of it.
    struct InvitePrompt: Decodable, Equatable {
        let title: String
        let message: String
        let placeholder: String
        let button: String
    }

    static func invitePrompt() async throws -> InvitePrompt {
        let device = try ParleKeys.devicePublicKeyString()
        let data = try await send(
            "/invite/prompt", method: "POST", json: ["device": device], headers: try deviceHeaders("ff-invite-prompt"))
        return try JSONDecoder().decode(InvitePrompt.self, from: data)
    }

    /// Redeems an invite code for this Mac. Returns the server's name.
    static func redeemInvite(_ code: String) async throws -> String {
        let device = try ParleKeys.devicePublicKeyString()
        let data = try await send(
            "/invite/redeem", method: "POST", json: ["device": device, "code": code],
            headers: try deviceHeaders("ff-invite-redeem"))
        struct Reply: Decodable { let server_name: String? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.server_name ?? ""
    }

    /// The server's own reason from a rejection body ({"detail": "..."}), if any.
    static func detail(of error: Error) -> String? {
        guard case ParlePCError.rejected(_, let body) = error,
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["detail"] as? String
    }

    /// Proves the request comes from this Mac's own device key.
    static func deviceHeaders(_ context: String) throws -> [String: String] {
        let time = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let signature = try ParleKeys.deviceKey()
            .signature(for: Data("\(context)\n\(time)\n\(nonce)".utf8)).derRepresentation
        return [
            "X-Parle-Time": time, "X-Parle-Nonce": nonce,
            "X-Parle-Signature": ParleCodec.base64url(signature),
        ]
    }

    // Transport ------------------------------------------------------------------

    @discardableResult
    private static func send(
        _ path: String, method: String, json: [String: String]? = nil, body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var lastError: Error = ParlePCError.unreachable
        let payload = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? body
        for base in ParlePC.urls {
            guard let url = URL(string: base + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 10
            if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            do {
                let (data, response): (Data, URLResponse)
                if let payload {
                    (data, response) = try await ParlePC.session.upload(for: request, from: payload)
                } else {
                    (data, response) = try await ParlePC.session.data(for: request)
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code) else {
                    throw ParlePCError.rejected(code, String(data: data, encoding: .utf8) ?? "")
                }
                return data
            } catch let error as URLError {
                lastError = error
                continue
            }
        }
        throw lastError is URLError ? ParlePCError.unreachable : lastError
    }
}
