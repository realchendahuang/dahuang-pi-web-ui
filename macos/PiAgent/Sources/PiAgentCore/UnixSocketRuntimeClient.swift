import Foundation
import CryptoKit

#if os(macOS)
import Darwin
#else
import Glibc
#endif

public struct UnixSocketRuntimeClient: RuntimeClient, RuntimeHelloClient, RuntimeEventStreamClient, RuntimeTerminalClient, Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func health() async throws -> RuntimeHealth {
        try await request(method: "GET", path: "/health")
    }

    public func hello() async throws -> RuntimeHello {
        try await request(method: "GET", path: "/runtime/hello")
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
        text: String,
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/sessions/\(Self.pathSegment(sessionId))/prompt",
            query: nil,
            body: PromptPayload(
                cwd: cwd,
                text: text,
                runtimeId: runtimeId,
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func abortActiveWork(
        commandId: String,
        expectedRuntimeEpoch: String
    ) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "POST",
            path: "/runtime/commands/abort-active-work",
            body: RuntimeCommandPayload(
                commandId: commandId,
                runtimeEpoch: expectedRuntimeEpoch
            )
        )
    }

    public func commandReceipt(commandId: String) async throws -> RuntimeCommandReceipt {
        try await request(
            method: "GET",
            path: "/runtime/commands/\(Self.pathSegment(commandId))"
        )
    }

    public func streamSnapshot(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) async throws -> RuntimeStreamSnapshot {
        try await request(
            method: "GET",
            path: "/sessions/\(Self.pathSegment(sessionId))/stream-snapshot",
            query: query(cwd: cwd, runtimeId: runtimeId)
        )
    }

    public func subscribe(
        sessionId: String,
        cwd: String,
        runtimeId: String?
    ) -> RuntimeEventSubscription {
        let runner = UnixSocketStreamRunner<RuntimeSessionEvent>(
            socketPath: socketPath,
            path: "/sessions/\(Self.pathSegment(sessionId))/events",
            query: query(cwd: cwd, runtimeId: runtimeId),
            decode: { data in
                try JSONDecoder().decode(RuntimeSessionEvent.self, from: data)
            }
        )
        return runner.eventSubscription()
    }

    public func listTerminals(cwd: String) async throws -> [RuntimeTerminalInfo] {
        try await request(
            method: "GET",
            path: "/terminals",
            query: [("cwd", cwd)]
        )
    }

    public func createTerminal(
        cwd: String,
        name: String,
        cols: Int,
        rows: Int
    ) async throws -> RuntimeTerminalInfo {
        try await request(
            method: "POST",
            path: "/terminals",
            body: TerminalCreatePayload(cwd: cwd, name: name, cols: cols, rows: rows)
        )
    }

    public func continueTerminal(id: String) async throws -> RuntimeTerminalInfo {
        try await request(
            method: "POST",
            path: "/terminals/\(Self.pathSegment(id))/continue"
        )
    }

    public func subscribeTerminal(
        id: String,
        cols: Int,
        rows: Int
    ) -> RuntimeTerminalSubscription {
        let runner = UnixSocketStreamRunner<RuntimeTerminalEvent>(
            socketPath: socketPath,
            path: "/terminals/\(Self.pathSegment(id))/socket",
            query: [("cols", String(cols)), ("rows", String(rows))],
            decode: { data in
                try JSONDecoder().decode(RuntimeTerminalEvent.self, from: data)
            }
        )
        return runner.terminalSubscription()
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
    let commandId: String
    let runtimeEpoch: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(runtimeId, forKey: .runtimeId)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(runtimeEpoch, forKey: .runtimeEpoch)
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case text
        case runtimeId
        case commandId
        case runtimeEpoch
    }
}

private struct RuntimeCommandPayload: Encodable {
    let commandId: String
    let runtimeEpoch: String
}

private struct TerminalCreatePayload: Encodable {
    let cwd: String
    let name: String
    let cols: Int
    let rows: Int
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

        let descriptor = try UnixSocketTransport.connect(socketPath: socketPath)
        defer { close(descriptor) }

        let requestPath = path + queryString(query)
        var request = "\(method) \(requestPath) HTTP/1.1\r\nHost: pi-agent\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        try UnixSocketTransport.writeAll(descriptor, data: payload)

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

}

private struct RuntimeErrorResponse: Decodable {
    let error: String?
}

