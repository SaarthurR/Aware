import Darwin
import Foundation

public final class BatteryDayDeadlineStore: @unchecked Sendable {
    private struct Record: Codable { let deadline: Date }

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// Returns the original persisted deadline. A later proposal can never extend it.
    public func loadOrCreate(proposedDeadline: Date) throws -> Date {
        try lock.withLock {
            var info = stat()
            let result = lstat(url.path, &info)
            if result == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let existing = try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
                if proposedDeadline < existing.deadline {
                    try write(Record(deadline: proposedDeadline))
                    return proposedDeadline
                }
                return existing.deadline
            }
            guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
            try write(Record(deadline: proposedDeadline))
            return proposedDeadline
        }
    }

    public func clear() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ record: Record) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
}
