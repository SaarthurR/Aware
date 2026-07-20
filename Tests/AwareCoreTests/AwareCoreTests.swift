import Darwin
import Foundation
import Testing
@testable import AwareCore

@Test func helperBootstrapArmHeartbeatAndWatchdogRestoreSleep() throws {
    let controller = RecordingPowerController()
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let service = PowerHelperService(
        controller: controller,
        watchdogTimeout: 120,
        wallNow: { clock.value },
        monotonicNow: { clock.nanoseconds }
    )

    try service.bootstrap()
    #expect(controller.values == [false])
    #expect(service.handle(HelperCommand(.arm)).ok)
    #expect(controller.values == [false, true])
    #expect(service.snapshot().armed)

    clock.advance(119)
    #expect(!service.enforceWatchdog())
    clock.advance(1)
    #expect(service.enforceWatchdog())
    #expect(controller.values == [false, true, false])
    #expect(!service.snapshot().armed)
    #expect(!service.snapshot().sleepDisabled)
}

@Test func watchdogIgnoresWallClockRollback() throws {
    let controller = RecordingPowerController()
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let service = PowerHelperService(controller: controller, wallNow: { clock.value }, monotonicNow: { clock.nanoseconds })
    try service.bootstrap()
    #expect(service.handle(HelperCommand(.arm)).ok)
    clock.rollWallClockBack(10_000)
    clock.advanceMonotonic(120)
    #expect(service.enforceWatchdog())
    #expect(controller.values.last == false)
}

@Test func helperRestartRestoresSleepBeforeSafeRearm() throws {
    let controller = RecordingPowerController()
    let first = PowerHelperService(controller: controller)
    try first.bootstrap()
    #expect(first.handle(HelperCommand(.arm)).ok)
    let restarted = PowerHelperService(controller: controller)
    try restarted.bootstrap()
    #expect(restarted.handle(HelperCommand(.arm)).ok)
    #expect(controller.values == [false, true, false, true])
}

@Test func heartbeatRequiresArmedHelper() {
    let service = PowerHelperService(controller: RecordingPowerController())
    let response = service.handle(HelperCommand(.heartbeat))
    #expect(!response.ok)
    #expect(response.error == .notArmed)
}

@Test func criticalThermalAndBatteryReserveAlwaysRestoreSleep() {
    let policy = SafetyPolicy()
    let critical = policy.decide(
        sample: PowerSample(source: .ac, batteryPercent: 100, thermal: .critical),
        armed: true,
        activeLeaseDeadline: Date.distantFuture,
        runsUntilReserve: true
    )
    #expect(critical.state == .reserveSleep)
    #expect(!critical.shouldDisableSleep)
    #expect(!critical.shouldRunAllowedApps)

    let reserve = policy.decide(
        sample: PowerSample(source: .battery, batteryPercent: 20, thermal: .nominal),
        armed: true,
        activeLeaseDeadline: Date.distantFuture,
        runsUntilReserve: true
    )
    #expect(reserve.state == .reserveSleep)
    #expect(reserve.reason == .batteryReserve)
}

@Test func unknownThermalTelemetryFailsClosed() {
    let policy = SafetyPolicy()
    let sample = PowerSample(source: .battery, batteryPercent: 80, thermal: .unknown)
    #expect(!policy.mayStart(.minutes(30), sample: sample))
    let decision = policy.decide(sample: sample, armed: true, activeLeaseDeadline: .distantFuture, runsUntilReserve: true)
    #expect(decision.state == .reserveSleep)
    #expect(decision.reason == .telemetryUnavailable)
}

@Test func limitedReserveRejectsLongButAllowsThirtyMinuteLease() {
    let policy = SafetyPolicy()
    let sample = PowerSample(source: .battery, batteryPercent: 25, thermal: .nominal)
    #expect(policy.mayStart(.minutes(30), sample: sample))
    #expect(!policy.mayStart(.minutes(120), sample: sample))
    #expect(!policy.mayStart(.reserve, sample: sample))
}

@Test func sentinelArmPolicyFailsClosedAtReserveAndCriticalThermal() {
    let policy = SafetyPolicy()
    #expect(policy.mayArmSentinel(sample: PowerSample(source: .battery, batteryPercent: 21, thermal: .serious)))
    #expect(!policy.mayArmSentinel(sample: PowerSample(source: .battery, batteryPercent: 20, thermal: .nominal)))
    #expect(!policy.mayArmSentinel(sample: PowerSample(source: .ac, batteryPercent: 100, thermal: .critical)))
}