/// Shared blocking Unix-socket primitives. HTTP requests and WebSocket
/// upgrades use the same address/write boundary so the native client cannot
/// accidentally drift into a second transport implementation.
private enum UnixSocketTransport {
    static func connect(socketPath: String) throws -> Int32 {
        guard !socketPath.isEmpty else {
            throw RuntimeClientError.invalidSocketPath
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [UInt8(0)]
        let addressCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= addressCapacity else {
            Darwin.close(descriptor)
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
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw RuntimeClientError.connectionFailed(message)
        }
        return descriptor
    }

    static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }
}

private enum UnixSocketWebSocketError: LocalizedError {
    case invalidHandshake
    case invalidFrame
    case messageTooLarge
    case closed
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .invalidHandshake: return "The Runtime WebSocket handshake was invalid."
        case .invalidFrame: return "The Runtime WebSocket frame was invalid."
        case .messageTooLarge: return "The Runtime WebSocket message was too large."
        case .closed: return "The Runtime WebSocket closed."
        case .unsupportedMessage: return "The Runtime sent an unsupported WebSocket message."
        }
    }
}

/// Minimal RFC 6455 client transport for the Unix-socket session daemon.
///
/// URLSession's WebSocket implementation cannot dial a Unix domain socket,
/// while the daemon intentionally does not expose a TCP listener. This small
/// transport handles the protocol pieces the daemon uses: text frames,
/// fragmentation, ping/pong, close, and masked client writes.
private final class UnixSocketWebSocket: @unchecked Sendable {
    private static let maxFrameSize = 16 * 1024 * 1024
    private static let closeOpcode: UInt8 = 0x8

    private let descriptor: Int32
    private let writeLock = NSLock()
    private var closed = false
    private var readBuffer: Data

    private init(descriptor: Int32, initialData: Data) {
        self.descriptor = descriptor
        self.readBuffer = initialData
    }

