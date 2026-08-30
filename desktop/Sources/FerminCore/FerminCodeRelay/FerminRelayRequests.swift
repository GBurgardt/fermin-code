import Foundation

public struct FerminRelayHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    public let ready: Bool
    public let service: String
    public let version: String
    public let schemaVersion: Int
    public let role: String
    public let details: JSONValue

    public init(
        ok: Bool,
        ready: Bool,
        service: String,
        version: String,
        schemaVersion: Int,
        role: String,
        details: JSONValue = .object([:])
    ) {
        self.ok = ok
        self.ready = ready
        self.service = service
        self.version = version
        self.schemaVersion = schemaVersion
        self.role = role
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case ok, ready, service, version, schemaVersion, role, details
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok)
        ready = values.relayBool(forKey: .ready)
        service = values.relayString(forKey: .service)
        version = values.relayString(forKey: .version)
        schemaVersion = values.relayInt(forKey: .schemaVersion)
        role = values.relayString(forKey: .role)
        details = values.relayValue(JSONValue.self, forKey: .details) ?? .object([:])
    }
}

public struct FerminRelayProjectDirectory: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let kind: String?

    public var id: String { path }

    public init(name: String, path: String, kind: String? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case name, path, kind }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = values.relayString(forKey: .name)
        path = values.relayString(forKey: .path)
        kind = values.relayStringIfPresent(forKey: .kind)
    }
}

public struct FerminRelayProjectDirectoryEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let rootPath: String?
    public let items: [FerminRelayProjectDirectory]

    public init(
        ok: Bool = true,
        rootPath: String? = nil,
        items: [FerminRelayProjectDirectory]
    ) {
        self.ok = ok
        self.rootPath = rootPath
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case ok, rootPath, items }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        rootPath = values.relayStringIfPresent(forKey: .rootPath)
        items = values.relayArray(FerminRelayProjectDirectory.self, forKey: .items)
    }
}

public struct FerminRelayFilePreview: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let content: String
    public let kind: String
    public let language: String?
    public let sizeBytes: Int

    public init(
        path: String,
        name: String,
        content: String,
        kind: String,
        language: String? = nil,
        sizeBytes: Int
    ) {
        self.path = path
        self.name = name
        self.content = content
        self.kind = kind
        self.language = language
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, content, kind, language, sizeBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = values.relayString(forKey: .path)
        name = values.relayString(forKey: .name)
        content = values.relayString(forKey: .content)
        kind = values.relayString(forKey: .kind, default: "text")
        language = values.relayStringIfPresent(forKey: .language)
        sizeBytes = values.relayInt(forKey: .sizeBytes)
    }
}

public struct FerminRelayAttachmentUpload: Equatable, Sendable {
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public init(fileName: String, mimeType: String, data: Data) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

public struct FerminRelayAttachmentUploadEnvelope: Codable, Equatable, Sendable {
    public let ok: Bool
    public let path: String
    public let bytes: Int
    public let mimeType: String

    public init(ok: Bool = true, path: String, bytes: Int, mimeType: String) {
        self.ok = ok
        self.path = path
        self.bytes = bytes
        self.mimeType = mimeType
    }

    private enum CodingKeys: String, CodingKey { case ok, path, bytes, mimeType }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        path = values.relayString(forKey: .path)
        bytes = values.relayInt(forKey: .bytes)
        mimeType = values.relayString(forKey: .mimeType)
    }
}

public struct FerminRelayAttachmentContent: Equatable, Sendable {
    public let data: Data
    public let mimeType: String?

    public init(data: Data, mimeType: String?) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct FerminRelayCreateSessionRequest: Codable, Equatable, Sendable {
    public let projectPath: String
    public let sessionID: String?
    public let sessionName: String?
    public let model: String?
    public let reasoningEffort: String?
    public let idempotencyKey: String?

    public init(
        projectPath: String,
        sessionID: String? = nil,
        sessionName: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case projectPath
        case sessionID = "sessionId"
        case sessionName, model, reasoningEffort, idempotencyKey
    }
}

public struct FerminRelayMessageAttachment: Codable, Equatable, Sendable {
    public let id: String?
    public let path: String
    public let name: String
    public let size: Int
    public let mimeType: String

