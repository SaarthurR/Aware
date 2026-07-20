import Darwin
import Foundation

public struct OwnedAppProcessIdentity: Codable, Sendable, Hashable {
    public let app: AwareApp
    public let pid: Int32
    public let processStartedAt: Date

    public init(app: AwareApp, pid: Int32, processStartedAt: Date) {
        self.app = app
        self.pid = pid
        self.processStartedAt = processStartedAt
    }
}

public enum OwnedProcessCollectionPolicy {
    public static func appending(
        _ identity: OwnedAppProcessIdentity,
        to existing: Set<OwnedAppProcessIdentity>
    ) -> Set<OwnedAppProcessIdentity> {
        existing.union([identity])
    }

    public static func retainingSurvivors(
        from attempted: Set<OwnedAppProcessIdentity>,
        stillRunning: Set<OwnedAppProcessIdentity>
    ) -> Set<OwnedAppProcessIdentity> {
        attempted.intersection(stillRunning)
    }
}

public struct PendingLaunchTransaction: Codable, Sendable, Equatable {
    public let app: AwareApp
    public let operationID: String
    public let activeDeadline: Date?
    public let runsUntilReserve: Bool
    public let preLaunchProcesses: [OwnedAppProcessIdentity]

    public init(app: AwareApp, operationID: String, activeDeadline: Date?, runsUntilReserve: Bool, preLaunchProcesses: [OwnedAppProcessIdentity]) {
        self.app = app
        self.operationID = operationID
        self.activeDeadline = activeDeadline
        self.runsUntilReserve = runsUntilReserve
        self.preLaunchProcesses = preLaunchProcesses.sorted { ($0.pid, $0.processStartedAt) < ($1.pid, $1.processStartedAt) }
    }
}

public enum LaunchOwnershipPolicy {
    /// Ownership can come only from NSWorkspace's completion-returned application.
    /// A preexisting identity or a nil/unknown completion can never be claimed.
    public static func ownableCompletionIdentity(
        _ completionIdentity: OwnedAppProcessIdentity?,
        preLaunchProcesses: [OwnedAppProcessIdentity]
    ) -> OwnedAppProcessIdentity? {
        guard let completionIdentity else { return nil }
        let wasPresent = preLaunchProcesses.contains {
            $0.pid == completionIdentity.pid && $0.processStartedAt == completionIdentity.processStartedAt
        }
        return wasPresent ? nil : completionIdentity
    }
}

public enum OwnedCleanupPolicy {
    public static func mayAcknowledgeSentinel(remainingOwnedProcesses: [OwnedAppProcessIdentity]) -> Bool {
        remainingOwnedProcesses.isEmpty
    }
}

public struct LaunchTransactionGate: Sendable {
    public private(set) var isActive = false
    public init() {}
    public mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }
    public mutating func end() { isActive = false }
}

public enum GuardianDesiredIntent: String, Codable, Sendable {
    case armed
    case disarmed
}

public enum GuardianLifecyclePolicy {
    public static func startupIntent(hasExistingState: Bool, autoArm: Bool) -> GuardianDesiredIntent {
        hasExistingState ? .disarmed : (autoArm ? .armed : .disarmed)
    }
}

public struct LaunchGenerationTracker: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func cancelAndAdvance() -> UInt64 { value &+= 1; return value }
    public func isCurrent(_ captured: UInt64) -> Bool { captured == value }
}

public enum LaunchTimeoutPolicy {
    public static let hardLimit: TimeInterval = 15
    public static let supersessionDrainLimit: TimeInterval = hardLimit + 3
}

public struct LaunchSupersessionModel {
    public private(set) var generation: UInt64 = 0
    public private(set) var gateOwner: UInt64?
    public private(set) var exactCleanupCount = 0
    public private(set) var remoteReadySequence: UInt64?
    public init() {}
    public mutating func occupyGate(sequence: UInt64) { gateOwner = sequence }
    public mutating func acceptNewWake(sequence: UInt64) { generation &+= 1; remoteReadySequence = nil }
    public mutating func oldLaunchCleansAndReleases(sequence: UInt64) {
        guard gateOwner == sequence else { return }
        exactCleanupCount += 1
        gateOwner = nil
    }
    public mutating func launchCurrent(sequence: UInt64) -> Bool {
        guard gateOwner == nil else { return false }
        remoteReadySequence = sequence
        return true
    }
}

public enum CommandConcurrencyPolicy {
    public static let maximumInFlight = 8
}

public enum HeartbeatAuthorizationPolicy {
    public static func maySend(desiredIntent: GuardianDesiredIntent) -> Bool {
        desiredIntent == .armed
    }
}

public enum SequencedIntentCommand: Equatable { case wake, safety }

public struct SequencedIntentModel {
    public private(set) var highestAcceptedSequence: UInt64 = 0
    public private(set) var desiredIntent: GuardianDesiredIntent = .disarmed
    public init() {}
    @discardableResult public mutating func apply(sequence: UInt64, command: SequencedIntentCommand) -> Bool {
        guard sequence > highestAcceptedSequence else { return false }
        highestAcceptedSequence = sequence
        desiredIntent = command == .wake ? .armed : .disarmed
        return true
    }
}

public struct SequencedSafetyCleanupModel {
    public private(set) var highestSequence: UInt64 = 0
    public private(set) var desiredIntent: GuardianDesiredIntent = .disarmed
    private var cleanups: [UInt64: GuardianDesiredIntent] = [:]
    private var waitingWake: UInt64?
    public init() {}