@Test func batteryDayExpiresOnlyWithoutActiveLease() {
    let policy = BatteryDayPolicy(hours: 24)
    let start = Date(timeIntervalSince1970: 1_000)
    let deadline = policy.deadline(from: start)
    #expect(!policy.shouldDisarm(deadline: deadline, activeLeaseDeadline: deadline.addingTimeInterval(60), runsUntilReserve: false, now: deadline))
    #expect(!policy.shouldDisarm(deadline: deadline, activeLeaseDeadline: nil, runsUntilReserve: true, now: deadline))
    #expect(policy.shouldDisarm(deadline: deadline, activeLeaseDeadline: nil, runsUntilReserve: false, now: deadline))
}

@Test func cloudWakeContractDecodesDurationAndCreatedAt() throws {
    let json = #"{"type":"wake","operation_id":"op1","sequence":10,"target_request_id":"session1","apps":["chatgpt","cursor"],"duration_minutes":"reserve","created_at":"2026-07-19T18:00:00.123Z"}"#
    let command = try JSONDecoder.aware().decode(CloudCommand.self, from: Data(json.utf8))
    guard case .wake(let request) = command else {
        Issue.record("expected wake")
        return
    }
    #expect(request.operationID == "op1")
    #expect(request.sequence == 10)
    #expect(request.targetRequestID == "session1")
    #expect(request.apps == [.chatgpt, .cursor])
    #expect(request.duration == .reserve)
}

@Test func cloudTextFramesMatchWorkerContract() throws {
    let sentinel = #"{"type":"return_to_sentinel","operation_id":"op2","sequence":11,"target_request_id":"session1","requested_at":"2026-07-19T18:00:00Z","delivered_at":"2026-07-19T18:10:01Z"}"#
    let command = try JSONDecoder.aware().decode(CloudCommand.self, from: Data(sentinel.utf8))
    guard case .returnToSentinel(let requestID, let sequence, let targetID, let requestedAt, let deliveredAt) = command else {
        Issue.record("expected return_to_sentinel")
        return
    }
    #expect(requestID == "op2")
    #expect(sequence == 11)
    #expect(targetID == "session1")
    #expect(deliveredAt.timeIntervalSince(requestedAt) == 601)
    #expect(command.requestedAt == requestedAt)
    #expect(command.freshnessDate == deliveredAt)
    #expect(abs(Date(timeIntervalSince1970: deliveredAt.timeIntervalSince1970 + 1).timeIntervalSince(command.freshnessDate)) <= 300)
    let status = HostStatus(
        state: .batterySentinel, powerSource: .battery, batteryPercent: 80,
        thermalState: .nominal, sentinelDrainPercentPerHour: 1,
        estimatedReadyUntil: nil, appsStarted: [], lastSeen: Date(timeIntervalSince1970: 1_000), failureReason: nil
    )
    let text = try CloudReport.progress(operationID: "op2", sequence: 11, state: .returnedToSentinel, status: status, failureReason: nil).utf8Text()
    #expect(text.contains(#""type":"operation_status""#))
    #expect(text.contains(#""state":"returned_to_sentinel""#))
    #expect(text.contains(#""sequence":11"#))
    #expect(String(data: Data(text.utf8), encoding: .utf8) == text)
}

@Test func controlIdentityUsesOperationNotTargetSession() throws {
    let first = #"{"type":"disarm","operation_id":"op-a","sequence":12,"target_request_id":"session-1","requested_at":"2026-07-19T18:00:00Z","delivered_at":"2026-07-19T18:00:01Z"}"#
    let second = #"{"type":"disarm","operation_id":"op-b","sequence":13,"target_request_id":"session-1","requested_at":"2026-07-19T18:00:00Z","delivered_at":"2026-07-19T18:00:02Z"}"#
    let decoder = JSONDecoder.aware()
    let a = try decoder.decode(CloudCommand.self, from: Data(first.utf8))
    let b = try decoder.decode(CloudCommand.self, from: Data(second.utf8))
    #expect(a.targetRequestID == b.targetRequestID)
    #expect(a.operationID != b.operationID)
}

