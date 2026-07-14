@testable import OpenBox
import XCTest

final class OpenBoxTests: XCTestCase {
    func testTokenYAMLOnlyIncludesAllowlistedValues() {
        let tokens = TokenYAML.collect(
            allowlist: ["OPENAI_API_KEY", "MISSING", "bad-key"],
            from: [
                "OPENAI_API_KEY": "secret",
                "ANTHROPIC_API_KEY": "not requested",
            ]
        )

        XCTAssertEqual(tokens, ["OPENAI_API_KEY": "secret"])
    }

    func testTokenYAMLFallsBackToGitHubCLIForGHToken() {
        let tokens = TokenYAML.collect(
            allowlist: ["GH_TOKEN"],
            from: [:],
            githubTokenProvider: { _ in "from-gh" }
        )

        XCTAssertEqual(tokens, ["GH_TOKEN": "from-gh"])
    }

    func testTokenYAMLQuoting() {
        let yaml = TokenYAML.render([
            "A": "line\nquote\"slash\\tab\t"
        ])

        XCTAssertEqual(yaml, #"tokens:\#n  A: "line\nquote\"slash\\tab\t"\#n"#)
    }

    func testInvalidTimersAreRejected() {
        var options = SandboxRunOptions(command: ["echo", "ok"])
        options.timeoutSeconds = 0

        XCTAssertThrowsError(try options.validate())
    }

    func testContainerArgumentsIncludeWorkspaceAndTokenMounts() throws {
        let tokenFile = URL(fileURLWithPath: "/tmp/tokens.yaml")
        let options = SandboxRunOptions(
            image: "example/image:latest",
            workspace: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            command: ["echo", "ok"],
            timeoutSeconds: 1,
            forwardSSHAgent: true
        )

        let args = try ContainerArguments.run(
            options: options,
            name: "test-container",
            tokenFile: tokenFile,
            tokenEnvironment: ["OPENAI_API_KEY": "secret"],
            workspaceSource: URL(fileURLWithPath: "/tmp/staged-workspace")
        )

        XCTAssertTrue(args.contains("run"))
        XCTAssertTrue(args.contains("test-container"))
        XCTAssertTrue(args.contains("example/image:latest"))
        XCTAssertTrue(args.contains("--ssh"))
        XCTAssertTrue(args.contains("echo"))
        XCTAssertTrue(args.contains { $0.contains("target=/workspace") })
        XCTAssertTrue(args.contains { $0.contains("target=/run/openbox") && $0.contains("readonly") })
        XCTAssertTrue(args.contains { $0.contains("source=/tmp/staged-workspace") })
        XCTAssertTrue(args.contains("OPENAI_API_KEY=secret"))
    }

    func testMissingImagePullReportsEvents() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeContainer = dir.appendingPathComponent("container")
        try """
        #!/bin/sh
        if [ "$1 $2" = "image inspect" ]; then exit 1; fi
        if [ "$1 $2" = "image pull" ]; then echo pulling "$5" >&2; exit 0; fi
        exit 2
        """.write(to: fakeContainer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeContainer.path(percentEncoded: false)
        )

        let events = EventRecorder()
        try pullImageIfNeeded(
            "example/image:latest",
            containerExecutable: fakeContainer.path(percentEncoded: false),
            environment: [:],
            streamOutput: false
        ) { event in
            switch event {
            case .pullingImage(let image):
                events.append("pulling \(image)")
            case .output(.stderr(let data)):
                events.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            case .output(.stdout):
                break
            }
        }

        XCTAssertEqual(events.values, ["pulling example/image:latest", "pulling example/image:latest"])
    }

    func testCleanCacheStopsRunningOpenBoxContainersBeforePrune() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = dir.appendingPathComponent("record")
        let fakeContainer = dir.appendingPathComponent("container")
        try """
        #!/bin/sh
        echo "$*" >> "$RECORD"
        if [ "$1 $2" = "list --quiet" ]; then
          echo openbox-running
          echo openbox-box-managed
          echo other-container
          exit 0
        fi
        if [ "$1" = "stop" ]; then exit 0; fi
        if [ "$1" = "prune" ]; then exit 0; fi
        exit 2
        """.write(to: fakeContainer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeContainer.path(percentEncoded: false)
        )

        let runner = SandboxRunner(
            containerExecutable: fakeContainer.path(percentEncoded: false),
            hostEnvironment: ["RECORD": record.path(percentEncoded: false)]
        )
        try await runner.cleanCache()

        let calls = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(calls, "list --quiet\nstop openbox-running\nprune\n")
    }

    func testProtectedWorkspaceDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        XCTAssertTrue(WorkspaceStager.shouldStage(URL(fileURLWithPath: "\(home)/Documents/project")))
        XCTAssertFalse(WorkspaceStager.shouldStage(URL(fileURLWithPath: "/tmp/project")))
    }

    func testPTYProcessRoundTrip() async throws {
        let pty = try PTYProcess.start(
            executable: "/bin/cat",
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            columns: 80,
            rows: 24
        )
        let received = expectation(description: "received terminal output")

        let reader = Task {
            for await data in pty.output {
                if String(decoding: data, as: UTF8.self).contains("hello") {
                    received.fulfill()
                    break
                }
            }
        }

        try pty.write(Data("hello\n".utf8))
        await fulfillment(of: [received], timeout: 2)
        reader.cancel()
        pty.terminate()
        _ = try await pty.wait()
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func append(_ value: String) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }
}
