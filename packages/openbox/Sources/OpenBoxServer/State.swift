import Darwin
import Foundation
import OpenBoxClient
import Security

public struct OpenBoxServerConfiguration: Sendable {
    public static let version = "0.2.0"

    public var host: String
    public var port: Int
    public var stateDirectory: URL
    public var tokenFile: URL
    public var allowedEnvironmentNames: [String]
    public var maxCPUs: Int
    public var maxMemoryMB: Int
    public var defaultCPUs: Int
    public var defaultMemoryMB: Int
    public var defaultTTLSeconds: Int
    public var maxTTLSeconds: Int
    public var defaultExecTimeoutSeconds: Int
    public var maxExecTimeoutSeconds: Int
    public var outputLimitBytes: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 7070,
        stateDirectory: URL = Self.defaultStateDirectory,
        tokenFile: URL? = nil,
        allowedEnvironmentNames: [String] = [],
        maxCPUs: Int = 8,
        maxMemoryMB: Int = 8192,
        defaultCPUs: Int = 4,
        defaultMemoryMB: Int = 4096,
        defaultTTLSeconds: Int = 900,
        maxTTLSeconds: Int = 86_400,
        defaultExecTimeoutSeconds: Int = 300,
        maxExecTimeoutSeconds: Int = 3_600,
        outputLimitBytes: Int = 10 * 1024 * 1024
    ) {
        self.host = host
        self.port = port
        self.stateDirectory = stateDirectory
        self.tokenFile = tokenFile ?? stateDirectory.appendingPathComponent("token")
        self.allowedEnvironmentNames = allowedEnvironmentNames
        self.maxCPUs = maxCPUs
        self.maxMemoryMB = maxMemoryMB
        self.defaultCPUs = defaultCPUs
        self.defaultMemoryMB = defaultMemoryMB
        self.defaultTTLSeconds = defaultTTLSeconds
        self.maxTTLSeconds = maxTTLSeconds
        self.defaultExecTimeoutSeconds = defaultExecTimeoutSeconds
        self.maxExecTimeoutSeconds = maxExecTimeoutSeconds
        self.outputLimitBytes = outputLimitBytes
    }

    public static var defaultStateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenBox", isDirectory: true)
    }

    public func validate() throws {
        guard !host.isEmpty, (1...65_535).contains(port) else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_server_options", message: "invalid host or port")
        }
        guard maxCPUs > 0, maxMemoryMB > 0,
              (1...maxCPUs).contains(defaultCPUs),
              (1...maxMemoryMB).contains(defaultMemoryMB),
              defaultTTLSeconds > 0, defaultTTLSeconds <= maxTTLSeconds,
              defaultExecTimeoutSeconds > 0, defaultExecTimeoutSeconds <= maxExecTimeoutSeconds,
              outputLimitBytes > 0
        else {
            throw OpenBoxServiceError(
                .badRequest,
                code: "invalid_server_options",
                message: "invalid resource, TTL, timeout, or output limits"
            )
        }
    }
}

public struct OpenBoxServiceError: Error, CustomStringConvertible, Sendable {
    public enum Status: Int, Sendable {
        case badRequest = 400
        case unauthorized = 401
        case notFound = 404
        case conflict = 409
        case internalError = 500
        case unavailable = 503
    }

    public var status: Status
    public var code: String
    public var message: String

    public init(_ status: Status, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

public actor WorkspaceRegistry {
    private let stateDirectory: URL
    private let fileURL: URL
    private let lockURL: URL

    public init(stateDirectory: URL = OpenBoxServerConfiguration.defaultStateDirectory) throws {
        self.stateDirectory = stateDirectory
        self.fileURL = stateDirectory.appendingPathComponent("workspaces.json")
        self.lockURL = stateDirectory.appendingPathComponent("workspaces.lock")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    public func list() throws -> [WorkspaceGrant] {
        try withFileLock(lockURL) {
            try load().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public func get(id: String) throws -> WorkspaceGrant {
        guard let workspace = try list().first(where: { $0.id == id }) else {
            throw OpenBoxServiceError(.notFound, code: "workspace_not_found", message: "workspace \(id) was not found")
        }
        return workspace
    }

    @discardableResult
    public func add(path: URL, name: String?) throws -> WorkspaceGrant {
        let standardized = path.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_workspace", message: "workspace must be an existing directory")
        }
        return try withFileLock(lockURL) {
            var items = try load()
            if let existing = items.first(where: { $0.path == standardized.path(percentEncoded: false) }) {
                return existing
            }
            let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspace = WorkspaceGrant(
                id: "ws-\(UUID().uuidString.lowercased())",
                name: (displayName?.isEmpty == false ? displayName! : standardized.lastPathComponent),
                path: standardized.path(percentEncoded: false),
                createdAt: iso8601(Date())
            )
            items.append(workspace)
            try write(items)
            return workspace
        }
    }

    public func remove(id: String, activeWorkspaceIDs: Set<String> = []) throws {
        guard !activeWorkspaceIDs.contains(id) else {
            throw OpenBoxServiceError(.conflict, code: "workspace_in_use", message: "workspace \(id) has an active box")
        }
        try withFileLock(lockURL) {
            var items = try load()
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw OpenBoxServiceError(.notFound, code: "workspace_not_found", message: "workspace \(id) was not found")
            }
            items.remove(at: index)
            try write(items)
        }
    }

    private func load() throws -> [WorkspaceGrant] {
        try loadRecovering([WorkspaceGrant].self, from: fileURL) ?? []
    }

    private func write(_ value: [WorkspaceGrant]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeWithBackup(encoder.encode(value), to: fileURL)
    }
}

public enum ServerTokenStore {
    public static func loadOrCreate(at url: URL) throws -> String {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return try load(at: url)
        }
        return try rotate(at: url)
    }

    public static func load(at url: URL) throws -> String {
        let token = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw OpenBoxServiceError(.internalError, code: "invalid_token_file", message: "server token file is empty")
        }
        return token
    }

    @discardableResult
    public static func rotate(at url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenBoxServiceError(.internalError, code: "token_generation_failed", message: "could not generate server token")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try (token + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return token
    }
}

public final class ServerInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(stateDirectory: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let url = stateDirectory.appendingPathComponent("server.lock")
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw OpenBoxServiceError(.internalError, code: "server_lock_failed", message: "could not open server lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw OpenBoxServiceError(.conflict, code: "server_already_running", message: "another OpenBox server is using this state directory")
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

struct PersistedBox: Codable, Sendable {
    var box: Box
    var expiresAtEpoch: TimeInterval
    var originalWorkspacePath: String?
    var stagingWorkspacePath: String?
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func withFileLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
    let descriptor = Darwin.open(url.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw OpenBoxServiceError(.internalError, code: "state_lock_failed", message: "could not open state lock")
    }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
        throw OpenBoxServiceError(.internalError, code: "state_lock_failed", message: "could not lock state")
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
}

func loadRecovering<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    } catch {
        let backup = url.appendingPathExtension("backup")
        guard FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) else { throw error }
        let value = try JSONDecoder().decode(type, from: Data(contentsOf: backup))
        try Data(contentsOf: backup).write(to: url, options: .atomic)
        return value
    }
}

func writeWithBackup(_ data: Data, to url: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
        let backup = url.appendingPathExtension("backup")
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: url, to: backup)
    }
    try data.write(to: url, options: .atomic)
}
