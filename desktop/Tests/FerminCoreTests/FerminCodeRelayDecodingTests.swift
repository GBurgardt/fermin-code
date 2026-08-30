import Foundation
import Testing
@testable import FerminCore

@Suite("Fermin Code relay tolerant decoding")
struct FerminCodeRelayDecodingTests {
    @Test
    func authoritativeAndMobileSnapshotFieldsDecodeTogether() throws {
        let data = Data(
            """
            {
              "globalSequence": "42",
              "generatedAt": "1720000000123",
              "sessions": [{
                "windowId": 17,
                "sessionId": "session-1",
                "projectKey": "project",
                "displayName": "Build",
                "activityStatus": "ready",
                "messageCount": "2",
                "updatedAt": "1720000000000",
                "isPinned": "false",
                "canSend": "true",
                "futureField": {"ignored": true}
              }]
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(FerminRelaySessionsEnvelope.self, from: data)
        #expect(envelope.ok)
        #expect(envelope.cursor == 42)
        #expect(envelope.now == 1_720_000_000_123)
        #expect(envelope.items.count == 1)
        #expect(envelope.items[0].windowID == "17")
        #expect(envelope.items[0].messageCount == 2)
        #expect(envelope.items[0].canSend)
        #expect(envelope.items[0].isPinned == false)
        #expect(envelope.items[0].messages.isEmpty)
    }

    @Test
    func messageModelAndPreferencesTolerateMissingAndFutureFields() throws {
        let message = try JSONDecoder().decode(
            FerminRelayMessage.self,
            from: Data("{\"id\":5,\"role\":\"assistant\",\"content\":\"ok\",\"timestamp\":\"9.5\"}".utf8)
        )
        #expect(message.id == "5")
        #expect(message.timestamp == 9.5)
        #expect(message.imageAttachments.isEmpty)

        let preference = try JSONDecoder().decode(
            FerminRelayPromptImproverPreferenceEnvelope.self,
            from: Data("{\"preference\":{\"variant\":\"future-variant\"}}".utf8)
        )
        #expect(preference.ok)
        #expect(preference.preference.variant == .unknown)
        #expect(preference.preference.version == 1)
    }

    @Test
    func historyAcceptsCanonicalAndLegacyUUIDSpellings() throws {
        let canonical = try decodeHistoryItem(uuidKey: "sessionUuid")
        let legacy = try decodeHistoryItem(uuidKey: "sessionUUID")
        #expect(canonical.sessionUUID == "uuid-1")
        #expect(legacy.sessionUUID == "uuid-1")
        #expect(canonical.updatedAt == 1_720_000_000_000)
    }

    @Test
    func recoveryEnvelopeDecodesContentMatchesWithoutExposingHistorySemantics() throws {
        let envelope = try JSONDecoder().decode(
            FerminRelaySessionRecoveryEnvelope.self,
            from: Data(
                """
                {
                  "ok":true,"offset":0,"limit":20,"total":1,"hasMore":false,
                  "updatedAt":1720000000000,"items":[{
                    "id":"legacy-1","projectName":"cloudx-toolbox",
                    "projectPath":"/tmp/cloudx-toolbox","sessionName":"GitHub deploy notes",
                    "createdAt":1710000000000,"updatedAt":1720000000000,
                    "archived":false,"score":1.0,"preview":"tools.article-studio.tsx",
                    "matchedIn":"contenido","canRecover":true
                  }]
                }
                """.utf8
            )
        )
        #expect(envelope.items.count == 1)
        #expect(envelope.items[0].projectName == "cloudx-toolbox")
        #expect(envelope.items[0].matchedIn == "contenido")
        #expect(envelope.items[0].canRecover)
    }

    private func decodeHistoryItem(uuidKey: String) throws -> FerminRelaySessionHistoryItem {
        try JSONDecoder().decode(
            FerminRelaySessionHistoryItem.self,
            from: Data(
                """
                {
                  "id":"history-1","\(uuidKey)":"uuid-1","projectKey":"p",
                  "projectName":"Project","sessionId":"s","sessionName":"Session",
                  "sessionPath":"/tmp/s.jsonl","createdAt":1710000000000,
                  "updatedAt":1720000000000,"state":"archived","score":1.5,
                  "preview":"hello","canResume":true
                }
                """.utf8
            )
        )
    }
}
