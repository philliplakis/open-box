import Foundation
import Hummingbird
import HummingbirdRouter
import HummingbirdWebSocket
import OpenBox
import OpenBoxClient

public struct OpenBoxHTTPServer: Sendable {
    public let configuration: OpenBoxServerConfiguration
    public let token: String
    public let manager: BoxManager
    private let instanceLock: ServerInstanceLock

    public init(configuration: OpenBoxServerConfiguration = .init()) throws {
        self.configuration = configuration
        self.instanceLock = try ServerInstanceLock(stateDirectory: configuration.stateDirectory)
        self.token = try ServerTokenStore.loadOrCreate(at: configuration.tokenFile)
        self.manager = try BoxManager(configuration: configuration)
    }

    public func run() async throws {
        _ = instanceLock
        if !Self.isLoopback(configuration.host) {
            fputs(
                "openbox: warning: listening on \(configuration.host) over plaintext HTTP; tokens, commands, and output are not encrypted\n",
                stderr
            )
        }

        try await manager.start()
        let httpRouter = Self.makeHTTPRouter(manager: manager, token: token)
        let webSocketRouter = Self.makeWebSocketRouter(manager: manager, token: token)
        let application = Application(
            router: httpRouter,
            server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter),
            configuration: .init(address: .hostname(configuration.host, port: configuration.port))
        )
        do {
            try await application.runService()
            await manager.stop()
        } catch {
            await manager.stop()
            throw error
        }
    }

    public static func makeHTTPRouter(
        manager: BoxManager,
        token: String
    ) -> Router<BasicRouterRequestContext> {
        let router = Router(context: BasicRouterRequestContext.self)

        router.get("/healthz") { _, _ -> Response in
            jsonResponse(APIHealth(status: "ok", version: OpenBoxServerConfiguration.version))
        }

        router.get("/v1/workspaces") { request, _ -> Response in
            await route(request: request, token: token) {
                jsonResponse(WorkspaceListResponse(workspaces: try await manager.workspaces.list()))
            }
        }

        router.get("/v1/boxes") { request, _ -> Response in
            await route(request: request, token: token) {
                jsonResponse(BoxListResponse(boxes: await manager.listBoxes()))
            }
        }

        router.post("/v1/boxes") { request, context -> Response in
            await route(request: request, token: token) {
                let body: CreateBoxRequest = try await decode(request, context: context)
                return jsonResponse(try await manager.create(body), status: .created)
            }
        }

        router.get("/v1/boxes/:id") { request, context -> Response in
            await route(request: request, token: token) {
                let id = try parameter("id", context: context)
                return jsonResponse(try await manager.getBox(id: id))
            }
        }

        router.delete("/v1/boxes/:id") { request, context -> Response in
            await route(request: request, token: token) {
                let id = try parameter("id", context: context)
                try await manager.delete(id: id)
                return Response(status: .noContent)
            }
        }

        router.post("/v1/boxes/:id/exec") { request, context -> Response in
            await route(request: request, token: token) {
                let id = try parameter("id", context: context)
                let body: ExecuteBoxRequest = try await decode(request, context: context)
                return jsonResponse(try await manager.execute(id: id, request: body))
            }
        }

        router.post("/v1/boxes/:id/extend") { request, context -> Response in
            await route(request: request, token: token) {
                let id = try parameter("id", context: context)
                let body: ExtendBoxRequest = try await decode(request, context: context)
                return jsonResponse(try await manager.extend(id: id, ttlSeconds: body.ttlSeconds))
            }
        }

        router.get("/v1/boxes/:id/tty") { request, _ -> Response in
            await route(request: request, token: token) {
                errorResponse(OpenBoxServiceError(.badRequest, code: "websocket_required", message: "this endpoint requires a WebSocket upgrade"))
            }
        }

        return router
    }

    public static func makeWebSocketRouter(
        manager: BoxManager,
        token: String
    ) -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/v1/boxes/:id/tty") { request, context in
            guard authorized(request, token: token),
                  let id = context.parameters.get("id"),
                  (try? await manager.getBox(id: id)) != nil
            else {
                return .dontUpgrade
            }
            return .upgrade()
        } onUpgrade: { inbound, outbound, context in
            guard let id = context.requestContext.parameters.get("id") else { return }
            var session: (any ManagedTerminalSessionProtocol)?
            var completed = false
            do {
                let messages = inbound.messages(maxSize: 64 * 1024)
                let reader = WebSocketMessageReader(messages.makeAsyncIterator())
                guard let first = try await reader.next(), case .text(let text) = first else {
                    throw OpenBoxServiceError(.badRequest, code: "tty_start_required", message: "the first frame must start the terminal")
                }
                let start = try JSONDecoder().decode(TTYStartMessage.self, from: Data(text.utf8))
                guard start.type == "start" else {
                    throw OpenBoxServiceError(.badRequest, code: "tty_start_required", message: "the first frame must be a start message")
                }
                let terminal = try await manager.openTerminal(
                    id: id,
                    command: start.command,
                    columns: start.columns,
                    rows: start.rows
                )
                session = terminal

                completed = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for await data in terminal.output {
                            try await outbound.write(.binary(ByteBuffer(bytes: data)))
                        }
                        let exitCode = try await terminal.wait()
                        try await writeEvent(.init(type: "exit", exitCode: exitCode), to: outbound)
                        return true
                    }
                    group.addTask {
                        while let message = try await reader.next() {
                            switch message {
                            case .binary(let buffer):
                                try terminal.write(Data(buffer.readableBytesView))
                            case .text(let text):
                                let resize = try JSONDecoder().decode(TTYResizeMessage.self, from: Data(text.utf8))
                                guard resize.type == "resize" else { continue }
                                try terminal.resize(columns: resize.columns, rows: resize.rows)
                            }
                        }
                        terminal.terminate()
                        return false
                    }
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } catch {
                session?.terminate()
                let serviceError = normalized(error)
                try? await writeEvent(.init(type: "error", code: serviceError.code, message: serviceError.message), to: outbound)
            }
            await manager.finishTerminal(id: id, completed: completed)
        }
        return router
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.lowercased() == "localhost"
    }
}

