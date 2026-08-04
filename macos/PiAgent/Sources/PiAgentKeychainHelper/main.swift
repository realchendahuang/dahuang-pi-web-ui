import Foundation
import Security

private let service = "com.realchendahuang.pi-agent.credentials.v1"
private let maximumInputBytes = 1_048_576

private struct Request: Decodable {
    let operation: String
    let providerId: String?
    let credentialBase64: String?
    let credentialType: String?
}

private struct CredentialInfo: Encodable {
    let providerId: String
    let type: String
}

private struct Response: Encodable {
    let found: Bool?
    let credentialBase64: String?
    let credentialType: String?
    let credentials: [CredentialInfo]?
    let error: String?

    init(
        found: Bool? = nil,
        credentialBase64: String? = nil,
        credentialType: String? = nil,
        credentials: [CredentialInfo]? = nil,
        error: String? = nil
    ) {
        self.found = found
        self.credentialBase64 = credentialBase64
        self.credentialType = credentialType
        self.credentials = credentials
        self.error = error
    }
}

@main
struct PiAgentKeychainHelper {
    static func main() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= maximumInputBytes else { throw HelperError.invalidRequest }
            let request = try JSONDecoder().decode(Request.self, from: data)
            let response = try handle(request)
            try write(response)
        } catch {
            try? write(Response(error: error.localizedDescription))
            Foundation.exit(1)
        }
    }

    private static func handle(_ request: Request) throws -> Response {
        switch request.operation {
        case "read": return try read(providerId: try providerId(from: request))
        case "write": return try write(
            providerId: try providerId(from: request),
            credentialBase64: try required(request.credentialBase64),
            credentialType: try credentialType(request.credentialType)
        )
        case "delete": return try delete(providerId: try providerId(from: request))
        case "list": return try list()
        default: throw HelperError.invalidRequest
        }
    }

    private static func read(providerId: String) throws -> Response {
        var query = itemQuery(providerId: providerId)
        query[kSecReturnAttributes] = true
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Response(found: false) }
        try requireSuccess(status)
        guard let item = result as? [CFString: Any],
              let data = item[kSecValueData] as? Data,
              let type = item[kSecAttrComment] as? String,
              isCredentialType(type)
        else { throw HelperError.invalidStoredCredential }
        return Response(found: true, credentialBase64: data.base64EncodedString(), credentialType: type)
    }

    private static func write(providerId: String, credentialBase64: String, credentialType: String) throws -> Response {
        guard let data = Data(base64Encoded: credentialBase64), data.count <= maximumInputBytes else {
            throw HelperError.invalidRequest
        }
        let query = itemQuery(providerId: providerId)
        let updates: [CFString: Any] = [kSecValueData: data, kSecAttrComment: credentialType]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            attributes[kSecAttrComment] = credentialType
            try requireSuccess(SecItemAdd(attributes as CFDictionary, nil))
        } else {
            try requireSuccess(status)
        }
        return Response(found: true)
    }

    private static func delete(providerId: String) throws -> Response {
        let status = SecItemDelete(itemQuery(providerId: providerId) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            try requireSuccess(status)
        }
        return Response(found: false)
    }

    private static func list() throws -> Response {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Response(credentials: []) }
        try requireSuccess(status)
        let items = result as? [[CFString: Any]] ?? []
        let credentials = items.compactMap { item -> CredentialInfo? in
            guard let providerId = item[kSecAttrAccount] as? String,
                  let type = item[kSecAttrComment] as? String,
                  isProviderId(providerId), isCredentialType(type)
            else { return nil }
            return CredentialInfo(providerId: providerId, type: type)
        }.sorted { $0.providerId < $1.providerId }
        return Response(credentials: credentials)
    }

    private static func itemQuery(providerId: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: providerId]
    }

    private static func providerId(from request: Request) throws -> String {
        let value = try required(request.providerId)
        guard isProviderId(value) else { throw HelperError.invalidRequest }
        return value
    }

    private static func credentialType(_ value: String?) throws -> String {
        let type = try required(value)
        guard isCredentialType(type) else { throw HelperError.invalidRequest }
        return type
    }

    private static func required(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw HelperError.invalidRequest }
        return value
    }

    private static func isProviderId(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    private static func isCredentialType(_ value: String) -> Bool {
        value == "api_key" || value == "oauth"
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw HelperError.keychain(status) }
    }

    private static func write(_ response: Response) throws {
        let data = try JSONEncoder().encode(response)
        FileHandle.standardOutput.write(data)
    }
}

private enum HelperError: LocalizedError {
    case invalidRequest
    case invalidStoredCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid Pi Agent Keychain request"
        case .invalidStoredCredential: return "Stored Pi Agent Keychain credential is invalid"
        case let .keychain(status): return "Pi Agent Keychain operation failed (\(status))"
        }
    }
}
