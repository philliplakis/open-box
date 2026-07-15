@testable import OpenBox
@testable import OpenBoxServer
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSTesting
import OpenBoxClient
import XCTest

final class OpenBoxServerTests: XCTestCase {
    func testStartupMessageUsesOpenBoxBrand() {
        XCTAssertEqual(
            OpenBoxHTTPServer.startupMessage(host: "127.0.0.1", port: 7070, color: false),
            "OpenBox ready  http://127.0.0.1:7070  ·  bearer auth required\n"
        )
    }

    func testManagedLifecycleAndResourceBounds() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let runtime = FakeRuntime(state: state)
        var configuration = OpenBoxServerConfiguration(stateDirectory: stateURL, maxCPUs: 2, maxMemoryMB: 1024)
        configuration.defaultCPUs = 1
        configuration.defaultMemoryMB = 512
        let manager = try BoxManager(configuration: configuration, runtime: runtime)
        try await manager.start()
        defer { Task { await manager.stop() } }

        let box = try await manager.create(.init(workspace: .ephemeral, ttlSeconds: 30, cpus: 2, memoryMB: 1024))
        XCTAssertEqual(box.state, .running)
        XCTAssertTrue(box.id.hasPrefix("openbox-box-"))
        let created = await state.lastCreate
        XCTAssertEqual(created?.cpus, 2)
        XCTAssertEqual(created?.memoryMB, 1024)
        XCTAssertEqual(created?.environment, [:])

