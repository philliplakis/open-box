import Darwin
import Foundation

final class PTYProcess: @unchecked Sendable {
    let output: AsyncStream<Data>

    private let process: Process
    private let masterHandle: FileHandle
    private let masterFD: Int32
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var result: Result<Int32, Error>?
    private var waiters: [CheckedContinuation<Int32, Error>] = []

    private init(
        process: Process,
        masterHandle: FileHandle,
        masterFD: Int32,
        output: AsyncStream<Data>,
        outputContinuation: AsyncStream<Data>.Continuation
    ) {
        self.process = process
        self.masterHandle = masterHandle
        self.masterFD = masterFD
        self.output = output
        self.outputContinuation = outputContinuation
    }

    static func start(
        executable: String,
        arguments: [String],
        environment: [String: String],
        columns: Int,
        rows: Int
    ) throws -> PTYProcess {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SandboxError.systemCall("openpty", errno)
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        var outputContinuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { continuation in
            outputContinuation = continuation
        }

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let pty = PTYProcess(
            process: process,
            masterHandle: masterHandle,
            masterFD: master,
            output: output,
            outputContinuation: outputContinuation
        )
        try pty.resize(columns: columns, rows: rows)

        masterHandle.readabilityHandler = { [pty] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            pty.yield(data)
        }
        process.terminationHandler = { [weak pty] process in
            pty?.finish(.success(process.terminationStatus))
        }

        do {
            try process.run()
            slaveHandle.closeFile()
            return pty
        } catch {
            masterHandle.readabilityHandler = nil
            masterHandle.closeFile()
            slaveHandle.closeFile()
            throw error
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }

        lock.lock()
        let isFinished = result != nil
        lock.unlock()
        guard !isFinished else {
            throw SandboxError.systemCall("write", EPIPE)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, pointer, remaining)
                guard written > 0 else {
                    throw SandboxError.systemCall("write", errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    func resize(columns: Int, rows: Int) throws {
        guard columns > 0, rows > 0,
              columns <= Int(UInt16.max), rows <= Int(UInt16.max)
        else {
            throw SandboxError.invalidOptions("terminal size must fit UInt16 rows/columns")
        }

        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &size) != -1 else {
            throw SandboxError.systemCall("ioctl(TIOCSWINSZ)", errno)
        }
    }

    func terminate() {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [process] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func wait() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Int32, Error>?
            lock.lock()
            if let result {
                immediate = result
            } else {
                waiters.append(continuation)
                immediate = nil
            }
            lock.unlock()

            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    private func yield(_ data: Data) {
        outputContinuation.yield(data)
    }

    private func finish(_ result: Result<Int32, Error>) {
        process.terminationHandler = nil
        masterHandle.readabilityHandler = nil
        masterHandle.closeFile()
        outputContinuation.finish()

        let pending: [CheckedContinuation<Int32, Error>]
        lock.lock()
        if self.result != nil {
            lock.unlock()
            return
        }
        self.result = result
        pending = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume(with: result)
        }
    }
}
