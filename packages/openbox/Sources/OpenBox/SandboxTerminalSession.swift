import Foundation

public final class SandboxTerminalSession: @unchecked Sendable {
    public let name: String
    public let output: AsyncStream<Data>

    private let pty: PTYProcess
    private let waitTask: Task<Int32, Error>

    fileprivate init(
        name: String,
        pty: PTYProcess,
        stagedWorkspace: StagedWorkspace,
        tempDir: URL
    ) {
        self.name = name
        self.pty = pty
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
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> SandboxTerminalSession {
        try await Task.detached {
            try startSync(
                options: options,
                columns: columns,
                rows: rows,
                containerExecutable: containerExecutable,
                hostEnvironment: hostEnvironment
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
    hostEnvironment: [String: String]
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
        let tokenFile = tempDir.appendingPathComponent("tokens.yaml")
        let tokens = TokenYAML.collect(allowlist: launchOptions.environmentAllowlist, from: hostEnvironment)
        try TokenYAML.write(tokens, to: tokenFile)

        let preparedWorkspace = try WorkspaceStager.prepare(
            workspace: launchOptions.workspace,
            enabled: launchOptions.stageProtectedWorkspace
        )
        stagedWorkspace = preparedWorkspace

        let arguments = try ContainerArguments.run(
            options: launchOptions,
            name: name,
            tokenFile: tokenFile,
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
            stagedWorkspace: preparedWorkspace,
            tempDir: tempDir
        )
    } catch {
        try? stagedWorkspace?.cleanup()
        try? FileManager.default.removeItem(at: tempDir)
        throw error
    }
}
