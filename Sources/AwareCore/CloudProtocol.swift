import CryptoKit
import Foundation

public struct SocketWakeRequest: Codable, Sendable, Equatable {
    public let operationID: String
    public let sequence: UInt64
    public let targetRequestID: String?
    public let apps: [AwareApp]
    public let duration: LeaseDuration
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case sequence
        case targetRequestID = "target_request_id"
        case apps
        case duration = "duration_minutes"
        case createdAt = "created_at"
    }
}

public enum CloudCommand: Sendable, Equatable {
    case wake(SocketWakeRequest)
    case disarm(operationID: String, sequence: UInt64, targetRequestID: String?, requestedAt: Date, deliveredAt: Date)
    case returnToSentinel(operationID: String, sequence: UInt64, targetRequestID: String?, requestedAt: Date, deliveredAt: Date)
}

public extension CloudCommand {
    var operationID: String {
        switch self {
        case .wake(let request): request.operationID
        case .disarm(let operationID, _, _, _, _), .returnToSentinel(let operationID, _, _, _, _): operationID
        }
    }

    var sequence: UInt64 {
        switch self {
        case .wake(let request): request.sequence
        case .disarm(_, let sequence, _, _, _), .returnToSentinel(_, let sequence, _, _, _): sequence
        }
    }

    var targetRequestID: String? {
        switch self {
        case .wake(let request): request.targetRequestID
        case .disarm(_, _, let target, _, _), .returnToSentinel(_, _, let target, _, _): target
        }
    }

    /// Immutable user intent time retained for audit. This does not expire a
    /// fixed safety control that was durably queued while the Mac was offline.
    var requestedAt: Date {
        switch self {
        case .wake(let request): request.createdAt
        case .disarm(_, _, _, let requestedAt, _), .returnToSentinel(_, _, _, let requestedAt, _): requestedAt
        }
    }

    /// Timestamp used for the five-minute transport freshness check. Wake uses
    /// its immutable creation time; fixed safety controls use Worker delivery.
    var freshnessDate: Date {
        switch self {
        case .wake(let request): request.createdAt
        case .disarm(_, _, _, _, let deliveredAt), .returnToSentinel(_, _, _, _, let deliveredAt): deliveredAt
        }
    }
}

extension CloudCommand: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case operationID = "operation_id"
        case sequence
        case targetRequestID = "target_request_id"
        case requestedAt = "requested_at"
        case deliveredAt = "delivered_at"
    }
    private enum Kind: String, Decodable { case wake, disarm; case returnToSentinel = "return_to_sentinel" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .wake:
            let request = try SocketWakeRequest(from: decoder)
            guard request.sequence > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .sequence, in: container, debugDescription: "sequence must be positive")
            }
            self = .wake(request)
        case .disarm:
            let sequence = try container.decode(UInt64.self, forKey: .sequence)
            guard sequence > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .sequence, in: container, debugDescription: "sequence must be positive")
            }
            self = .disarm(
                operationID: try container.decode(String.self, forKey: .operationID),
                sequence: sequence,
                targetRequestID: try container.decodeIfPresent(String.self, forKey: .targetRequestID),
                requestedAt: try container.decode(Date.self, forKey: .requestedAt),
                deliveredAt: try container.decode(Date.self, forKey: .deliveredAt)
            )
        case .returnToSentinel:
            let sequence = try container.decode(UInt64.self, forKey: .sequence)
            guard sequence > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .sequence, in: container, debugDescription: "sequence must be positive")
            }
            self = .returnToSentinel(
                operationID: try container.decode(String.self, forKey: .operationID),
                sequence: sequence,
                targetRequestID: try container.decodeIfPresent(String.self, forKey: .targetRequestID),
                requestedAt: try container.decode(Date.self, forKey: .requestedAt),
                deliveredAt: try container.decode(Date.self, forKey: .deliveredAt)
            )
        }
    }
}

public enum RequestProgressState: String, Codable, Sendable {
    case powerArmed = "power_armed"
    case appsStarted = "apps_started"
    case remoteReady = "remote_ready"
    case reserveSleep = "reserve_sleep"
    case failed
    case sentinelCleanupPending = "sentinel_cleanup_pending"
    case disarmed
    case returnedToSentinel = "returned_to_sentinel"
    case cancelled
}

public extension RequestProgressState {
    var isTerminal: Bool {
        switch self {
        case .remoteReady, .reserveSleep, .failed, .disarmed, .returnedToSentinel, .cancelled:
            true
        case .powerArmed, .appsStarted, .sentinelCleanupPending:
            false
        }
    }

    var closesOperationAttempt: Bool {
        isTerminal || self == .sentinelCleanupPending
    }
}

public enum CanonicalBase64URLSecret {
    public static func decode(_ value: String, minimumBytes: Int = 32) -> Data? {
        guard minimumBytes > 0,
              !value.isEmpty,
              value.count % 4 != 1,
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let decoded = Data(base64Encoded: base64), decoded.count >= minimumBytes else { return nil }
        let canonical = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value ? decoded : nil
    }
}

public extension CloudReport {
    /// Durable Objects accepts host reports as UTF-8 WebSocket text frames.
    func utf8Text() throws -> String {
        let data = try JSONEncoder.aware().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }
}

public enum CloudReport: Encodable, Sendable {
    case hello(HostStatus)
    case status(HostStatus)
    case progress(operationID: String, sequence: UInt64, state: RequestProgressState, status: HostStatus, failureReason: String?)

    private enum CodingKeys: String, CodingKey {
        case type, status, operationID = "operation_id", sequence, state, failureReason = "failure_reason"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let status):
            try container.encode("hello", forKey: .type)
            try container.encode(status, forKey: .status)
        case .status(let status):
            try container.encode("status", forKey: .type)
            try container.encode(status, forKey: .status)
        case .progress(let operationID, let sequence, let state, let status, let failureReason):
            try container.encode("operation_status", forKey: .type)
            try container.encode(operationID, forKey: .operationID)
            try container.encode(sequence, forKey: .sequence)
            try container.encode(state, forKey: .state)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(failureReason, forKey: .failureReason)
        }
    }
}

public struct AuthenticationHeaders: Sendable, Equatable {
    public let keyID: String
    public let timestamp: String
    public let nonce: String
    public let signature: String
}

public enum RequestSigner {
    public static func headers(method: String, url: URL, body: Data, keyID: String, secret: Data, now: Date = Date(), nonce: String = UUID().uuidString) throws -> AuthenticationHeaders {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        }
        let pathAndQuery = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let timestamp = String(Int(now.timeIntervalSince1970))
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = [method.uppercased(), pathAndQuery, timestamp, nonce, bodyHash].joined(separator: "\n")
        let key = SymmetricKey(data: secret)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        let encoded = Data(signature).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AuthenticationHeaders(keyID: keyID, timestamp: timestamp, nonce: nonce, signature: encoded)
    }
}
