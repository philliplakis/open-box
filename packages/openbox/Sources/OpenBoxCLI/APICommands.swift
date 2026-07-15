import Darwin
import Foundation
import OpenBox
import OpenBoxClient
import OpenBoxServer

enum APICommands {
    static func handle(command: String, arguments: [String]) async throws -> Int32? {
        switch command {
        case "serve":
            let configuration = try parseServerConfiguration(arguments)
            try await OpenBoxHTTPServer(configuration: configuration).run()
            return 0
        case "token":
            try token(arguments)
            return 0
        case "workspace":
            try await workspace(arguments)
            return 0
        case "box":
            return try await box(arguments)
        default:
            return nil
        }
    }

    private static func parseServerConfiguration(_ arguments: [String]) throws -> OpenBoxServerConfiguration {
        var configuration = OpenBoxServerConfiguration()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw cliError("\(option) requires a value") }
                index += 2
                return arguments[index - 1]
            }
            switch option {
            case "--host":
                configuration.host = try value()
            case "--port":
                guard let port = Int(try value()) else { throw cliError("--port must be an integer") }
                configuration.port = port
            case "--allow-env":
                configuration.allowedEnvironmentNames.append(try value())
            case "--token-file":
                configuration.tokenFile = expandedURL(try value())
            case "--max-cpus":
                guard let cpus = Int(try value()) else { throw cliError("--max-cpus must be an integer") }
                configuration.maxCPUs = cpus
                configuration.defaultCPUs = min(configuration.defaultCPUs, cpus)
            case "--max-memory":
                configuration.maxMemoryMB = try memoryMB(try value())
                configuration.defaultMemoryMB = min(configuration.defaultMemoryMB, configuration.maxMemoryMB)
            case "-h", "--help":
                printServeHelp()
                Foundation.exit(0)
            default:
                throw cliError("unknown serve option: \(option)")
            }
        }
        try configuration.validate()
        return configuration
    }

    private static func token(_ arguments: [String]) throws {
        guard let action = arguments.first, arguments.count == 1 else {
            throw cliError("usage: openbox token show|rotate")
        }
        let file = OpenBoxServerConfiguration().tokenFile
        switch action {
        case "show":
            print(try ServerTokenStore.loadOrCreate(at: file))
        case "rotate":
            let lock = try ServerInstanceLock(stateDirectory: OpenBoxServerConfiguration.defaultStateDirectory)
            _ = lock
            print(try ServerTokenStore.rotate(at: file))
        default:
            throw cliError("usage: openbox token show|rotate")
        }
    }

    private static func workspace(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            throw cliError("usage: openbox workspace add|list|remove")
        }
        let configuration = OpenBoxServerConfiguration()
        let registry = try WorkspaceRegistry(stateDirectory: configuration.stateDirectory)
        switch action {
        case "add":
            guard arguments.count >= 2 else { throw cliError("workspace add requires a path") }
            let path = expandedURL(arguments[1])
            var name: String?
            var index = 2
            while index < arguments.count {
                guard arguments[index] == "--name", index + 1 < arguments.count else {
                    throw cliError("usage: openbox workspace add <path> --name <name>")
                }
                name = arguments[index + 1]
                index += 2
            }
            printJSON(try await registry.add(path: path, name: name))
        case "list":
            guard arguments.count == 1 else { throw cliError("usage: openbox workspace list") }
            printJSON(WorkspaceListResponse(workspaces: try await registry.list()))
        case "remove":
            guard arguments.count == 2 else { throw cliError("usage: openbox workspace remove <id>") }
            let manager = try BoxManager(configuration: configuration)
            try await registry.remove(id: arguments[1], activeWorkspaceIDs: await manager.activeWorkspaceIDs())
        default:
            throw cliError("usage: openbox workspace add|list|remove")
        }
    }

    private static func box(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else { throw cliError("usage: openbox box create|list|inspect|exec|shell|extend|delete") }
        let client = try makeClient()
        let rest = Array(arguments.dropFirst())
        switch action {
        case "create":
            var workspace = BoxWorkspace.ephemeral
            var image: String?
            var ttl: Int?
            var cpus: Int?
            var memory: Int?
            var index = 0
            while index < rest.count {
                let option = rest[index]
                func value() throws -> String {
                    guard index + 1 < rest.count else { throw cliError("\(option) requires a value") }
                    index += 2
                    return rest[index - 1]
                }
                switch option {
                case "--workspace": workspace = .registered(try value())
                case "--image": image = try value()
                case "--ttl": ttl = try positiveInt(try value(), option: option)
                case "--cpus": cpus = try positiveInt(try value(), option: option)
                case "--memory": memory = try memoryMB(try value())
                default: throw cliError("unknown box create option: \(option)")
                }
            }
            printJSON(try await client.createBox(.init(workspace: workspace, image: image, ttlSeconds: ttl, cpus: cpus, memoryMB: memory)))
            return 0
        case "list":
            guard rest.isEmpty else { throw cliError("usage: openbox box list") }
            printJSON(BoxListResponse(boxes: try await client.listBoxes()))
            return 0
        case "inspect":
            guard rest.count == 1 else { throw cliError("usage: openbox box inspect <id>") }
            printJSON(try await client.getBox(id: rest[0]))
            return 0
        case "exec":
            guard let id = rest.first else { throw cliError("box exec requires a box id") }
            var commandArguments = Array(rest.dropFirst())
            var timeout: Int?
            if commandArguments.first == "--timeout" {
                guard commandArguments.count >= 2 else { throw cliError("--timeout requires seconds") }
                timeout = try positiveInt(commandArguments[1], option: "--timeout")
                commandArguments.removeFirst(2)
            }
            var command = commandArguments
            if command.first == "--" { command.removeFirst() }
            guard !command.isEmpty else { throw cliError("box exec requires a command after --") }
            let response = try await client.execute(id: id, request: .init(command: command, timeoutSeconds: timeout))
            FileHandle.standardOutput.write(Data(response.stdout.utf8))
            FileHandle.standardError.write(Data(response.stderr.utf8))
            if response.timedOut { fputs("openbox: command timed out\n", stderr) }
            return response.exitCode
        case "shell":
            guard let id = rest.first else { throw cliError("box shell requires a box id") }
            var command = Array(rest.dropFirst())
            if command.first == "--" { command.removeFirst() }
            return try await shell(client: client, id: id, command: command.isEmpty ? ["/bin/sh"] : command)
        case "extend":
            guard rest.count == 2 else { throw cliError("usage: openbox box extend <id> <ttl-seconds>") }
            printJSON(try await client.extend(id: rest[0], ttlSeconds: positiveInt(rest[1], option: "ttl-seconds")))
            return 0
        case "delete":
            guard rest.count == 1 else { throw cliError("usage: openbox box delete <id>") }
            try await client.deleteBox(id: rest[0])
            return 0
        default:
            throw cliError("usage: openbox box create|list|inspect|exec|shell|extend|delete")
        }
    }

    private static func shell(client: OpenBoxClient, id: String, command: [String]) async throws -> Int32 {
        let terminal = try client.terminal(id: id)
        let size = terminalSize()
        try await terminal.start(command: command, columns: size.columns, rows: size.rows)
        let output = Task<Int32, Error> {
            while true {
                switch try await terminal.receive() {
                case .data(let data):
                    FileHandle.standardOutput.write(data)
                case .event(let event):
                    if event.type == "exit" { return event.exitCode ?? 1 }
                    if event.type == "error" { throw cliError("\(event.code ?? "terminal_error"): \(event.message ?? "terminal failed")") }
                }
            }
        }
        let old = try enableRawInput()
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                terminal.close()
            } else {
                Task { try? await terminal.send(data) }
            }
        }
        defer {
            FileHandle.standardInput.readabilityHandler = nil
            restoreInput(old)
            terminal.close()
        }
        return try await output.value
    }

    private static func makeClient() throws -> OpenBoxClient {
        let environment = ProcessInfo.processInfo.environment
        let rawURL = environment["OPENBOX_URL"] ?? "http://127.0.0.1:7070"
        guard let url = URL(string: rawURL), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw cliError("OPENBOX_URL must be an http or https URL")
        }
        let token: String
        if let supplied = environment["OPENBOX_TOKEN"], !supplied.isEmpty {
            token = supplied
        } else if environment["OPENBOX_URL"] != nil {
            throw cliError("OPENBOX_TOKEN is required when OPENBOX_URL is set")
        } else {
            token = try ServerTokenStore.loadOrCreate(at: OpenBoxServerConfiguration().tokenFile)
        }
        return OpenBoxClient(baseURL: url, token: token)
    }

    private static func memoryMB(_ raw: String) throws -> Int {
        let value = raw.uppercased()
        if value.hasSuffix("G"), let number = Int(value.dropLast()), number > 0 { return number * 1024 }
        if value.hasSuffix("M"), let number = Int(value.dropLast()), number > 0 { return number }
        return try positiveInt(value, option: "memory")
    }

    private static func positiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value > 0 else { throw cliError("\(option) must be a positive integer") }
        return value
    }

    private static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try! encoder.encode(value), as: UTF8.self))
    }

    private static func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return (80, 24) }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    private static func enableRawInput() throws -> termios? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        var old = termios()
        guard tcgetattr(STDIN_FILENO, &old) == 0 else { throw SandboxError.systemCall("tcgetattr", errno) }
        var raw = old
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw SandboxError.systemCall("tcsetattr", errno) }
        return old
    }

    private static func restoreInput(_ old: termios?) {
        guard var old else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &old)
    }

    private static func printServeHelp() {
        print("usage: openbox serve [--host 127.0.0.1] [--port 7070] [--allow-env NAME] [--token-file PATH] [--max-cpus N] [--max-memory 8G]")
    }

    private static func cliError(_ message: String) -> SandboxError {
        .invalidOptions(message)
    }
}
