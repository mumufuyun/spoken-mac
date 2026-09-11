import Foundation
import Darwin

enum ConfigurationError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        }
    }
}

/// Atomic local files; injectable to exercise failed writes without touching user settings.
struct ConfigurationFile {
    let url: URL
    var write: (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        guard rename(staged.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func local(_ name: String) -> ConfigurationFile {
        #if SPOKEN_OFFLINE_TESTS
        // A missed dependency injection must fail before accessing real user files.
        preconditionFailure("Offline tests must inject a temporary ConfigurationFile")
        #else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConfigurationFile(url: root.appendingPathComponent("Spoken/Configuration/\(name).json"))
        #endif
    }

    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func save<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), url)
    }
}
