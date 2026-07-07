import Foundation

public struct SandboxMount: Sendable, Equatable {
    public var source: URL
    public var target: String
    public var readOnly: Bool

    public init(source: URL, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    var containerArgument: String {
        var parts = [
            "type=bind",
            "source=\(source.path(percentEncoded: false))",
            "target=\(target)",
        ]
        if readOnly {
            parts.append("readonly")
        }
        return parts.joined(separator: ",")
    }
}

public struct SandboxRunOptions: Sendable, Equatable {
    public static let defaultImage = "ghcr.io/philliplakis/open-box:latest"
    public static let defaultEnvironmentAllowlist = [
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GOOGLE_API_KEY",
        "GITHUB_TOKEN",
        "GH_TOKEN",
    ]

    public var image: String
    public var name: String?
    public var workspace: URL
    public var workspaceMountPath: String
    public var cpus: Int
    public var memory: String
    public var environmentAllowlist: [String]
    public var mounts: [SandboxMount]
    public var command: [String]
    public var timeoutSeconds: TimeInterval?
    public var idleTimeoutSeconds: TimeInterval?
    public var forwardSSHAgent: Bool
    public var interactive: Bool
    public var removeWhenStopped: Bool
    public var tokenYAMLPath: String
    public var stageProtectedWorkspace: Bool

    public init(
        image: String = Self.defaultImage,
        name: String? = nil,
        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        workspaceMountPath: String = "/workspace",
        cpus: Int = 4,
        memory: String = "4G",
        environmentAllowlist: [String] = Self.defaultEnvironmentAllowlist,
        mounts: [SandboxMount] = [],
        command: [String],
        timeoutSeconds: TimeInterval? = nil,
        idleTimeoutSeconds: TimeInterval? = nil,
        forwardSSHAgent: Bool = false,
        interactive: Bool = false,
        removeWhenStopped: Bool = true,
        tokenYAMLPath: String = "/run/openbox/tokens.yaml",
        stageProtectedWorkspace: Bool = true
    ) {
        self.image = image
        self.name = name
        self.workspace = workspace
        self.workspaceMountPath = workspaceMountPath
        self.cpus = cpus
        self.memory = memory
        self.environmentAllowlist = environmentAllowlist
        self.mounts = mounts
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.forwardSSHAgent = forwardSSHAgent
        self.interactive = interactive
        self.removeWhenStopped = removeWhenStopped
        self.tokenYAMLPath = tokenYAMLPath
        self.stageProtectedWorkspace = stageProtectedWorkspace
    }

    func validate() throws {
        guard !image.isEmpty else { throw SandboxError.invalidOptions("image is required") }
        guard !command.isEmpty else { throw SandboxError.invalidOptions("command is required") }
        guard cpus > 0 else { throw SandboxError.invalidOptions("cpus must be greater than 0") }
        guard !memory.isEmpty else { throw SandboxError.invalidOptions("memory is required") }
        guard workspaceMountPath.hasPrefix("/") else {
            throw SandboxError.invalidOptions("workspace mount path must be absolute")
        }
        guard tokenYAMLPath.hasPrefix("/") else {
            throw SandboxError.invalidOptions("token YAML path must be absolute")
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw SandboxError.invalidOptions("timeout must be greater than 0")
        }
        if let idleTimeoutSeconds, idleTimeoutSeconds <= 0 {
            throw SandboxError.invalidOptions("idle timeout must be greater than 0")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspace.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SandboxError.invalidOptions("workspace does not exist or is not a directory")
        }
        for key in environmentAllowlist {
            guard TokenYAML.isValidEnvironmentKey(key) else {
                throw SandboxError.invalidOptions("invalid environment key: \(key)")
            }
        }
        for mount in mounts {
            guard mount.target.hasPrefix("/") else {
                throw SandboxError.invalidOptions("mount target must be absolute: \(mount.target)")
            }
            guard !mount.source.path(percentEncoded: false).contains(","),
                  !mount.target.contains(",")
            else {
                throw SandboxError.invalidOptions("mount paths cannot contain commas")
            }
        }
    }
}

public struct SandboxResult: Sendable, Equatable {
    public var name: String
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var idleTimedOut: Bool