    public init(
        id: String? = nil,
        path: String,
        name: String,
        size: Int,
        mimeType: String
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

public struct FerminRelaySendMessageRequest: Codable, Equatable, Sendable {
    public let message: String
    public let clientMessageID: String?
    public let attachments: [FerminRelayMessageAttachment]
    public let features: FerminRelaySessionFeatures?
    public let fastModeEnabled: Bool?
    public let parentNotificationPrompt: String?
    public let idempotencyKey: String?

    public init(
        message: String,
        clientMessageID: String? = nil,
        attachments: [FerminRelayMessageAttachment] = [],
        features: FerminRelaySessionFeatures? = nil,
        fastModeEnabled: Bool? = nil,
        parentNotificationPrompt: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.message = message
        self.clientMessageID = clientMessageID
        self.attachments = attachments
        self.features = features
        self.fastModeEnabled = fastModeEnabled
        self.parentNotificationPrompt = parentNotificationPrompt
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case clientMessageID = "clientMessageId"
        case attachments, features, fastModeEnabled, parentNotificationPrompt, idempotencyKey
    }
}

public struct FerminRelaySteerRequest: Codable, Equatable, Sendable {
    public let message: String
    public let idempotencyKey: String?

    public init(message: String, idempotencyKey: String? = nil) {
        self.message = message
        self.idempotencyKey = idempotencyKey
    }
}

public struct FerminRelayFeaturePatch: Codable, Equatable, Sendable {
    public let promptImproverEnabled: Bool?
    public let explainerEnabled: Bool?
    public let codeContextEnabled: Bool?
    public let idempotencyKey: String?

    public init(
        promptImproverEnabled: Bool? = nil,
        explainerEnabled: Bool? = nil,
        codeContextEnabled: Bool? = nil,
        idempotencyKey: String? = nil
    ) {
        self.promptImproverEnabled = promptImproverEnabled
        self.explainerEnabled = explainerEnabled
        self.codeContextEnabled = codeContextEnabled
        self.idempotencyKey = idempotencyKey
    }
}

public struct FerminRelayRunModeRequest: Codable, Equatable, Sendable {
    public let goalEnabled: Bool
    public let objective: String?
    public let idempotencyKey: String?

    public init(
        goalEnabled: Bool,
        objective: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.goalEnabled = goalEnabled
        self.objective = objective
        self.idempotencyKey = idempotencyKey
    }
}

public struct FerminRelayModelSettingsRequest: Codable, Equatable, Sendable {
    public let model: String
    public let modelProvider: String?
    public let reasoningEffort: String
    public let idempotencyKey: String?

    public init(
        model: String,
        modelProvider: String? = "openai",
        reasoningEffort: String,
        idempotencyKey: String? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.reasoningEffort = reasoningEffort
        self.idempotencyKey = idempotencyKey
    }
}

public struct FerminRelayRuntimeModelSettings: Codable, Equatable, Sendable {
    public let model: String
    public let modelProvider: String?
    public let effort: String

    public init(model: String, modelProvider: String? = nil, effort: String) {
        self.model = model
        self.modelProvider = modelProvider
        self.effort = effort
    }

    private enum CodingKeys: String, CodingKey { case model, modelProvider, effort }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = values.relayString(forKey: .model)
        modelProvider = values.relayStringIfPresent(forKey: .modelProvider)
        effort = values.relayString(forKey: .effort)
    }
}

public struct FerminRelayModelSettingsEnvelope: Codable, Equatable, Sendable {
    public let ok: Bool
    public let modelSettings: FerminRelayRuntimeModelSettings
    public let command: FerminRelayDurableCommandAcknowledgement

