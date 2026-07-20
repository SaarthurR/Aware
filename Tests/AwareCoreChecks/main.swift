import AwareCore
import Darwin
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "failed" }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private final class RecordingPowerController: SleepPowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func setSleepDisabled(_ disabled: Bool) throws { lock.withLock { storage.append(disabled) } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    private var monotonicStorage: UInt64 = 0
    init(_ value: Date) { storage = value }
    var value: Date { lock.withLock { storage } }
    var nanoseconds: UInt64 { lock.withLock { monotonicStorage } }
    func advance(_ seconds: TimeInterval) { lock.withLock { storage = storage.addingTimeInterval(seconds); monotonicStorage += UInt64(seconds * 1_000_000_000) } }
}

do {
    let controller = RecordingPowerController()
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let helper = PowerHelperService(controller: controller, watchdogTimeout: 120, wallNow: { clock.value }, monotonicNow: { clock.nanoseconds })
    try helper.bootstrap()
    try check(helper.handle(HelperCommand(.arm)).ok, "arm failed")
    clock.advance(120)
    try check(helper.enforceWatchdog(), "watchdog did not expire")
    try check(controller.values == [false, true, false], "watchdog did not restore sleep")

    let rearmController = RecordingPowerController()
    let firstBoot = PowerHelperService(controller: rearmController)
    try firstBoot.bootstrap()
    try check(firstBoot.handle(HelperCommand(.arm)).ok, "initial arm failed")
    let secondBoot = PowerHelperService(controller: rearmController)
    try secondBoot.bootstrap()
    try check(secondBoot.handle(HelperCommand(.arm)).ok, "safe re-arm failed")
    try check(rearmController.values == [false, true, false, true], "re-arm did not restore sleep first")

    let rollbackController = RecordingPowerController()
    let rollbackClock = TestClock(Date(timeIntervalSince1970: 10_000))
    let rollbackHelper = PowerHelperService(controller: rollbackController, wallNow: { rollbackClock.value }, monotonicNow: { rollbackClock.nanoseconds })
    try rollbackHelper.bootstrap()
    try check(rollbackHelper.handle(HelperCommand(.arm)).ok, "rollback helper arm failed")
    rollbackClock.advance(120)
    try check(rollbackHelper.enforceWatchdog(), "monotonic watchdog was deferred")

    let policy = SafetyPolicy()
    let reserve = policy.decide(
        sample: PowerSample(source: .battery, batteryPercent: 20, thermal: .nominal),
        armed: true,
        activeLeaseDeadline: .distantFuture,
        runsUntilReserve: true
    )
    try check(reserve.state == .reserveSleep && !reserve.shouldDisableSleep, "20% reserve policy failed")
    let limited = PowerSample(source: .battery, batteryPercent: 25, thermal: .nominal)
    try check(policy.mayStart(.minutes(30), sample: limited), "30-minute limited lease refused")
    try check(!policy.mayStart(.minutes(120), sample: limited), "long limited lease accepted")
    try check(policy.mayArmSentinel(sample: PowerSample(source: .battery, batteryPercent: 21, thermal: .serious)), "safe serious-thermal sentinel was refused")
    try check(!policy.mayArmSentinel(sample: PowerSample(source: .battery, batteryPercent: 20, thermal: .nominal)), "reserve-floor sentinel was armed")
    let unknownThermal = PowerSample(source: .battery, batteryPercent: 80, thermal: .unknown)
    try check(!policy.mayStart(.minutes(30), sample: unknownThermal), "unknown thermal telemetry allowed launch")
    let batteryDay = BatteryDayPolicy(hours: 24)
    let batteryDayDeadline = batteryDay.deadline(from: clock.value)
    try check(batteryDay.shouldDisarm(deadline: batteryDayDeadline, activeLeaseDeadline: nil, runsUntilReserve: false, now: batteryDayDeadline), "battery day did not expire")
    let calibratedDeadline = batteryDay.deadline(from: clock.value, batteryPercent: 80, sleepReservePercent: 20, calibratedDrainPercentPerHour: 5)
    try check(calibratedDeadline == clock.value.addingTimeInterval(12 * 3_600), "calibrated drain did not bound Battery Day")
    let acExpiry = policy.decide(sample: PowerSample(source: .ac, batteryPercent: 100, thermal: .nominal), armed: true, activeLeaseDeadline: clock.value, runsUntilReserve: false, now: clock.value)
    try check(acExpiry.reason == .activeLeaseExpired && !acExpiry.shouldRunAllowedApps, "timed AC lease did not expire")

    var telemetry = PowerTelemetryGuard(gracePeriod: 30)
    let telemetryStart = clock.value
    _ = telemetry.resolve(PowerSample(source: .battery, batteryPercent: 70, thermal: .nominal, observedAt: telemetryStart), now: telemetryStart, monotonicNow: 1_000)
    let graceSample = telemetry.resolve(PowerSample(source: .unknown, batteryPercent: 0, thermal: .nominal, observedAt: telemetryStart.addingTimeInterval(10)), now: telemetryStart.addingTimeInterval(-10_000), monotonicNow: 29_000_001_000)
    let failedClosed = telemetry.resolve(PowerSample(source: .unknown, batteryPercent: 0, thermal: .nominal, observedAt: telemetryStart.addingTimeInterval(31)), now: telemetryStart.addingTimeInterval(-10_000), monotonicNow: 31_000_001_000)
    try check(graceSample.source == .battery && failedClosed.source == .unknown, "telemetry grace was not bounded")

    let deadlineDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: deadlineDirectory) }
    let deadlineStore = BatteryDayDeadlineStore(url: deadlineDirectory.appendingPathComponent("deadline.plist"))
    let originalDeadline = telemetryStart.addingTimeInterval(1_000)
    let createdDeadline = try deadlineStore.loadOrCreate(proposedDeadline: originalDeadline)
    let restartedDeadline = try deadlineStore.loadOrCreate(proposedDeadline: originalDeadline.addingTimeInterval(86_400))
    try check(createdDeadline == originalDeadline, "deadline store create failed")
    try check(restartedDeadline == originalDeadline, "deadline store extended after restart")

    let stateStore = GuardianStateStore(url: deadlineDirectory.appendingPathComponent("guardian-state.plist"))
    let durableState = GuardianPersistentState(
        activeDeadline: originalDeadline,
        runsUntilReserve: false,
        requestedApps: [.chatgpt],
        ownedProcesses: [OwnedAppProcessIdentity(app: .chatgpt, pid: 42, processStartedAt: telemetryStart)],
        desiredIntent: .armed,
        operationProgress: ["completed-op": .remoteReady]
    )
    try stateStore.save(durableState)
    let restoredDurableState = try stateStore.load()
    try check(restoredDurableState == durableState, "durable lease/process state did not round trip")

    let prior = OwnedAppProcessIdentity(app: .chatgpt, pid: 10, processStartedAt: telemetryStart)
    let crashLaunch = OwnedAppProcessIdentity(app: .chatgpt, pid: 11, processStartedAt: telemetryStart.addingTimeInterval(1))
    let pending = PendingLaunchTransaction(app: .chatgpt, operationID: "crash-window", activeDeadline: originalDeadline, runsUntilReserve: false, preLaunchProcesses: [prior])
    try stateStore.save(GuardianPersistentState(activeDeadline: originalDeadline, runsUntilReserve: false, requestedApps: [.chatgpt], ownedProcesses: [], pendingLaunch: pending))
    let restartedPending = try stateStore.load()?.pendingLaunch
    try check(restartedPending == pending, "pending launch was not durable before app launch")
    try check(LaunchOwnershipPolicy.ownableCompletionIdentity(crashLaunch, preLaunchProcesses: [prior]) == crashLaunch, "distinct completion identity was not ownable")
    try check(LaunchOwnershipPolicy.ownableCompletionIdentity(prior, preLaunchProcesses: [prior]) == nil, "preexisting completion identity was incorrectly owned")
    let retainedPending = try stateStore.load()?.pendingLaunch
    try check(retainedPending == pending, "ambiguous pending launch was not retained")

    let wakeJSON = #"{"type":"wake","operation_id":"op1","sequence":10,"target_request_id":"session1","apps":["chatgpt"],"duration_minutes":120,"created_at":"2026-07-19T18:00:00.123Z"}"#
    let command = try JSONDecoder.aware().decode(CloudCommand.self, from: Data(wakeJSON.utf8))
    guard case .wake(let wake) = command else { throw CheckFailure.failed("wake contract failed") }
    try check(wake.duration == .minutes(120), "wake duration failed")

    let sentinelJSON = #"{"type":"return_to_sentinel","operation_id":"op2","sequence":11,"target_request_id":"session1","requested_at":"2026-07-19T18:00:00Z","delivered_at":"2026-07-19T18:10:01Z"}"#
    let sentinelCommand = try JSONDecoder.aware().decode(CloudCommand.self, from: Data(sentinelJSON.utf8))
    guard case .returnToSentinel(let sentinelID, let sequence, let targetID, let requestedAt, let deliveredAt) = sentinelCommand else {
        throw CheckFailure.failed("return_to_sentinel contract failed")
    }
    try check(sentinelID == "op2" && sequence == 11 && targetID == "session1", "sentinel operation correlation failed")
    try check(deliveredAt.timeIntervalSince(requestedAt) == 601, "durable control did not retain requested_at")
    try check(sentinelCommand.freshnessDate == deliveredAt, "durable control freshness did not use delivered_at")
    let status = HostStatus(state: .batterySentinel, powerSource: .battery, batteryPercent: 80, thermalState: .nominal, sentinelDrainPercentPerHour: 1, estimatedReadyUntil: nil, appsStarted: [], lastSeen: clock.value, failureReason: nil)
    let report = try CloudReport.progress(operationID: "op2", sequence: 11, state: .returnedToSentinel, status: status, failureReason: nil).utf8Text()
    try check(report.contains(#""type":"operation_status""#), "operation status contract failed")
    try check(!OwnedCleanupPolicy.mayAcknowledgeSentinel(remainingOwnedProcesses: [crashLaunch]), "sentinel acknowledged an owned survivor")
    try check(OwnedCleanupPolicy.mayAcknowledgeSentinel(remainingOwnedProcesses: []), "sentinel refused after exact ownership cleared")
    let stubborn = OwnedAppProcessIdentity(app: .chatgpt, pid: 51, processStartedAt: telemetryStart)
    let replacement = OwnedAppProcessIdentity(app: .chatgpt, pid: 52, processStartedAt: telemetryStart.addingTimeInterval(1))
    let retained = OwnedProcessCollectionPolicy.retainingSurvivors(from: [stubborn], stillRunning: [stubborn])
    let appended = OwnedProcessCollectionPolicy.appending(replacement, to: retained)
    try check(appended == [stubborn, replacement], "new launch overwrote stubborn owned survivor")
    try check(OwnedProcessCollectionPolicy.retainingSurvivors(from: appended, stillRunning: []).isEmpty, "later cleanup retained exited ownership")
    var launchGate = LaunchTransactionGate()
    try check(launchGate.begin() && !launchGate.begin(), "launch transaction gate allowed reentrant mutation")
    launchGate.end()
    try check(launchGate.begin(), "launch transaction gate did not release")
    try check(GuardianLifecyclePolicy.startupIntent(hasExistingState: false, autoArm: true) == .armed, "first initialization ignored auto-arm")
    try check(GuardianLifecyclePolicy.startupIntent(hasExistingState: true, autoArm: true) == .disarmed, "restart rearmed persisted state")
    var generation = LaunchGenerationTracker()
    let capturedGeneration = generation.value
    generation.cancelAndAdvance()
    try check(!generation.isCurrent(capturedGeneration), "late launch survived cancellation generation")
    try check(LaunchTimeoutPolicy.hardLimit == 15, "launch hard timeout changed")
    var wakeGate = LaunchSupersessionModel()
    wakeGate.occupyGate(sequence: 10)
    wakeGate.acceptNewWake(sequence: 11)
    wakeGate.oldLaunchCleansAndReleases(sequence: 10)
    try check(wakeGate.launchCurrent(sequence: 11) && wakeGate.remoteReadySequence == 11 && wakeGate.exactCleanupCount == 1, "wake11 did not drain and supersede wake10")
    var monitorGate = LaunchSupersessionModel()
    monitorGate.occupyGate(sequence: 0)
    monitorGate.acceptNewWake(sequence: 12)
    monitorGate.oldLaunchCleansAndReleases(sequence: 0)
    try check(monitorGate.launchCurrent(sequence: 12), "wake12 failed behind monitor launch gate")
    try check(CommandConcurrencyPolicy.maximumInFlight == 8, "command backpressure bound changed")
    try check(!HeartbeatAuthorizationPolicy.maySend(desiredIntent: .disarmed), "disarm retained heartbeat authority")
    try check(OperationAdmissionPolicy.decide(cached: .returnedToSentinel, isFresh: false) == .replay(.returnedToSentinel), "terminal replay was rejected by age")
    try check(OperationAdmissionPolicy.decide(cached: .sentinelCleanupPending, isFresh: false) == .retryCleanup, "sentinel cleanup was not retryable")
    try check(OperationAdmissionPolicy.decide(cached: .appsStarted, isFresh: false) == .rejectStale, "intermediate progress was treated as a terminal replay")
    var wakeThenDisarm = SequencedIntentModel()
    _ = wakeThenDisarm.apply(sequence: 10, command: .wake)
    _ = wakeThenDisarm.apply(sequence: 11, command: .safety)
    var disarmThenWake = SequencedIntentModel()
    _ = disarmThenWake.apply(sequence: 11, command: .safety)
    try check(!disarmThenWake.apply(sequence: 10, command: .wake), "lower wake crossed safety sequence barrier")
    try check(wakeThenDisarm.desiredIntent == .disarmed && disarmThenWake.desiredIntent == .disarmed, "wake10/disarm11 depended on arrival order")
    var safetyThenWake = SequencedIntentModel()
    _ = safetyThenWake.apply(sequence: 11, command: .safety)
    _ = safetyThenWake.apply(sequence: 12, command: .wake)
    var wakeThenSafety = SequencedIntentModel()
    _ = wakeThenSafety.apply(sequence: 12, command: .wake)
    try check(!wakeThenSafety.apply(sequence: 11, command: .safety), "older safety cancelled newer wake")
    try check(safetyThenWake.desiredIntent == .armed && wakeThenSafety.desiredIntent == .armed, "disarm11/wake12 depended on arrival order")
    var gatedSentinel = SequencedSafetyCleanupModel()
    _ = gatedSentinel.startSafety(sequence: 10, completion: .armed)
    _ = gatedSentinel.acceptWake(sequence: 11)
    gatedSentinel.finishSafety(sequence: 10)
    try check(gatedSentinel.desiredIntent == .armed && !gatedSentinel.mayRetrySafety(sequence: 10), "sentinel10 resumed after wake11")
    var gatedDisarm = SequencedSafetyCleanupModel()
    _ = gatedDisarm.startSafety(sequence: 10, completion: .disarmed)
    _ = gatedDisarm.acceptWake(sequence: 11)
    gatedDisarm.finishSafety(sequence: 10)
    try check(gatedDisarm.desiredIntent == .armed, "disarm10 resumed after wake11")
    var overlappingSafety = SequencedSafetyCleanupModel()
    _ = overlappingSafety.startSafety(sequence: 10, completion: .disarmed)
    _ = overlappingSafety.startSafety(sequence: 11, completion: .disarmed)
    _ = overlappingSafety.acceptWake(sequence: 12)
    overlappingSafety.finishSafety(sequence: 10)
    overlappingSafety.finishSafety(sequence: 11)
    try check(overlappingSafety.desiredIntent == .armed, "overlapping safety cleanup terminated wake12")

    let secondControlJSON = #"{"type":"return_to_sentinel","operation_id":"op3","sequence":12,"target_request_id":"session1","requested_at":"2026-07-19T18:00:00Z","delivered_at":"2026-07-19T18:10:02Z"}"#
    let secondControl = try JSONDecoder.aware().decode(CloudCommand.self, from: Data(secondControlJSON.utf8))
    try check(secondControl.targetRequestID == sentinelCommand.targetRequestID && secondControl.operationID != sentinelCommand.operationID, "control dedupe identity incorrectly used target session")

    let url = URL(string: "wss://example.com/v1/host/socket?z=last&a=first")!
    let headers = try RequestSigner.headers(method: "GET", url: url, body: Data(), keyID: "v1", secret: Data(0..<32), now: Date(timeIntervalSince1970: 1_000), nonce: "abc")
    try check(headers.signature == "pQ_c3P_pDLym-KS--FgifEacPTAEfADEihqDft0XsEE", "HMAC canonical vector failed")
    let canonicalSecret = String(repeating: "A", count: 43)
    try check(CanonicalBase64URLSecret.decode(canonicalSecret)?.count == 32, "canonical 32-byte secret was rejected")
    try check(CanonicalBase64URLSecret.decode(String(repeating: "A", count: 42) + "Q")?.count == 32, "distinct canonical secret was rejected")
    try check(CanonicalBase64URLSecret.decode(String(repeating: "A", count: 45)) == nil, "mod-4==1 secret was accepted")
    try check(CanonicalBase64URLSecret.decode(canonicalSecret + "=") == nil, "padded secret was accepted")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("helper.sock").path
    let encoder = JSONEncoder.aware()
    let server = UnixSocketServer(path: path, allowedUID: geteuid()) { data in
        let request = try? JSONDecoder.aware().decode(HelperCommand.self, from: data)
        return (try? encoder.encode(HelperResponse(ok: request?.command == .status))) ?? Data()
    }
    Thread.detachNewThread { _ = try? server.run() }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { usleep(10_000) }
    defer { server.stop() }
    var info = stat()
    try check(lstat(path, &info) == 0 && info.st_mode & mode_t(0o777) == mode_t(0o600), "socket is not mode 0600")
    let response: HelperResponse = try UnixSocketClient(path: path).request(HelperCommand(.status), response: HelperResponse.self)
    try check(response.ok, "socket round trip failed")

    print("AwareCoreChecks: all 25 safety and protocol checks passed")
} catch {
    FileHandle.standardError.write(Data("AwareCoreChecks failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