@Test func telemetryFailsClosedAfterBoundedGrace() {
    let start = Date(timeIntervalSince1970: 1_000)
    var guardrail = PowerTelemetryGuard(gracePeriod: 30)
    let valid = PowerSample(source: .battery, batteryPercent: 70, thermal: .nominal, observedAt: start)
    _ = guardrail.resolve(valid, now: start, monotonicNow: 1_000)
    #expect(guardrail.resolve(PowerSample(source: .unknown, batteryPercent: 0, thermal: .nominal, observedAt: start.addingTimeInterval(10)), now: start.addingTimeInterval(-10_000), monotonicNow: 29_000_001_000).source == .battery)
    let unavailable = guardrail.resolve(PowerSample(source: .unknown, batteryPercent: 0, thermal: .nominal, observedAt: start.addingTimeInterval(31)), now: start.addingTimeInterval(-10_000), monotonicNow: 31_000_001_000)
    #expect(unavailable.source == .unknown)
    #expect(SafetyPolicy().decide(sample: unavailable, armed: true, activeLeaseDeadline: .distantFuture, runsUntilReserve: true).state == .reserveSleep)
}

@Test func guardianStateStoreAtomicallyRoundTripsLeaseAndStableOwnership() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GuardianStateStore(url: directory.appendingPathComponent("guardian-state.plist"))
    let deadline = Date(timeIntervalSince1970: 2_000)
    let started = Date(timeIntervalSince1970: 1_900)
    let state = GuardianPersistentState(
        activeDeadline: deadline,
        runsUntilReserve: false,
        requestedApps: [.chatgpt, .amphetamine],
        ownedProcesses: [OwnedAppProcessIdentity(app: .chatgpt, pid: 42, processStartedAt: started)],
        desiredIntent: .armed,
        operationProgress: ["completed-op": .remoteReady]
    )
    try store.save(state)
    #expect(try store.load() == state)
    var info = stat()
    #expect(lstat(store.url.path, &info) == 0)
    #expect(info.st_mode & mode_t(0o077) == 0)
}

@Test func pendingLaunchCrashWindowRecoversOnlyExactNewProcess() throws {
    let before = OwnedAppProcessIdentity(app: .chatgpt, pid: 10, processStartedAt: Date(timeIntervalSince1970: 100))
    let launched = OwnedAppProcessIdentity(app: .chatgpt, pid: 11, processStartedAt: Date(timeIntervalSince1970: 101))
    let unrelated = OwnedAppProcessIdentity(app: .cursor, pid: 12, processStartedAt: Date(timeIntervalSince1970: 102))
    let pending = PendingLaunchTransaction(app: .chatgpt, operationID: "wake-1", activeDeadline: Date(timeIntervalSince1970: 200), runsUntilReserve: false, preLaunchProcesses: [before])
    #expect(LaunchOwnershipPolicy.ownableCompletionIdentity(launched, preLaunchProcesses: [before]) == launched)
    #expect(LaunchOwnershipPolicy.ownableCompletionIdentity(before, preLaunchProcesses: [before]) == nil)
    #expect(LaunchOwnershipPolicy.ownableCompletionIdentity(unrelated, preLaunchProcesses: [before]) == unrelated)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GuardianStateStore(url: directory.appendingPathComponent("guardian-state.plist"))
    try store.save(GuardianPersistentState(activeDeadline: pending.activeDeadline, runsUntilReserve: false, requestedApps: [.chatgpt], ownedProcesses: [], pendingLaunch: pending))
    #expect(try store.load()?.pendingLaunch == pending)
    #expect(try store.load()?.pendingLaunch == pending)
}

@Test func sentinelAcknowledgementRequiresNoOwnedSurvivors() {
    let survivor = OwnedAppProcessIdentity(app: .chatgpt, pid: 44, processStartedAt: Date(timeIntervalSince1970: 100))
    #expect(!OwnedCleanupPolicy.mayAcknowledgeSentinel(remainingOwnedProcesses: [survivor]))
    #expect(OwnedCleanupPolicy.mayAcknowledgeSentinel(remainingOwnedProcesses: []))
}

@Test func stubbornOldOwnershipSurvivesAppendAndLaterCleanup() {
    let old = OwnedAppProcessIdentity(app: .chatgpt, pid: 41, processStartedAt: Date(timeIntervalSince1970: 100))
    let new = OwnedAppProcessIdentity(app: .chatgpt, pid: 42, processStartedAt: Date(timeIntervalSince1970: 200))
    let retained = OwnedProcessCollectionPolicy.retainingSurvivors(from: [old], stillRunning: [old])
    let appended = OwnedProcessCollectionPolicy.appending(new, to: retained)
    #expect(appended == [old, new])
    #expect(OwnedProcessCollectionPolicy.retainingSurvivors(from: appended, stillRunning: []).isEmpty)
}

