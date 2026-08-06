import Foundation
import Testing
@testable import PiAgentCore

@Suite("Runtime contract codable")
struct RuntimeContractCodableTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesRuntimeSessionModelWithAllFields() throws {
        let model: RuntimeSessionModel = try decode("""
        {
            "provider": "anthropic",
            "id": "claude-sonnet-4",
            "name": "Claude Sonnet 4",
            "contextWindow": 200000,
            "reasoning": true
        }
        """)

        #expect(model.provider == "anthropic")
        #expect(model.id == "claude-sonnet-4")
        #expect(model.name == "Claude Sonnet 4")
        #expect(model.contextWindow == 200000)
        #expect(model.reasoning == true)
    }

    @Test func decodesRuntimeSessionModelWithMissingFields() throws {
        let model: RuntimeSessionModel = try decode(#"{"id": "small-model"}"#)

        #expect(model.id == "small-model")
        #expect(model.provider == nil)
        #expect(model.name == nil)
        #expect(model.contextWindow == nil)
        #expect(model.reasoning == nil)
    }

    @Test func toleratesUnknownReasoningWireType() throws {
        // The runtime reports reasoning as `unknown`; decode must not fail.
        let model: RuntimeSessionModel = try decode(#"{"id": "m", "reasoning": "unknown"}"#)

        #expect(model.id == "m")
        #expect(model.reasoning == nil)
    }

    @Test func decodesRuntimeSessionStatus() throws {
        let status: RuntimeSessionStatus = try decode("""
        {
            "sessionId": "s1",
            "runtimeId": "pi",
            "model": { "provider": "anthropic", "id": "claude-sonnet-4" },
            "thinkingLevel": "high",
            "isStreaming": true,
            "isCompacting": false,
            "isBashRunning": false,
            "pendingMessageCount": 2,
            "messageCount": 10
        }
        """)

        #expect(status.sessionId == "s1")
        #expect(status.model?.id == "claude-sonnet-4")
        #expect(status.thinkingLevel == "high")
        #expect(status.isStreaming)
        #expect(status.pendingMessageCount == 2)
        #expect(status.messageCount == 10)
    }

    @Test func decodesStreamSnapshotMessageEvent() throws {
        let event: RuntimeSessionEvent = try decode("""
        {
            "type": "message",
            "seq": 7,
            "message": { "id": "m1", "role": "user", "text": "hello" }
        }
        """)

        #expect(event.type == "message")
        #expect(event.seq == 7)
        #expect(event.message?.id == "m1")
        #expect(event.message?.text == "hello")
    }

    @Test func decodesStatusUpdateEvent() throws {
        let event: RuntimeSessionEvent = try decode("""
        {
            "type": "status.update",
            "status": {
                "sessionId": "s1",
                "isStreaming": false,
                "isCompacting": false,
                "isBashRunning": false,
                "pendingMessageCount": 0
            }
        }
        """)

        #expect(event.type == "status.update")
        #expect(event.status?.isStreaming == false)
    }

    @Test func decodesDeltaEvent() throws {
        let event: RuntimeSessionEvent = try decode(#"{"type": "delta", "chunk": "part", "seq": 3}"#)

        #expect(event.type == "delta")
        #expect(event.chunk == "part")
    }

    @Test func decodesUnreadCatalog() throws {
        let catalog: RuntimeUnreadCatalog = try decode("""
        {
            "catalogId": "cat-1",
            "catalogRevision": 3,
            "sessions": [
                {
                    "sessionId": "s2",
                    "cwd": "/projects/a",
                    "completionOrder": 7,
                    "completedAt": "2026-08-05T09:00:00Z"
                }
            ]
        }
        """)

        #expect(catalog.catalogId == "cat-1")
        #expect(catalog.catalogRevision == 3)
        #expect(catalog.sessions.count == 1)
        #expect(catalog.sessions[0].sessionId == "s2")
        #expect(catalog.sessions[0].completionOrder == 7)
    }

    @Test func surfacesErrorMessageForSessionError() throws {
        let event: RuntimeSessionEvent = try decode(#"{"type": "session.error", "text": "boom"}"#)

        #expect(event.errorMessage == "boom")
    }
}
