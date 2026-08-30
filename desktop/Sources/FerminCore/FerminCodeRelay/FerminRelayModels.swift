import Foundation

public struct FerminRelayMessageImageAttachment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String?
    public let size: Int
    public let mimeType: String
    public let previewData: Data?

    public init(
        id: String,
        name: String,
        path: String? = nil,
        size: Int = 0,
        mimeType: String = "application/octet-stream",
        previewData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.previewData = previewData
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, size, mimeType, previewData
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.relayString(forKey: .id)
        name = values.relayString(forKey: .name)
        path = values.relayStringIfPresent(forKey: .path)
        size = values.relayInt(forKey: .size)
        mimeType = values.relayString(forKey: .mimeType, default: "application/octet-stream")
        previewData = values.relayValue(Data.self, forKey: .previewData)
    }
}

public struct FerminRelayMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let type: String?
    public let content: String
    public let originalPrompt: String?
    public let transformedPrompt: String?
    public let improvedPrompt: String?
    public let timestamp: Double
    public let status: String?
    public let imageAttachments: [FerminRelayMessageImageAttachment]
    public let transformStatus: String?
    public let transformErrorReason: String?
    public let promptTransformNote: String?

    public init(
        id: String,
        role: String,
        type: String? = nil,
        content: String,
        originalPrompt: String? = nil,
        transformedPrompt: String? = nil,
        improvedPrompt: String? = nil,
        timestamp: Double = 0,
        status: String? = nil,
        imageAttachments: [FerminRelayMessageImageAttachment] = [],
        transformStatus: String? = nil,
        transformErrorReason: String? = nil,
        promptTransformNote: String? = nil
    ) {
        self.id = id
        self.role = role
        self.type = type
        self.content = content
        self.originalPrompt = originalPrompt
        self.transformedPrompt = transformedPrompt
        self.improvedPrompt = improvedPrompt
        self.timestamp = timestamp
        self.status = status
        self.imageAttachments = imageAttachments
        self.transformStatus = transformStatus
        self.transformErrorReason = transformErrorReason
        self.promptTransformNote = promptTransformNote
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, type, content, originalPrompt, transformedPrompt, improvedPrompt
        case timestamp, status, imageAttachments, transformStatus, transformErrorReason
        case promptTransformNote
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.relayString(forKey: .id)
        role = values.relayString(forKey: .role)
        type = values.relayStringIfPresent(forKey: .type)
        content = values.relayString(forKey: .content)
        originalPrompt = values.relayStringIfPresent(forKey: .originalPrompt)
        transformedPrompt = values.relayStringIfPresent(forKey: .transformedPrompt)
        improvedPrompt = values.relayStringIfPresent(forKey: .improvedPrompt)
        timestamp = values.relayDouble(forKey: .timestamp)
        status = values.relayStringIfPresent(forKey: .status)
        imageAttachments = values.relayArray(
            FerminRelayMessageImageAttachment.self,
            forKey: .imageAttachments
        )
        transformStatus = values.relayStringIfPresent(forKey: .transformStatus)
        transformErrorReason = values.relayStringIfPresent(forKey: .transformErrorReason)
        promptTransformNote = values.relayStringIfPresent(forKey: .promptTransformNote)
    }
}

public struct FerminRelaySessionFeatures: Codable, Hashable, Sendable {
    public let promptImproverEnabled: Bool
    public let explainerEnabled: Bool
    public let codeContextEnabled: Bool

    public init(
        promptImproverEnabled: Bool = false,
        explainerEnabled: Bool = false,
        codeContextEnabled: Bool = false
    ) {
        self.promptImproverEnabled = promptImproverEnabled
        self.explainerEnabled = explainerEnabled
        self.codeContextEnabled = codeContextEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case promptImproverEnabled, explainerEnabled, codeContextEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        promptImproverEnabled = values.relayBool(forKey: .promptImproverEnabled)
        explainerEnabled = values.relayBool(forKey: .explainerEnabled)
        codeContextEnabled = values.relayBool(forKey: .codeContextEnabled)
    }
}

public struct FerminRelayPendingSubagent: Codable, Hashable, Sendable {
    public let displayMessage: String
    public let parentNotificationPrompt: String?
    public let childMessageSentAt: Double?

    public init(
        displayMessage: String,
        parentNotificationPrompt: String? = nil,
        childMessageSentAt: Double? = nil
    ) {
        self.displayMessage = displayMessage
        self.parentNotificationPrompt = parentNotificationPrompt
        self.childMessageSentAt = childMessageSentAt
    }

