import Foundation

public enum OpenBoxClientError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case api(status: Int, code: String, message: String)
    case unexpectedStatus(Int)

    public var description: String {
        switch self {
        case .invalidResponse:
            "OpenBox returned an invalid response"
        case .api(let status, let code, let message):
            "OpenBox API error \(status) (\(code)): \(message)"
        case .unexpectedStatus(let status):
            "OpenBox returned HTTP \(status)"
        }
    }
}

public struct OpenBoxClient: Sendable {
    public var baseURL: URL
    public var token: String
    public var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func health() async throws -> APIHealth {
        try await send(path: "/healthz", authenticated: false)
    }

    public func listWorkspaces() async throws -> [WorkspaceGrant] {
        let response: WorkspaceListResponse = try await send(path: "/v1/workspaces")
        return response.workspaces
    }

    public func createBox(_ body: CreateBoxRequest) async throws -> Box {
        try await send(path: "/v1/boxes", method: "POST", body: body)
    }

    public func listBoxes() async throws -> [Box] {
        let response: BoxListResponse = try await send(path: "/v1/boxes")
        return response.boxes
    }

    public func getBox(id: String) async throws -> Box {
        try await send(path: "/v1/boxes/\(encodePath(id))")
    }

    public func deleteBox(id: String) async throws {
        let request = try makeRequest(path: "/v1/boxes/\(encodePath(id))", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try validateEmpty(data: data, response: response)
    }

    public func execute(id: String, request body: ExecuteBoxRequest) async throws -> ExecuteBoxResponse {
        try await send(path: "/v1/boxes/\(encodePath(id))/exec", method: "POST", body: body)
    }

    public func extend(id: String, ttlSeconds: Int) async throws -> Box {
        try await send(
            path: "/v1/boxes/\(encodePath(id))/extend",
            method: "POST",
            body: ExtendBoxRequest(ttlSeconds: ttlSeconds)
        )
    }

    public func terminal(id: String) throws -> OpenBoxTerminal {
        var request = try makeRequest(path: "/v1/boxes/\(encodePath(id))/tty", method: "GET")
        guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
            throw OpenBoxClientError.invalidResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        return OpenBoxTerminal(task: session.webSocketTask(with: request))
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        authenticated: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: method, authenticated: authenticated)
        return try await decode(request)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await decode(request)
    }

    private func decode<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenBoxClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw OpenBoxClientError.api(
                    status: http.statusCode,
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw OpenBoxClientError.unexpectedStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validateEmpty(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenBoxClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw OpenBoxClientError.api(
                    status: http.statusCode,
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw OpenBoxClientError.unexpectedStatus(http.statusCode)
        }
    }

    private func makeRequest(path: String, method: String, authenticated: Bool = true) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw OpenBoxClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private func encodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

public final class OpenBoxTerminal: @unchecked Sendable {
    public enum Message: Sendable {
        case data(Data)
        case event(TTYServerEvent)
    }

    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    public func start(command: [String] = ["bash"], columns: Int = 80, rows: Int = 24) async throws {
        let data = try JSONEncoder().encode(TTYStartMessage(command: command, columns: columns, rows: rows))
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func resize(columns: Int, rows: Int) async throws {
        let data = try JSONEncoder().encode(TTYResizeMessage(columns: columns, rows: rows))
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func receive() async throws -> Message {
        switch try await task.receive() {
        case .data(let data):
            return .data(data)
        case .string(let string):
            return .event(try JSONDecoder().decode(TTYServerEvent.self, from: Data(string.utf8)))
        @unknown default:
            throw OpenBoxClientError.invalidResponse
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