@Test func launchTransactionGateRejectsReentrantMutation() {
    var gate = LaunchTransactionGate()
    let first = gate.begin()
    let reentrant = gate.begin()
    #expect(first)
    #expect(!reentrant)
    #expect(gate.isActive)
    gate.end()
    let afterRelease = gate.begin()
    #expect(afterRelease)
}

@Test func lifecycleRestartNeverRearmsAndGenerationPreemptsLateLaunch() {
    #expect(GuardianLifecyclePolicy.startupIntent(hasExistingState: false, autoArm: true) == .armed)
    #expect(GuardianLifecyclePolicy.startupIntent(hasExistingState: true, autoArm: true) == .disarmed)
    var generation = LaunchGenerationTracker()
    let captured = generation.value
    #expect(generation.isCurrent(captured))
    generation.cancelAndAdvance()
    #expect(!generation.isCurrent(captured))
    #expect(LaunchTimeoutPolicy.hardLimit == 15)
}

@Test func remoteDisarmPreemptsLateLaunchWithoutWaitingForTimeoutBudget() async throws {
    #expect(CommandConcurrencyPolicy.maximumInFlight == 8)
    let harness = RemotePreemptionHarness()
    async let lateLaunchWasAdopted = harness.completeLaunchAfterDelay()
    let started = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(5))
    await harness.disarm()
    #expect(!(await harness.heartbeatAuthorized()))
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(1 < LaunchTimeoutPolicy.hardLimit * 4)
    #expect(!(await lateLaunchWasAdopted))
}

@Test func newerWakeDrainsOlderAndMonitorLaunchGates() {
    var wakeGate = LaunchSupersessionModel()
    wakeGate.occupyGate(sequence: 10)
    wakeGate.acceptNewWake(sequence: 11)
    wakeGate.oldLaunchCleansAndReleases(sequence: 10)
    let wakeLaunched = wakeGate.launchCurrent(sequence: 11)
    #expect(wakeLaunched)
    #expect(wakeGate.exactCleanupCount == 1)
    #expect(wakeGate.remoteReadySequence == 11)

    var monitorGate = LaunchSupersessionModel()
    monitorGate.occupyGate(sequence: 0)
    monitorGate.acceptNewWake(sequence: 12)
    monitorGate.oldLaunchCleansAndReleases(sequence: 0)
    let monitorWakeLaunched = monitorGate.launchCurrent(sequence: 12)
    #expect(monitorWakeLaunched)
    #expect(monitorGate.remoteReadySequence == 12)
    #expect(LaunchTimeoutPolicy.supersessionDrainLimit <= LaunchTimeoutPolicy.hardLimit + 3)
}

@Test func terminalReplayPrecedesFreshnessAndSentinelCleanupRetries() {
    #expect(OperationAdmissionPolicy.decide(cached: .disarmed, isFresh: false) == .replay(.disarmed))
    #expect(OperationAdmissionPolicy.decide(cached: .sentinelCleanupPending, isFresh: false) == .retryCleanup)
    #expect(OperationAdmissionPolicy.decide(cached: .appsStarted, isFresh: true) == .accept)
    #expect(OperationAdmissionPolicy.decide(cached: .appsStarted, isFresh: false) == .rejectStale)
    #expect(OperationAdmissionPolicy.decide(cached: nil, isFresh: false) == .rejectStale)
}