    public var succeeded: Bool {
        exitCode == 0 && !timedOut && !idleTimedOut
    }
}

public struct SandboxStatus: Sendable, Equatable {
    public var name: String
    public var description: String
}

public enum SandboxError: Error, CustomStringConvertible, Equatable {
    case invalidOptions(String)
    case commandFailed([String], Int32, String)
    case timeout(String)

    public var description: String {
        switch self {
        case .invalidOptions(let message):
            message
        case .commandFailed(let command, let code, let stderr):
            "\(command.joined(separator: " ")) failed with exit code \(code): \(stderr)"
        case .timeout(let message):
            message
        }
    }
}

public struct SandboxRunner: Sendable {
    public var containerExecutable: String
    public var hostEnvironment: [String: String]
    public var streamOutput: Bool

    public init(
        containerExecutable: String = "container",
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        streamOutput: Bool = false
    ) {
        self.containerExecutable = containerExecutable
        self.hostEnvironment = hostEnvironment
        self.streamOutput = streamOutput
    }

    public func run(options: SandboxRunOptions) async throws -> SandboxResult {
        try await Task.detached {
            try self.runSync(options: options)
        }.value
    }

    public func stop(name: String) async throws {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["stop", name],
                environment: self.hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: self.streamOutput,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(["container", "stop", name], result.exitCode, result.stderr)
            }
        }.value
    }

    public func status(name: String) async throws -> SandboxStatus {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["inspect", name],
                environment: self.hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(["container", "inspect", name], result.exitCode, result.stderr)
            }
            return SandboxStatus(name: name, description: result.stdout)
        }.value
    }

    public func cleanCache() async throws {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["prune"],
                environment: self.hostEnvironment,
                timeout: 120,
                idleTimeout: nil,
                streamOutput: self.streamOutput,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(["container", "prune"], result.exitCode, result.stderr)
            }
        }.value
    }

    private func runSync(options: SandboxRunOptions) throws -> SandboxResult {
        try options.validate()

        let name = options.name ?? "openbox-\(UUID().uuidString.lowercased())"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tokenFile = tempDir.appendingPathComponent("tokens.yaml")
        let tokens = TokenYAML.collect(allowlist: options.environmentAllowlist, from: hostEnvironment)
        try TokenYAML.write(tokens, to: tokenFile)

        let stagedWorkspace = try WorkspaceStager.prepare(
            workspace: options.workspace,
            enabled: options.stageProtectedWorkspace
        )
        defer { try? stagedWorkspace.cleanup() }

        let arguments = try ContainerArguments.run(
            options: options,
            name: name,
            tokenFile: tokenFile,
            workspaceSource: stagedWorkspace.mountSource
        )
        let result = try ProcessRunner.run(
            executable: containerExecutable,
            arguments: arguments,
            environment: hostEnvironment,
            timeout: options.timeoutSeconds,
            idleTimeout: options.idleTimeoutSeconds,
            streamOutput: streamOutput,
            interactive: options.interactive
        )

        if result.timedOut || result.idleTimedOut {
            _ = try? ProcessRunner.run(
                executable: containerExecutable,
                arguments: ["stop", name],
                environment: hostEnvironment,
                timeout: 15,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
        }

        if !result.timedOut && !result.idleTimedOut {
            try stagedWorkspace.syncBack()
        }

        return SandboxResult(
            name: name,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut,
            idleTimedOut: result.idleTimedOut
        )
    }
}