    static func connect(socketPath: String, path: String, query: [(String, String)]?) throws -> UnixSocketWebSocket {
        let descriptor = try UnixSocketTransport.connect(socketPath: socketPath)
        do {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            for index in randomBytes.indices {
                randomBytes[index] = UInt8.random(in: .min ... .max)
            }
            let key = Data(randomBytes).base64EncodedString()
            let requestPath = path + queryString(query)
            let request = "GET \(requestPath) HTTP/1.1\r\n"
                + "Host: pi-agent\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: \(key)\r\n\r\n"
            try UnixSocketTransport.writeAll(descriptor, data: Data(request.utf8))

            let response = try readHTTPHeaders(descriptor)
            guard response.status == 101,
                  response.headers["upgrade"]?.lowercased() == "websocket",
                  response.headers["connection"]?.lowercased().contains("upgrade") == true,
                  let accept = response.headers["sec-websocket-accept"]
            else {
                Darwin.close(descriptor)
                throw RuntimeClientError.unexpectedHTTPStatus(response.status)
            }

            let expectedAccept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard accept == expectedAccept else {
                Darwin.close(descriptor)
                throw UnixSocketWebSocketError.invalidHandshake
            }
            return UnixSocketWebSocket(descriptor: descriptor, initialData: response.remaining)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func close() {
        writeLock.lock()
        guard !closed else {
            writeLock.unlock()
            return
        }
        closed = true
        writeLock.unlock()
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    func sendText(_ text: String) throws {
        try sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func receiveText() throws -> String {
        var message = Data()
        var expectingContinuation = false

        while true {
            let frame = try readFrame()
            switch frame.opcode {
            case 0x8:
                if !isClosed {
                    try? sendFrame(opcode: Self.closeOpcode, payload: frame.payload)
                }
                throw UnixSocketWebSocketError.closed
            case 0x9:
                try sendFrame(opcode: 0xA, payload: frame.payload)
            case 0xA:
                continue
            case 0x1:
                guard !expectingContinuation else { throw UnixSocketWebSocketError.invalidFrame }
                message = frame.payload
                if frame.fin {
                    return try decodeText(message)
                }
                expectingContinuation = true
            case 0x0:
                guard expectingContinuation else { throw UnixSocketWebSocketError.invalidFrame }
                message.append(frame.payload)
                if frame.fin {
                    return try decodeText(message)
                }
            default:
                if !frame.fin || (frame.opcode & 0x8) != 0 {
                    throw UnixSocketWebSocketError.invalidFrame
                }
                throw UnixSocketWebSocketError.unsupportedMessage
            }
            if message.count > Self.maxFrameSize {
                throw UnixSocketWebSocketError.messageTooLarge
            }
        }
    }

    private var isClosed: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return closed
    }

    private func decodeText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UnixSocketWebSocketError.invalidFrame
        }
        return text
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        guard payload.count <= Self.maxFrameSize else {
            throw UnixSocketWebSocketError.messageTooLarge
        }
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))

        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let value = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        for index in mask.indices {
            mask[index] = UInt8.random(in: .min ... .max)
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }

        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { throw UnixSocketWebSocketError.closed }
        try UnixSocketTransport.writeAll(descriptor, data: frame)
    }

    private func readFrame() throws -> WebSocketFrame {
        let first = try readByte()
        let second = try readByte()
        let fin = (first & 0x80) != 0
        let opcode = first & 0x0F
        let isMasked = (second & 0x80) != 0
        var length = UInt64(second & 0x7F)

        if length == 126 {
            length = UInt64(try readUInt16())
        } else if length == 127 {
            length = try readUInt64()
            guard length <= UInt64(Self.maxFrameSize) else {
                throw UnixSocketWebSocketError.messageTooLarge
            }
        }
        guard length <= UInt64(Self.maxFrameSize), length <= UInt64(Int.max) else {
            throw UnixSocketWebSocketError.messageTooLarge
        }
        if (opcode & 0x8) != 0 && (!fin || length > 125) {
            throw UnixSocketWebSocketError.invalidFrame
        }

        var mask = [UInt8]()
        if isMasked { mask = try readBytes(count: 4) }
        var payload = try readData(count: Int(length))
        if !mask.isEmpty {
            payload.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                for index in 0..<bytes.count {
                    baseAddress.storeBytes(of: baseAddress.load(fromByteOffset: index, as: UInt8.self) ^ mask[index % 4], toByteOffset: index, as: UInt8.self)
                }
            }
        }
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }

    private func readByte() throws -> UInt8 {
        try readBytes(count: 1)[0]
    }

    private func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func readBytes(count: Int) throws -> [UInt8] {
        Array(try readData(count: count))
    }

    private func readData(count: Int) throws -> Data {
        guard count >= 0 else { throw UnixSocketWebSocketError.invalidFrame }
        while readBuffer.count < count {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let readCount = buffer.withUnsafeMutableBytes { destination in
                read(descriptor, destination.baseAddress, destination.count)
            }
            if readCount < 0 && errno == EINTR { continue }
            if readCount == 0 { throw UnixSocketWebSocketError.closed }
            if readCount < 0 {
                throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
            }
            readBuffer.append(contentsOf: buffer[0..<readCount])
            if readBuffer.count > Self.maxFrameSize + 16 * 1024 {
                throw UnixSocketWebSocketError.messageTooLarge
            }
        }
        let value = Data(readBuffer.prefix(count))
        readBuffer.removeFirst(count)
        return value
    }

    private struct WebSocketFrame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    private struct HTTPHeaders {
        let status: Int
        let headers: [String: String]
        let remaining: Data
    }

    private static func readHTTPHeaders(_ descriptor: Int32) throws -> HTTPHeaders {
        var response = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while response.range(of: delimiter) == nil {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { destination in
                read(descriptor, destination.baseAddress, destination.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { throw UnixSocketWebSocketError.invalidHandshake }
            if count < 0 {
                throw RuntimeClientError.connectionFailed(String(cString: strerror(errno)))
            }
            response.append(contentsOf: buffer[0..<count])
            if response.count > 64 * 1024 { throw UnixSocketWebSocketError.invalidHandshake }
        }
        guard let headerEnd = response.range(of: delimiter) else {
            throw UnixSocketWebSocketError.invalidHandshake
        }
        let headerText = String(decoding: response[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw UnixSocketWebSocketError.invalidHandshake }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw UnixSocketWebSocketError.invalidHandshake
        }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return HTTPHeaders(status: status, headers: headers, remaining: Data(response[headerEnd.upperBound...]))
    }

    private static func queryString(_ values: [(String, String)]?) -> String {
        guard let values, !values.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return "" }
        return "?\(query)"
    }
}

