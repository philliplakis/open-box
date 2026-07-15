import Foundation

public struct APIHealth: Codable, Equatable, Sendable {
    public var status: String
    public var version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}

public struct WorkspaceGrant: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var createdAt: String

    public init(id: String, name: String, path: String, createdAt: String) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path
        case createdAt = "created_at"
    }
}

public struct WorkspaceListResponse: Codable, Equatable, Sendable {
    public var workspaces: [WorkspaceGrant]

    public init(workspaces: [WorkspaceGrant]) {
        self.workspaces = workspaces
    }
}

public struct BoxWorkspace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ephemeral
        case registered
    }

    public var type: Kind
    public var workspaceID: String?

    public init(type: Kind, workspaceID: String? = nil) {
        self.type = type
        self.workspaceID = workspaceID
    }

    public static var ephemeral: BoxWorkspace {
        BoxWorkspace(type: .ephemeral)
    }

    public static func registered(_ id: String) -> BoxWorkspace {
        BoxWorkspace(type: .registered, workspaceID: id)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case workspaceID = "workspace_id"
    }
}

public enum BoxState: String, Codable, Sendable {
    case creating
    case running
    case deleting
    case failed
}

public struct Box: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var state: BoxState
    public var image: String
    public var workspace: BoxWorkspace
    public var cpus: Int
    public var memoryMB: Int
    public var createdAt: String
    public var expiresAt: String

    public init(
        id: String,
        state: BoxState,
        image: String,
        workspace: BoxWorkspace,
        cpus: Int,
        memoryMB: Int,
        createdAt: String,
        expiresAt: String
    ) {
        self.id = id
        self.state = state
        self.image = image
        self.workspace = workspace
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id, state, image, workspace, cpus
        case memoryMB = "memory_mb"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public struct BoxListResponse: Codable, Equatable, Sendable {
    public var boxes: [Box]

    public init(boxes: [Box]) {
        self.boxes = boxes
    }
}

public struct CreateBoxRequest: Codable, Equatable, Sendable {
    public var workspace: BoxWorkspace
    public var image: String?
    public var ttlSeconds: Int?
    public var cpus: Int?
    public var memoryMB: Int?

    public init(
        workspace: BoxWorkspace,
        image: String? = nil,
        ttlSeconds: Int? = nil,
        cpus: Int? = nil,
        memoryMB: Int? = nil
    ) {
        self.workspace = workspace
        self.image = image
        self.ttlSeconds = ttlSeconds
        self.cpus = cpus
        self.memoryMB = memoryMB
    }

    enum CodingKeys: String, CodingKey {
        case workspace, image, cpus
        case ttlSeconds = "ttl_seconds"
        case memoryMB = "memory_mb"
    }
}

public struct ExecuteBoxRequest: Codable, Equatable, Sendable {
    public var command: [String]
    public var timeoutSeconds: Int?

    public init(command: [String], timeoutSeconds: Int? = nil) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case command
        case timeoutSeconds = "timeout_seconds"
    }
}

public struct ExecuteBoxResponse: Codable, Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    enum CodingKeys: String, CodingKey {
        case stdout, stderr
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case stdoutTruncated = "stdout_truncated"
        case stderrTruncated = "stderr_truncated"
    }
}

public struct ExtendBoxRequest: Codable, Equatable, Sendable {
    public var ttlSeconds: Int

    public init(ttlSeconds: Int) {
        self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}

public struct TTYStartMessage: Codable, Equatable, Sendable {
    public var type = "start"
    public var command: [String]
    public var columns: Int
    public var rows: Int

    public init(command: [String] = ["bash"], columns: Int = 80, rows: Int = 24) {
        self.command = command
        self.columns = columns
        self.rows = rows
    }
}

public struct TTYResizeMessage: Codable, Equatable, Sendable {
    public var type = "resize"
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public struct TTYServerEvent: Codable, Equatable, Sendable {
    public var type: String
    public var exitCode: Int32?
    public var code: String?
    public var message: String?

    public init(type: String, exitCode: Int32? = nil, code: String? = nil, message: String? = nil) {
        self.type = type
        self.exitCode = exitCode
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case type, code, message
        case exitCode = "exit_code"
    }
}

public struct APIErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct APIErrorEnvelope: Codable, Equatable, Sendable {
    public var error: APIErrorBody

    public init(error: APIErrorBody) {
        self.error = error
    }
}
