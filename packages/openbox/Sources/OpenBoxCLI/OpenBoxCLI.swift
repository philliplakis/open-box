import Darwin
import Foundation
import OpenBox
import OpenBoxClient
import OpenBoxServer

@main
enum OpenBoxCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("openbox: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printHelp()
            return
        }
        args.removeFirst()

        if let exitCode = try await APICommands.handle(command: command, arguments: args) {
            if exitCode != 0 { Foundation.exit(exitCode) }
            return
        }

        let runner = SandboxRunner(streamOutput: true) { event in
            if case .pullingImage(let image) = event {
                fputs("openbox: pulling image \(image)\n", stderr)
            }
        }
        switch command {
        case "run":
            let options = try parseRun(args)
            if options.interactive {
                let exitCode = try await runInteractive(options: options, eventHandler: runner.eventHandler)
                Foundation.exit(exitCode)
            }
            let result = try await runner.run(options: options)
            if result.timedOut {
                throw SandboxError.timeout("container timed out")
            }
            if result.idleTimedOut {
                throw SandboxError.timeout("container idle timeout reached")
            }
            Foundation.exit(result.exitCode)
        case "stop":
            guard let name = args.first else {
                throw SandboxError.invalidOptions("stop requires a container name")
            }
            try await runner.stop(name: name)
        case "status":
            guard let name = args.first else {
                throw SandboxError.invalidOptions("status requires a container name")
            }
            let status = try await runner.status(name: name)
            print(status.description)
        case "cache":
            guard args == ["clean"] else {
                throw SandboxError.invalidOptions("supported cache command: cache clean")
            }
            try await runner.cleanCache()
        case "-h", "--help", "help":
            printHelp()
        default:
            throw SandboxError.invalidOptions("unknown command: \(command)")
        }
    }

    private static func runInteractive(
        options: SandboxRunOptions,
        eventHandler: (@Sendable (SandboxEvent) -> Void)?
    ) async throws -> Int32 {
        let size = terminalSize()
        let session = try await SandboxTerminalSession.start(
            options: options,
            columns: size.columns,
            rows: size.rows,
            eventHandler: eventHandler
        )

        let outputTask = Task {
            for await data in session.output {
                FileHandle.standardOutput.write(data)
            }
        }

        let oldTermios = try enableRawInput()
        var completed = false
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                session.terminate()
                return
            }
            try? session.write(data)
        }
        defer {
            FileHandle.standardInput.readabilityHandler = nil
            restoreInput(oldTermios)
            outputTask.cancel()
            if !completed {
                session.terminate()
            }
        }

        let exitCode = try await session.wait()
        await outputTask.value
        completed = true
        return exitCode
    }

    private static func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (80, 24)
    }

    private static func enableRawInput() throws -> termios? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }

        var old = termios()
        guard tcgetattr(STDIN_FILENO, &old) == 0 else {
            throw SandboxError.systemCall("tcgetattr", errno)
        }
        var raw = old
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw SandboxError.systemCall("tcsetattr", errno)
        }
        return old
    }

    private static func restoreInput(_ old: termios?) {
        guard var old else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &old)
    }

    private static func parseRun(_ rawArgs: [String]) throws -> SandboxRunOptions {
        var image = SandboxRunOptions.defaultImage
        var name: String?
        var workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var cpus = 4
        var memory = "4G"
        var envAllowlist = SandboxRunOptions.defaultEnvironmentAllowlist
        var mounts: [SandboxMount] = []
        var timeout: TimeInterval?
        var idleTimeout: TimeInterval?
        var sshAgent = false
        var interactive = false
        var removeWhenStopped = true
        var command: [String] = []

        var index = 0
        while index < rawArgs.count {
            let arg = rawArgs[index]
            if arg == "--" {
                command = Array(rawArgs.dropFirst(index + 1))
                break
            }
            if !arg.hasPrefix("-") {
                command = Array(rawArgs.dropFirst(index))
                break
            }

            func requireValue() throws -> String {
                let valueIndex = index + 1
                guard valueIndex < rawArgs.count else {
                    throw SandboxError.invalidOptions("\(arg) requires a value")
                }
                index += 2
                return rawArgs[valueIndex]
            }

            switch arg {
            case "--image":
                image = try requireValue()
            case "--name":
                name = try requireValue()
            case "--workspace", "-w":
                workspace = URL(fileURLWithPath: NSString(string: try requireValue()).expandingTildeInPath)
            case "--cpus":
                guard let value = Int(try requireValue()) else {
                    throw SandboxError.invalidOptions("--cpus must be an integer")
                }
                cpus = value
            case "--memory":
                memory = try requireValue()
            case "--env", "-e":
                envAllowlist.append(try requireValue())
            case "--no-default-env":
                envAllowlist = []
                index += 1
            case "--mount", "-m":
                mounts.append(try parseMount(try requireValue()))
            case "--timeout":
                timeout = try parseSeconds(try requireValue(), flag: "--timeout")
            case "--idle-timeout":
                idleTimeout = try parseSeconds(try requireValue(), flag: "--idle-timeout")
            case "--ssh-agent":
                sshAgent = true
                index += 1
            case "--tty", "--interactive":
                interactive = true
                index += 1
            case "--keep":
                removeWhenStopped = false
                index += 1
            case "-h", "--help":
                printRunHelp()
                Foundation.exit(0)
            default:
                throw SandboxError.invalidOptions("unknown run option: \(arg)")
            }
        }

        return SandboxRunOptions(
            image: image,
            name: name,
            workspace: workspace,
            cpus: cpus,
            memory: memory,
            environmentAllowlist: envAllowlist,
            mounts: mounts,
            command: command,
            timeoutSeconds: timeout,
            idleTimeoutSeconds: idleTimeout,
            forwardSSHAgent: sshAgent,
            interactive: interactive,
            removeWhenStopped: removeWhenStopped
        )
    }

    private static func parseSeconds(_ raw: String, flag: String) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value > 0 else {
            throw SandboxError.invalidOptions("\(flag) must be a positive number of seconds")
        }
        return value
    }

    private static func parseMount(_ raw: String) throws -> SandboxMount {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else {
            throw SandboxError.invalidOptions("mount format is hostpath:containerpath[:ro|rw]")
        }
        let mode = parts.count == 3 ? String(parts[2]) : "rw"
        guard mode == "ro" || mode == "rw" else {
            throw SandboxError.invalidOptions("mount mode must be ro or rw")
        }
        return SandboxMount(
            source: URL(fileURLWithPath: NSString(string: String(parts[0])).expandingTildeInPath),
            target: String(parts[1]),
            readOnly: mode == "ro"
        )
    }

    private static func printHelp() {
        print(
            """
            USAGE:
              openbox run [options] -- <command...>
              openbox stop <name>
              openbox status <name>
              openbox cache clean
              openbox serve [options]
              openbox token show|rotate
              openbox workspace add|list|remove
              openbox box create|list|inspect|exec|shell|extend|delete

            Run `openbox run --help` for run options.
            """
        )
    }

    private static func printRunHelp() {
        print(
            """
            USAGE:
              openbox run [options] -- <command...>

            OPTIONS:
              --image <image>          Container image (default: \(SandboxRunOptions.defaultImage))
              --name <name>            Container name
              -w, --workspace <path>   Workspace to mount at /workspace
              --cpus <n>               CPU count (default: 4)
              --memory <size>          Memory, e.g. 4G (default: 4G)
              -e, --env <KEY>          Add a host env var to tokens.yaml
              --no-default-env         Do not include default token env keys
              -m, --mount <spec>       hostpath:containerpath[:ro|rw]
              --timeout <seconds>      Kill command after this many seconds
              --idle-timeout <seconds> Kill command after no output for this many seconds
              --ssh-agent              Forward host SSH agent
              --tty                    Request interactive stdin and TTY
              --keep                   Do not remove the container after stop
            """
        )
    }
}