@Test func monotonicSequenceMakesConcurrentArrivalOrderDeterministic() {
    var wakeThenDisarm = SequencedIntentModel()
    let wake10Accepted = wakeThenDisarm.apply(sequence: 10, command: .wake)
    let disarm11Accepted = wakeThenDisarm.apply(sequence: 11, command: .safety)
    #expect(wake10Accepted && disarm11Accepted)
    var disarmThenWake = SequencedIntentModel()
    let reorderedDisarm11Accepted = disarmThenWake.apply(sequence: 11, command: .safety)
    let reorderedWake10Accepted = disarmThenWake.apply(sequence: 10, command: .wake)
    #expect(reorderedDisarm11Accepted && !reorderedWake10Accepted)
    #expect(wakeThenDisarm.desiredIntent == .disarmed)
    #expect(disarmThenWake.desiredIntent == .disarmed)

    var safetyThenNewWake = SequencedIntentModel()
    let orderedSafety11Accepted = safetyThenNewWake.apply(sequence: 11, command: .safety)
    let orderedWake12Accepted = safetyThenNewWake.apply(sequence: 12, command: .wake)
    #expect(orderedSafety11Accepted && orderedWake12Accepted)
    var newWakeThenSafety = SequencedIntentModel()
    let reorderedWake12Accepted = newWakeThenSafety.apply(sequence: 12, command: .wake)
    let reorderedSafety11Accepted = newWakeThenSafety.apply(sequence: 11, command: .safety)
    #expect(reorderedWake12Accepted && !reorderedSafety11Accepted)
    #expect(safetyThenNewWake.desiredIntent == .armed)
    #expect(newWakeThenSafety.desiredIntent == .armed)
}

@Test func safetyCleanupGatePreventsOlderSafetyFromResumingAfterWake() {
    var pendingSentinel = SequencedSafetyCleanupModel()
    let pendingStarted = pendingSentinel.startSafety(sequence: 10, completion: .armed)
    #expect(pendingStarted)
    pendingSentinel.finishSafety(sequence: 10)
    let pendingWakeAccepted = pendingSentinel.acceptWake(sequence: 11)
    #expect(pendingWakeAccepted)
    #expect(!pendingSentinel.mayRetrySafety(sequence: 10))
    #expect(pendingSentinel.desiredIntent == .armed)

    var inFlightSentinel = SequencedSafetyCleanupModel()
    let sentinelStarted = inFlightSentinel.startSafety(sequence: 10, completion: .armed)
    let sentinelWakeAccepted = inFlightSentinel.acceptWake(sequence: 11)
    #expect(sentinelStarted && sentinelWakeAccepted)
    inFlightSentinel.finishSafety(sequence: 10)
    #expect(inFlightSentinel.desiredIntent == .armed)

    var inFlightDisarm = SequencedSafetyCleanupModel()
    let disarmStarted = inFlightDisarm.startSafety(sequence: 10, completion: .disarmed)
    let disarmWakeAccepted = inFlightDisarm.acceptWake(sequence: 11)
    #expect(disarmStarted && disarmWakeAccepted)
    inFlightDisarm.finishSafety(sequence: 10)
    #expect(inFlightDisarm.desiredIntent == .armed)

    var overlappingSafety = SequencedSafetyCleanupModel()
    let disarm10 = overlappingSafety.startSafety(sequence: 10, completion: .disarmed)
    let safety11 = overlappingSafety.startSafety(sequence: 11, completion: .disarmed)
    let wake12 = overlappingSafety.acceptWake(sequence: 12)
    overlappingSafety.finishSafety(sequence: 10)
    overlappingSafety.finishSafety(sequence: 11)
    #expect(disarm10 && safety11 && wake12)
    #expect(overlappingSafety.desiredIntent == .armed)
}

