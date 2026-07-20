import AwareCore
import Darwin
import Dispatch
import Foundation

private struct HelperConfiguration: Decodable {
    let socketPath: String
    let allowedUID: uid_t
    let watchdogSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
        case allowedUID = "allowed_uid"
        case watchdogSeconds = "watchdog_seconds"
    }
}

private let configurationPath = "/Library/Application Support/Aware/helper.plist"

private func loadConfiguration() throws -> HelperConfiguration {
    let attributes = try FileManager.default.attributesOfItem(atPath: configurationPath)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0 else {
        throw CocoaError(.fileReadNoPermission)
    }
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
    guard permissions & 0o022 == 0 else { throw CocoaError(.fileReadNoPermission) }
    let configuration = try ConfigurationData.decode(
        HelperConfiguration.self,
        from: Data(contentsOf: URL(fileURLWithPath: configurationPath))
    )
    guard configuration.socketPath.hasPrefix("/var/run/aware/"),
          configuration.allowedUID >= 500,
          configuration.watchdogSeconds == 120 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return configuration
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("AwarePowerHelper must run as root\n".utf8))
    exit(EXIT_FAILURE)
}

do {
    // This fixed recovery action must precede every fallible configuration read. A
    // corrupt/missing plist after a crash must never strand disablesleep at 1.
    let controller = PMSetController()
    try controller.setSleepDisabled(false)
    let configuration = try loadConfiguration()
    let service = PowerHelperService(
        controller: controller,
        watchdogTimeout: configuration.watchdogSeconds
    )
    try service.bootstrap()
    let encoder = JSONEncoder.aware()
    let decoder = JSONDecoder.aware()
    let server = UnixSocketServer(path: configuration.socketPath, allowedUID: configuration.allowedUID) { data in
        guard let command = try? decoder.decode(HelperCommand.self, from: data) else {
            return (try? encoder.encode(HelperResponse(ok: false, error: .invalidRequest, message: "invalid command"))) ?? Data()
        }
        return (try? encoder.encode(service.handle(command))) ?? Data()
    }

    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.aware.power-helper.watchdog"))
    // A sub-second cadence keeps enforcement at the configured 120-second ceiling in
    // practice. Expiry itself is measured with DispatchTime's monotonic clock.
    watchdog.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(10))
    watchdog.setEventHandler { _ = service.enforceWatchdog() }
    watchdog.resume()

    for signalNumber in [SIGTERM, SIGINT] { signal(signalNumber, SIG_IGN) }
    let signalQueue = DispatchQueue(label: "com.aware.power-helper.signals")
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    for source in [termination, interrupt] {
        source.setEventHandler {
            try? service.restoreSleep()
            server.stop()
            exit(EXIT_SUCCESS)
        }
        source.resume()
    }

    try server.run()
} catch {
    FileHandle.standardError.write(Data("AwarePowerHelper failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
