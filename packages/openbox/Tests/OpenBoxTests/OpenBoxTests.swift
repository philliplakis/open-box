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