@Test func legacyStateWithoutIntentMigratesDisarmed() throws {
    let plist: [String: Any] = [
        "runsUntilReserve": false,
        "requestedApps": [],
        "ownedProcesses": [],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    let state = try PropertyListDecoder().decode(GuardianPersistentState.self, from: data)
    #expect(state.desiredIntent == .disarmed)
    #expect(state.operationProgress.isEmpty)
}

@Test func durableStateFailureIsDetectableBeforeLaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    try Data().write(to: target)
    let link = directory.appendingPathComponent("guardian-state.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = GuardianStateStore(url: link)
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func acTimedLeaseExpiresAndCalibrationBoundsBatteryDay() {
    let policy = SafetyPolicy()
    let now = Date(timeIntervalSince1970: 1_000)
    let expired = policy.decide(
        sample: PowerSample(source: .ac, batteryPercent: 100, thermal: .nominal),
        armed: true, activeLeaseDeadline: now, runsUntilReserve: false, now: now
    )
    #expect(expired.reason == .activeLeaseExpired)
    #expect(!expired.shouldRunAllowedApps)
    let batteryDay = BatteryDayPolicy(hours: 24)
    let bounded = batteryDay.deadline(from: now, batteryPercent: 80, sleepReservePercent: 20, calibratedDrainPercentPerHour: 5)
    #expect(bounded == now.addingTimeInterval(12 * 3_600))
    #expect(!batteryDay.calibratedDurationIsSupported(batteryPercent: 80, sleepReservePercent: 20, calibratedDrainPercentPerHour: 5))
}

@Test func batteryDayDeadlineStoreNeverExtends() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BatteryDayDeadlineStore(url: directory.appendingPathComponent("battery-day.plist"))
    let first = Date(timeIntervalSince1970: 2_000)
    #expect(try store.loadOrCreate(proposedDeadline: first) == first)
    #expect(try store.loadOrCreate(proposedDeadline: first.addingTimeInterval(86_400)) == first)
    let earlier = first.addingTimeInterval(-60)
    #expect(try store.loadOrCreate(proposedDeadline: earlier) == earlier)
}

@Test func requestSignerMatchesCanonicalVector() throws {
    let url = try #require(URL(string: "wss://example.com/v1/host/socket?z=last&a=first"))
    let headers = try RequestSigner.headers(
        method: "GET",
        url: url,
        body: Data(),
        keyID: "v1",
        secret: Data(0..<32),
        now: Date(timeIntervalSince1970: 1_000),
        nonce: "abc"
    )
    #expect(headers.signature == "pQ_c3P_pDLym-KS--FgifEacPTAEfADEihqDft0XsEE")
}

@Test func secretValidationRequiresCanonicalBase64URLAndThirtyTwoBytes() {
    let canonical = String(repeating: "A", count: 43)
    let distinctCanonical = String(repeating: "A", count: 42) + "Q"
    #expect(CanonicalBase64URLSecret.decode(canonical)?.count == 32)
    #expect(CanonicalBase64URLSecret.decode(distinctCanonical)?.count == 32)
    #expect(CanonicalBase64URLSecret.decode(String(repeating: "A", count: 45)) == nil)
    #expect(CanonicalBase64URLSecret.decode(canonical + "=") == nil)
    #expect(CanonicalBase64URLSecret.decode(String(repeating: "B", count: 43)) == nil)
    #expect(CanonicalBase64URLSecret.decode(String(repeating: "A", count: 42)) == nil)
}

@Test func unixSocketIsMode0600AndRoundTripsJSONLine() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("helper.sock").path
    let encoder = JSONEncoder.aware()
    let server = UnixSocketServer(path: path, allowedUID: geteuid()) { data in
        let command = try? JSONDecoder.aware().decode(HelperCommand.self, from: data)
        return (try? encoder.encode(HelperResponse(ok: command?.command == .status))) ?? Data()
    }
    Thread.detachNewThread { _ = try? server.run() }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { usleep(10_000) }
    defer { server.stop() }

    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & mode_t(0o777) == mode_t(0o600))
    let response: HelperResponse = try UnixSocketClient(path: path).request(HelperCommand(.status), response: HelperResponse.self)
    #expect(response.ok)
}

private final class RecordingPowerController: SleepPowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func setSleepDisabled(_ disabled: Bool) throws { lock.withLock { storage.append(disabled) } }
}

private actor RemotePreemptionHarness {
    private var generation = LaunchGenerationTracker()
    private var desiredIntent = GuardianDesiredIntent.armed

    func completeLaunchAfterDelay() async -> Bool {
        let captured = generation.value
        try? await Task.sleep(for: .milliseconds(50))
        return desiredIntent == .armed && generation.isCurrent(captured)
    }

    func disarm() {
        generation.cancelAndAdvance()
        desiredIntent = .disarmed
    }

    func heartbeatAuthorized() -> Bool {
        HeartbeatAuthorizationPolicy.maySend(desiredIntent: desiredIntent)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    private var monotonicStorage: UInt64 = 0
    init(_ value: Date) { storage = value }
    var value: Date { lock.withLock { storage } }
    var nanoseconds: UInt64 { lock.withLock { monotonicStorage } }
    func advance(_ seconds: TimeInterval) { lock.withLock { storage = storage.addingTimeInterval(seconds); monotonicStorage += UInt64(seconds * 1_000_000_000) } }
    func advanceMonotonic(_ seconds: TimeInterval) { lock.withLock { monotonicStorage += UInt64(seconds * 1_000_000_000) } }
    func rollWallClockBack(_ seconds: TimeInterval) { lock.withLock { storage = storage.addingTimeInterval(-seconds) } }
}