    private enum CodingKeys: String, CodingKey {
        case displayMessage, parentNotificationPrompt, childMessageSentAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayMessage = values.relayString(forKey: .displayMessage)
        parentNotificationPrompt = values.relayStringIfPresent(forKey: .parentNotificationPrompt)
        childMessageSentAt = values.relayDoubleIfPresent(forKey: .childMessageSentAt)
    }
}

public struct FerminRelaySession: Codable, Identifiable, Hashable, Sendable {
    public let windowID: String
    public let sessionID: String
    public let engine: String?
    public let model: String?
    public let reasoningEffort: String?
    public let providerSessionID: String?
    public let providerSessionPath: String?
    public let projectKey: String
    public let projectPath: String?
    public let projectName: String?
    public let windowName: String?
    public let displayName: String
    public let sidecarMode: String
    public let sidecarURL: String?
    public let activityStatus: String
    public let runtimeStatus: String?
    public let runtimeStatusDetail: String?
    public let features: FerminRelaySessionFeatures?
    public let runMode: String?
    public let goalStartedAt: Double?
    public let messageCount: Int
    public let updatedAt: Double
    public let createdAt: Double?
    public let rawPrompt: String?
    public let originalPrompt: String?
    public let improvedPrompt: String?
    public let lastMessagePreview: String?
    public let isMinimized: Bool?
    public let isPinned: Bool?
    public let canSend: Bool
    public let canControlFeatures: Bool?
    public let unsupportedReason: String?
    public let messages: [FerminRelayMessage]
    public let pendingSubagent: FerminRelayPendingSubagent?
    public let collaborationProjectID: String?
    public let collaborationProjectName: String?
    public let sessionName: String?

    public var id: String { windowID }

