import Foundation

#if os(macOS)
import Darwin
#else
import Glibc
#endif

public struct UnixSocketRuntimeClient: RuntimeClient, Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func health() async throws -> RuntimeHealth {
        try await request(method: "GET", path: "/health")
    }

    public func listSessions(cwd: String) async throws -> [RuntimeSession] {
        try await request(
            method: "GET",
            path: "/sessions",
            query: query(cwd: cwd, runtimeId: nil)
        )
    }

    public func startSession(cwd: String, runtimeId: String?) async throws -> RuntimeSession {
        try await request(
            method: "POST",
            path: "/sessions",
            body: StartSessionPayload(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func messages(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeMessagePage {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/messages",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func status(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeSessionStatus {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/status",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func prompt(
        sessionId: String,
        cwd: String,
        runtimeId: String?,
        text: String
    ) async throws {
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/prompt",
            query: nil,
            body: PromptPayload(cwd: cwd, text: text, runtimeId: runtimeId)
        )
    }

    private func query(cwd: String, runtimeId: String?) -> [(String, String)] {
        var values = [("cwd", cwd)]
        if let runtimeId, !runtimeId.isEmpty {
            values.append(("runtimeId", runtimeId))
        }
        return values
    }

    private func request<Response: Decodable & Sendable>(
        method: String,
        path: String,
        query: [(String, String)]? = nil,
        body: (any Encodable)? = nil
    ) async throws -> Response {
        let socketPath = socketPath
        let encodedBody = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        return try await Task.detached(priority: .userInitiated) {
            try UnixSocketHTTP.requestJSON(
                method: method,
                path: path,
                query: query,
                socketPath: socketPath,
                body: encodedBody
            )
        }.value
    }

    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct StartSessionPayload: Encodable {
    let cwd: String
    let runtimeId: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(runtimeId, forKey: .runtimeId)
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case runtimeId
    }
}

private struct PromptPayload: Encodable {
    let cwd: String
    let text: String
    let runtimeId: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(runtimeId, forKey: .runtimeId)
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case text
        case runtimeId
    }
}

private struct EmptyResponse: Decodable, Sendable {}

/// Type-erased Encodable wrapper used by the transport's generic request
/// boundary. It keeps JSON encoding out of the SwiftUI feature layer.
private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private enum UnixSocketHTTP {
    static func requestJSON<Response: Decodable & Sendable>(
        method: String,
        path: String,
        query: [(String, String)]?,
        socketPath: String,
        body: Data?
    ) throws -> Response {
        let response = try request(
            method: method,
            path: path,
            query: query,
            socketPath: socketPath,
            body: body
        )
        guard (200..<300).contains(response.status) else {
            if let error = try? JSONDecoder().decode(RuntimeErrorResponse.self, from: response.body),
               let message = error.error,
               !message.isEmpty
            {
                throw RuntimeClientError.serverError(response.status, message)
            }
            throw RuntimeClientError.unexpectedHTTPStatus(response.status)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw RuntimeClientError.invalidJSON(String(describing: error))
        }
    }

    private static func request(
        method: String,
        path: String,
        query: [(String, String)]?,
        socketPath: String,
        body: Data?
    ) throws -> (status: Int, body: Data) {
        guard !socketPath.isEmpty else {
            throw RuntimeClientError.invalidSocketPath
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [UInt8(0)]
        let addressCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= addressCapacity else {
            throw RuntimeClientError.invalidSocketPath
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = byte
            }
        }

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
        }

        let requestPath = path + queryString(query)
        var request = "\(method) \(requestPath) HTTP/1.1\r\nHost: pi-agent\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        try writeAll(descriptor, data: payload)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { destination in
                read(descriptor, destination.baseAddress, destination.count)
            }
            if count == 0 { break }
            if count < 0 {
                throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
            }
            response.append(contentsOf: buffer[0..<count])
            if response.count > 16 * 1024 * 1024 {
                throw RuntimeClientError.connectionFailed("response too large")
            }
        }

        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw RuntimeClientError.invalidHTTPResponse
        }
        let header = String(decoding: response[..<headerEnd.lowerBound], as: UTF8.self)
        let statusLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw RuntimeClientError.invalidHTTPResponse
        }

        return (status, Data(response[headerEnd.upperBound...]))
    }

    private static func queryString(_ values: [(String, String)]?) -> String {
        guard let values, !values.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return "" }
        return "?\(query)"
    }

    private static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }
}

private struct RuntimeErrorResponse: Decodable {
    let error: String?
}
