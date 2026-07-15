import Foundation

public protocol ManagedTerminalSessionProtocol: Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) throws
    func resize(columns: Int, rows: Int) throws
    func terminate()
    func wait() async throws -> Int32
}

public protocol ManagedContainerRuntimeProtocol: Sendable {
    var hostEnvironment: [String: String] { get }
    func create(_ options: ManagedContainerCreateOptions) async throws
    func execute(id: String, command: [String], timeout: TimeInterval, outputLimitBytes: Int) async throws -> ManagedCommandResult
    func startTerminal(id: String, command: [String], columns: Int, rows: Int) async throws -> any ManagedTerminalSessionProtocol
    func delete(id: String) async throws
    func inspect(id: String) async throws -> String
    func managedContainerIDs() async throws -> [String]
}

public struct ManagedContainerCreateOptions: Sendable, Equatable {
    public var id: String
    public var image: String
    public var cpus: Int
    public var memoryMB: Int
    public var workspaceSource: URL?
    public var environment: [String: String]

    public init(
        id: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        workspaceSource: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.image = image
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.workspaceSource = workspaceSource
        self.environment = environment
    }
}

public struct ManagedCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public struct AppleContainerRuntime: ManagedContainerRuntimeProtocol, Sendable {
    public var containerExecutable: String
    public var hostEnvironment: [String: String]

    public init(
        containerExecutable: String = "container",
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.containerExecutable = containerExecutable
        self.hostEnvironment = hostEnvironment
    }

    public func create(_ options: ManagedContainerCreateOptions) async throws {
        try await Task.detached {
            try self.createSync(options)
        }.value
    }

    public func execute(
        id: String,
        command: [String],
        timeout: TimeInterval,
        outputLimitBytes: Int
    ) async throws -> ManagedCommandResult {
        try await Task.detached {
            guard !command.isEmpty else {
                throw SandboxError.invalidOptions("command is required")
            }
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["exec", "--workdir", "/workspace", id] + command,
                environment: self.hostEnvironment,
                timeout: timeout,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false,
                outputLimitBytes: outputLimitBytes
            )
            return ManagedCommandResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                timedOut: result.timedOut,
                stdoutTruncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated
            )
        }.value
    }

    public func startTerminal(
        id: String,
        command: [String],
        columns: Int,
        rows: Int
    ) async throws -> any ManagedTerminalSessionProtocol {
        try await Task.detached {
            guard !command.isEmpty else {
                throw SandboxError.invalidOptions("terminal command is required")
            }
            let pty = try PTYProcess.start(
                executable: self.containerExecutable,
                arguments: ["exec", "--interactive", "--tty", "--workdir", "/workspace", id] + command,
                environment: self.hostEnvironment,
                columns: columns,
                rows: rows
            )
            return ManagedTerminalSession(pty: pty)
        }.value
    }

    public func delete(id: String) async throws {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["delete", "--force", id],
                environment: self.hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(
                    ["container", "delete", "--force", id],
                    result.exitCode,
                    result.stderr
                )
            }
        }.value
    }

    public func inspect(id: String) async throws -> String {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["inspect", id],
                environment: self.hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(["container", "inspect", id], result.exitCode, result.stderr)
            }
            return result.stdout
        }.value
    }

    public func managedContainerIDs() async throws -> [String] {
        try await Task.detached {
            let result = try ProcessRunner.run(
                executable: self.containerExecutable,
                arguments: ["list", "--all", "--format", "json"],
                environment: self.hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
            guard result.exitCode == 0 else {
                throw SandboxError.commandFailed(
                    ["container", "list", "--all", "--format", "json"],
                    result.exitCode,
                    result.stderr
                )
            }
            guard let data = result.stdout.data(using: .utf8),
                  let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw SandboxError.invalidOptions("container list returned invalid JSON")
            }
            return items.compactMap { item in
                let configuration = item["configuration"] as? [String: Any]
                let id = (configuration?["id"] as? String) ?? (item["id"] as? String)
                let rawLabels = (configuration?["labels"] as? [String: Any]) ?? (item["labels"] as? [String: Any])
                let isManaged = (rawLabels?["openbox.managed"] as? String) == "true"
                guard let id, id.hasPrefix("openbox-box-"), isManaged else { return nil }
                return id
            }
        }.value
    }

    private func createSync(_ options: ManagedContainerCreateOptions) throws {
        guard options.id.hasPrefix("openbox-box-"), options.cpus > 0, options.memoryMB > 0 else {
            throw SandboxError.invalidOptions("invalid managed container options")
        }
        try pullImageIfNeeded(
            options.image,
            containerExecutable: containerExecutable,
            environment: hostEnvironment,
            streamOutput: false,
            eventHandler: nil
        )

        var arguments = [
            "run", "--detach", "--init",
            "--name", options.id,
            "--cpus", String(options.cpus),
            "--memory", "\(options.memoryMB)M",
            "--label", "openbox.managed=true",
            "--label", "openbox.box-id=\(options.id)",
            "--workdir", "/",
        ]
        if let workspaceSource = options.workspaceSource {
            arguments.append(contentsOf: [
                "--mount",
                SandboxMount(source: workspaceSource, target: "/workspace").containerArgument,
            ])
        }
        for key in options.environment.keys.sorted() {
            arguments.append(contentsOf: ["--env", "\(key)=\(options.environment[key] ?? "")"])
        }
        arguments.append(options.image)
        arguments.append(contentsOf: [
            "/bin/sh", "-lc",
            "mkdir -p /workspace && trap 'exit 0' TERM INT; while :; do sleep 3600; done",
        ])

        let result = try ProcessRunner.run(
            executable: containerExecutable,
            arguments: arguments,
            environment: hostEnvironment,
            timeout: 120,
            idleTimeout: nil,
            streamOutput: false,
            interactive: false
        )
        guard result.exitCode == 0 else {
            throw SandboxError.commandFailed(["container"] + arguments, result.exitCode, result.stderr)
        }

        let running = try ProcessRunner.run(
            executable: containerExecutable,
            arguments: ["list", "--quiet"],
            environment: hostEnvironment,
            timeout: 30,
            idleTimeout: nil,
            streamOutput: false,
            interactive: false
        )
        let runningIDs = Set(running.stdout.split(whereSeparator: \.isNewline).map(String.init))
        guard running.exitCode == 0, runningIDs.contains(options.id) else {
            _ = try? ProcessRunner.run(
                executable: containerExecutable,
                arguments: ["delete", "--force", options.id],
                environment: hostEnvironment,
                timeout: 30,
                idleTimeout: nil,
                streamOutput: false,
                interactive: false
            )
            throw SandboxError.commandFailed(
                ["container", "run", options.id],
                running.exitCode == 0 ? 1 : running.exitCode,
                "container init exited immediately"
            )
        }
    }
}

public final class ManagedTerminalSession: ManagedTerminalSessionProtocol, @unchecked Sendable {
    public let output: AsyncStream<Data>
    private let pty: PTYProcess

    fileprivate init(pty: PTYProcess) {
        self.pty = pty
        self.output = pty.output
    }

    public func write(_ data: Data) throws {
        try pty.write(data)
    }

    public func resize(columns: Int, rows: Int) throws {
        try pty.resize(columns: columns, rows: rows)
    }

    public func terminate() {
        pty.terminate()
    }

    public func wait() async throws -> Int32 {
        try await pty.wait()
    }
}
