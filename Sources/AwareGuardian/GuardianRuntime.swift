import AwareCore
import Dispatch
import Foundation

struct GuardianConfiguration: Decodable, Sendable {
    let cloudSocketURL: URL
    let keyID: String
    let helperSocketPath: String
    let autoArm: Bool
    let batterySentinelHours: Int
    let sentinelDrainPercentPerHour: Double?
    let iMessageAdapterEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case cloudSocketURL = "cloud_socket_url"
        case keyID = "key_id"
        case helperSocketPath = "helper_socket_path"
        case autoArm = "auto_arm"
        case batterySentinelHours = "battery_sentinel_hours"
        case sentinelDrainPercentPerHour = "sentinel_drain_percent_per_hour"
        case iMessageAdapterEnabled = "imessage_adapter_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the URL from a plain string so it round-trips through both JSONDecoder
        // and PropertyListDecoder. PropertyListDecoder decodes `URL` only from a keyed
        // {relative,base} container, which the installed plist does not use.
        let urlString = try container.decode(String.self, forKey: .cloudSocketURL)
        guard let url = URL(string: urlString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cloudSocketURL, in: container,
                debugDescription: "cloud_socket_url is not a valid URL"
            )
        }
        cloudSocketURL = url
        keyID = try container.decode(String.self, forKey: .keyID)
        helperSocketPath = try container.decode(String.self, forKey: .helperSocketPath)
        autoArm = try container.decode(Bool.self, forKey: .autoArm)
        batterySentinelHours = try container.decode(Int.self, forKey: .batterySentinelHours)
        sentinelDrainPercentPerHour = try container.decodeIfPresent(Double.self, forKey: .sentinelDrainPercentPerHour)
        iMessageAdapterEnabled = try container.decode(Bool.self, forKey: .iMessageAdapterEnabled)
    }
}

struct PowerHelperClient: Sendable {
    let socket: UnixSocketClient

    func send(_ kind: HelperCommandKind) throws -> HelperStatus {
        let response = try socket.request(HelperCommand(kind), response: HelperResponse.self)
        guard response.ok, let status = response.status else {
            throw NSError(
                domain: "com.aware.guardian.helper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.message ?? response.error?.rawValue ?? "helper failed"]
            )
        }
        return status
    }
}

