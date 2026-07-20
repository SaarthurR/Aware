import AppKit
import AwareCore
import Foundation

@MainActor
final class AllowedAppController {
    struct LaunchResult {
        let running: Bool
        let ownedProcess: OwnedAppProcessIdentity?
        let timedOut: Bool
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        func claim() -> Bool { lock.withLock { if completed { return false }; completed = true; return true } }
    }
    private struct Definition {
        let bundleIdentifier: String
        let url: URL
    }

    private let definitions: [AwareApp: Definition] = [
        .chatgpt: Definition(bundleIdentifier: "com.openai.codex", url: URL(fileURLWithPath: "/Applications/ChatGPT.app")),
        .claude: Definition(bundleIdentifier: "com.anthropic.claudefordesktop", url: URL(fileURLWithPath: "/Applications/Claude.app")),
        .cursor: Definition(bundleIdentifier: "com.todesktop.230313mzl4w4u92", url: URL(fileURLWithPath: "/Applications/Cursor.app")),
        .amphetamine: Definition(bundleIdentifier: "com.if.Amphetamine", url: URL(fileURLWithPath: "/Applications/Amphetamine.app")),
    ]

    private var launchedByAware = Set<OwnedAppProcessIdentity>()
    private var ownershipOperation: [OwnedAppProcessIdentity: String] = [:]

    func restoreOwnedProcesses(_ identities: [OwnedAppProcessIdentity]) {
        launchedByAware = Set(identities)
        ownershipOperation.removeAll()
    }

    func ownedProcessIdentities() -> [OwnedAppProcessIdentity] {
        launchedByAware.sorted { ($0.app.rawValue, $0.pid) < ($1.app.rawValue, $1.pid) }
    }

    func processIdentities(for app: AwareApp) -> [OwnedAppProcessIdentity] {
        guard let definition = definitions[app] else { return [] }
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.bundleIdentifier == definition.bundleIdentifier,
                  let startedAt = application.launchDate else { return nil }
            return OwnedAppProcessIdentity(app: app, pid: application.processIdentifier, processStartedAt: startedAt)
        }
    }

    func adoptOwnedProcess(_ identity: OwnedAppProcessIdentity, operationID: String) {
        launchedByAware.insert(identity)
        ownershipOperation[identity] = operationID
    }

    @discardableResult
    func gracefullyQuitOwnedProcesses(operationID: String) async -> Bool {
        let identities = launchedByAware.filter { ownershipOperation[$0] == operationID }
        let complete = await gracefullyQuitExactProcesses(Array(identities))
        for identity in identities where processIdentities(for: identity.app).contains(identity) == false {
            launchedByAware.remove(identity)
            ownershipOperation.removeValue(forKey: identity)
        }
        return complete
    }

    @discardableResult
    func gracefullyQuitExactProcesses(_ identities: [OwnedAppProcessIdentity]) async -> Bool {
        for identity in identities {
            guard let bundleIdentifier = definitions[identity.app]?.bundleIdentifier else { continue }
            _ = runningApplication(bundleIdentifier, identity: identity)?.terminate()
        }
        for _ in 0..<20 {
            let survivors = identities.filter { identity in
                guard let bundleIdentifier = definitions[identity.app]?.bundleIdentifier else { return false }
                return runningApplication(bundleIdentifier, identity: identity) != nil
            }
            if survivors.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func launchOne(_ app: AwareApp, preLaunchProcesses: [OwnedAppProcessIdentity], timeout: TimeInterval = LaunchTimeoutPolicy.hardLimit) async -> LaunchResult {
        guard let definition = definitions[app], validate(definition) else {
            return LaunchResult(running: false, ownedProcess: nil, timedOut: false)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let gate = CompletionGate()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: definition.url, configuration: configuration) { application, _ in
                let identity = application.flatMap { running -> OwnedAppProcessIdentity? in
                    guard let startedAt = running.launchDate else { return nil }
                    return OwnedAppProcessIdentity(app: app, pid: running.processIdentifier, processStartedAt: startedAt)
                }
                let owned = LaunchOwnershipPolicy.ownableCompletionIdentity(identity, preLaunchProcesses: preLaunchProcesses)
                if gate.claim() {
                    continuation.resume(returning: LaunchResult(running: application != nil, ownedProcess: owned, timedOut: false))
                } else if owned != nil {
                    // The hard timeout/cancellation won. A late, exactly-proven process
                    // is never adopted and is asked to exit immediately.
                    _ = application?.terminate()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(returning: LaunchResult(running: false, ownedProcess: nil, timedOut: true))
                }
            }
        }
    }

    @discardableResult
    func gracefullyQuitLaunchedApps() async -> Bool {
        for identity in launchedByAware {
            guard let bundleIdentifier = definitions[identity.app]?.bundleIdentifier else { continue }
            _ = runningApplication(bundleIdentifier, identity: identity)?.terminate()
        }
        // terminate() is intentionally graceful and asynchronous. Retain ownership for
        // any exact process that refuses to exit so a restart can reconcile it safely.
        for _ in 0..<20 {
            launchedByAware = launchedByAware.filter { identity in
                guard let bundleIdentifier = definitions[identity.app]?.bundleIdentifier else { return false }
                return runningApplication(bundleIdentifier, identity: identity) != nil
            }
            ownershipOperation = ownershipOperation.filter { launchedByAware.contains($0.key) }
            if launchedByAware.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return launchedByAware.isEmpty
    }

    func currentAwareApps() -> Set<AwareApp> {
        Set(definitions.compactMap { app, definition in
            runningApplication(definition.bundleIdentifier) == nil ? nil : app
        })
    }

    private func runningApplication(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func runningApplication(_ bundleIdentifier: String, identity: OwnedAppProcessIdentity) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            guard $0.processIdentifier == identity.pid,
                  $0.bundleIdentifier == bundleIdentifier,
                  let launchDate = $0.launchDate else { return false }
            // PID reuse cannot satisfy this stable process-start identity check.
            return abs(launchDate.timeIntervalSince(identity.processStartedAt)) < 0.001
        }
    }

    private func validate(_ definition: Definition) -> Bool {
        guard FileManager.default.fileExists(atPath: definition.url.path),
              let bundle = Bundle(url: definition.url) else { return false }
        return bundle.bundleIdentifier == definition.bundleIdentifier
    }

}
