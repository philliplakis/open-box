import Foundation
import OpenBox
import OpenBoxClient

public actor BoxManager {
    public let configuration: OpenBoxServerConfiguration
    public let workspaces: WorkspaceRegistry

    private let runtime: any ManagedContainerRuntimeProtocol
    private let workspaceRequiresStaging: @Sendable (URL) -> Bool
    private let boxesFile: URL
    private var records: [String: PersistedBox]
    private var busyBoxes: Set<String> = []
    private var reaperTask: Task<Void, Never>?

    public init(
        configuration: OpenBoxServerConfiguration,
        runtime: any ManagedContainerRuntimeProtocol = AppleContainerRuntime(),
        workspaceRequiresStaging: @escaping @Sendable (URL) -> Bool = WorkspaceFiles.requiresStaging
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.runtime = runtime
        self.workspaceRequiresStaging = workspaceRequiresStaging
        self.workspaces = try WorkspaceRegistry(stateDirectory: configuration.stateDirectory)
        self.boxesFile = configuration.stateDirectory.appendingPathComponent("boxes.json")
        try FileManager.default.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        if let items = try loadRecovering([PersistedBox].self, from: boxesFile) {
            self.records = Dictionary(uniqueKeysWithValues: items.map { ($0.box.id, $0) })
        } else {
            self.records = [:]
        }
    }

    public func start() async throws {
        try await reconcile()
        guard reaperTask == nil else { return }
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.expireBoxes()
            }
        }
    }

    public func stop() {
        reaperTask?.cancel()
        reaperTask = nil
    }

    public func listBoxes() -> [Box] {
        records.values.map(\.box).sorted { $0.createdAt < $1.createdAt }
    }

    public func getBox(id: String) throws -> Box {
        guard let record = records[id] else {
            throw OpenBoxServiceError(.notFound, code: "box_not_found", message: "box \(id) was not found")
        }
        return record.box
    }

    public func activeWorkspaceIDs() -> Set<String> {
        Set(records.values.compactMap { record in
            record.box.workspace.type == .registered ? record.box.workspace.workspaceID : nil
        })
    }

    public func create(_ request: CreateBoxRequest) async throws -> Box {
        let cpus = request.cpus ?? configuration.defaultCPUs
        let memoryMB = request.memoryMB ?? configuration.defaultMemoryMB
        let ttl = request.ttlSeconds ?? configuration.defaultTTLSeconds
        guard (1...configuration.maxCPUs).contains(cpus) else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_cpus", message: "cpus must be between 1 and \(configuration.maxCPUs)")
        }
        guard (1...configuration.maxMemoryMB).contains(memoryMB) else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_memory", message: "memory_mb must be between 1 and \(configuration.maxMemoryMB)")
        }
        try validateTTL(ttl)

        let id = "openbox-box-\(UUID().uuidString.lowercased())"
        let image = request.image?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedImage = image?.isEmpty == false ? image! : SandboxRunOptions.defaultImage
        let now = Date()
        let expires = now.addingTimeInterval(TimeInterval(ttl))

        var originalPath: String?
        var stagingPath: String?
        var mountSource: URL?
        switch request.workspace.type {
        case .ephemeral:
            guard request.workspace.workspaceID == nil else {
                throw OpenBoxServiceError(.badRequest, code: "invalid_workspace", message: "ephemeral workspace cannot include workspace_id")
            }
        case .registered:
            guard let workspaceID = request.workspace.workspaceID else {
                throw OpenBoxServiceError(.badRequest, code: "invalid_workspace", message: "registered workspace requires workspace_id")
            }
            guard !activeWorkspaceIDs().contains(workspaceID) else {
                throw OpenBoxServiceError(.conflict, code: "workspace_in_use", message: "workspace already has an active box")
            }
            let grant = try await workspaces.get(id: workspaceID)
            let original = URL(fileURLWithPath: grant.path, isDirectory: true)
            originalPath = grant.path
            if workspaceRequiresStaging(original) {
                let staging = configuration.stateDirectory
                    .appendingPathComponent("boxes", isDirectory: true)
                    .appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent("workspace", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try WorkspaceFiles.copy(from: original, to: staging)
                stagingPath = staging.path(percentEncoded: false)
                mountSource = staging
            } else {
                mountSource = original
            }
        }

        let box = Box(
            id: id,
            state: .creating,
            image: resolvedImage,
            workspace: request.workspace,
            cpus: cpus,
            memoryMB: memoryMB,
            createdAt: iso8601(now),
            expiresAt: iso8601(expires)
        )
        records[id] = PersistedBox(
            box: box,
            expiresAtEpoch: expires.timeIntervalSince1970,
            originalWorkspacePath: originalPath,
            stagingWorkspacePath: stagingPath
        )
        try persist()

        let allowedEnvironment = Dictionary(uniqueKeysWithValues: configuration.allowedEnvironmentNames.compactMap { name in
            runtime.hostEnvironment[name].map { (name, $0) }
        })
        do {
            try await runtime.create(
                ManagedContainerCreateOptions(
                    id: id,
                    image: resolvedImage,
                    cpus: cpus,
                    memoryMB: memoryMB,
                    workspaceSource: mountSource,
                    environment: allowedEnvironment
                )
            )
            records[id]?.box.state = .running
            try persist()
            return records[id]!.box
        } catch {
            records.removeValue(forKey: id)
            try? persist()
            if let stagingPath {
                try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: stagingPath).deletingLastPathComponent().path)
            }
            throw OpenBoxServiceError(.unavailable, code: "container_create_failed", message: String(describing: error))
        }
    }

    public func execute(id: String, request: ExecuteBoxRequest) async throws -> ExecuteBoxResponse {
        guard !request.command.isEmpty else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_command", message: "command cannot be empty")
        }
        let timeout = request.timeoutSeconds ?? configuration.defaultExecTimeoutSeconds
        guard (1...configuration.maxExecTimeoutSeconds).contains(timeout) else {
            throw OpenBoxServiceError(
                .badRequest,
                code: "invalid_timeout",
                message: "timeout_seconds must be between 1 and \(configuration.maxExecTimeoutSeconds)"
            )
        }
        try acquire(id: id)
        do {
            let result = try await runtime.execute(
                id: id,
                command: request.command,
                timeout: TimeInterval(timeout),
                outputLimitBytes: configuration.outputLimitBytes
            )
            if !result.timedOut {
                do {
                    try syncWorkspace(id: id)
                } catch {
                    throw OpenBoxServiceError(.internalError, code: "workspace_sync_failed", message: String(describing: error))
                }
            }
            busyBoxes.remove(id)
            await deleteIfExpired(id: id)
            return ExecuteBoxResponse(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                stdoutTruncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated
            )
        } catch let error as OpenBoxServiceError {
            busyBoxes.remove(id)
            throw error
        } catch {
            busyBoxes.remove(id)
            throw OpenBoxServiceError(.unavailable, code: "container_exec_failed", message: String(describing: error))
        }
    }

    public func openTerminal(
        id: String,
        command: [String],
        columns: Int,
        rows: Int
    ) async throws -> any ManagedTerminalSessionProtocol {
        guard !command.isEmpty,
              (1...Int(UInt16.max)).contains(columns),
              (1...Int(UInt16.max)).contains(rows)
        else {
            throw OpenBoxServiceError(.badRequest, code: "invalid_terminal_options", message: "invalid command or terminal dimensions")
        }
        try acquire(id: id)
        do {
            return try await runtime.startTerminal(id: id, command: command, columns: columns, rows: rows)
        } catch {
            busyBoxes.remove(id)
            throw OpenBoxServiceError(.unavailable, code: "terminal_start_failed", message: String(describing: error))
        }
    }

    public func finishTerminal(id: String, completed: Bool) async {
        if completed {
            do {
                try syncWorkspace(id: id)
            } catch {
                records[id]?.box.state = .failed
                try? persist()
            }
        }
        busyBoxes.remove(id)
        await deleteIfExpired(id: id)
    }

    public func extend(id: String, ttlSeconds: Int) throws -> Box {
        try validateTTL(ttlSeconds)
        guard records[id] != nil else {
            throw OpenBoxServiceError(.notFound, code: "box_not_found", message: "box \(id) was not found")
        }
        let expires = Date().addingTimeInterval(TimeInterval(ttlSeconds))
        records[id]!.expiresAtEpoch = expires.timeIntervalSince1970
        records[id]!.box.expiresAt = iso8601(expires)
        try persist()
        return records[id]!.box
    }

    public func delete(id: String) async throws {
        guard records[id] != nil else {
            throw OpenBoxServiceError(.notFound, code: "box_not_found", message: "box \(id) was not found")
        }
        guard !busyBoxes.contains(id) else {
            throw OpenBoxServiceError(.conflict, code: "box_busy", message: "box has an active command or terminal")
        }
        var synchronizationError: Error?
        do {
            try syncWorkspace(id: id)
        } catch {
            records[id]?.box.state = .failed
            try? persist()
            synchronizationError = error
        }
        do {
            try await runtime.delete(id: id)
        } catch {
            throw OpenBoxServiceError(.unavailable, code: "container_delete_failed", message: String(describing: error))
        }
        let stagingParent = records[id]?.stagingWorkspacePath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        records.removeValue(forKey: id)
        try persist()
        if synchronizationError == nil, let stagingParent {
            try? FileManager.default.removeItem(at: stagingParent)
        }
        if let synchronizationError {
            throw OpenBoxServiceError(.internalError, code: "workspace_sync_failed", message: String(describing: synchronizationError))
        }
    }

    private func acquire(id: String) throws {
        guard let record = records[id] else {
            throw OpenBoxServiceError(.notFound, code: "box_not_found", message: "box \(id) was not found")
        }
        guard record.box.state == .running else {
            throw OpenBoxServiceError(.conflict, code: "box_not_running", message: "box is not running")
        }
        guard record.expiresAtEpoch > Date().timeIntervalSince1970 else {
            throw OpenBoxServiceError(.conflict, code: "box_expired", message: "box has expired")
        }
        guard busyBoxes.insert(id).inserted else {
            throw OpenBoxServiceError(.conflict, code: "box_busy", message: "box has an active command or terminal")
        }
    }

    private func syncWorkspace(id: String) throws {
        guard let record = records[id],
              let originalPath = record.originalWorkspacePath,
              let stagingPath = record.stagingWorkspacePath
        else { return }
        try WorkspaceFiles.copy(
            from: URL(fileURLWithPath: stagingPath, isDirectory: true),
            to: URL(fileURLWithPath: originalPath, isDirectory: true)
        )
    }

    private func validateTTL(_ ttl: Int) throws {
        guard (1...configuration.maxTTLSeconds).contains(ttl) else {
            throw OpenBoxServiceError(
                .badRequest,
                code: "invalid_ttl",
                message: "ttl_seconds must be between 1 and \(configuration.maxTTLSeconds)"
            )
        }
    }

    private func reconcile() async throws {
        let runtimeIDs: Set<String>
        do {
            runtimeIDs = Set(try await runtime.managedContainerIDs())
        } catch {
            throw OpenBoxServiceError(.unavailable, code: "container_runtime_unavailable", message: String(describing: error))
        }
        let persistedIDs = Set(records.keys)
        for missing in persistedIDs.subtracting(runtimeIDs) {
            records.removeValue(forKey: missing)
        }
        for orphan in runtimeIDs.subtracting(persistedIDs) {
            try? await runtime.delete(id: orphan)
        }
        try persist()
        await expireBoxes()
    }

    private func expireBoxes() async {
        let now = Date().timeIntervalSince1970
        let expired = records.values
            .filter { $0.expiresAtEpoch <= now && !busyBoxes.contains($0.box.id) }
            .map { $0.box.id }
        for id in expired {
            try? await delete(id: id)
        }
    }

    private func deleteIfExpired(id: String) async {
        guard let record = records[id], record.expiresAtEpoch <= Date().timeIntervalSince1970 else { return }
        try? await delete(id: id)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let values = records.values.sorted { $0.box.id < $1.box.id }
        try writeWithBackup(encoder.encode(values), to: boxesFile)
    }
}
