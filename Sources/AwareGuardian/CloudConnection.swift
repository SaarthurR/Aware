import AwareCore
import Foundation
import LocalAuthentication
import Security

protocol CloudCommandHandling: AnyObject, Sendable {
    func handle(_ command: CloudCommand) async
    func currentStatus() async -> HostStatus
}

enum GuardianSecret {
    static let service = "com.aware.guardian"

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func load(keyID: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: nonInteractiveContext(),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let encoded = result as? Data,
              let string = String(data: encoded, encoding: .utf8),
              let decoded = CanonicalBase64URLSecret.decode(string) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Aware HMAC secret is missing from Keychain"])
        }
        return decoded
    }

    static func storeFromStandardInput(keyID: String) throws {
        guard keyID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil,
              let secret = try FileHandle.standardInput.readToEnd(),
              let encoded = String(data: secret, encoding: .utf8),
              CanonicalBase64URLSecret.decode(encoded) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: secret,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateQuery = lookup.merging([kSecUseAuthenticationContext: nonInteractiveContext()]) { _, value in value }
        let update = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        let status = update == errSecItemNotFound
            ? SecItemAdd(lookup.merging(attributes) { _, value in value } as CFDictionary, nil)
            : update
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(keyID: String) throws {
        guard keyID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
            kSecUseAuthenticationContext: nonInteractiveContext(),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func verifyFromStandardInput(keyID: String) throws {
        guard let supplied = try FileHandle.standardInput.readToEnd(),
              let encoded = String(data: supplied, encoding: .utf8),
              let decoded = CanonicalBase64URLSecret.decode(encoded) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let stored = try load(keyID: keyID)
        guard stored.count == decoded.count else { throw CocoaError(.fileReadNoPermission) }
        var difference: UInt8 = 0
        for index in stored.indices { difference |= stored[index] ^ decoded[index] }
        guard difference == 0 else { throw CocoaError(.fileReadNoPermission) }
    }

    static func validateStandardInput() throws {
        guard let supplied = try FileHandle.standardInput.readToEnd(),
              let encoded = String(data: supplied, encoding: .utf8),
              CanonicalBase64URLSecret.decode(encoded) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

actor CloudConnection {
    private static let maximumCommandFrameBytes = 16 * 1_024
    private let configuration: GuardianConfiguration
    private let secret: Data
    private weak var handler: (any CloudCommandHandling)?
    private var socket: URLSessionWebSocketTask?

    init(configuration: GuardianConfiguration, secret: Data) {
        self.configuration = configuration
        self.secret = secret
    }

    func setHandler(_ handler: any CloudCommandHandling) {
        self.handler = handler
    }

    func connectForever() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                try await connectOnce()
                delay = .seconds(1)
            } catch {
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    func send(_ report: CloudReport) async {
        guard let socket else { return }
        do {
            try await socket.send(.string(try report.utf8Text()))
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }
    }

    private func connectOnce() async throws {
        let headers = try RequestSigner.headers(
            method: "GET",
            url: configuration.cloudSocketURL,
            body: Data(),
            keyID: configuration.keyID,
            secret: secret
        )
        var request = URLRequest(url: configuration.cloudSocketURL)
        request.setValue(headers.keyID, forHTTPHeaderField: "X-Aware-Key-Id")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Aware-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Aware-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Aware-Signature")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        if let status = await handler?.currentStatus() { await send(.hello(status)) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            defer { group.cancelAll() }
            while !Task.isCancelled {
                // Backpressure bounds retained command frames and handler tasks. A
                // safety command can still enter Guardian while an earlier launch is
                // suspended in NSWorkspace.
                if inFlight >= CommandConcurrencyPolicy.maximumInFlight {
                    _ = try await group.next()
                    inFlight -= 1
                }
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value):
                    guard value.utf8.count <= Self.maximumCommandFrameBytes else {
                        task.cancel(with: .policyViolation, reason: Data("command frame too large".utf8))
                        throw CocoaError(.fileReadTooLarge)
                    }
                    data = Data(value.utf8)
                @unknown default: continue
                }
                guard data.count <= Self.maximumCommandFrameBytes else {
                    task.cancel(with: .policyViolation, reason: Data("command frame too large".utf8))
                    throw CocoaError(.fileReadTooLarge)
                }
                let command = try JSONDecoder.aware().decode(CloudCommand.self, from: data)
                guard let handler else { continue }
                group.addTask { await handler.handle(command) }
                inFlight += 1
            }
        }
    }
}
