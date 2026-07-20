import Foundation

public enum HelperCommandKind: String, Codable, Sendable {
    case arm
    case heartbeat
    case disarm
    case status
}

/// The helper deliberately exposes no executable names, paths, scripts, or arbitrary arguments.
public struct HelperCommand: Codable, Sendable, Equatable {
    public let command: HelperCommandKind

    public init(_ command: HelperCommandKind) {
        self.command = command
    }
}

public enum HelperErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case commandFailed = "command_failed"
    case notArmed = "not_armed"
    case internalError = "internal_error"
}

public struct HelperStatus: Codable, Sendable, Equatable {
    public let armed: Bool
    public let sleepDisabled: Bool
    public let lastHeartbeat: Date?
    public let watchdogDeadline: Date?

    public init(armed: Bool, sleepDisabled: Bool, lastHeartbeat: Date?, watchdogDeadline: Date?) {
        self.armed = armed
        self.sleepDisabled = sleepDisabled
        self.lastHeartbeat = lastHeartbeat
        self.watchdogDeadline = watchdogDeadline
    }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let status: HelperStatus?
    public let error: HelperErrorCode?
    public let message: String?

    public init(ok: Bool, status: HelperStatus? = nil, error: HelperErrorCode? = nil, message: String? = nil) {
        self.ok = ok
        self.status = status
        self.error = error
        self.message = message
    }
}

public enum AwareApp: String, Codable, CaseIterable, Sendable {
    case chatgpt
    case claude
    case cursor
    case amphetamine
}

public enum LeaseDuration: Codable, Sendable, Equatable {
    case minutes(Int)
    case reserve

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self), value == 30 || value == 120 {
            self = .minutes(value)
            return
        }
        if let value = try? container.decode(String.self), value == "reserve" {
            self = .reserve
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "duration_minutes must be 30, 120, or reserve")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .minutes(let minutes): try container.encode(minutes)
        case .reserve: try container.encode("reserve")
        }
    }

    public var isLong: Bool {
        switch self {
        case .minutes(30): false
        default: true
        }
    }

    public func deadline(from date: Date) -> Date? {
        switch self {
        case .minutes(let value): date.addingTimeInterval(TimeInterval(value * 60))
        case .reserve: nil
        }
    }
}

public struct WakeRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let timestamp: Date
    public let nonce: String
    public let apps: Set<AwareApp>
    public let duration: LeaseDuration

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case timestamp, nonce, apps
        case duration = "duration_minutes"
    }

    public init(requestID: String, timestamp: Date, nonce: String, apps: Set<AwareApp>, duration: LeaseDuration) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.nonce = nonce
        self.apps = apps
        self.duration = duration
    }
}

public enum PowerSource: String, Codable, Sendable {
    case ac
    case battery
    case unknown
}

public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum HostState: String, Codable, Sendable {
    case acReady = "ac_ready"
    case batterySentinel = "battery_sentinel"
    case batteryActive = "battery_active"
    case reserveSleep = "reserve_sleep"
    case offline
}

public enum ReadinessEstimateQuality: String, Codable, Sendable {
    case calibrated
    case bestEffort = "best_effort"
}

public struct PowerSample: Codable, Sendable, Equatable {
    public let source: PowerSource
    public let batteryPercent: Int
    public let thermal: ThermalLevel
    public let observedAt: Date

    public init(source: PowerSource, batteryPercent: Int, thermal: ThermalLevel, observedAt: Date = Date()) {
        self.source = source
        self.batteryPercent = min(100, max(0, batteryPercent))
        self.thermal = thermal
        self.observedAt = observedAt
    }
}

public struct HostStatus: Codable, Sendable, Equatable {
    public let state: HostState
    public let powerSource: PowerSource
    public let batteryPercent: Int?
    public let thermalState: ThermalLevel
    public let sentinelDrainPercentPerHour: Double?
    public let estimatedReadyUntil: Date?
    public let readinessEstimateQuality: ReadinessEstimateQuality
    public let appsStarted: [AwareApp]
    public let lastSeen: Date
    public let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case state
        case powerSource = "power_source"
        case batteryPercent = "battery_percent"
        case thermalState = "thermal_state"
        case sentinelDrainPercentPerHour = "sentinel_drain_percent_per_hour"
        case estimatedReadyUntil = "estimated_ready_until"
        case readinessEstimateQuality = "readiness_estimate_quality"
        case appsStarted = "apps_started"
        case lastSeen = "last_seen"
        case failureReason = "failure_reason"
    }

    public init(state: HostState, powerSource: PowerSource, batteryPercent: Int?, thermalState: ThermalLevel, sentinelDrainPercentPerHour: Double?, estimatedReadyUntil: Date?, readinessEstimateQuality: ReadinessEstimateQuality = .bestEffort, appsStarted: [AwareApp], lastSeen: Date, failureReason: String?) {
        self.state = state
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.thermalState = thermalState
        self.sentinelDrainPercentPerHour = sentinelDrainPercentPerHour
        self.estimatedReadyUntil = estimatedReadyUntil
        self.readinessEstimateQuality = readinessEstimateQuality
        self.appsStarted = appsStarted.sorted { $0.rawValue < $1.rawValue }
        self.lastSeen = lastSeen
        self.failureReason = failureReason
    }
}

public extension JSONEncoder {
    static func aware() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static func aware() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date")
            }
            return date
        }
        return decoder
    }
}

public enum ConfigurationData {
    /// Installed configs are property lists because `plutil` can update them without shell interpolation;
    /// checked-in examples remain JSON for readability.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        return try PropertyListDecoder().decode(type, from: data)
    }
}