    public init(
        windowID: String,
        sessionID: String,
        engine: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        providerSessionID: String? = nil,
        providerSessionPath: String? = nil,
        projectKey: String = "",
        projectPath: String? = nil,
        projectName: String? = nil,
        windowName: String? = nil,
        displayName: String = "",
        sidecarMode: String = "",
        sidecarURL: String? = nil,
        activityStatus: String = "",
        runtimeStatus: String? = nil,
        runtimeStatusDetail: String? = nil,
        features: FerminRelaySessionFeatures? = nil,
        runMode: String? = nil,
        goalStartedAt: Double? = nil,
        messageCount: Int = 0,
        updatedAt: Double = 0,
        createdAt: Double? = nil,
        rawPrompt: String? = nil,
        originalPrompt: String? = nil,
        improvedPrompt: String? = nil,
        lastMessagePreview: String? = nil,
        isMinimized: Bool? = nil,
        isPinned: Bool? = nil,
        canSend: Bool = false,
        canControlFeatures: Bool? = nil,
        unsupportedReason: String? = nil,
        messages: [FerminRelayMessage] = [],
        pendingSubagent: FerminRelayPendingSubagent? = nil,
        collaborationProjectID: String? = nil,
        collaborationProjectName: String? = nil,
        sessionName: String? = nil
    ) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.engine = engine
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.providerSessionID = providerSessionID
        self.providerSessionPath = providerSessionPath
        self.projectKey = projectKey
        self.projectPath = projectPath
        self.projectName = projectName
        self.windowName = windowName
        self.displayName = displayName
        self.sidecarMode = sidecarMode
        self.sidecarURL = sidecarURL
        self.activityStatus = activityStatus
        self.runtimeStatus = runtimeStatus
        self.runtimeStatusDetail = runtimeStatusDetail
        self.features = features
        self.runMode = runMode
        self.goalStartedAt = goalStartedAt
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.rawPrompt = rawPrompt
        self.originalPrompt = originalPrompt
        self.improvedPrompt = improvedPrompt
        self.lastMessagePreview = lastMessagePreview
        self.isMinimized = isMinimized
        self.isPinned = isPinned
        self.canSend = canSend
        self.canControlFeatures = canControlFeatures
        self.unsupportedReason = unsupportedReason
        self.messages = messages
        self.pendingSubagent = pendingSubagent
        self.collaborationProjectID = collaborationProjectID
        self.collaborationProjectName = collaborationProjectName
        self.sessionName = sessionName
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId"
        case sessionID = "sessionId"
        case engine, model, reasoningEffort
        case providerSessionID = "providerSessionId"
        case providerSessionPath, projectKey, projectPath, projectName, windowName, displayName
        case sidecarMode
        case sidecarURL = "sidecarUrl"
        case activityStatus, runtimeStatus, runtimeStatusDetail, features, runMode, goalStartedAt
        case messageCount, updatedAt, createdAt, rawPrompt, originalPrompt, improvedPrompt
        case lastMessagePreview, isMinimized, isPinned, canSend, canControlFeatures, unsupportedReason
        case messages, pendingSubagent
        case collaborationProjectID = "collaborationProjectId"
        case collaborationProjectName, sessionName
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = values.relayString(forKey: .windowID)
        sessionID = values.relayString(forKey: .sessionID)
        engine = values.relayStringIfPresent(forKey: .engine)
        model = values.relayStringIfPresent(forKey: .model)
        reasoningEffort = values.relayStringIfPresent(forKey: .reasoningEffort)
        providerSessionID = values.relayStringIfPresent(forKey: .providerSessionID)
        providerSessionPath = values.relayStringIfPresent(forKey: .providerSessionPath)
        projectKey = values.relayString(forKey: .projectKey)
        projectPath = values.relayStringIfPresent(forKey: .projectPath)
        projectName = values.relayStringIfPresent(forKey: .projectName)
        windowName = values.relayStringIfPresent(forKey: .windowName)
        displayName = values.relayString(forKey: .displayName)
        sidecarMode = values.relayString(forKey: .sidecarMode)
        sidecarURL = values.relayStringIfPresent(forKey: .sidecarURL)
        activityStatus = values.relayString(forKey: .activityStatus)
        runtimeStatus = values.relayStringIfPresent(forKey: .runtimeStatus)
        runtimeStatusDetail = values.relayStringIfPresent(forKey: .runtimeStatusDetail)
        features = values.relayValue(FerminRelaySessionFeatures.self, forKey: .features)
        runMode = values.relayStringIfPresent(forKey: .runMode)
        goalStartedAt = values.relayDoubleIfPresent(forKey: .goalStartedAt)
        messageCount = values.relayInt(forKey: .messageCount)
        updatedAt = values.relayDouble(forKey: .updatedAt)
        createdAt = values.relayDoubleIfPresent(forKey: .createdAt)
        rawPrompt = values.relayStringIfPresent(forKey: .rawPrompt)
        originalPrompt = values.relayStringIfPresent(forKey: .originalPrompt)
        improvedPrompt = values.relayStringIfPresent(forKey: .improvedPrompt)
        lastMessagePreview = values.relayStringIfPresent(forKey: .lastMessagePreview)
        isMinimized = values.relayBoolIfPresent(forKey: .isMinimized)
        isPinned = values.relayBoolIfPresent(forKey: .isPinned)
        canSend = values.relayBool(forKey: .canSend)
        canControlFeatures = values.relayBoolIfPresent(forKey: .canControlFeatures)
        unsupportedReason = values.relayStringIfPresent(forKey: .unsupportedReason)
        messages = values.relayArray(FerminRelayMessage.self, forKey: .messages)
        pendingSubagent = values.relayValue(FerminRelayPendingSubagent.self, forKey: .pendingSubagent)
        collaborationProjectID = values.relayStringIfPresent(forKey: .collaborationProjectID)
        collaborationProjectName = values.relayStringIfPresent(forKey: .collaborationProjectName)
        sessionName = values.relayStringIfPresent(forKey: .sessionName)
    }
}

public struct FerminRelaySessionsEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let now: Double?
    public let exportedAt: Double?
    public let items: [FerminRelaySession]
    public let cursor: UInt64?

    public init(
        ok: Bool = true,
        now: Double? = nil,
        exportedAt: Double? = nil,
        items: [FerminRelaySession],
        cursor: UInt64? = nil
    ) {
        self.ok = ok
        self.now = now
        self.exportedAt = exportedAt
        self.items = items
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case ok, now, exportedAt, items, cursor
    }

    private enum AliasCodingKeys: String, CodingKey {
        case generatedAt, sessions, globalSequence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        let generatedAt = aliases.relayDoubleIfPresent(forKey: .generatedAt)
        now = values.relayDoubleIfPresent(forKey: .now) ?? generatedAt
        exportedAt = values.relayDoubleIfPresent(forKey: .exportedAt) ?? generatedAt
        let mobileItems = values.relayArray(FerminRelaySession.self, forKey: .items)
        items = mobileItems.isEmpty
            ? aliases.relayArray(FerminRelaySession.self, forKey: .sessions)
            : mobileItems
        cursor = values.relayUInt64IfPresent(forKey: .cursor)
            ?? aliases.relayUInt64IfPresent(forKey: .globalSequence)
    }
}

public struct FerminRelaySessionDetailEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let now: Double?
    public let item: FerminRelaySession

    public init(ok: Bool = true, now: Double? = nil, item: FerminRelaySession) {
        self.ok = ok
        self.now = now
        self.item = item
    }

    private enum CodingKeys: String, CodingKey { case ok, now, item }
    private enum AliasCodingKeys: String, CodingKey { case session }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        now = values.relayDoubleIfPresent(forKey: .now)
        if let decoded = values.relayValue(FerminRelaySession.self, forKey: .item)
            ?? aliases.relayValue(FerminRelaySession.self, forKey: .session) {
            item = decoded
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.item,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing session detail"
                )
            )
        }
    }
}

public struct FerminRelayReasoningEffortOption: Codable, Hashable, Sendable {
    public let reasoningEffort: String
    public let description: String?

    public init(reasoningEffort: String, description: String? = nil) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case reasoningEffort, description }
    private enum AliasCodingKeys: String, CodingKey { case effort }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        reasoningEffort = values.relayStringIfPresent(forKey: .reasoningEffort)
            ?? aliases.relayString(forKey: .effort)
        description = values.relayStringIfPresent(forKey: .description)
    }
}

public struct FerminRelayAvailableModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let model: String
    public let modelProvider: String?
    public let displayName: String
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [FerminRelayReasoningEffortOption]
    public let hidden: Bool?
    public let isDefault: Bool?

    public init(
        id: String,
        model: String,
        modelProvider: String? = nil,
        displayName: String,
        defaultReasoningEffort: String = "",
        supportedReasoningEfforts: [FerminRelayReasoningEffortOption] = [],
        hidden: Bool? = nil,
        isDefault: Bool? = nil
    ) {
        self.id = id
        self.model = model
        self.modelProvider = modelProvider
        self.displayName = displayName
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.hidden = hidden
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, modelProvider, displayName, defaultReasoningEffort
        case supportedReasoningEfforts
        case hidden, isDefault
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = values.relayString(forKey: .model)
        id = values.relayStringIfPresent(forKey: .id) ?? model
        modelProvider = values.relayStringIfPresent(forKey: .modelProvider)
        displayName = values.relayStringIfPresent(forKey: .displayName) ?? model
        defaultReasoningEffort = values.relayString(forKey: .defaultReasoningEffort)
        supportedReasoningEfforts = values.relayArray(
            FerminRelayReasoningEffortOption.self,
            forKey: .supportedReasoningEfforts
        )
        hidden = values.relayBoolIfPresent(forKey: .hidden)
        isDefault = values.relayBoolIfPresent(forKey: .isDefault)
    }
}

public struct FerminRelayModelCatalogEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let data: [FerminRelayAvailableModel]

    public init(ok: Bool = true, data: [FerminRelayAvailableModel]) {
        self.ok = ok
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case ok, data }
    private enum AliasCodingKeys: String, CodingKey { case items, models }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        let candidates = [
            values.relayArray(FerminRelayAvailableModel.self, forKey: .data),
            aliases.relayArray(FerminRelayAvailableModel.self, forKey: .items),
            aliases.relayArray(FerminRelayAvailableModel.self, forKey: .models),
        ]
        data = candidates.first(where: { !$0.isEmpty }) ?? []
    }
}

public enum FerminRelayRuntimeModelError: Error, Equatable, Sendable {
    case unsupportedModel(String)
    case unsupportedEngine(String)
}

public enum FerminRelayRuntimePolicy {
    public static func isSupportedModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gpt-")
            && !containsRetiredProviderName(normalized)
    }

    public static func isSupported(_ candidate: FerminRelayAvailableModel) -> Bool {
        let normalizedID = candidate.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let provider = candidate.modelProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "openai"
        return candidate.hidden != true
            && isSupportedModel(candidate.model)
            && normalizedID.hasPrefix("gpt-")
            && !containsRetiredProviderName(normalizedID)
            && (provider == "openai" || provider == "codex")
    }

    public static func supportedModels(
        from models: [FerminRelayAvailableModel]
    ) -> [FerminRelayAvailableModel] {
        models.filter(isSupported)
    }

    public static func validate(model: String) throws {
        guard isSupportedModel(model) else {
            throw FerminRelayRuntimeModelError.unsupportedModel(model)
        }
    }

    public static func validate(engine: String) throws {
        let normalized = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "codex" else {
            throw FerminRelayRuntimeModelError.unsupportedEngine(engine)
        }
    }

    private static func containsRetiredProviderName(_ value: String) -> Bool {
        let scalars = value.unicodeScalars.map(\.value)
        guard scalars.count >= 4 else { return false }
        for index in 0...(scalars.count - 4) {
            if scalars[index] == 103,
               scalars[index + 1] == 114,
               scalars[index + 2] == 111,
               scalars[index + 3] == 107 {
                return true
            }
        }
        return false
    }
}
