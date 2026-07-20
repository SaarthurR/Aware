import AppKit
import AwareCore
import Foundation

private let configurationURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Aware/config.plist")

do {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--setup-keychain" {
        try GuardianSecret.storeFromStandardInput(keyID: CommandLine.arguments[2])
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--delete-keychain" {
        try GuardianSecret.delete(keyID: CommandLine.arguments[2])
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-keychain" {
        try GuardianSecret.verifyFromStandardInput(keyID: CommandLine.arguments[2])
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-keychain" {
        try GuardianSecret.verifyFromStandardInput(keyID: CommandLine.arguments[2])
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--validate-secret" {
        try GuardianSecret.validateStandardInput()
        exit(EXIT_SUCCESS)
    }
    guard CommandLine.arguments.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
    let data = try Data(contentsOf: configurationURL)
    let configuration = try ConfigurationData.decode(GuardianConfiguration.self, from: data)
    guard configuration.cloudSocketURL.scheme == "wss",
          configuration.helperSocketPath.hasPrefix("/var/run/aware/"),
          (1...48).contains(configuration.batterySentinelHours),
          !configuration.iMessageAdapterEnabled else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let secret = try GuardianSecret.load(keyID: configuration.keyID)
    let appController = AllowedAppController()
    let runtime = GuardianRuntime(configuration: configuration, appController: appController)
    let cloud = CloudConnection(configuration: configuration, secret: secret)

    Task {
        await runtime.setCloud(cloud)
        await cloud.setHandler(runtime)
        await runtime.start()
        await cloud.connectForever()
    }
    RunLoop.main.run()
} catch {
    FileHandle.standardError.write(Data("AwareGuardian failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