enum ContainerArguments {
    static func run(
        options: SandboxRunOptions,
        name: String,
        tokenFile: URL,
        workspaceSource: URL? = nil
    ) throws -> [String] {
        try options.validate()

        var arguments = [
            "run",
            "--name", name,
            "--cpus", String(options.cpus),
            "--memory", options.memory,
            "--mount", SandboxMount(
                source: workspaceSource ?? options.workspace,
                target: options.workspaceMountPath
            ).containerArgument,
            "--mount", SandboxMount(
                source: tokenFile.deletingLastPathComponent(),
                target: tokenMountPath(for: options.tokenYAMLPath),
                readOnly: true
            ).containerArgument,
            "--workdir", options.workspaceMountPath,
            "--env", "OPENBOX_TOKENS_YAML=\(options.tokenYAMLPath)",
            "--env", "IS_SANDBOX=1",
        ]

        if options.removeWhenStopped {
            arguments.append("--rm")
        }
        if options.forwardSSHAgent {
            arguments.append("--ssh")
        }
        if options.interactive {
            arguments.append(contentsOf: ["--interactive", "--tty"])
        }
        for mount in options.mounts {
            arguments.append(contentsOf: ["--mount", mount.containerArgument])
        }
        arguments.append(options.image)
        arguments.append(contentsOf: options.command)
        return arguments
    }

    private static func tokenMountPath(for tokenYAMLPath: String) -> String {
        let parent = NSString(string: tokenYAMLPath).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

struct StagedWorkspace {
    var original: URL
    var mountSource: URL
    var stagingRoot: URL?

    func syncBack() throws {
        guard stagingRoot != nil else { return }
        try WorkspaceStager.rsync(from: mountSource, to: original)
    }

    func cleanup() throws {
        if let stagingRoot {
            try FileManager.default.removeItem(at: stagingRoot)
        }
    }
}

enum WorkspaceStager {
    static func prepare(workspace: URL, enabled: Bool) throws -> StagedWorkspace {
        let original = workspace.standardizedFileURL
        guard enabled, shouldStage(original) else {
            return StagedWorkspace(original: original, mountSource: original, stagingRoot: nil)
        }

        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("openbox-\(UUID().uuidString)", isDirectory: true)
        let staged = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try rsync(from: original, to: staged)
        return StagedWorkspace(original: original, mountSource: staged, stagingRoot: root)
    }

    static func shouldStage(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let home = stripTrailingSlash(FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .path(percentEncoded: false))
        let protectedRoots = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Library/Mobile Documents",
        ]
        return protectedRoots.contains { root in
            path == root || path.hasPrefix("\(root)/")
        }
    }

    static func rsync(from source: URL, to destination: URL) throws {
        let sourcePath = source.path(percentEncoded: false)
        let destinationPath = destination.path(percentEncoded: false)
        let result = try ProcessRunner.run(
            executable: "/usr/bin/rsync",
            arguments: ["-a", trailingSlash(sourcePath), trailingSlash(destinationPath)],
            environment: ProcessInfo.processInfo.environment,
            timeout: nil,
            idleTimeout: nil,
            streamOutput: false,
            interactive: false
        )
        guard result.exitCode == 0 else {
            throw SandboxError.commandFailed(["rsync", sourcePath, destinationPath], result.exitCode, result.stderr)
        }
    }

    private static func trailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : "\(path)/"
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

enum TokenYAML {
    static func collect(allowlist: [String], from environment: [String: String]) -> [String: String] {
        var tokens: [String: String] = [:]
        for key in allowlist where isValidEnvironmentKey(key) {
            if let value = environment[key], !value.isEmpty {
                tokens[key] = value
            }
        }
        return tokens
    }

    static func write(_ tokens: [String: String], to url: URL) throws {
        let rendered = render(tokens)
        try rendered.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    static func render(_ tokens: [String: String]) -> String {
        var lines = ["tokens:"]
        for key in tokens.keys.sorted() {
            lines.append("  \(key): \(quote(tokens[key] ?? ""))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else {
            return false
        }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
