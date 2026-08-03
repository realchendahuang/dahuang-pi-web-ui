import Foundation

#if os(macOS)
import Darwin
#else
import Glibc
#endif

public struct UnixSocketRuntimeClient: RuntimeHealthClient, Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func health() async throws -> RuntimeHealth {
        let socketPath = socketPath
        return try await Task.detached(priority: .userInitiated) {
            try UnixSocketHTTP.getJSON(path: "/health", socketPath: socketPath)
        }.value
    }
}

private enum UnixSocketHTTP {
    static func getJSON<T: Decodable>(path: String, socketPath: String) throws -> T {
        let body = try get(path: path, socketPath: socketPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw RuntimeClientError.invalidJSON(String(describing: error))
        }
    }

    static func get(path: String, socketPath: String) throws -> Data {
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

        let request = "GET \(path) HTTP/1.1\r\nHost: pi-agent\r\nConnection: close\r\n\r\n"
        let requestBytes = Array(request.utf8)
        let written = requestBytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == requestBytes.count else {
            throw RuntimeClientError.connectionFailed("short write")
        }

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
        guard (200..<300).contains(status) else {
            throw RuntimeClientError.unexpectedHTTPStatus(status)
        }

        return response[headerEnd.upperBound...]
    }
}