actor GuardianRuntime: CloudCommandHandling {
    private enum HelperIntent { case armed, disarming, disarmed }
    private enum ExpectedLaunchCancellation: Error { case superseded }
    private struct SafetyCleanupKey: Hashable { let operationID: String; let sequence: UInt64 }

    private let configuration: GuardianConfiguration
    private let helper: PowerHelperClient
    private let powerMonitor = SystemPowerMonitor()
    private let policy = SafetyPolicy()
    private let batteryDayPolicy: BatteryDayPolicy
    private let batteryDayStore: BatteryDayDeadlineStore
    private let stateStore: GuardianStateStore
    private let appController: AllowedAppController
    private weak var cloud: CloudConnection?

    private var helperIntent: HelperIntent = .disarmed
    private var desiredIntent: GuardianDesiredIntent = .disarmed
    private var launchGeneration = LaunchGenerationTracker()
    private var helperArmed = false
    private var activeDeadline: Date?
    private var runsUntilReserve = false
    private var requestedApps = Set<AwareApp>()
    private var runningApps = Set<AwareApp>()
    private var pendingLaunch: PendingLaunchTransaction?
    private var launchTransactionGate = LaunchTransactionGate()
    private var batteryTransitionAt: Date?
    private var batteryDayDeadline: Date?
    private var lastPowerSource: PowerSource = .unknown
    private var telemetryGuard = PowerTelemetryGuard(gracePeriod: 30)
    private let startupTelemetryGraceDeadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
    private var failureReason: String?
    private var pendingDisarmRequest: (operationID: String, sequence: UInt64)?
    private var safetyCleanups = Set<SafetyCleanupKey>()
    private var operationProgress: [String: RequestProgressState] = [:]
    private var operationSequences: [String: UInt64] = [:]
    private var highestAcceptedSequence: UInt64 = 0
    private var inFlightOperationIDs = Set<String>()
    private var heartbeatTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(configuration: GuardianConfiguration, appController: AllowedAppController) {
        self.configuration = configuration
        self.helper = PowerHelperClient(socket: UnixSocketClient(path: configuration.helperSocketPath))
        self.appController = appController
        self.batteryDayPolicy = BatteryDayPolicy(hours: configuration.batterySentinelHours)
        let stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aware/battery-day.plist")
        self.batteryDayStore = BatteryDayDeadlineStore(url: stateURL)
        self.stateStore = GuardianStateStore(
            url: stateURL.deletingLastPathComponent().appendingPathComponent("guardian-state.plist")
        )
    }

    deinit {
        heartbeatTask?.cancel()
        monitorTask?.cancel()
    }

    func setCloud(_ cloud: CloudConnection) { self.cloud = cloud }

    func start() async {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.heartbeat()
            }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.monitorSafety()
            }
        }

        var isFirstInitialization = false
        do {
            if let restored = try stateStore.load() {
                await appController.restoreOwnedProcesses(restored.ownedProcesses)
                pendingLaunch = restored.pendingLaunch
                operationProgress = restored.operationProgress
                operationSequences = restored.operationSequences
                highestAcceptedSequence = restored.highestAcceptedSequence
                activeDeadline = restored.activeDeadline
                runsUntilReserve = restored.runsUntilReserve
                requestedApps = restored.requestedApps
                // A process restart is never authority to resume closed-lid operation.
                // A fresh authenticated wake must explicitly restore armed intent.
                desiredIntent = .disarmed
                helperIntent = .disarmed
                activeDeadline = nil
                runsUntilReserve = false
                requestedApps.removeAll()
                launchGeneration.cancelAndAdvance()
                try await persistOperationalState()
                do { _ = try helper.send(.disarm) } catch {
                    failureReason = "restart remains disarmed; helper watchdog restoration pending"
                }
                _ = await appController.gracefullyQuitLaunchedApps()
                try await persistOperationalState()
                guard pendingLaunch == nil else {
                    failureReason = "unresolved pending launch retained; restart remains disarmed"
                    return
                }
                return
            } else {
                isFirstInitialization = true
                desiredIntent = GuardianLifecyclePolicy.startupIntent(hasExistingState: false, autoArm: configuration.autoArm)
                helperIntent = desiredIntent == .armed ? .armed : .disarmed
                try await persistOperationalState()
            }
        } catch {
            await failClosedForDurableState("durable lease recovery failed; refusing to re-arm")
            return
        }

        guard isFirstInitialization, desiredIntent == .armed else { return }
        let sample = samplePower()
        lastPowerSource = sample.source
        guard sample.source != .unknown, sample.thermal != .unknown else {
            helperIntent = .disarmed
            desiredIntent = .disarmed
            do {
                try await persistOperationalState()
            } catch {
                await failClosedForDurableState("startup telemetry failure could not persist disarmed intent")
            }
            failureReason = "startup power or thermal telemetry unavailable; refusing to arm"
            return
        }
        do {
            try ensureHelperArmed()
            if sample.source == .battery {
                batteryTransitionAt = Date()
                establishBatteryDay(sample: sample)
            } else if sample.source == .ac {
                try? batteryDayStore.clear()
            }
            if activeDeadline != nil || runsUntilReserve {
                guard policy.mayStart(runsUntilReserve ? .reserve : .minutes(30), sample: sample) else {
                    await beginDisarm(requestID: nil, reason: "restored lease refused by current safety telemetry")
                    return
                }
                runningApps = try await launchRequestedApps(operationID: "restart-recovery", generation: launchGeneration.value)
            } else if sample.source == .ac {
                requestedApps = Set(AwareApp.allCases)
                runningApps = try await launchRequestedApps(operationID: "auto-arm", generation: launchGeneration.value)
            }
            try await persistOperationalState()
        } catch {
            await failClosedForDurableState("startup/recovery transaction failed: \(error.localizedDescription)")
        }
    }

    func handle(_ command: CloudCommand) async {
        switch command {
        case .wake(let request):
            await handleWake(request)
        case .disarm(let operationID, let sequence, _, _, _):
            guard await beginOperation(operationID, sequence: sequence, freshnessDate: command.freshnessDate, staleReason: "stale disarm delivery") else { return }
            let cleanup = SafetyCleanupKey(operationID: operationID, sequence: sequence)
            safetyCleanups.insert(cleanup)
            defer { safetyCleanups.remove(cleanup) }
            await beginDisarm(requestID: operationID, operationSequence: sequence, reason: "remote disarm requested")
        case .returnToSentinel(let operationID, let sequence, _, _, _):
            guard await beginOperation(operationID, sequence: sequence, freshnessDate: command.freshnessDate, staleReason: "stale return-to-sentinel delivery") else { return }
            let cleanup = SafetyCleanupKey(operationID: operationID, sequence: sequence)
            safetyCleanups.insert(cleanup)
            defer { safetyCleanups.remove(cleanup) }
            await returnToSentinel(requestID: operationID, sequence: sequence)
        }
    }

    func currentStatus() async -> HostStatus {
        let sample = samplePower()
        let decision = policy.decide(
            sample: sample,
            armed: helperIntent == .armed && helperArmed,
            activeLeaseDeadline: activeDeadline,
            runsUntilReserve: runsUntilReserve
        )
        return status(sample: sample, state: decision.state)
    }

    private func beginOperation(_ operationID: String, sequence: UInt64, freshnessDate: Date, staleReason: String) async -> Bool {
        if let cached = operationProgress[operationID] {
            guard operationSequences[operationID] == sequence else { return false }
            if cached.isTerminal {
                await report(operationID, cached, nil)
                return false
            }
            guard sequence == highestAcceptedSequence else {
                await report(operationID, .cancelled, "superseded by sequence \(highestAcceptedSequence)")
                return false
            }
            if cached != .sentinelCleanupPending && !isFresh(freshnessDate) {
                await report(operationID, .failed, staleReason)
                return false
            }
            guard inFlightOperationIDs.insert(operationID).inserted else { return false }
            return true
        }
        guard !operationID.isEmpty, isFresh(freshnessDate) else {
            operationSequences[operationID] = sequence
            await report(operationID, .failed, staleReason)
            return false
        }
        guard !inFlightOperationIDs.contains(operationID) else { return false }
        guard sequence > highestAcceptedSequence else {
            operationSequences[operationID] = sequence
            await report(operationID, .cancelled, "superseded by sequence \(highestAcceptedSequence)")
            return false
        }
        highestAcceptedSequence = sequence
        operationSequences[operationID] = sequence
        guard inFlightOperationIDs.insert(operationID).inserted else { return false }
        do {
            try await persistOperationalState()
        } catch {
            if !isCurrent(operationID, sequence) {
                await report(operationID, .cancelled, "superseded by a newer operation sequence")
                return false
            }
            await failClosedForDurableState("operation sequence persistence failed")
            await report(operationID, .failed, "operation sequence persistence failed")
            return false
        }
        guard isCurrent(operationID, sequence) else {
            await report(operationID, .cancelled, "superseded by a newer operation sequence")
            return false
        }
        return true
    }

    private func isCurrent(_ operationID: String, _ sequence: UInt64) -> Bool {
        highestAcceptedSequence == sequence && operationSequences[operationID] == sequence
    }

    private func waitForSafetyCleanup(operationID: String, sequence: UInt64) async -> Bool {
        while safetyCleanups.contains(where: { $0.sequence < sequence }) {
            guard isCurrent(operationID, sequence) else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isCurrent(operationID, sequence)
    }

    private func waitForSupersededLaunchDrain(operationID: String, sequence: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(LaunchTimeoutPolicy.supersessionDrainLimit))
        while launchTransactionGate.isActive || pendingLaunch != nil || safetyCleanups.contains(where: { $0.sequence < sequence }) {
            guard isCurrent(operationID, sequence), clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isCurrent(operationID, sequence)
    }

    private func cancelSuperseded(_ operationID: String) async {
        await report(operationID, .cancelled, "superseded by a newer operation")
    }

    private func handleWake(_ request: SocketWakeRequest) async {
        guard await beginOperation(request.operationID, sequence: request.sequence, freshnessDate: request.createdAt, staleReason: "stale or invalid wake operation") else { return }
        guard isCurrent(request.operationID, request.sequence) else { await cancelSuperseded(request.operationID); return }
        // Invalidate an older launch immediately. Its completion path owns exact
        // cleanup and releases the serialized launch gate; this wake waits boundedly.
        let wakeGeneration = launchGeneration.cancelAndAdvance()
        guard await waitForSupersededLaunchDrain(operationID: request.operationID, sequence: request.sequence) else {
            guard isCurrent(request.operationID, request.sequence) else { await cancelSuperseded(request.operationID); return }
            let reason = "superseded launch did not drain within \(Int(LaunchTimeoutPolicy.supersessionDrainLimit)) seconds"
            await failClosedForDurableState(reason)
            await report(request.operationID, .failed, reason)
            return
        }
        guard await waitForSafetyCleanup(operationID: request.operationID, sequence: request.sequence) else {
            await cancelSuperseded(request.operationID)
            return
        }
        guard isCurrent(request.operationID, request.sequence) else { await cancelSuperseded(request.operationID); return }
        let sample = samplePower()
        guard policy.mayStart(request.duration, sample: sample) else {
            failureReason = sample.source == .unknown
                ? "launch refused because power telemetry is unavailable"
                : (sample.thermal == .serious || sample.thermal == .critical
                    ? "launch refused by thermal safety policy"
                    : "launch refused at battery reserve")
            await report(request.operationID, sample.source == .battery && sample.batteryPercent <= policy.sleepReservePercent ? .reserveSleep : .failed, failureReason)
            return
        }

        guard isCurrent(request.operationID, request.sequence) else { await cancelSuperseded(request.operationID); return }
        desiredIntent = .armed
        helperIntent = .armed
        do {
            requestedApps = Set(request.apps)
            // Base timed leases on the immutable cloud creation time. A reconnect or
            // redelivery therefore cannot extend an already-running lease.
            activeDeadline = request.duration.deadline(from: request.createdAt)
            runsUntilReserve = request.duration == .reserve
            try await persistOperationalState()
            guard isCurrent(request.operationID, request.sequence), desiredIntent == .armed, launchGeneration.isCurrent(wakeGeneration) else { throw ExpectedLaunchCancellation.superseded }
            try ensureHelperArmed()
            if sample.source == .battery { establishBatteryDay(sample: sample) }
            failureReason = nil
            guard isCurrent(request.operationID, request.sequence) else { throw ExpectedLaunchCancellation.superseded }
            await report(request.operationID, .powerArmed, nil)
            guard isCurrent(request.operationID, request.sequence), desiredIntent == .armed, launchGeneration.isCurrent(wakeGeneration) else { throw ExpectedLaunchCancellation.superseded }

            // A newer accepted wake replaces the prior run intent. Exact ownership is
            // cleaned before the replacement launch so a superseded handler can never
            // later terminate processes belonging to this newer sequence.
            _ = await appController.gracefullyQuitLaunchedApps()
            guard isCurrent(request.operationID, request.sequence) else { throw ExpectedLaunchCancellation.superseded }
            runningApps = try await launchRequestedApps(operationID: request.operationID, sequence: request.sequence, generation: wakeGeneration)
            guard isCurrent(request.operationID, request.sequence), desiredIntent == .armed, launchGeneration.isCurrent(wakeGeneration) else { throw ExpectedLaunchCancellation.superseded }
            guard runningApps.isSuperset(of: requestedApps) else {
                let missing = requestedApps.subtracting(runningApps).map(\.rawValue).sorted().joined(separator: ", ")
                failureReason = "failed to launch: \(missing)"
                _ = await appController.gracefullyQuitLaunchedApps()
                guard isCurrent(request.operationID, request.sequence) else { throw ExpectedLaunchCancellation.superseded }
                runningApps.removeAll()
                requestedApps.removeAll()
                activeDeadline = nil
                runsUntilReserve = false
                try await persistOperationalState()
                guard isCurrent(request.operationID, request.sequence) else { throw ExpectedLaunchCancellation.superseded }
                await report(request.operationID, .failed, failureReason)
                return
            }
            guard isCurrent(request.operationID, request.sequence) else { throw ExpectedLaunchCancellation.superseded }
            await report(request.operationID, .appsStarted, nil)
            guard isCurrent(request.operationID, request.sequence), desiredIntent == .armed, launchGeneration.isCurrent(wakeGeneration) else { throw ExpectedLaunchCancellation.superseded }
            await report(request.operationID, .remoteReady, nil)
        } catch ExpectedLaunchCancellation.superseded {
            // The newer sequenced command owns desiredIntent. Clean only exact launch
            // provenance and never fail-close or overwrite that newer durable intent.
            _ = await appController.gracefullyQuitOwnedProcesses(operationID: request.operationID)
            if pendingLaunch?.operationID == request.operationID { pendingLaunch = nil }
            do { try await persistOperationalState() } catch { failureReason = "cancelled launch cleanup could not be persisted" }
            await cancelSuperseded(request.operationID)
        } catch {
            if !isCurrent(request.operationID, request.sequence) {
                _ = await appController.gracefullyQuitOwnedProcesses(operationID: request.operationID)
                await cancelSuperseded(request.operationID)
                return
            }
            let reason = "wake transaction failed: \(error.localizedDescription)"
            await failClosedForDurableState(reason)
            await report(request.operationID, .failed, reason)
        }
    }

    private func returnToSentinel(requestID: String, sequence: UInt64) async {
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        guard helperIntent != .disarming else {
            await report(requestID, .failed, "safety shutdown or disarm is still pending")
            return
        }
        let sample = samplePower()
        guard policy.mayArmSentinel(sample: sample) else {
            await beginDisarm(requestID: requestID, operationSequence: sequence, reason: "awake sentinel refused by current safety telemetry")
            guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
            let progress: RequestProgressState = sample.source == .battery && sample.batteryPercent <= policy.sleepReservePercent
                ? .reserveSleep : .failed
            await report(requestID, progress, failureReason)
            return
        }
        // Cancel run intent durably before the first await. A reentrant monitor can no
        // longer relaunch apps while cleanup is pending.
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        launchGeneration.cancelAndAdvance()
        desiredIntent = .armed
        helperIntent = .armed
        requestedApps.removeAll()
        activeDeadline = nil
        runsUntilReserve = false
        runningApps.removeAll()
        do {
            try await persistOperationalState()
        } catch {
            guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
            let reason = "sentinel intent persistence failed"
            await failClosedForDurableState(reason)
            await report(requestID, .failed, reason)
            return
        }
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        do {
            try ensureHelperArmed()
        } catch {
            let reason = "sentinel helper arm failed: \(error.localizedDescription)"
            await failClosedForDurableState(reason)
            await report(requestID, .failed, reason)
            return
        }
        let cleanupComplete = await appController.gracefullyQuitLaunchedApps()
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        let remainingOwned = await appController.ownedProcessIdentities()
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        guard pendingLaunch == nil,
              cleanupComplete,
              OwnedCleanupPolicy.mayAcknowledgeSentinel(remainingOwnedProcesses: remainingOwned) else {
            failureReason = "return to sentinel pending: an exactly-owned app refused graceful termination"
            do {
                try await persistOperationalState()
            } catch {
                guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
                await failClosedForDurableState("sentinel retry ownership persistence failed")
            }
            guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
            await report(requestID, .sentinelCleanupPending, failureReason)
            return
        }
        do {
            let verified = try helper.send(.status)
            helperArmed = verified.armed && verified.sleepDisabled
            guard desiredIntent == .armed, helperIntent == .armed, helperArmed else {
                throw CocoaError(.featureUnsupported)
            }
        } catch {
            let reason = "sentinel helper verification failed: \(error.localizedDescription)"
            await failClosedForDurableState(reason)
            await report(requestID, .failed, reason)
            return
        }
        guard isCurrent(requestID, sequence) else { await cancelSuperseded(requestID); return }
        failureReason = nil
        await report(requestID, .returnedToSentinel, nil)
    }

    private func beginDisarm(requestID: String?, operationSequence: UInt64? = nil, reason: String) async {
        if let requestID, let operationSequence, !isCurrent(requestID, operationSequence) {
            await cancelSuperseded(requestID)
            return
        }
        // Persist cancellation before touching the helper. Actor reentrancy may complete
        // an in-flight launch, but its captured generation can no longer adopt or re-arm.
        launchGeneration.cancelAndAdvance()
        desiredIntent = .disarmed
        helperIntent = .disarming
        helperArmed = false
        pendingDisarmRequest = requestID.flatMap { id in operationSequence.map { (id, $0) } }
        failureReason = reason
        activeDeadline = nil
        runsUntilReserve = false
        requestedApps.removeAll()
        runningApps.removeAll()
        do {
            try await persistOperationalState()
        } catch {
            failureReason = "durable disarm state write failed; helper disarm still pending"
        }
        if let requestID, let operationSequence, !isCurrent(requestID, operationSequence) {
            pendingDisarmRequest = nil
            await cancelSuperseded(requestID)
            return
        }
        // Sleep restoration preempts slow application cleanup.
        await attemptPendingDisarm()
        if let requestID, let operationSequence, !isCurrent(requestID, operationSequence) {
            await cancelSuperseded(requestID)
            return
        }
        _ = await appController.gracefullyQuitLaunchedApps()
        if let requestID, let operationSequence, !isCurrent(requestID, operationSequence) {
            await cancelSuperseded(requestID)
            return
        }
        do {
            try await persistOperationalState()
        } catch {
            failureReason = "exact cleanup ownership could not be persisted after disarm"
        }
    }

    private func attemptPendingDisarm() async {
        guard helperIntent == .disarming else { return }
        if let pending = pendingDisarmRequest, !isCurrent(pending.operationID, pending.sequence) {
            pendingDisarmRequest = nil
            await cancelSuperseded(pending.operationID)
            return
        }
        do {
            _ = try helper.send(.disarm)
            helperIntent = .disarmed
            helperArmed = false
            failureReason = nil
            if let pending = pendingDisarmRequest {
                pendingDisarmRequest = nil
                guard isCurrent(pending.operationID, pending.sequence) else {
                    await cancelSuperseded(pending.operationID)
                    return
                }
                await report(pending.operationID, .disarmed, nil)
            }
        } catch {
            // Monitor retries without heartbeats. The helper's own watchdog remains a
            // second independent restoration path.
            failureReason = "restoring normal sleep; helper retry pending: \(error.localizedDescription)"
        }
    }

    private func ensureHelperArmed() throws {
        guard desiredIntent == .armed, helperIntent == .armed else { return }
        let status = try helper.send(.arm)
        helperArmed = status.armed && status.sleepDisabled
        guard helperArmed else { throw CocoaError(.featureUnsupported) }
    }

    private func heartbeat() async {
        guard HeartbeatAuthorizationPolicy.maySend(desiredIntent: desiredIntent), helperIntent == .armed else { return }
        do {
            let status = try helper.send(.heartbeat)
            helperArmed = status.armed && status.sleepDisabled
        } catch {
            helperArmed = false
            failureReason = "power helper heartbeat failed; re-arm pending"
            // A restarted helper bootstraps with sleep enabled and rejects heartbeat.
            // Re-arm only while the durable intent remains armed.
            do {
                try ensureHelperArmed()
                failureReason = nil
            } catch {
                helperArmed = false
            }
        }
    }

    private func monitorSafety() async {
        if helperIntent == .disarming {
            await attemptPendingDisarm()
            return
        }

        let sample = samplePower()
        if sample.source == .unknown {
            if DispatchTime.now().uptimeNanoseconds >= startupTelemetryGraceDeadline {
                await beginDisarm(requestID: nil, reason: "power telemetry unavailable beyond 30-second grace")
            } else {
                await cloud?.send(.status(status(sample: sample, state: .offline)))
            }
            return
        }
        // Emergency power/thermal safety always preempts an active launch gate.
        if sample.thermal == .critical ||
            (sample.source == .battery && sample.batteryPercent <= policy.sleepReservePercent) {
            await beginDisarm(
                requestID: nil,
                reason: sample.thermal == .critical ? "critical thermal state" : "battery reserve reached"
            )
            return
        }
        // Non-emergency monitor mutation stays serialized with two-phase launch state.
        guard !launchTransactionGate.isActive else { return }

        if sample.source == .battery && lastPowerSource != .battery {
            batteryTransitionAt = Date()
            establishBatteryDay(sample: sample)
        } else if sample.source == .ac {
            batteryTransitionAt = nil
            batteryDayDeadline = nil
            try? batteryDayStore.clear()
        }
        lastPowerSource = sample.source

        if sample.source == .battery,
           batteryDayPolicy.shouldDisarm(
               deadline: batteryDayDeadline,
               activeLeaseDeadline: activeDeadline,
               runsUntilReserve: runsUntilReserve,
               now: Date()
           ) {
            await beginDisarm(requestID: nil, reason: "battery day expired")
            await cloud?.send(.status(status(sample: sample, state: .reserveSleep)))
            return
        }

        let decision = policy.decide(
            sample: sample,
            armed: helperIntent == .armed && helperArmed,
            activeLeaseDeadline: activeDeadline,
            runsUntilReserve: runsUntilReserve
        )
        if decision.state == .reserveSleep {
            let reason: String
            switch decision.reason {
            case .thermalSafety: reason = "critical thermal state"
            case .telemetryUnavailable: reason = "power telemetry unavailable"
            default: reason = "battery reserve reached"
            }
            await beginDisarm(requestID: nil, reason: reason)
        } else if !decision.shouldRunAllowedApps {
            let acGraceExpired = batteryTransitionAt.map { Date().timeIntervalSince($0) >= 120 } ?? true
            if decision.reason == .thermalSafety || decision.reason == .activeLeaseExpired || acGraceExpired {
                await appController.gracefullyQuitLaunchedApps()
                runningApps.removeAll()
                requestedApps.removeAll()
                activeDeadline = nil
                runsUntilReserve = false
                do {
                    try await persistOperationalState()
                } catch {
                    await failClosedForDurableState("lease-expiry state persistence failed")
                    return
                }
            }
        } else if activeDeadline != nil || runsUntilReserve {
            let observed = await appController.currentAwareApps()
            let missing = requestedApps.subtracting(observed)
            do {
                runningApps = missing.isEmpty
                    ? observed.intersection(requestedApps)
                    : try await launchRequestedApps(operationID: "monitor-relaunch", generation: launchGeneration.value)
                try await persistOperationalState()
            } catch {
                await failClosedForDurableState("monitor relaunch transaction failed: \(error.localizedDescription)")
                return
            }
        }
        await cloud?.send(.status(status(sample: sample, state: decision.state)))
    }

    private func samplePower() -> PowerSample {
        telemetryGuard.resolve(powerMonitor.sample())
    }

    private func establishBatteryDay(sample: PowerSample) {
        let proposed = batteryDayPolicy.deadline(
            from: Date(),
            batteryPercent: sample.batteryPercent,
            sleepReservePercent: policy.sleepReservePercent,
            calibratedDrainPercentPerHour: configuration.sentinelDrainPercentPerHour
        )
        do {
            batteryDayDeadline = try batteryDayStore.loadOrCreate(proposedDeadline: proposed)
        } catch {
            // A corrupt or unsafe state path must not silently renew another 24 hours.
            batteryDayDeadline = Date()
            failureReason = "battery day state unavailable; safety shutdown pending"
        }
    }

    private func status(sample: PowerSample, state: HostState) -> HostStatus {
        let battery = sample.source == .unknown ? nil : sample.batteryPercent
        var bounds = [Date]()
        if let activeDeadline { bounds.append(activeDeadline) }
        if let batteryDayDeadline, !runsUntilReserve { bounds.append(batteryDayDeadline) }
        if sample.source == .battery,
           let drain = configuration.sentinelDrainPercentPerHour, drain > 0 {
            let usable = max(0, sample.batteryPercent - policy.sleepReservePercent)
            bounds.append(Date().addingTimeInterval(Double(usable) / drain * 3_600))
        }
        return HostStatus(
            state: state,
            powerSource: sample.source,
            batteryPercent: battery,
            thermalState: sample.thermal,
            sentinelDrainPercentPerHour: configuration.sentinelDrainPercentPerHour,
            estimatedReadyUntil: bounds.min(),
            readinessEstimateQuality: configuration.sentinelDrainPercentPerHour.map { $0 > 0 } == true ? .calibrated : .bestEffort,
            appsStarted: Array(runningApps),
            lastSeen: Date(),
            failureReason: failureReason
        )
    }

    private func persistOperationalState() async throws {
        let identities = await appController.ownedProcessIdentities()
        try stateStore.save(GuardianPersistentState(
            activeDeadline: activeDeadline,
            runsUntilReserve: runsUntilReserve,
            requestedApps: requestedApps,
            ownedProcesses: identities,
            pendingLaunch: pendingLaunch,
            desiredIntent: desiredIntent,
            operationProgress: operationProgress,
            operationSequences: operationSequences,
            highestAcceptedSequence: highestAcceptedSequence
        ))
    }

    private func launchRequestedApps(operationID: String, sequence: UInt64? = nil, generation: UInt64) async throws -> Set<AwareApp> {
        guard launchTransactionGate.begin() else { throw CocoaError(.fileWriteUnknown) }
        defer { launchTransactionGate.end() }
        func hasAuthority() -> Bool { sequence.map { isCurrent(operationID, $0) } ?? true }
        var running = Set<AwareApp>()
        for app in requestedApps.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard hasAuthority(), desiredIntent == .armed, helperIntent == .armed, launchGeneration.isCurrent(generation) else {
                throw ExpectedLaunchCancellation.superseded
            }
            let before = await appController.processIdentities(for: app)
            guard hasAuthority() else { throw ExpectedLaunchCancellation.superseded }
            pendingLaunch = PendingLaunchTransaction(
                app: app,
                operationID: operationID,
                activeDeadline: activeDeadline,
                runsUntilReserve: runsUntilReserve,
                preLaunchProcesses: before
            )
            try await persistOperationalState()
            guard hasAuthority(), desiredIntent == .armed, helperIntent == .armed, launchGeneration.isCurrent(generation) else {
                throw ExpectedLaunchCancellation.superseded
            }

            guard let transaction = pendingLaunch else { throw CocoaError(.fileWriteUnknown) }
            let result = await appController.launchOne(app, preLaunchProcesses: transaction.preLaunchProcesses)
            guard hasAuthority(), desiredIntent == .armed, helperIntent == .armed, launchGeneration.isCurrent(generation) else {
                if let identity = result.ownedProcess {
                    _ = await appController.gracefullyQuitExactProcesses([identity])
                }
                pendingLaunch = nil
                try await persistOperationalState()
                throw ExpectedLaunchCancellation.superseded
            }
            guard !result.timedOut else { throw CocoaError(.fileReadUnknown) }
            if let identity = result.ownedProcess { await appController.adoptOwnedProcess(identity, operationID: operationID) }
            guard hasAuthority() else {
                _ = await appController.gracefullyQuitOwnedProcesses(operationID: operationID)
                throw ExpectedLaunchCancellation.superseded
            }
            pendingLaunch = nil
            do {
                try await persistOperationalState()
            } catch {
                _ = await appController.gracefullyQuitLaunchedApps()
                throw error
            }
            if result.running { running.insert(app) }
        }
        return running
    }

    private func failClosedForDurableState(_ reason: String) async {
        launchGeneration.cancelAndAdvance()
        desiredIntent = .disarmed
        helperIntent = .disarming
        helperArmed = false
        failureReason = reason
        activeDeadline = nil
        runsUntilReserve = false
        requestedApps.removeAll()
        runningApps.removeAll()
        // Best effort durable cancellation precedes helper action; the helper watchdog
        // remains independent if the store itself is the failing component.
        do {
            try await persistOperationalState()
        } catch {
            failureReason = "\(reason); durable disarm record could not be written"
        }
        await attemptPendingDisarm()
        _ = await appController.gracefullyQuitLaunchedApps()
        do {
            try await persistOperationalState()
        } catch {
            failureReason = "\(reason); post-cleanup ownership could not be persisted"
        }
    }

    private func report(_ operationID: String, _ state: RequestProgressState, _ reason: String?) async {
        operationProgress[operationID] = state
        if state.closesOperationAttempt {
            inFlightOperationIDs.remove(operationID)
        }
        if operationProgress.count > 128, let oldest = operationProgress.keys.sorted().first {
            operationProgress.removeValue(forKey: oldest)
            operationSequences.removeValue(forKey: oldest)
        }
        do {
            try await persistOperationalState()
        } catch {
            failureReason = "operation result cache could not be persisted"
        }
        let current = await currentStatus()
        guard let sequence = operationSequences[operationID] else { return }
        await cloud?.send(.progress(operationID: operationID, sequence: sequence, state: state, status: current, failureReason: reason))
    }

    private func isFresh(_ date: Date) -> Bool {
        abs(Date().timeIntervalSince(date)) <= 300
    }
}
