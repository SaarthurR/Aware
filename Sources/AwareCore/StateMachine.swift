import Dispatch
import Foundation

public enum TransitionReason: Sendable, Equatable {
    case normal
    case activeLease
    case batteryReserve
    case thermalSafety
    case activeLeaseExpired
    case telemetryUnavailable
}

public struct StateDecision: Sendable, Equatable {
    public let state: HostState
    public let shouldDisableSleep: Bool
    public let shouldRunAllowedApps: Bool
    public let reason: TransitionReason

    public init(state: HostState, shouldDisableSleep: Bool, shouldRunAllowedApps: Bool, reason: TransitionReason) {
        self.state = state
        self.shouldDisableSleep = shouldDisableSleep
        self.shouldRunAllowedApps = shouldRunAllowedApps
        self.reason = reason
    }
}

public struct SafetyPolicy: Sendable {
    public let limitedReservePercent: Int
    public let sleepReservePercent: Int

    public init(limitedReservePercent: Int = 25, sleepReservePercent: Int = 20) {
        precondition(limitedReservePercent > sleepReservePercent)
        self.limitedReservePercent = limitedReservePercent
        self.sleepReservePercent = sleepReservePercent
    }

    public func mayStart(_ duration: LeaseDuration, sample: PowerSample) -> Bool {
        guard sample.source != .unknown else { return false }
        guard sample.thermal != .serious && sample.thermal != .critical && sample.thermal != .unknown else { return false }
        guard sample.batteryPercent > sleepReservePercent else { return false }
        if sample.source == .battery && sample.batteryPercent <= limitedReservePercent && duration.isLong {
            return false
        }
        return true
    }

    /// An awake sentinel runs no user applications, so serious thermal pressure may
    /// retain it, but unknown/critical telemetry and the battery floor fail closed.
    public func mayArmSentinel(sample: PowerSample) -> Bool {
        sample.source != .unknown &&
            sample.thermal != .unknown &&
            sample.thermal != .critical &&
            (sample.source != .battery || sample.batteryPercent > sleepReservePercent)
    }

    public func decide(sample: PowerSample, armed: Bool, activeLeaseDeadline: Date?, runsUntilReserve: Bool, now: Date = Date()) -> StateDecision {
        if sample.source == .unknown || sample.thermal == .unknown {
            return StateDecision(state: .reserveSleep, shouldDisableSleep: false, shouldRunAllowedApps: false, reason: .telemetryUnavailable)
        }
        if sample.thermal == .critical {
            return StateDecision(state: .reserveSleep, shouldDisableSleep: false, shouldRunAllowedApps: false, reason: .thermalSafety)
        }
        if sample.source == .battery && sample.batteryPercent <= sleepReservePercent {
            return StateDecision(state: .reserveSleep, shouldDisableSleep: false, shouldRunAllowedApps: false, reason: .batteryReserve)
        }
        guard armed else {
            return StateDecision(state: .offline, shouldDisableSleep: false, shouldRunAllowedApps: false, reason: .normal)
        }
        if !runsUntilReserve, let activeLeaseDeadline, activeLeaseDeadline <= now {
            return StateDecision(
                state: sample.source == .ac ? .acReady : .batterySentinel,
                shouldDisableSleep: true,
                shouldRunAllowedApps: false,
                reason: .activeLeaseExpired
            )
        }
        let active = runsUntilReserve || activeLeaseDeadline.map { $0 > now } == true
        if active {
            return StateDecision(
                state: sample.source == .ac ? .acReady : .batteryActive,
                shouldDisableSleep: true,
                shouldRunAllowedApps: sample.thermal != .serious,
                reason: sample.thermal == .serious ? .thermalSafety : .activeLease
            )
        }
        return StateDecision(
            state: sample.source == .ac ? .acReady : .batterySentinel,
            shouldDisableSleep: true,
            shouldRunAllowedApps: sample.source == .ac,
            reason: .normal
        )
    }
}

/// Retains the last valid power sample only for a short, explicit grace period.
/// Once that bound is exceeded, callers receive `.unknown` and the safety policy disarms.
public struct PowerTelemetryGuard: Sendable {
    public let gracePeriod: TimeInterval
    private var lastValid: PowerSample?
    private var lastValidMonotonicNanoseconds: UInt64?

    public init(gracePeriod: TimeInterval = 30) {
        precondition(gracePeriod > 0 && gracePeriod <= 60)
        self.gracePeriod = gracePeriod
    }

    public mutating func resolve(
        _ sample: PowerSample,
        now: Date = Date(),
        monotonicNow: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> PowerSample {
        if sample.source != .unknown,
           sample.observedAt <= now,
           now.timeIntervalSince(sample.observedAt) <= gracePeriod {
            lastValid = sample
            lastValidMonotonicNanoseconds = monotonicNow
            return sample
        }
        if let lastValid, let observed = lastValidMonotonicNanoseconds {
            let elapsed = monotonicNow >= observed ? monotonicNow - observed : UInt64.max
            if elapsed <= UInt64(gracePeriod * 1_000_000_000) { return lastValid }
        }
        return PowerSample(source: .unknown, batteryPercent: 0, thermal: sample.thermal, observedAt: now)
    }
}

public struct BatteryDayPolicy: Sendable {
    public let duration: TimeInterval

    public init(hours: Int = 24) {
        precondition((1...48).contains(hours))
        self.duration = TimeInterval(hours * 3_600)
    }

    public func deadline(from date: Date) -> Date {
        date.addingTimeInterval(duration)
    }

    public func deadline(
        from date: Date,
        batteryPercent: Int,
        sleepReservePercent: Int,
        calibratedDrainPercentPerHour: Double?
    ) -> Date {
        let configuredDeadline = deadline(from: date)
        guard let drain = calibratedDrainPercentPerHour, drain > 0 else { return configuredDeadline }
        let usablePercent = max(0, batteryPercent - sleepReservePercent)
        let calibratedDeadline = date.addingTimeInterval(Double(usablePercent) / drain * 3_600)
        return min(configuredDeadline, calibratedDeadline)
    }

    public func calibratedDurationIsSupported(
        batteryPercent: Int,
        sleepReservePercent: Int,
        calibratedDrainPercentPerHour: Double?
    ) -> Bool {
        guard let drain = calibratedDrainPercentPerHour, drain > 0 else { return false }
        return Double(max(0, batteryPercent - sleepReservePercent)) / drain * 3_600 >= duration
    }

    public func shouldDisarm(deadline: Date?, activeLeaseDeadline: Date?, runsUntilReserve: Bool, now: Date) -> Bool {
        guard let deadline, deadline <= now, !runsUntilReserve else { return false }
        return activeLeaseDeadline.map { $0 <= now } ?? true
    }
}