    public mutating func startSafety(sequence: UInt64, completion: GuardianDesiredIntent) -> Bool {
        guard sequence > highestSequence else { return false }
        highestSequence = sequence
        cleanups[sequence] = completion
        return true
    }

    public mutating func acceptWake(sequence: UInt64) -> Bool {
        guard sequence > highestSequence else { return false }
        highestSequence = sequence
        if cleanups.isEmpty { desiredIntent = .armed } else { waitingWake = sequence }
        return true
    }

    public mutating func finishSafety(sequence: UInt64) {
        guard let completion = cleanups.removeValue(forKey: sequence) else { return }
        if sequence == highestSequence { desiredIntent = completion }
        if cleanups.isEmpty, waitingWake == highestSequence {
            desiredIntent = .armed
            waitingWake = nil
        }
    }

    public func mayRetrySafety(sequence: UInt64) -> Bool { sequence == highestSequence }
}

public enum OperationAdmission: Equatable {
    case replay(RequestProgressState)
    case retryCleanup
    case accept
    case rejectStale
}

public enum OperationAdmissionPolicy {
    public static func decide(cached: RequestProgressState?, isFresh: Bool) -> OperationAdmission {
        if let cached {
            if cached == .sentinelCleanupPending { return .retryCleanup }
            if cached.isTerminal { return .replay(cached) }
        }
        return isFresh ? .accept : .rejectStale
    }
}

public struct GuardianPersistentState: Codable, Sendable, Equatable {
    public let activeDeadline: Date?
    public let runsUntilReserve: Bool
    public let requestedApps: Set<AwareApp>
    public let ownedProcesses: [OwnedAppProcessIdentity]
    public let pendingLaunch: PendingLaunchTransaction?
    public let desiredIntent: GuardianDesiredIntent
    public let operationProgress: [String: RequestProgressState]
    public let operationSequences: [String: UInt64]
    public let highestAcceptedSequence: UInt64

    public init(
        activeDeadline: Date?,
        runsUntilReserve: Bool,
        requestedApps: Set<AwareApp>,
        ownedProcesses: [OwnedAppProcessIdentity],
        pendingLaunch: PendingLaunchTransaction? = nil,
        desiredIntent: GuardianDesiredIntent = .disarmed,
        operationProgress: [String: RequestProgressState] = [:],
        operationSequences: [String: UInt64] = [:],
        highestAcceptedSequence: UInt64 = 0
    ) {
        self.activeDeadline = activeDeadline
        self.runsUntilReserve = runsUntilReserve
        self.requestedApps = requestedApps
        self.ownedProcesses = Array(Set(ownedProcesses)).sorted {
            ($0.app.rawValue, $0.pid, $0.processStartedAt) < ($1.app.rawValue, $1.pid, $1.processStartedAt)
        }
        self.pendingLaunch = pendingLaunch
        self.desiredIntent = desiredIntent
        self.operationProgress = operationProgress
        self.operationSequences = operationSequences
        self.highestAcceptedSequence = highestAcceptedSequence
    }

    public static let empty = GuardianPersistentState(
        activeDeadline: nil,
        runsUntilReserve: false,
        requestedApps: [],
        ownedProcesses: [],
        pendingLaunch: nil,
        desiredIntent: .disarmed,
        operationProgress: [:],
        operationSequences: [:],
        highestAcceptedSequence: 0
    )

    private enum CodingKeys: String, CodingKey {
        case activeDeadline, runsUntilReserve, requestedApps, ownedProcesses, pendingLaunch, desiredIntent, operationProgress, operationSequences, highestAcceptedSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeDeadline = try container.decodeIfPresent(Date.self, forKey: .activeDeadline)
        runsUntilReserve = try container.decodeIfPresent(Bool.self, forKey: .runsUntilReserve) ?? false
        requestedApps = try container.decodeIfPresent(Set<AwareApp>.self, forKey: .requestedApps) ?? []
        ownedProcesses = try container.decodeIfPresent([OwnedAppProcessIdentity].self, forKey: .ownedProcesses) ?? []
        pendingLaunch = try container.decodeIfPresent(PendingLaunchTransaction.self, forKey: .pendingLaunch)
        // Pre-intent state files are an upgrade boundary and fail safe to disarmed.
        desiredIntent = try container.decodeIfPresent(GuardianDesiredIntent.self, forKey: .desiredIntent) ?? .disarmed
        operationProgress = try container.decodeIfPresent([String: RequestProgressState].self, forKey: .operationProgress) ?? [:]
        operationSequences = try container.decodeIfPresent([String: UInt64].self, forKey: .operationSequences) ?? [:]
        highestAcceptedSequence = try container.decodeIfPresent(UInt64.self, forKey: .highestAcceptedSequence) ?? 0
    }
}

/// Atomically stores the complete lease and process-ownership transaction. The file is
/// user-only and symlinks/non-regular files are rejected rather than followed.
public final class GuardianStateStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() throws -> GuardianPersistentState? {
        try lock.withLock {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw CocoaError(.fileReadNoPermission)
            }
            guard info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(),
                  info.st_mode & mode_t(0o077) == 0 else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try PropertyListDecoder().decode(
                GuardianPersistentState.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe])
            )
        }
    }

    public func save(_ state: GuardianPersistentState) throws {
        try lock.withLock {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try PropertyListEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
            guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }

    public func clear() throws {
        try lock.withLock {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return }
                throw CocoaError(.fileWriteNoPermission)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