    public init(
        ok: Bool = true,
        modelSettings: FerminRelayRuntimeModelSettings,
        command: FerminRelayDurableCommandAcknowledgement
    ) {
        self.ok = ok
        self.modelSettings = modelSettings
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case ok, modelSettings, command }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        modelSettings = values.relayValue(
            FerminRelayRuntimeModelSettings.self,
            forKey: .modelSettings
        ) ?? FerminRelayRuntimeModelSettings(model: "", effort: "")
        command = values.relayValue(
            FerminRelayDurableCommandAcknowledgement.self,
            forKey: .command
        ) ?? FerminRelayDurableCommandAcknowledgement(
            ok: false,
            commandID: "",
            commandState: nil,
            inserted: nil,
            durable: nil,
            queuedAt: nil
        )
    }
}

public struct FerminRelayCreateSubagentRequest: Codable, Equatable, Sendable {
    public let message: String
    public let sessionID: String?
    public let displayName: String?
    public let parentNotificationPrompt: String?
    public let engine: String?
    public let idempotencyKey: String?

    public init(
        message: String,
        sessionID: String? = nil,
        displayName: String? = nil,
        parentNotificationPrompt: String? = nil,
        engine: String? = "codex",
        idempotencyKey: String? = nil
    ) {
        self.message = message
        self.sessionID = sessionID
        self.displayName = displayName
        self.parentNotificationPrompt = parentNotificationPrompt
        self.engine = engine
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case sessionID = "sessionId"
        case displayName, parentNotificationPrompt, engine, idempotencyKey
    }
}

public struct FerminRelayHistoryResumeEnvelope: Codable, Equatable, Sendable {
    public let ok: Bool
    public let queued: Bool
    public let commandID: String
    public let queuedAt: Double
    public let state: FerminRelayDurableCommandState
    public let windowID: String?
    public let sessionID: String
    public let projectPath: String?

    public init(
        ok: Bool,
        queued: Bool,
        commandID: String,
        queuedAt: Double,
        state: FerminRelayDurableCommandState,
        windowID: String? = nil,
        sessionID: String,
        projectPath: String? = nil
    ) {
        self.ok = ok
        self.queued = queued
        self.commandID = commandID
        self.queuedAt = queuedAt
        self.state = state
        self.windowID = windowID
        self.sessionID = sessionID
        self.projectPath = projectPath
    }

    private enum CodingKeys: String, CodingKey {
        case ok, queued
        case commandID = "commandId"
        case queuedAt, state
        case windowID = "windowId"
        case sessionID = "sessionId"
        case projectPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok)
        queued = values.relayBool(forKey: .queued)
        commandID = values.relayString(forKey: .commandID)
        queuedAt = values.relayDouble(forKey: .queuedAt)
        state = values.relayValue(FerminRelayDurableCommandState.self, forKey: .state)
            ?? .unknown
        windowID = values.relayStringIfPresent(forKey: .windowID)
        sessionID = values.relayString(forKey: .sessionID)
        projectPath = values.relayStringIfPresent(forKey: .projectPath)
    }
}

public struct FerminRelayOmittedEvent: Codable, Equatable, Sendable {
    public let ok: Bool
    public let code: String
    public let reason: String
    public let originalEvent: String
    public let originalBytes: Int
    public let refetchRequired: Bool

    public init(
        ok: Bool,
        code: String,
        reason: String,
        originalEvent: String,
        originalBytes: Int,
        refetchRequired: Bool
    ) {
        self.ok = ok
        self.code = code
        self.reason = reason
        self.originalEvent = originalEvent
        self.originalBytes = originalBytes
        self.refetchRequired = refetchRequired
    }

    private enum CodingKeys: String, CodingKey {
        case ok, code, reason, originalEvent, originalBytes, refetchRequired
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok)
        code = values.relayString(forKey: .code)
        reason = values.relayString(forKey: .reason)
        originalEvent = values.relayString(forKey: .originalEvent)
        originalBytes = values.relayInt(forKey: .originalBytes)
        refetchRequired = values.relayBool(forKey: .refetchRequired, default: true)
    }
}
