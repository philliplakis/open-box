import Observation
import OpenBoxClient
import SwiftUI

@main
struct OpenBoxShowcaseApp: App {
    var body: some Scene {
        Window("OpenBox Showcase", id: "main") {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var model = ShowcaseModel()

    var body: some View {
        Form {
            Section("Features") {
                Text("Workspace registration • Environment forwarding • Box lifecycle • Command execution • WebSocket terminal client")
            }

            Section("Service") {
                LabeledContent("Status", value: model.serviceStatus)
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }

            Section("Workspace") {
                TextField("Host folder", text: $model.workspacePath)
                Button("Register workspace") { Task { await model.addWorkspace() } }
                    .disabled(model.isBusy || model.workspacePath.isEmpty)
                Picker("Registered workspace", selection: $model.selectedWorkspaceID) {
                    Text("None").tag(String?.none)
                    ForEach(model.workspaces) { workspace in
                        Text("\(workspace.name) — \(workspace.path)").tag(Optional(workspace.id))
                    }
                }
            }

            Section("Boxes") {
                Picker("Active box", selection: $model.selectedBoxID) {
                    Text("None").tag(String?.none)
                    ForEach(model.boxes) { box in
                        Text("\(box.id) — \(box.state.rawValue)").tag(Optional(box.id))
                    }
                }

                HStack {
                    Button("Create workspace box") { Task { await model.createBox() } }
                        .disabled(model.selectedWorkspaceID == nil)
                    Button("Extend 15 minutes") { Task { await model.extendBox() } }
                        .disabled(model.selectedBoxID == nil)
                    Button("Delete") { Task { await model.deleteBox() } }
                        .disabled(model.selectedBoxID == nil)
                }
                .disabled(model.isBusy)
            }

            Section("Command") {
                TextField("Shell command", text: $model.command)
                    .onSubmit { Task { await model.execute() } }
                HStack {
                    Button("Run in box") { Task { await model.execute() } }
                    Button("Check environment names") {
                        Task { await model.execute("env | cut -d= -f1 | sort") }
                    }
                    Button("Git status") { Task { await model.execute("git status --short --branch") } }
                }
                .disabled(model.isBusy || model.selectedBoxID == nil || model.command.isEmpty)
                Text(model.output.isEmpty ? "Output appears here." : model.output)
                    .textSelection(.enabled)
            }

            if let error = model.errorMessage {
                Section("Error") {
                    Text(error)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 720, minHeight: 650)
        .task { await model.refresh() }
    }
}

@MainActor
@Observable
final class ShowcaseModel {
    var serviceStatus = "Connecting…"
    var workspacePath: String
    var workspaces: [WorkspaceGrant] = []
    var selectedWorkspaceID: String?
    var boxes: [Box] = []
    var selectedBoxID: String?
    var command = "echo 'Hello from OpenBox'"
    var output = ""
    var errorMessage: String?
    var isBusy = false

    @ObservationIgnored private let client: OpenBoxClient
    @ObservationIgnored private let cliURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) {
        workspacePath = arguments.dropFirst().first ?? ""
        let url = URL(string: environment["OPENBOX_URL"] ?? "http://127.0.0.1:7070")!
        let tokenFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBox/token")
        let token = environment["OPENBOX_TOKEN"]
            ?? (try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            ?? ""
        client = OpenBoxClient(baseURL: url, token: token)
        cliURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("openbox")
    }

    func refresh() async {
        await perform {
            let health = try await client.health()
            workspaces = try await client.listWorkspaces()
            boxes = try await client.listBoxes()
            if selectedWorkspaceID == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = workspaces.first?.id
            }
            if selectedBoxID == nil || !boxes.contains(where: { $0.id == selectedBoxID }) {
                selectedBoxID = boxes.first?.id
            }
            serviceStatus = "\(health.status) (v\(health.version))"
        }
    }

    func addWorkspace() async {
        let path = NSString(string: workspacePath).expandingTildeInPath
        await perform {
            let response = try await runCLI(["workspace", "add", path])
            let workspace = try JSONDecoder().decode(WorkspaceGrant.self, from: Data(response.utf8))
            output = response
            workspaces = try await client.listWorkspaces()
            selectedWorkspaceID = workspace.id
        }
    }

    func createBox() async {
        guard let workspaceID = selectedWorkspaceID else { return }
        await perform {
            let box = try await client.createBox(.init(workspace: .registered(workspaceID), ttlSeconds: 900))
            selectedBoxID = box.id
            boxes = try await client.listBoxes()
            output = "Created \(box.id)"
        }
    }

    func execute(_ requestedCommand: String? = nil) async {
        guard let id = selectedBoxID else { return }
        let command = requestedCommand ?? command
        self.command = command
        await perform {
            let result = try await client.execute(
                id: id,
                request: .init(command: ["sh", "-lc", command])
            )
            output = result.stdout + result.stderr + "\nExit: \(result.exitCode)"
        }
    }

    private func runCLI(_ arguments: [String]) async throws -> String {
        let executable = cliURL
        return try await Task.detached {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw CocoaError(.executableRuntimeMismatch, userInfo: [NSLocalizedDescriptionKey: stderr])
            }
            return stdout
        }.value
    }

    func extendBox() async {
        guard let id = selectedBoxID else { return }
        await perform {
            let box = try await client.extend(id: id, ttlSeconds: 900)
            boxes = try await client.listBoxes()
            output = "Extended \(box.id) until \(box.expiresAt)"
        }
    }

    func deleteBox() async {
        guard let id = selectedBoxID else { return }
        await perform {
            try await client.deleteBox(id: id)
            boxes = try await client.listBoxes()
            selectedBoxID = boxes.first?.id
            output = "Deleted \(id)"
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            serviceStatus = "Unavailable"
            errorMessage = String(describing: error)
        }
    }
}
