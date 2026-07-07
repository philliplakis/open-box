import Darwin
import Foundation

struct ProcessRunResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var idleTimedOut: Bool
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        idleTimeout: TimeInterval?,
        streamOutput: Bool,
        interactive: Bool
    ) throws -> ProcessRunResult {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = environment
        if interactive {
            process.standardInput = FileHandle.standardInput
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = OutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.appendStdout(data)
            if streamOutput {
                FileHandle.standardOutput.write(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.appendStderr(data)
            if streamOutput {
                FileHandle.standardError.write(data)
            }
        }

        try process.run()

        let startedAt = Date()
        var timedOut = false
        var idleTimedOut = false
        while process.isRunning {
            let now = Date()
            if let timeout, now.timeIntervalSince(startedAt) >= timeout {
                timedOut = true
                terminate(process)
                break
            }
            if let idleTimeout {
                let idleFor = now.timeIntervalSince(output.lastOutput)
                if idleFor >= idleTimeout {
                    idleTimedOut = true
                    terminate(process)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let snapshot = output.snapshot()

        return ProcessRunResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: snapshot.stdout, as: UTF8.self),
            stderr: String(decoding: snapshot.stderr, as: UTF8.self),
            timedOut: timedOut,
            idleTimedOut: idleTimedOut
        )
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var lastOutputDate = Date()

    var lastOutput: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastOutputDate
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        stdout.append(data)
        lastOutputDate = Date()
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderr.append(data)
        lastOutputDate = Date()
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
