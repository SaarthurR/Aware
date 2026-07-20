import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible, Sendable {
    case invalidPath
    case systemCall(String, Int32)
    case peerRejected(uid_t)
    case requestTooLarge
    case disconnected

    public var description: String {
        switch self {
        case .invalidPath: "Unix socket path is too long or invalid"
        case .systemCall(let call, let error): "\(call) failed: \(String(cString: strerror(error)))"
        case .peerRejected(let uid): "Peer UID \(uid) is not authorized"
        case .requestTooLarge: "Request exceeds the 4096-byte limit"
        case .disconnected: "Peer disconnected before sending a complete line"
        }
    }
}

private let maximumLineBytes = 4_096

private func makeAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !pathBytes.isEmpty, pathBytes.count < capacity else { throw UnixSocketError.invalidPath }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        rawBuffer.copyBytes(from: pathBytes)
    }
    return (address, socklen_t(MemoryLayout<sockaddr_un>.size))
}

private func checkedSocket() throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
    var noSignal: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
        let savedError = errno
        Darwin.close(descriptor)
        throw UnixSocketError.systemCall("setsockopt", savedError)
    }
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        let savedError = errno
        Darwin.close(descriptor)
        throw UnixSocketError.systemCall("fcntl", savedError)
    }
    return descriptor
}

private func sendAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < rawBuffer.count {
            let result = Darwin.send(descriptor, base.advanced(by: sent), rawBuffer.count - sent, 0)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw UnixSocketError.systemCall("send", errno) }
            sent += result
        }
    }
}

private func receiveLine(from descriptor: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count <= maximumLineBytes {
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else {
            if count == 0 { throw UnixSocketError.disconnected }
            throw UnixSocketError.systemCall("recv", errno)
        }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    throw UnixSocketError.requestTooLarge
}

public final class UnixSocketClient: @unchecked Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func request<Request: Encodable, Response: Decodable>(
        _ request: Request,
        response: Response.Type,
        encoder: JSONEncoder = .aware(),
        decoder: JSONDecoder = .aware()
    ) throws -> Response {
        let descriptor = try checkedSocket()
        defer { Darwin.close(descriptor) }
        var (address, length) = try makeAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw UnixSocketError.systemCall("connect", errno) }
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try sendAll(payload, to: descriptor)
        return try decoder.decode(Response.self, from: receiveLine(from: descriptor))
    }
}

/// A local, line-delimited JSON transport. Socket ownership plus `getpeereid` provide
/// independent filesystem and kernel-verified peer checks.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data

    private let path: String
    private let allowedUID: uid_t
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(path: String, allowedUID: uid_t, handler: @escaping Handler) {
        self.path = path
        self.allowedUID = allowedUID
        self.handler = handler
    }

    deinit { stop() }

    public func run() throws -> Never {
        let descriptor = try prepareListener()
        lock.withLock { listener = descriptor }
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 && errno == EINTR { continue }
            guard client >= 0 else { throw UnixSocketError.systemCall("accept", errno) }
            autoreleasepool { serve(client) }
        }
    }

    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            let current = listener
            listener = -1
            return current
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
        unlink(path)
    }

    private func prepareListener() throws -> Int32 {
        let descriptor = try checkedSocket()
        do {
            unlink(path)
            var (address, length) = try makeAddress(path: path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard bindResult == 0 else { throw UnixSocketError.systemCall("bind", errno) }
            guard Darwin.chown(path, allowedUID, gid_t.max) == 0 else { throw UnixSocketError.systemCall("chown", errno) }
            guard Darwin.chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw UnixSocketError.systemCall("chmod", errno) }
            guard Darwin.listen(descriptor, 8) == 0 else { throw UnixSocketError.systemCall("listen", errno) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            unlink(path)
            throw error
        }
    }

    private func serve(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == allowedUID else { return }
        do {
            var response = handler(try receiveLine(from: descriptor))
            response.append(0x0A)
            try sendAll(response, to: descriptor)
        } catch {
            // Protocol and transport failures intentionally disclose nothing to an invalid client.
        }
    }
}
