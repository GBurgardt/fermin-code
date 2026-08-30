import Foundation

public struct FerminRelaySessionRemovedEvent: Codable, Equatable, Sendable {
    public let windowID: String?
    public let sessionID: String?

    public init(windowID: String? = nil, sessionID: String? = nil) {
        self.windowID = windowID
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case sessionID = "sessionId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = values.relayStringIfPresent(forKey: .windowID)
        sessionID = values.relayStringIfPresent(forKey: .sessionID)
    }
}

public struct FerminRelayEventTarget: Codable, Equatable, Sendable {
    public let windowID: String?
    public let sessionID: String?

    public init(windowID: String? = nil, sessionID: String? = nil) {
        self.windowID = windowID
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case sessionID = "sessionId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = values.relayStringIfPresent(forKey: .windowID)
        sessionID = values.relayStringIfPresent(forKey: .sessionID)
    }
}

public struct FerminRelayLiveMessagePatch: Codable, Equatable, Sendable {
    public let windowID: String
    public let message: FerminRelayMessage
    public let revision: Int
    public let updatedAt: Double
    public let isFinal: Bool

    public init(
        windowID: String,
        message: FerminRelayMessage,
        revision: Int,
        updatedAt: Double,
        isFinal: Bool
    ) {
        self.windowID = windowID
        self.message = message
        self.revision = revision
        self.updatedAt = updatedAt
        self.isFinal = isFinal
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case message, revision, updatedAt
        case isFinal = "final"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = values.relayString(forKey: .windowID)
        message = values.relayValue(FerminRelayMessage.self, forKey: .message)
            ?? FerminRelayMessage(id: "", role: "", content: "")
        revision = values.relayInt(forKey: .revision)
        updatedAt = values.relayDouble(forKey: .updatedAt)
        isFinal = values.relayBool(forKey: .isFinal)
    }
}

public enum FerminRelayDecodedStreamEvent: Equatable, Sendable {
    case snapshot(FerminRelaySessionsEnvelope)
    case messagePatch(FerminRelayLiveMessagePatch)
    case commandStateChanged(FerminRelayCommandStateChangedEvent)
    case sessionUpserted(FerminRelaySession)
    case sessionRemoved(FerminRelaySessionRemovedEvent)
    case eventOmitted(FerminRelayOmittedEvent)
    case refreshTarget(name: String, target: FerminRelayEventTarget)
    case serverError(String)
    case unknown(name: String, data: Data)
}

public enum FerminRelayStreamEventDecodingError: Error, Equatable, Sendable {
    case invalidSessionIdentity
}

public enum FerminRelayStreamEventDecoder {
    private static let refreshEvents: Set<String> = [
        "turn_started", "turn_completed", "turn_interrupted",
        "item_started", "item_updated", "item_completed",
        "approval_requested", "approval_resolved",
        "user_input_requested", "user_input_resolved",
        "model_catalog_updated", "goal_updated", "subagent_updated",
        "runtime_status",
    ]

    public static func decode(
        _ event: FerminRelaySSEEvent,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FerminRelayDecodedStreamEvent {
        switch event.name {
        case "snapshot":
            return .snapshot(try decoder.decode(FerminRelaySessionsEnvelope.self, from: event.data))
        case "message_patch":
            return .messagePatch(try decoder.decode(FerminRelayLiveMessagePatch.self, from: event.data))
        case "command_state_changed":
            return .commandStateChanged(
                try decoder.decode(FerminRelayCommandStateChangedEvent.self, from: event.data)
            )
        case "session_upserted":
            let session = try decoder.decode(FerminRelaySession.self, from: event.data)
            let windowID = session.windowID.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionID = session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !windowID.isEmpty, !sessionID.isEmpty {
                return .sessionUpserted(session)
            }
            if let normalized = try? decoder.decode(
                FerminRelayNormalizedEventWrapper.self,
                from: event.data
            ), !normalized.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .refreshTarget(
                    name: "session_upserted",
                    target: FerminRelayEventTarget()
                )
            }
            throw FerminRelayStreamEventDecodingError.invalidSessionIdentity
        case "session_removed":
            return .sessionRemoved(
                try decoder.decode(FerminRelaySessionRemovedEvent.self, from: event.data)
            )
        case "event_omitted":
            return .eventOmitted(try decoder.decode(FerminRelayOmittedEvent.self, from: event.data))
        case "error":
            if let object = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any],
               let message = object["error"] as? String {
                return .serverError(message)
            }
            return .serverError(String(data: event.data, encoding: .utf8) ?? "")
        case let name where refreshEvents.contains(name):
            let target = (try? decoder.decode(FerminRelayEventTarget.self, from: event.data))
                ?? FerminRelayEventTarget()
            return .refreshTarget(name: name, target: target)
        default:
            return .unknown(name: event.name, data: event.data)
        }
    }
}

private struct FerminRelayNormalizedEventWrapper: Decodable {
    let method: String
    let threadID: String?
    let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case method
        case threadID = "threadId"
        case params
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = values.relayString(forKey: .method)
        threadID = values.relayStringIfPresent(forKey: .threadID)
        params = values.relayValue(JSONValue.self, forKey: .params)
    }
}
