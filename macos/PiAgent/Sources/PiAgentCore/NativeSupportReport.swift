import Foundation

/// A deliberately small, redacted support artifact for the unsigned native
/// product. It records version and connection evidence only; it never includes
/// prompts, transcripts, workspace content, credentials, capability tokens, or
/// terminal bytes.
public struct NativeSupportReport: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public let bundleIdentifier: String?
        public let version: String?
        public let build: String?
        public let bundlePath: String

        public init(bundleIdentifier: String?, version: String?, build: String?, bundlePath: String) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.build = build
            self.bundlePath = bundlePath
        }
    }

    public struct Runtime: Codable, Equatable, Sendable {
        public let socket: String
        public let connectionState: String
        public let health: RuntimeHealth?
        public let hello: RuntimeHello?
        public let diagnosticError: String?

        public init(socket: String, connectionState: String, health: RuntimeHealth?, hello: RuntimeHello?, diagnosticError: String?) {
            self.socket = socket
            self.connectionState = connectionState
            self.health = health
            self.hello = hello
            self.diagnosticError = diagnosticError
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public let path: String
        public let authorization: String

        public init(path: String, authorization: String) {
            self.path = path
            self.authorization = authorization
        }
    }

    public struct Provider: Codable, Equatable, Sendable {
        public let id: String
        public let authType: String
        public let configured: Bool
        public let source: String?

        public init(id: String, authType: String, configured: Bool, source: String?) {
            self.id = id
            self.authType = authType
            self.configured = configured
            self.source = source
        }
    }

    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let redacted: Bool
    public let application: Application
    public let runtime: Runtime
    public let project: Project
    public let providers: [Provider]

    public init(
        generatedAt: Date = Date(),
        application: Application,
        runtime: Runtime,
        project: Project,
        providers: [Provider]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.redacted = true
        self.application = application
        self.runtime = runtime
        self.project = project
        self.providers = providers.sorted { lhs, rhs in
            (lhs.id, lhs.authType) < (rhs.id, rhs.authType)
        }
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
