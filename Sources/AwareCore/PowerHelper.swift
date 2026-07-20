import Dispatch
import Foundation

public protocol SleepPowerControlling: Sendable {
    func setSleepDisabled(_ disabled: Bool) throws
}

public enum PowerControlError: Error, CustomStringConvertible, Sendable {
    case mustRunAsRoot
    case pmsetFailed(Int32)

    public var description: String {
        switch self {
        case .mustRunAsRoot: "AwarePowerHelper must run as root"
        case .pmsetFailed(let status): "pmset exited with status \(status)"
        }
    }
}

/// The only privileged subprocess entry point. Neither executable nor arguments are caller-controlled.
public struct PMSetController: SleepPowerControlling {
    public init() {}

    public func setSleepDisabled(_ disabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PowerControlError.pmsetFailed(process.terminationStatus)
        }
    }
}

public final class PowerHelperService: @unchecked Sendable {
    private struct State {
        var armed = false
        var sleepDisabled = false
        var lastHeartbeatWallTime: Date?
        var lastHeartbeatMonotonicNanoseconds: UInt64?
    }

    private let controller: any SleepPowerControlling
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private let watchdogTimeout: TimeInterval
    private let lock = NSLock()
    private var state = State()

    public init(
        controller: any SleepPowerControlling,
        watchdogTimeout: TimeInterval = 120,
        wallNow: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        precondition(watchdogTimeout > 0 && watchdogTimeout <= 120)
        self.controller = controller
        self.watchdogTimeout = watchdogTimeout
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
    }

    public func handle(_ command: HelperCommand) -> HelperResponse {
        do {
            switch command.command {
            case .arm:
                try lock.withLock {
                    if !state.sleepDisabled { try controller.setSleepDisabled(true) }
                    state.armed = true
                    state.sleepDisabled = true
                    state.lastHeartbeatWallTime = wallNow()
                    state.lastHeartbeatMonotonicNanoseconds = monotonicNow()
                }
            case .heartbeat:
                let wasArmed = lock.withLock { () -> Bool in
                    guard state.armed else { return false }
                    state.lastHeartbeatWallTime = wallNow()
                    state.lastHeartbeatMonotonicNanoseconds = monotonicNow()
                    return true
                }
                guard wasArmed else {
                    return HelperResponse(ok: false, status: snapshot(), error: .notArmed, message: "helper is not armed")
                }
            case .disarm:
                try restoreSleep()
            case .status:
                break
            }
            return HelperResponse(ok: true, status: snapshot())
        } catch {
            return HelperResponse(ok: false, status: snapshot(), error: .commandFailed, message: String(describing: error))
        }
    }

    /// A helper crash must never leave the machine permanently unable to sleep.
    public func bootstrap() throws {
        try controller.setSleepDisabled(false)
        lock.withLock { state = State() }
    }

    /// Called by the daemon timer. Public to make the safety invariant testable without sleeping.
    @discardableResult
    public func enforceWatchdog() -> Bool {
        let expired = lock.withLock {
            guard state.armed, let heartbeat = state.lastHeartbeatMonotonicNanoseconds else { return false }
            let current = monotonicNow()
            let elapsed = current >= heartbeat ? current - heartbeat : UInt64.max
            return elapsed >= UInt64(watchdogTimeout * 1_000_000_000)
        }
        guard expired else { return false }
        do {
            try restoreSleep()
            return true
        } catch {
            // Keep the real power state visible and retry on the next watchdog tick.
            return false
        }
    }

    public func restoreSleep() throws {
        try lock.withLock {
            if state.sleepDisabled { try controller.setSleepDisabled(false) }
            state = State()
        }
    }

    public func snapshot() -> HelperStatus {
        lock.withLock {
            let deadline = state.lastHeartbeatWallTime.map { $0.addingTimeInterval(watchdogTimeout) }
            return HelperStatus(
                armed: state.armed,
                sleepDisabled: state.sleepDisabled,
                lastHeartbeat: state.lastHeartbeatWallTime,
                watchdogDeadline: deadline
            )
        }
    }
}
