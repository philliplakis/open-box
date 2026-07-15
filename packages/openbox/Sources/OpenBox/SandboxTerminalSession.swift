import Foundation

public final class SandboxTerminalSession: @unchecked Sendable {
    public let name: String
    public let output: AsyncStream<Data>

    private let pty: PTYProcess
    private let containerExecutable: String
    private let hostEnvironment: [String: String]
    private let waitTask: Task<Int32, Error>

    fileprivate init(
        name: String,
        pty: PTYProcess,
        containerExecutable: String,
        hostEnvironment: [String: String],
        stagedWorkspace: StagedWorkspace,
        tempDir: URL
    ) {
        self.name = name
        self.pty = pty
        self.containerExecutable = containerExecutable
        self.hostEnvironment = hostEnvironment
        self.output = pty.output
        self.waitTask = Task {
            defer {
                try? stagedWorkspace.cleanup()
                try? FileManager.default.removeItem(at: tempDir)
            }
            let exitCode = try await pty.wait()
            try stagedWorkspace.syncBack()
            return exitCode
        }
    }

    public static func start(
        options: SandboxRunOptions,
        columns: Int = 80,
        rows: Int = 24,
        containerExecutable: String = "container",
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        eventHandler: (@Sendable (SandboxEvent) -> Void)? = nil
    ) async throws -> SandboxTerminalSession {
        try await Task.detached {
            try startSync(
                options: options,
                columns: columns,
                rows: rows,
                containerExecutable: containerExecutable,
                hostEnvironment: hostEnvironment,
                eventHandler: eventHandler
            )
        }.value
    }

    public func write(_ data: Data) throws {
        try pty.write(data)
    }

    public func resize(columns: Int, rows: Int) throws {
        try pty.resize(columns: columns, rows: rows)
    }

    public func terminate() {
        pty.terminate()
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

    @discardableResult
    public func wait() async throws -> Int32 {
        try await waitTask.value
    }
}

private func startSync(
    options: SandboxRunOptions,
    columns: Int,
    rows: Int,
    containerExecutable: String,
    hostEnvironment: [String: String],
    eventHandler: (@Sendable (SandboxEvent) -> Void)?
) throws -> SandboxTerminalSession {
    var launchOptions = options
    launchOptions.interactive = true
    launchOptions.timeoutSeconds = nil
    launchOptions.idleTimeoutSeconds = nil
    try launchOptions.validate()

    let name = launchOptions.name ?? "openbox-\(UUID().uuidString.lowercased())"
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("openbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    var stagedWorkspace: StagedWorkspace?
    do {
        let tokens = TokenYAML.collect(allowlist: launchOptions.environmentAllowlist, from: hostEnvironment)
        let tokenFile: URL?
        if tokens.isEmpty {
            tokenFile = nil
        } else {
            let file = tempDir.appendingPathComponent("tokens.yaml")
            try TokenYAML.write(tokens, to: file)
            tokenFile = file
        }

        let preparedWorkspace = try WorkspaceStager.prepare(
            workspace: launchOptions.workspace,
            enabled: launchOptions.stageProtectedWorkspace
        )
        stagedWorkspace = preparedWorkspace

        try pullImageIfNeeded(
            launchOptions.image,
            containerExecutable: containerExecutable,
            environment: hostEnvironment,
            streamOutput: false,
            eventHandler: eventHandler
        )

        let arguments = try ContainerArguments.run(
            options: launchOptions,
            name: name,
            tokenFile: tokenFile,
            tokenEnvironment: tokens,
            workspaceSource: preparedWorkspace.mountSource
        )
        let pty = try PTYProcess.start(
            executable: containerExecutable,
            arguments: arguments,
            environment: hostEnvironment,
            columns: columns,
            rows: rows
        )
        return SandboxTerminalSession(
            name: name,
            pty: pty,
            containerExecutable: containerExecutable,
            hostEnvironment: hostEnvironment,
            stagedWorkspace: preparedWorkspace,
            tempDir: tempDir
        )
    } catch {
        try? stagedWorkspace?.cleanup()
        try? FileManager.default.removeItem(at: tempDir)
        throw error
    }
}