/// Owns one WebSocket read loop and closes it when the subscription is
/// cancelled. The generic runner is shared by session JSON events and
/// terminal JSON messages; terminal writes use the same masked-frame path.
private final class UnixSocketStreamRunner<Event: Sendable>: @unchecked Sendable {
    private let socketPath: String
    private let path: String
    private let query: [(String, String)]?
    private let decode: (Data) throws -> Event
    private let lock = NSLock()
    private let eventContinuation: AsyncThrowingStream<Event, Error>.Continuation
    private let readyContinuation: AsyncThrowingStream<Void, Error>.Continuation
    private(set) var events: AsyncThrowingStream<Event, Error>
    private(set) var ready: AsyncThrowingStream<Void, Error>
    private var task: Task<Void, Never>?
    private var connection: UnixSocketWebSocket?
    private var pendingMessages: [String] = []
    private var cancelled = false
    private var finished = false

    init(socketPath: String, path: String, query: [(String, String)]?, decode: @escaping (Data) throws -> Event) {
        self.socketPath = socketPath
        self.path = path
        self.query = query
        self.decode = decode
        let eventStream = AsyncThrowingStream<Event, Error>.makeStream()
        let readyStream = AsyncThrowingStream<Void, Error>.makeStream()
        self.events = eventStream.stream
        self.ready = readyStream.stream
        self.eventContinuation = eventStream.continuation
        self.readyContinuation = readyStream.continuation
    }

    private func start() {
        lock.lock()
        guard task == nil, !cancelled else {
            lock.unlock()
            return
        }
        let socketPath = self.socketPath
        let path = self.path
        let query = self.query
        lock.unlock()

        let newTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let socket = try UnixSocketWebSocket.connect(socketPath: socketPath, path: path, query: query)
                guard self.install(socket) else { return }
                self.readyContinuation.yield(())
                self.readyContinuation.finish()
                self.flushPendingMessages()

                while !Task.isCancelled {
                    let text = try socket.receiveText()
                    let event = try self.decode(Data(text.utf8))
                    self.eventContinuation.yield(event)
                }
                self.finish()
            } catch {
                self.fail(error)
            }
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            newTask.cancel()
            return
        }
        task = newTask
        lock.unlock()
    }

    private func install(_ socket: UnixSocketWebSocket) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            socket.close()
            return false
        }
        connection = socket
        lock.unlock()
        return true
    }

    private func flushPendingMessages() {
        lock.lock()
        let messages = pendingMessages
        pendingMessages.removeAll(keepingCapacity: false)
        let socket = connection
        lock.unlock()
        guard let socket else { return }
        do {
            for message in messages { try socket.sendText(message) }
        } catch {
            fail(error)
        }
    }

    private func sendJSON<Payload: Encodable>(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        if let socket = connection {
            lock.unlock()
            do { try socket.sendText(text) } catch { fail(error) }
        } else {
            pendingMessages.append(text)
            lock.unlock()
        }
    }

    private func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let socket = connection
        let task = self.task
        connection = nil
        lock.unlock()
        socket?.close()
        task?.cancel()
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let socket = connection
        connection = nil
        lock.unlock()
        socket?.close()
        readyContinuation.finish()
        eventContinuation.finish()
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return
        }
        finished = true
        let socket = connection
        connection = nil
        lock.unlock()
        socket?.close()
        readyContinuation.finish(throwing: error)
        eventContinuation.finish(throwing: error)
    }
}

private extension UnixSocketStreamRunner where Event == RuntimeSessionEvent {
    func eventSubscription() -> RuntimeEventSubscription {
        start()
        return RuntimeEventSubscription(
            events: events,
            ready: ready,
            cancel: { [self] in self.cancel() }
        )
    }
}

private extension UnixSocketStreamRunner where Event == RuntimeTerminalEvent {
    func terminalSubscription() -> RuntimeTerminalSubscription {
        start()
        return RuntimeTerminalSubscription(
            events: events,
            ready: ready,
            sendInput: { [self] data in
                self.sendJSON(TerminalInputPayload(type: "input", data: data))
            },
            resize: { [self] cols, rows in
                self.sendJSON(TerminalResizePayload(type: "resize", cols: cols, rows: rows))
            },
            cancel: { [self] in self.cancel() }
        )
    }
}

private struct TerminalInputPayload: Encodable {
    let type: String
    let data: String
}

private struct TerminalResizePayload: Encodable {
    let type: String
    let cols: Int
    let rows: Int
}