private func route(
    request: Request,
    token: String,
    operation: () async throws -> Response
) async -> Response {
    guard authorized(request, token: token) else {
        return errorResponse(OpenBoxServiceError(.unauthorized, code: "unauthorized", message: "a valid bearer token is required"))
    }
    do {
        return try await operation()
    } catch {
        return errorResponse(normalized(error))
    }
}

private func authorized(_ request: Request, token: String) -> Bool {
    request.headers[.authorization] == "Bearer \(token)"
}

private func parameter(
    _ name: String,
    context: BasicRouterRequestContext
) throws -> String {
    guard let value = context.parameters.get(name), !value.isEmpty else {
        throw OpenBoxServiceError(.badRequest, code: "invalid_path", message: "missing \(name)")
    }
    return value
}

private func decode<T: Decodable>(
    _ request: Request,
    context: some RequestContext
) async throws -> T {
    do {
        return try await request.decode(as: T.self, context: context)
    } catch {
        throw OpenBoxServiceError(.badRequest, code: "invalid_json", message: "request body is not valid JSON")
    }
}

private func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) -> Response {
    do {
        let data = try JSONEncoder().encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    } catch {
        return errorResponse(OpenBoxServiceError(.internalError, code: "encoding_failed", message: "could not encode response"))
    }
}

private func errorResponse(_ error: OpenBoxServiceError) -> Response {
    let body = APIErrorEnvelope(error: APIErrorBody(code: error.code, message: error.message))
    let data = (try? JSONEncoder().encode(body)) ?? Data()
    return Response(
        status: HTTPResponse.Status(code: error.status.rawValue),
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

private func normalized(_ error: Error) -> OpenBoxServiceError {
    if let error = error as? OpenBoxServiceError { return error }
    return OpenBoxServiceError(.internalError, code: "internal_error", message: String(describing: error))
}

private func writeEvent(
    _ event: TTYServerEvent,
    to outbound: WebSocketOutboundWriter
) async throws {
    let data = try JSONEncoder().encode(event)
    try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
}

private final class WebSocketMessageReader: @unchecked Sendable {
    private var iterator: WebSocketInboundMessageStream.AsyncIterator

    init(_ iterator: WebSocketInboundMessageStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> WebSocketMessage? {
        try await iterator.next()
    }
}