        let result = try await manager.execute(id: box.id, request: .init(command: ["echo", "hello"]))
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.exitCode, 0)

        let extended = try await manager.extend(id: box.id, ttlSeconds: 60)
        XCTAssertNotEqual(extended.expiresAt, box.expiresAt)
        try await manager.delete(id: box.id)
        let deleted = await state.deleted
        XCTAssertTrue(deleted.contains(box.id))

        do {
            _ = try await manager.create(.init(workspace: .ephemeral, cpus: 3))
            XCTFail("expected resource validation to fail")
        } catch let error as OpenBoxServiceError {
            XCTAssertEqual(error.code, "invalid_cpus")
        }
    }

    func testReconciliationRemovesMissingRecordsAndOrphans() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let manager = try BoxManager(configuration: .init(stateDirectory: stateURL), runtime: FakeRuntime(state: state))
        let box = try await manager.create(.init(workspace: .ephemeral, ttlSeconds: 30))
        await state.removeContainer(box.id)
        await state.addContainer("openbox-box-orphan")

        let restarted = try BoxManager(configuration: .init(stateDirectory: stateURL), runtime: FakeRuntime(state: state))
        try await restarted.start()
        await restarted.stop()
        let boxes = await restarted.listBoxes()
        let deleted = await state.deleted
        XCTAssertTrue(boxes.isEmpty)
        XCTAssertTrue(deleted.contains("openbox-box-orphan"))
    }

    func testHTTPAuthenticationErrorsAndLifecycle() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let manager = try BoxManager(configuration: .init(stateDirectory: stateURL), runtime: FakeRuntime(state: state))
        let router = OpenBoxHTTPServer.makeHTTPRouter(manager: manager, token: "test-token")
        let app = Application(router: router)
        let auth: HTTPFields = [.authorization: "Bearer test-token"]

        try await app.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let health = try JSONDecoder().decode(APIHealth.self, from: Data(buffer: response.body))
                XCTAssertEqual(health.version, "0.2.0")
            }
            try await client.execute(uri: "/v1/boxes", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(buffer: response.body))
                XCTAssertEqual(envelope.error.code, "unauthorized")
            }
            try await client.execute(
                uri: "/v1/boxes",
                method: .post,
                headers: auth,
                body: ByteBuffer(string: #"{"workspace":{"type":"ephemeral"}}"#)
            ) { response in
                XCTAssertEqual(response.status, .created)
                let box = try JSONDecoder().decode(Box.self, from: Data(buffer: response.body))
                XCTAssertEqual(box.state, .running)
            }
            try await client.execute(
                uri: "/v1/boxes",
                method: .post,
                headers: auth,
                body: ByteBuffer(string: "not-json")
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(uri: "/v1/boxes/missing", method: .get, headers: auth) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testWebSocketAuthenticationTerminalIOResizeAndExit() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let terminal = FakeTerminal()
        let runtime = FakeRuntime(state: state, terminal: terminal)
        let manager = try BoxManager(configuration: .init(stateDirectory: stateURL), runtime: runtime)
        let box = try await manager.create(.init(workspace: .ephemeral, ttlSeconds: 30))
        let httpRouter = OpenBoxHTTPServer.makeHTTPRouter(manager: manager, token: "test-token")
        let webSocketRouter = OpenBoxHTTPServer.makeWebSocketRouter(manager: manager, token: "test-token")
        let app = Application(
            router: httpRouter,
            server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )

        try await app.test(.live) { client in
            do {
                try await client.ws("/v1/boxes/\(box.id)/tty") { _, _, _ in }
                XCTFail("unauthenticated WebSocket should not upgrade")
            } catch {}

            try await client.ws(
                "/v1/boxes/\(box.id)/tty",
                configuration: .init(additionalHeaders: [.authorization: "Bearer test-token"])
            ) { inbound, outbound, _ in
                let start = try JSONEncoder().encode(TTYStartMessage(command: ["/bin/sh"], columns: 80, rows: 24))
                try await outbound.write(.text(String(decoding: start, as: UTF8.self)))
                try await outbound.write(.binary(ByteBuffer(string: "hello")))
                var iterator = inbound.messages(maxSize: 1024).makeAsyncIterator()
                guard case .binary(let echoed)? = try await iterator.next() else {
                    return XCTFail("expected terminal bytes")
                }
                XCTAssertEqual(String(buffer: echoed), "hello")

                let resize = try JSONEncoder().encode(TTYResizeMessage(columns: 120, rows: 40))
                try await outbound.write(.text(String(decoding: resize, as: UTF8.self)))
                try await outbound.write(.binary(ByteBuffer(string: "exit\n")))
                guard case .text(let eventJSON)? = try await iterator.next() else {
                    return XCTFail("expected exit event")
                }
                let event = try JSONDecoder().decode(TTYServerEvent.self, from: Data(eventJSON.utf8))
                XCTAssertEqual(event.type, "exit")
                XCTAssertEqual(event.exitCode, 7)
            }
        }
        let resize = terminal.lastResize
        XCTAssertEqual(resize?.columns, 120)
        XCTAssertEqual(resize?.rows, 40)
    }

    func testFoundationSwiftClientLifecycleAgainstLiveServer() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let manager = try BoxManager(configuration: .init(stateDirectory: stateURL), runtime: FakeRuntime(state: state))
        let app = Application(
            router: OpenBoxHTTPServer.makeHTTPRouter(manager: manager, token: "client-token"),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )

        try await app.test(.live) { testClient in
            guard let port = testClient.port else { return XCTFail("expected a live server port") }
            let client = OpenBoxClient(
                baseURL: URL(string: "http://localhost:\(port)")!,
                token: "client-token"
            )
            let health = try await client.health()
            let workspaces = try await client.listWorkspaces()
            XCTAssertEqual(health.version, "0.2.0")
            XCTAssertTrue(workspaces.isEmpty)
            let box = try await client.createBox(.init(workspace: .ephemeral, ttlSeconds: 30))
            let inspected = try await client.getBox(id: box.id)
            let listed = try await client.listBoxes()
            XCTAssertEqual(inspected.id, box.id)
            XCTAssertEqual(listed.map(\.id), [box.id])
            let execution = try await client.execute(id: box.id, request: .init(command: ["echo", "hello"]))
            XCTAssertEqual(execution.stdout, "hello\n")
            _ = try await client.extend(id: box.id, ttlSeconds: 60)
            try await client.deleteBox(id: box.id)
            let remaining = try await client.listBoxes()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testOnlyOneActiveSessionPerBox() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let terminal = FakeTerminal()
        let manager = try BoxManager(
            configuration: .init(stateDirectory: stateURL),
            runtime: FakeRuntime(state: state, terminal: terminal)
        )
        let box = try await manager.create(.init(workspace: .ephemeral, ttlSeconds: 30))
        _ = try await manager.openTerminal(id: box.id, command: ["/bin/sh"], columns: 80, rows: 24)
        do {
            _ = try await manager.execute(id: box.id, request: .init(command: ["true"]))
            XCTFail("expected busy conflict")
        } catch let error as OpenBoxServiceError {
            XCTAssertEqual(error.code, "box_busy")
        }
        terminal.terminate()
        await manager.finishTerminal(id: box.id, completed: false)
    }

    func testTTLExpiryContinuesAcrossManagerRestart() async throws {
        let stateURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        var configuration = OpenBoxServerConfiguration(stateDirectory: stateURL)
        configuration.defaultTTLSeconds = 1
        let first = try BoxManager(configuration: configuration, runtime: FakeRuntime(state: state))
        let box = try await first.create(.init(workspace: .ephemeral, ttlSeconds: 1))
        let restarted = try BoxManager(configuration: configuration, runtime: FakeRuntime(state: state))
        try await restarted.start()
        try await Task.sleep(for: .seconds(6))
        await restarted.stop()
        let boxes = await restarted.listBoxes()
        let deleted = await state.deleted
        XCTAssertTrue(boxes.isEmpty)
        XCTAssertTrue(deleted.contains(box.id))
    }

    func testStagedWorkspaceSyncsNonzeroExitButNotTimeout() async throws {
        let stateURL = temporaryDirectory()
        let source = stateURL.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: source.appendingPathComponent("value.txt"))
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let state = FakeRuntimeState()
        let configuration = OpenBoxServerConfiguration(stateDirectory: stateURL)
        let manager = try BoxManager(
            configuration: configuration,
            runtime: FakeRuntime(state: state),
            workspaceRequiresStaging: { _ in true }
        )
        let grant = try await manager.workspaces.add(path: source, name: "Source")
        let box = try await manager.create(.init(workspace: .registered(grant.id), ttlSeconds: 30))
        guard let staging = await state.lastCreate?.workspaceSource else {
            return XCTFail("expected durable staging workspace")
        }

        try Data("nonzero".utf8).write(to: staging.appendingPathComponent("value.txt"))
        await state.setExecuteResult(.init(
            exitCode: 2,
            stdout: "",
            stderr: "failed",
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        ))
        let nonzero = try await manager.execute(id: box.id, request: .init(command: ["false"]))
        XCTAssertEqual(nonzero.exitCode, 2)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("value.txt"), encoding: .utf8), "nonzero")

        try Data("timed-out".utf8).write(to: staging.appendingPathComponent("value.txt"))
        await state.setExecuteResult(.init(
            exitCode: 143,
            stdout: "",
            stderr: "",
            timedOut: true,
            stdoutTruncated: false,
            stderrTruncated: false
        ))
        _ = try await manager.execute(id: box.id, request: .init(command: ["sleep", "10"]))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("value.txt"), encoding: .utf8), "nonzero")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        try FileManager.default.removeItem(at: source)
        try Data("not-a-directory".utf8).write(to: source)
        do {
            try await manager.delete(id: box.id)
            XCTFail("expected final synchronization to fail")
        } catch let error as OpenBoxServiceError {
            XCTAssertEqual(error.code, "workspace_sync_failed")
        }
        let deleted = await state.deleted
        XCTAssertTrue(deleted.contains(box.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testWorkspaceRegistryRecoveryAndExclusiveUse() async throws {
        let stateURL = temporaryDirectory()
        let workspaceURL = stateURL.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let registry = try WorkspaceRegistry(stateDirectory: stateURL)
        let grant = try await registry.add(path: workspaceURL, name: "Source")
        _ = try await registry.add(path: workspaceURL, name: "Duplicate")
        let deduplicated = try await registry.list()
        XCTAssertEqual(deduplicated.count, 1)

        let workspaceFile = stateURL.appendingPathComponent("workspaces.json")
        try await registry.add(path: stateURL, name: "Root")
        try Data("corrupt".utf8).write(to: workspaceFile)
        let recovered = try await registry.list()
        XCTAssertFalse(recovered.isEmpty)

        do {
            try await registry.remove(id: grant.id, activeWorkspaceIDs: [grant.id])
            XCTFail("expected active workspace removal to fail")
        } catch let error as OpenBoxServiceError {
            XCTAssertEqual(error.code, "workspace_in_use")
        }
    }

    func testProcessRunnerCapsEachOutputStream() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 1234567890; printf abcdefghij >&2"],
            environment: [:],
            timeout: 2,
            idleTimeout: nil,
            streamOutput: false,
            interactive: false,
            outputLimitBytes: 5
        )
        XCTAssertEqual(result.stdout.utf8.count, 5)
        XCTAssertEqual(result.stderr.utf8.count, 5)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testServerTokenIs256BitsAndPrivate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token")
        let first = try ServerTokenStore.loadOrCreate(at: file)
        let second = try ServerTokenStore.rotate(at: file)
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 43)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testAppleRuntimeUsesManagedLabelsAndResourceLimits() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("container")
        let record = directory.appendingPathComponent("record")
        try """
        #!/bin/sh
        echo "$*" >> "$RECORD"
        if [ "$1 $2" = "image inspect" ]; then exit 0; fi
        if [ "$1" = "run" ]; then exit 0; fi
        if [ "$1 $2" = "list --quiet" ]; then echo openbox-box-test; exit 0; fi
        exit 2
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runtime = AppleContainerRuntime(
            containerExecutable: executable.path,
            hostEnvironment: ["RECORD": record.path]
        )
        try await runtime.create(.init(
            id: "openbox-box-test",
            image: "example/image:latest",
            cpus: 3,
            memoryMB: 2048,
            environment: ["ALLOWED": "value"]
        ))
        let calls = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(calls.contains("run --detach --init"))
        XCTAssertTrue(calls.contains("--cpus 3"))
        XCTAssertTrue(calls.contains("--memory 2048M"))
        XCTAssertTrue(calls.contains("--label openbox.managed=true"))
        XCTAssertTrue(calls.contains("--label openbox.box-id=openbox-box-test"))
        XCTAssertTrue(calls.contains("--env ALLOWED=value"))
    }

    func testAppleRuntimeOnlyDiscoversLabeledManagedContainers() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("container")
        try """
        #!/bin/sh
        printf '%s' '[{"configuration":{"id":"openbox-box-managed","labels":{"openbox.managed":"true"}}},{"configuration":{"id":"openbox-box-lookalike","labels":{}}},{"configuration":{"id":"someone-else","labels":{"openbox.managed":"true"}}}]'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = AppleContainerRuntime(containerExecutable: executable.path, hostEnvironment: [:])
        let identifiers = try await runtime.managedContainerIDs()
        XCTAssertEqual(identifiers, ["openbox-box-managed"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("openbox-server-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class OpenBoxIntegrationTests: XCTestCase {
    func testRealAppleContainerLifecycleTerminalRestartAndTTL() async throws {
        guard ProcessInfo.processInfo.environment["OPENBOX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("set OPENBOX_INTEGRATION_TESTS=1 to use the real Apple container runtime")
        }
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbox-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        var configuration = OpenBoxServerConfiguration(stateDirectory: stateURL, maxCPUs: 1, maxMemoryMB: 1024)
        configuration.defaultCPUs = 1
        configuration.defaultMemoryMB = 512
        configuration.defaultTTLSeconds = 30

        let first = try BoxManager(configuration: configuration)
        try await first.start()
        let box = try await first.create(.init(
            workspace: .ephemeral,
            image: "docker.io/library/alpine:latest",
            ttlSeconds: 30,
            cpus: 1,
            memoryMB: 512
        ))
        do {
            _ = try await first.execute(
                id: box.id,
                request: .init(command: ["/bin/sh", "-lc", "printf persistent > /workspace/state"])
            )
            let persisted = try await first.execute(id: box.id, request: .init(command: ["cat", "/workspace/state"]))
            XCTAssertEqual(persisted.stdout, "persistent")

            let terminal = try await first.openTerminal(
                id: box.id,
                command: ["/bin/sh", "-lc", "printf terminal-ok"],
                columns: 80,
                rows: 24
            )
            var terminalOutput = Data()
            for await data in terminal.output { terminalOutput.append(data) }
            _ = try await terminal.wait()
            await first.finishTerminal(id: box.id, completed: true)
            XCTAssertTrue(String(decoding: terminalOutput, as: UTF8.self).contains("terminal-ok"))

            await first.stop()
            let restarted = try BoxManager(configuration: configuration)
            try await restarted.start()
            let recovered = try await restarted.getBox(id: box.id)
            XCTAssertEqual(recovered.state, .running)
            _ = try await restarted.extend(id: box.id, ttlSeconds: 1)
            try await Task.sleep(for: .seconds(6))
            let remaining = await restarted.listBoxes()
            XCTAssertTrue(remaining.isEmpty)
            await restarted.stop()
        } catch {
            await first.stop()
            try? await first.delete(id: box.id)
            throw error
        }
    }
}

private actor FakeRuntimeState {
    var containers: Set<String> = []
    var deleted: Set<String> = []
    var lastCreate: ManagedContainerCreateOptions?
    var executeResult = ManagedCommandResult(
        exitCode: 0,
        stdout: "hello\n",
        stderr: "",
        timedOut: false,
        stdoutTruncated: false,
        stderrTruncated: false
    )

    func create(_ options: ManagedContainerCreateOptions) {
        lastCreate = options
        containers.insert(options.id)
    }

    func delete(_ id: String) {
        containers.remove(id)
        deleted.insert(id)
    }

    func removeContainer(_ id: String) { containers.remove(id) }
    func addContainer(_ id: String) { containers.insert(id) }
    func setExecuteResult(_ result: ManagedCommandResult) { executeResult = result }
}

private struct FakeRuntime: ManagedContainerRuntimeProtocol {
    let state: FakeRuntimeState
    var terminal: (any ManagedTerminalSessionProtocol)? = nil
    let hostEnvironment: [String: String] = [:]

    func create(_ options: ManagedContainerCreateOptions) async throws { await state.create(options) }

    func execute(id: String, command: [String], timeout: TimeInterval, outputLimitBytes: Int) async throws -> ManagedCommandResult {
        await state.executeResult
    }

    func startTerminal(id: String, command: [String], columns: Int, rows: Int) async throws -> any ManagedTerminalSessionProtocol {
        if let terminal { return terminal }
        throw OpenBoxServiceError(.unavailable, code: "unsupported", message: "not used by this fake")
    }

    func delete(id: String) async throws { await state.delete(id) }
    func inspect(id: String) async throws -> String { "{}" }
    func managedContainerIDs() async throws -> [String] { Array(await state.containers) }
}

private final class FakeTerminal: ManagedTerminalSessionProtocol, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Int32, Error>] = []
    private var result: Int32?
    private var resizeValue: (columns: Int, rows: Int)?

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var lastResize: (columns: Int, rows: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return resizeValue
    }

    func write(_ data: Data) throws {
        if data == Data("exit\n".utf8) {
            finish(7)
        } else {
            continuation.yield(data)
        }
    }

    func resize(columns: Int, rows: Int) throws {
        lock.lock()
        resizeValue = (columns, rows)
        lock.unlock()
    }

    func terminate() { finish(143) }

    func wait() async throws -> Int32 {
        try await withCheckedThrowingContinuation { waiter in
            lock.lock()
            if let result {
                lock.unlock()
                waiter.resume(returning: result)
            } else {
                waiters.append(waiter)
                lock.unlock()
            }
        }
    }

    private func finish(_ code: Int32) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        continuation.finish()
        pending.forEach { $0.resume(returning: code) }
    }
}

private extension Data {
    init(buffer: ByteBuffer) {
        self.init(buffer.readableBytesView)
    }
}
