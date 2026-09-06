import Darwin
import Foundation

enum KycodeRelayConfiguration {
    static let primaryBaseURL = configuredURL(
        infoKey: "FerminCodePrimaryRelayURL",
        fallback: "https://relay.example.com/fermin-code"
    )
    static let secondaryBaseURL = configuredURL(
        infoKey: "FerminCodeSecondaryRelayURL",
        fallback: "https://relay.example.com/fermin-code-puky"
    )

    private static func configuredURL(infoKey: String, fallback: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return fallback
    }
}

private func kycodeEncodedPathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

enum KycodeSessionRefreshPolicy {
    static let fallbackIntervalSeconds: UInt64 = 3
    static let workingDetailRefreshSeconds: TimeInterval = 8
    static let streamSilenceTimeoutSeconds: TimeInterval = 24

    static func hasRecentVerifiedStreamActivity(
        isStreaming: Bool,
        lastStreamActivityAt: Date?,
        now: Date
    ) -> Bool {
        guard isStreaming, let lastStreamActivityAt else { return false }
        return now.timeIntervalSince(lastStreamActivityAt) < streamSilenceTimeoutSeconds
    }

    static func shouldPoll(
        isStreaming: Bool,
        isReconnecting: Bool,
        lastStreamActivityAt: Date?,
        now: Date
    ) -> Bool {
        guard !isReconnecting else { return false }
        guard isStreaming else { return true }
        guard let lastStreamActivityAt else { return true }
        return now.timeIntervalSince(lastStreamActivityAt) >= streamSilenceTimeoutSeconds
    }

    static func shouldRestartStream(
        isStreaming: Bool,
        isReconnecting: Bool,
        lastStreamActivityAt: Date?,
        now: Date
    ) -> Bool {
        guard isStreaming, !isReconnecting else { return false }
        guard let lastStreamActivityAt else { return true }
        return now.timeIntervalSince(lastStreamActivityAt) >= streamSilenceTimeoutSeconds
    }

    static func shouldRefreshWorkingDetail(
        isWorking: Bool,
        lastRefreshAt: Date?,
        now: Date
    ) -> Bool {
        guard isWorking else { return false }
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= workingDetailRefreshSeconds
    }
}

enum KycodeSessionNameRules {
    static let maxLength = 64

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validationMessage(for value: String) -> String? {
        let normalizedName = normalized(value)
        if normalizedName.isEmpty {
            return "El nombre no puede estar vacío."
        }
        if normalizedName.count > maxLength {
            return "El nombre puede tener hasta \(maxLength) caracteres."
        }
        return nil
    }
}

enum KycodeSessionRefreshErrorPolicy {
    static let serverErrorCodeUserInfoKey = "KycodeServerErrorCode"

    static func isMissingWindow(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "KycodeMobile", nsError.code == 404 else { return false }
        if let serverCode = nsError.userInfo[serverErrorCodeUserInfoKey] as? String,
           serverCode.caseInsensitiveCompare("SESSION_NOT_FOUND") == .orderedSame {
            return true
        }
        return isMissingWindowMessage(nsError.localizedDescription)
    }

    /// Parses a background SSE failure for diagnostics only. Stream failures
    /// are asynchronous transport/runtime state and must never become a global
    /// user-facing banner; actionable command failures are reported by their
    /// owning control instead.
    static func streamDiagnosticMessage(from payload: String) -> String? {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else { return nil }

        let message: String
        if let data = trimmedPayload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let serverError = object["error"] as? String {
            message = serverError.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = trimmedPayload
        }

        guard !message.isEmpty, !isMissingWindowMessage(message) else { return nil }
        return message
    }

    static func isMissingWindowMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "window not found"
            || normalized == "windows not found"
            || normalized.hasPrefix("window not found at ")
            || normalized == "session not found"
            || normalized.hasPrefix("session not found at ")
    }
}

enum KycodeSessionDetailLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum KycodeDurableCommandState: String, Codable, CaseIterable, Sendable {
    case accepted
    case leased
    case engineDurable
    case sentToChild
    case completed
    case failed
    case cancelled
    case unknown

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .unknown:
            return true
        case .accepted, .leased, .engineDurable, .sentToChild:
            return false
        }
    }

    var isFailure: Bool {
        switch self {
        case .failed, .cancelled, .unknown:
            return true
        case .accepted, .leased, .engineDurable, .sentToChild, .completed:
            return false
        }
    }

    fileprivate var progressionRank: Int {
        switch self {
        case .accepted: return 0
        case .leased: return 1
        case .engineDurable: return 2
        case .sentToChild: return 3
        case .completed, .failed, .cancelled, .unknown: return 4
        }
    }
}

struct KycodeDurableCommandAck: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState
    let inserted: Bool
    let durable: Bool
    let queuedAt: Double
}

struct KycodeCommandStateChangedEvent: Codable, Sendable {
    let commandId: String
    let state: KycodeDurableCommandState
    let error: String?
}

enum KycodeTrackedCommandOperation: String, Sendable {
    case createSession
    case sendMessage
    case retryPromptTransform
    case minimize
    case setPinned
    case rename
    case archive
    case setFeatures
    case setRunMode
    case setModel
    case createSubagent
    case resumeHistory

    var failureLabel: String {
        switch self {
        case .createSession: return "crear la sesión"
        case .sendMessage: return "enviar el mensaje"
        case .retryPromptTransform: return "reintentar la mejora del prompt"
        case .minimize: return "cambiar la visibilidad de la sesión"
        case .setPinned: return "sincronizar el estado fijado de la sesión"
        case .rename: return "renombrar la sesión"
        case .archive: return "archivar la sesión"
        case .setFeatures: return "actualizar las funciones de la sesión"
        case .setRunMode: return "cambiar GOAL Mode"
        case .setModel: return "cambiar el modelo"
        case .createSubagent: return "crear el sub-agente"
        case .resumeHistory: return "reanudar la sesión"
        }
    }
}

struct KycodeTrackedCommandContext: Equatable, Sendable {
    let operation: KycodeTrackedCommandOperation
    let windowId: String?
    let messageId: String?
    let sessionId: String?
    let mutationId: UUID?

    init(
        operation: KycodeTrackedCommandOperation,
        windowId: String?,
        messageId: String?,
        sessionId: String?,
        mutationId: UUID? = nil
    ) {
        self.operation = operation
        self.windowId = windowId
        self.messageId = messageId
        self.sessionId = sessionId
        self.mutationId = mutationId
    }
}

enum KycodeCommandTransitionOutcome: Equatable, Sendable {
    case ignored
    case pending(KycodeTrackedCommandContext?)
    case completed(KycodeTrackedCommandContext?)
    case failed(KycodeTrackedCommandContext?, KycodeDurableCommandState, String?)
}

struct KycodeDurableCommandTracker: Sendable {
    private struct Entry: Sendable {
        var state: KycodeDurableCommandState
        let context: KycodeTrackedCommandContext
    }

    private struct OrphanedTerminal: Sendable {
        let state: KycodeDurableCommandState
        let error: String?
    }

    private var entries: [String: Entry] = [:]
    private var orphanedTerminals: [String: OrphanedTerminal] = [:]
    private var terminalOrder: [String] = []
    private var terminalIds: Set<String> = []
    private let maximumTerminalIds = 256

    mutating func register(
        commandId: String,
        state: KycodeDurableCommandState,
        context: KycodeTrackedCommandContext
    ) -> KycodeCommandTransitionOutcome {
        let normalizedId = commandId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedId.isEmpty else {
            return .ignored
        }
        if let orphaned = orphanedTerminals.removeValue(forKey: normalizedId) {
            return orphaned.state.isFailure
                ? .failed(context, orphaned.state, orphaned.error)
                : .completed(context)
        }
        guard !terminalIds.contains(normalizedId) else { return .ignored }
        if state.isTerminal {
            rememberTerminal(normalizedId)
            return state.isFailure
                ? .failed(context, state, nil)
                : .completed(context)
        }
        entries[normalizedId] = Entry(state: state, context: context)
        return .pending(context)
    }

    mutating func apply(_ event: KycodeCommandStateChangedEvent) -> KycodeCommandTransitionOutcome {
        let commandId = event.commandId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandId.isEmpty, !terminalIds.contains(commandId) else {
            return .ignored
        }
        let current = entries[commandId]
        if let current, event.state.progressionRank < current.state.progressionRank {
            return .ignored
        }
        if event.state.isTerminal {
            entries.removeValue(forKey: commandId)
            if current == nil {
                orphanedTerminals[commandId] = OrphanedTerminal(
                    state: event.state,
                    error: event.error
                )
            }
            rememberTerminal(commandId)
            return event.state.isFailure
                ? .failed(current?.context, event.state, event.error)
                : .completed(current?.context)
        }
        if var current {
            current.state = event.state
            entries[commandId] = current
        }
        return .pending(current?.context)
    }

    mutating func removeAll() {
        entries.removeAll()
        orphanedTerminals.removeAll()
        terminalOrder.removeAll()
        terminalIds.removeAll()
    }

    private mutating func rememberTerminal(_ commandId: String) {
        guard terminalIds.insert(commandId).inserted else { return }
        terminalOrder.append(commandId)
        while terminalOrder.count > maximumTerminalIds {
            let evicted = terminalOrder.removeFirst()
            terminalIds.remove(evicted)
            orphanedTerminals.removeValue(forKey: evicted)
        }
    }
}

enum KycodeCommandFailurePresentation {
    static func message(
        operation: KycodeTrackedCommandOperation?,
        state: KycodeDurableCommandState,
        serverError: String?
    ) -> String {
        let action = operation?.failureLabel ?? "completar una operación"
        let fallback: String
        switch state {
        case .cancelled:
            fallback = "La operación fue cancelada antes de completarse."
        case .unknown:
            fallback = "Fermín Code no pudo confirmar si la operación se completó."
        default:
            fallback = "Fermín Code no pudo completar la operación."
        }
        let detail = serverError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400)
        guard let detail, !detail.isEmpty else {
            return "No se pudo \(action). \(fallback)"
        }
        return "No se pudo \(action). \(detail)"
    }
}

struct KycodeSessionFeatures: Codable, Hashable, Sendable {
    let promptImproverEnabled: Bool
    let explainerEnabled: Bool
    let codeContextEnabled: Bool
}

enum KycodeAgentEngine: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

struct KycodeMessage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let role: String
    let type: String?
    let content: String
    let originalPrompt: String?
    let transformedPrompt: String?
    let improvedPrompt: String?
    let timestamp: Double
    let status: String?
    let imageAttachments: [KycodeMessageImageAttachment]?
    var transformStatus: String? = nil
    var transformErrorReason: String? = nil
    var promptTransformNote: String? = nil
}

private extension KycodeMessage {
    func replacingVoiceContent(_ content: String, status: String) -> KycodeMessage {
        KycodeMessage(
            id: id,
            role: role,
            type: type,
            content: content,
            originalPrompt: content,
            transformedPrompt: transformedPrompt,
            improvedPrompt: improvedPrompt,
            timestamp: timestamp,
            status: status,
            imageAttachments: imageAttachments,
            transformStatus: transformStatus,
            transformErrorReason: transformErrorReason,
            promptTransformNote: promptTransformNote
        )
    }
}

struct KycodeMessageImageAttachment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String?
    let size: Int
    let mimeType: String
    let previewData: Data?
}

struct KycodeImageAttachmentDraft: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let data: Data

    var size: Int { data.count }
}

enum KycodeImageAttachmentPolicy {
    static let maximumCount = 10
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumTotalBytes = 50 * 1024 * 1024
    static let supportedMimeTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func detectedMimeType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 6,
           let header = String(bytes: bytes.prefix(6), encoding: .ascii),
           header == "GIF87a" || header == "GIF89a" {
            return "image/gif"
        }
        if bytes.count >= 12,
           String(bytes: bytes.prefix(4), encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        return nil
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "img"
        }
    }

    static func validate(_ drafts: [KycodeImageAttachmentDraft]) throws {
        guard drafts.count <= maximumCount else {
            throw NSError(
                domain: "KycodeMobile",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "Podés adjuntar hasta \(maximumCount) imágenes."]
            )
        }
        let totalBytes = drafts.reduce(0) { partialResult, draft in
            partialResult + draft.size
        }
        guard totalBytes <= maximumTotalBytes else {
            throw NSError(
                domain: "KycodeMobile",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "Las imágenes superan el límite total de 50 MiB."]
            )
        }
        for draft in drafts {
            guard !draft.data.isEmpty else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "\(draft.name) está vacía."]
                )
            }
            guard draft.size <= maximumBytes else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 413,
                    userInfo: [NSLocalizedDescriptionKey: "\(draft.name) supera el límite de 20 MiB."]
                )
            }
            guard supportedMimeTypes.contains(draft.mimeType),
                  detectedMimeType(for: draft.data) == draft.mimeType else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 415,
                    userInfo: [NSLocalizedDescriptionKey: "\(draft.name) no es PNG, JPEG, GIF o WebP válido."]
                )
            }
        }
    }
}

enum KycodeImageAttachmentComposerPhase {
    case idle
    case recording
    case transcribing
}

enum KycodeImageAttachmentComposerPolicy {
    static func showsAttachmentControl(in phase: KycodeImageAttachmentComposerPhase) -> Bool {
        phase != .transcribing
    }

    static func allowsCamera(in phase: KycodeImageAttachmentComposerPhase) -> Bool {
        phase == .idle
    }
}

struct KycodeImageUploadProgress: Equatable, Sendable {
    let sendId: String
    let windowId: String
    let completed: Int
    let total: Int
}

struct KycodePendingSubagentDraft: Codable, Hashable, Sendable {
    let displayMessage: String
    let parentNotificationPrompt: String?
    let childMessageSentAt: Double?

    var isWaitingForExplicitSend: Bool {
        childMessageSentAt == nil
    }
}

struct KycodeSessionSummary: Codable, Identifiable, Hashable, Sendable {
    var windowId: String
    let sessionId: String
    let engine: String?
    var model: String?
    var reasoningEffort: String?
    let providerSessionId: String?
    var providerSessionPath: String?
    let projectKey: String
    let projectPath: String?
    let projectName: String?
    var windowName: String?
    var displayName: String
    let sidecarMode: String
    var sidecarUrl: String?
    let activityStatus: String
    let runtimeStatus: String?
    let runtimeStatusDetail: String?
    var features: KycodeSessionFeatures?
    var runMode: String? = nil
    var goalStartedAt: Double? = nil
    let messageCount: Int
    var updatedAt: Double
    let createdAt: Double?
    var rawPrompt: String?
    var originalPrompt: String?
    var improvedPrompt: String?
    let lastMessagePreview: String?
    var isMinimized: Bool?
    let canSend: Bool
    let canControlFeatures: Bool?
    let unsupportedReason: String?
    var messages: [KycodeMessage]?
    var pendingSubagent: KycodePendingSubagentDraft? = nil
    var collaborationProjectId: String? = nil
    var collaborationProjectName: String? = nil
    var sessionName: String? = nil
    var isPinned: Bool? = nil

    var id: String { windowId }
    var minimized: Bool { isMinimized == true }
    var goalModeEnabled: Bool { runMode == "goal" }
    var collaborationSessionName: String {
        // `windowName` is the canonical, user-editable Desktop title. Prefer
        // it over derived/mobile compatibility fields so a stale generic
        // `sessionName` (for example "Proyecto") cannot hide a real rename.
        for candidate in [windowName, sessionName] {
            let explicit = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !explicit.isEmpty {
                if let legacy = Self.splitLegacyCollaborationTitle(explicit) {
                    return legacy.sessionName
                }
                return explicit
            }
        }
        if collaborationProjectName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let legacy = Self.splitLegacyCollaborationTitle(displayName) {
            return legacy.sessionName
        }
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var collaborationProjectDisplayName: String? {
        if let explicit = collaborationProjectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        for candidate in [windowName, displayName] {
            if let legacy = Self.splitLegacyCollaborationTitle(candidate) {
                return legacy.projectName
            }
        }
        return nil
    }

    var collaborationDisplayName: String {
        guard let project = collaborationProjectDisplayName else {
            return collaborationSessionName
        }
        return "\(project): \(collaborationSessionName)"
    }

    private static func splitLegacyCollaborationTitle(_ value: String?) -> (
        projectName: String,
        sessionName: String
    )? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let separator = normalized.firstIndex(of: ":"),
              separator != normalized.startIndex else {
            return nil
        }
        let projectName = normalized[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionStart = normalized.index(after: separator)
        let sessionName = normalized[sessionStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, !sessionName.isEmpty else { return nil }
        return (projectName, sessionName)
    }
    var agentEngine: KycodeAgentEngine? {
        engine.flatMap(KycodeAgentEngine.init(rawValue:))
    }

    var runtimeModelDisplayName: String? {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let tokens = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        if let familyIndex = tokens.firstIndex(where: {
            ["opus", "sonnet", "haiku", "fable"].contains($0)
        }) {
            let versionParts = tokens.dropFirst(familyIndex + 1).filter {
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            }
            let family = tokens[familyIndex].prefix(1).uppercased() + tokens[familyIndex].dropFirst()
            if versionParts.count >= 2 {
                return "\(family) \(versionParts[0]).\(versionParts[1])"
            }
            if let version = versionParts.first {
                return "\(family) \(version)"
            }
        }
        return raw
    }

    var runtimeReasoningEffortDisplayName: String? {
        guard let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
              !effort.isEmpty,
              effort.lowercased() != "default" else {
            return nil
        }
        return effort.uppercased()
    }

    var runtimeModelMetadataLabel: String? {
        let values = [
            runtimeModelDisplayName?.uppercased(),
            runtimeReasoningEffortDisplayName,
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var runtimeDisplayLabel: String? {
        guard let metadata = runtimeModelMetadataLabel else {
            return agentEngine?.displayName
        }
        guard let engineName = agentEngine?.displayName else {
            return metadata
        }
        return "\(engineName.uppercased()) · \(metadata)"
    }
}

private struct KycodeCachedSessionsSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let profileId: String
    let cachedAt: Date
    let sessions: [KycodeSessionSummary]
}

enum KycodeCachedSessionIdentityPolicy {
    static func accepts(_ sessions: [KycodeSessionSummary]) -> Bool {
        var windowIds = Set<String>()
        for session in sessions {
            let windowId = session.windowId.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionId = session.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !windowId.isEmpty,
                  !sessionId.isEmpty,
                  windowId == session.windowId,
                  sessionId == session.sessionId,
                  windowIds.insert(windowId).inserted else {
                return false
            }
        }
        return true
    }
}

private extension KycodeSessionSummary {
    func replacingWindowId(_ nextWindowId: String) -> KycodeSessionSummary {
        var copy = self
        copy.windowId = nextWindowId
        return copy
    }

    var lightweightCachedCopy: KycodeSessionSummary {
        var copy = self
        copy.providerSessionPath = nil
        copy.sidecarUrl = nil
        copy.rawPrompt = nil
        copy.originalPrompt = nil
        copy.improvedPrompt = nil
        copy.messages = nil
        return copy
    }

    func replacingWindowName(_ name: String, updatedAt nextUpdatedAt: Double? = nil) -> KycodeSessionSummary {
        var copy = self
        copy.windowName = name
        copy.displayName = name
        copy.sessionName = name
        copy.updatedAt = nextUpdatedAt ?? updatedAt
        return copy
    }

    func replacingCollaborationProject(_ project: KycodeCollaborationProject) -> KycodeSessionSummary {
        var copy = self
        copy.windowName = collaborationSessionName
        copy.displayName = collaborationSessionName
        copy.sessionName = collaborationSessionName
        copy.collaborationProjectId = project.id
        copy.collaborationProjectName = project.name
        return copy
    }

    func replacingMinimized(_ minimized: Bool, updatedAt nextUpdatedAt: Double? = nil) -> KycodeSessionSummary {
        var copy = self
        copy.isMinimized = minimized
        copy.updatedAt = nextUpdatedAt ?? updatedAt
        return copy
    }

    func replacingRunMode(_ runMode: String, goalStartedAt: Double?) -> KycodeSessionSummary {
        var copy = self
        copy.runMode = runMode
        copy.goalStartedAt = goalStartedAt
        return copy
    }

    func replacingFeatures(_ features: KycodeSessionFeatures?) -> KycodeSessionSummary {
        var copy = self
        copy.features = features
        return copy
    }

    func replacingRuntimeSettings(
        model: String,
        reasoningEffort: String
    ) -> KycodeSessionSummary {
        var copy = self
        copy.model = model
        copy.reasoningEffort = reasoningEffort
        return copy
    }
}

struct KycodeSessionsEnvelope: Codable, Sendable {
    let ok: Bool
    let now: Double?
    let exportedAt: Double?
    let items: [KycodeSessionSummary]
    var cursor: UInt64? = nil
}

private struct KycodeAuthoritativeSnapshotPayload: Codable, Sendable {
    let globalSequence: UInt64
    let generatedAt: Double
    let sessions: [KycodeSessionSummary]
}

enum KycodeSSESnapshotDecoder {
    static func decode(_ data: Data) -> KycodeSessionsEnvelope? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(KycodeSessionsEnvelope.self, from: data) {
            return envelope
        }
        guard let snapshot = try? decoder.decode(KycodeAuthoritativeSnapshotPayload.self, from: data) else {
            return nil
        }
        return KycodeSessionsEnvelope(
            ok: true,
            now: snapshot.generatedAt,
            exportedAt: snapshot.generatedAt,
            items: snapshot.sessions,
            cursor: snapshot.globalSequence
        )
    }
}

private struct KycodeSessionRemovedEvent: Codable, Sendable {
    let windowId: String?
    let sessionId: String?
}

private struct KycodeSSEEventTarget: Codable, Sendable {
    let windowId: String?
    let sessionId: String?
}

struct KycodeSessionDetailEnvelope: Codable, Sendable {
    let ok: Bool
    let now: Double?
    let item: KycodeSessionSummary
}

struct KycodeCollaborationProject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let activeSessionCount: Int?
}

private struct KycodeCollaborationProjectsEnvelope: Codable, Sendable {
    let ok: Bool
    let now: Double?
    let items: [KycodeCollaborationProject]
}

struct KycodeReasoningEffortOption: Codable, Hashable, Sendable {
    let reasoningEffort: String
    let description: String?
}

struct KycodeAvailableModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [KycodeReasoningEffortOption]
    let hidden: Bool?
    let isDefault: Bool?
}

enum KycodeRuntimeModelPolicy {
    static func isSupported(_ model: String) -> Bool {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("gpt-")
    }

    static func supportedModels(from models: [KycodeAvailableModel]) -> [KycodeAvailableModel] {
        models.filter { isSupported($0.model) }
    }
}

private struct KycodeModelCatalogEnvelope: Codable, Sendable {
    let ok: Bool
    let data: [KycodeAvailableModel]
}

private struct KycodeRuntimeModelSettings: Codable, Sendable {
    let model: String?
    let effort: String?
}

private struct KycodeModelSettingsEnvelope: Codable, Sendable {
    let ok: Bool
    let modelSettings: KycodeRuntimeModelSettings
    let command: KycodeDurableCommandAck?
}

struct KycodeProjectDirectory: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let kind: String?

    var id: String { path }
}

private struct KycodeProjectDirectoryEnvelope: Codable, Sendable {
    let ok: Bool
    let rootPath: String?
    let items: [KycodeProjectDirectory]
}

private struct KycodeCreateSessionEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let projectPath: String
    let projectName: String
    let sessionId: String
    let sessionName: String?
}

private struct KycodeCreateSubagentEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let sourceWindowId: String
    let sourceSessionId: String?
    let projectPath: String?
    let projectName: String
    let sessionId: String
    let engine: String?
}

struct KycodeRecentCreatedSession: Codable, Identifiable, Hashable, Sendable {
    let sessionId: String
    var windowId: String?
    let projectPath: String
    var projectName: String
    var sessionName: String? = nil
    var profileId: String? = nil
    let createdAt: Date
    var status: String

    var id: String { sessionId }
}

enum KycodeRecentCreatedSessionScopePolicy {
    static func visibleEntries(
        _ entries: [KycodeRecentCreatedSession],
        selectedProfileId: String
    ) -> [KycodeRecentCreatedSession] {
        guard selectedProfileId != "all" else { return entries }
        return entries.filter { entry in
            entry.profileId == nil || entry.profileId == selectedProfileId
        }
    }
}

struct KycodeCreateSessionResult: Sendable {
    let sessionId: String
    let windowId: String?
    let projectName: String
    let status: String
}

struct KycodeCreateSubagentResult: Sendable {
    let sessionId: String
    let windowId: String?
    let projectName: String
    let status: String
    let engine: String?
}

private struct KycodeSendEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String?
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let parentCommandId: String?
}

private struct KycodeLegacyFilePreviewEnvelope: Codable, Sendable {
    let ok: Bool
    let path: String
    let content: String
}

private enum KycodeLegacyFilePreviewPolicy {
    static let maximumBytes = 10 * 1024 * 1024

    static func shouldFallback(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.code == 404 else { return false }
        return nsError.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("not found") == .orderedSame
    }
}

private struct KycodeImageUploadEnvelope: Codable, Sendable {
    let ok: Bool
    let path: String
    let bytes: Int
    let mimeType: String
}

struct KycodeMessageAttachmentPayload: Codable, Sendable {
    let path: String
    let name: String
    let size: Int
    let mimeType: String
}

struct KycodeMessagePayload: Codable, Sendable {
    let message: String
    let clientMessageId: String?
    let attachments: [KycodeMessageAttachmentPayload]
    let fastModeEnabled: Bool
    let parentNotificationPrompt: String?

    init(
        message: String,
        clientMessageId: String? = nil,
        attachments: [KycodeMessageAttachmentPayload],
        fastModeEnabled: Bool = false,
        parentNotificationPrompt: String? = nil
    ) {
        self.message = message
        self.clientMessageId = clientMessageId
        self.attachments = attachments
        self.fastModeEnabled = fastModeEnabled
        self.parentNotificationPrompt = parentNotificationPrompt
    }
}

enum KycodeFastModePreference {
    static let defaultsKey = "kycode.mobile.fastModeEnabled.v1"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

enum KycodePromptImproverVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case motivational

    var title: String {
        switch self {
        case .standard: return "Preciso"
        case .motivational: return "Impulso"
        }
    }

    var summary: String {
        switch self {
        case .standard:
            return "El comportamiento actual: fiel, claro y directo."
        case .motivational:
            return "La misma fidelidad, con energía progresiva y un cierre elevado."
        }
    }
}

enum KycodePromptImproverPreferenceStore {
    static let defaultsKey = "kycode.mobile.promptImproverVariant.v1"
    private static let scopedPrefix = "kycode.mobile.promptImproverVariant.v2"

    static func storageKey(profileId: String) -> String {
        "\(scopedPrefix).\(Data(profileId.utf8).base64EncodedString())"
    }

    static func load(
        profileId: String,
        from defaults: UserDefaults = .standard
    ) -> KycodePromptImproverVariant? {
        guard let rawValue = defaults.string(forKey: storageKey(profileId: profileId)) else {
            return nil
        }
        return KycodePromptImproverVariant(rawValue: rawValue)
    }

    static func save(
        _ variant: KycodePromptImproverVariant,
        profileId: String,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(variant.rawValue, forKey: storageKey(profileId: profileId))
    }

    @discardableResult
    static func migrateLegacyValueIfNeeded(
        to profileId: String,
        in defaults: UserDefaults = .standard
    ) -> KycodePromptImproverVariant? {
        guard profileId == "personal" || profileId == "puky" else { return nil }
        if let scoped = load(profileId: profileId, from: defaults) {
            defaults.removeObject(forKey: defaultsKey)
            return scoped
        }
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let legacy = KycodePromptImproverVariant(rawValue: rawValue) else {
            return nil
        }
        save(legacy, profileId: profileId, to: defaults)
        defaults.removeObject(forKey: defaultsKey)
        return legacy
    }

    // Kept for one-time migration and diagnostics. Product assigns the legacy
    // scalar only to the single selected runtime, never to the aggregate view.
    static func load(from defaults: UserDefaults = .standard) -> KycodePromptImproverVariant {
        guard let rawValue = defaults.string(forKey: defaultsKey) else { return .standard }
        return KycodePromptImproverVariant(rawValue: rawValue) ?? .standard
    }

    static func save(
        _ variant: KycodePromptImproverVariant,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(variant.rawValue, forKey: defaultsKey)
    }
}

enum KycodePromptImproverVariantSyncState: Equatable, Sendable {
    case cached
    case synchronized
    case mixed
    case partial
    case unavailable
}

private struct KycodePromptImproverPreferenceRecord: Codable, Sendable {
    let version: Int
    let variant: KycodePromptImproverVariant
    let updatedAt: String?
}

private struct KycodePromptImproverPreferenceEnvelope: Codable, Sendable {
    let ok: Bool
    let preference: KycodePromptImproverPreferenceRecord
    let variants: [KycodePromptImproverVariant]?
}

private struct KycodeFeaturesEnvelope: Codable {
    let ok: Bool
    let commandId: String?
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
}

private struct KycodeMinimizedEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let windowId: String
    let minimized: Bool
}

private struct KycodeRunModeEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let windowId: String
    let runMode: String
    let goalStartedAt: Double?
}

private struct KycodeRenameEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let windowId: String
    let name: String
}

private struct KycodeCollaborationProjectAssignmentEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String?
    let queuedAt: Double?
    let windowId: String
    let project: KycodeCollaborationProject
    let unchanged: Bool?
}

private struct KycodeWindowCommandEnvelope: Codable, Sendable {
    let ok: Bool
    let commandId: String
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let windowId: String
}

private struct KycodePendingMinimizedUpdate: Sendable {
    let minimized: Bool
    let expiresAt: Date
}

private struct KycodePendingPinnedUpdate {
    let id: UUID
    let pinned: Bool
    let previous: Bool?
}

private struct KycodePendingRenameUpdate: Sendable {
    let name: String
    let protectUntil: Date
    let expiresAt: Date
}

private struct KycodePendingCollaborationProjectUpdate: Sendable {
    let project: KycodeCollaborationProject
    let protectUntil: Date
    let expiresAt: Date
}

private enum KycodePendingRuntimeSettingsPhase: String, Codable, Sendable {
    case awaitingAcknowledgement
    case awaitingTerminal
    case awaitingAuthority
}

private struct KycodePendingRuntimeSettingsUpdate: Codable, Sendable {
    let mutationId: UUID
    let profileId: String
    let remoteWindowId: String
    var presentedWindowId: String
    let sessionId: String?
    var model: String
    var reasoningEffort: String
    let previousModel: String?
    let previousReasoningEffort: String?
    var commandId: String?
    var phase: KycodePendingRuntimeSettingsPhase
    let persistsAcrossRelaunch: Bool
}

private struct KycodePendingGoalModeUpdate: Sendable {
    let enabled: Bool
    let goalStartedAt: Double?
    let mutationId: UUID
    let protectUntil: Date
    let expiresAt: Date
    var sessionsConfirmed: Bool
    var detailConfirmed: Bool
}

private enum KycodePendingGoalModeSource {
    case sessions
    case detail
}

private struct KycodePendingFeatureUpdate: Sendable {
    let promptImproverEnabled: Bool
    let explainerEnabled: Bool
    let codeContextEnabled: Bool?
    let previousSummaryFeatures: KycodeSessionFeatures?
    let previousDetailFeatures: KycodeSessionFeatures?
    let mutationId: UUID
    let profileId: String
    let remoteWindowId: String
    let credentials: KycodeConnectionCredentials
    let sessionId: String?
    let generation: UInt64
    let protectUntil: TimeInterval
    let expiresAt: TimeInterval
    var sessionsConfirmed: Bool
    var detailConfirmed: Bool
}

private enum KycodePendingFeatureSource {
    case sessions
    case detail
}

private struct KycodePendingDeletion: Sendable {
    let expiresAt: Date
}

private struct KycodePendingOptimisticMessage: Sendable {
    var message: KycodeMessage
}

struct KycodeSendResult: Equatable {
    let sent: Bool
    let errorMessage: String?
    let shouldApplyToCurrentComposer: Bool

    static let success = KycodeSendResult(
        sent: true,
        errorMessage: nil,
        shouldApplyToCurrentComposer: true
    )

    static func failure(_ message: String) -> KycodeSendResult {
        KycodeSendResult(
            sent: false,
            errorMessage: message,
            shouldApplyToCurrentComposer: true
        )
    }

    static func ignoredAfterHandoff(sent: Bool) -> KycodeSendResult {
        KycodeSendResult(
            sent: sent,
            errorMessage: nil,
            shouldApplyToCurrentComposer: false
        )
    }
}

enum KycodeComposerDraftStoragePolicy {
    private static let scopedPrefix = "kycode.mobile.composerDraft.v2"
    private static let legacyPrefix = "kycode.mobile.composerDraft"

    static func storageKey(profileId: String, remoteWindowId: String) -> String {
        "\(scopedPrefix).\(encoded(profileId)).\(encoded(remoteWindowId))"
    }

    static func legacyStorageKey(windowId: String) -> String {
        "\(legacyPrefix).\(windowId)"
    }

    static func loadDraft(
        defaults: UserDefaults,
        storageKey: String
    ) -> String? {
        defaults.string(forKey: storageKey)
    }

    static func legacyDraft(defaults: UserDefaults, windowId: String) -> String? {
        defaults.string(forKey: legacyStorageKey(windowId: windowId))
    }

    static func recoverLegacyDraft(
        defaults: UserDefaults,
        storageKey: String,
        legacyWindowId: String
    ) -> String? {
        let legacyKey = legacyStorageKey(windowId: legacyWindowId)
        guard let legacyDraft = defaults.string(forKey: legacyKey) else { return nil }
        defaults.set(legacyDraft, forKey: storageKey)
        defaults.removeObject(forKey: legacyKey)
        return legacyDraft
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct KycodePromptTransformRetryEnvelope: Decodable {
    let ok: Bool
    let commandId: String?
    let commandState: KycodeDurableCommandState?
    let inserted: Bool?
    let durable: Bool?
    let queuedAt: Double?
    let messageId: String?
}

enum TranscriptStatus: String, Codable, Sendable {
    case pending
    case success
    case failed
}

enum SendStatus: String, Codable, Sendable {
    case idle
    case sending
    case sent
    case failed
}

struct VoiceDraft: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let windowId: String
    let filePath: String
    let duration: TimeInterval
    let createdAt: Date
    var transcriptStatus: TranscriptStatus
    var transcriptText: String?
    var sendStatus: SendStatus
    var errorMessage: String?
    var isolationReport: VoiceIsolationReport?
    var routeIdentity: VoiceTranscriptionRouteIdentity?

    init(
        id: String,
        windowId: String,
        filePath: String,
        duration: TimeInterval,
        createdAt: Date,
        transcriptStatus: TranscriptStatus,
        transcriptText: String?,
        sendStatus: SendStatus,
        errorMessage: String?,
        isolationReport: VoiceIsolationReport?,
        routeIdentity: VoiceTranscriptionRouteIdentity? = nil
    ) {
        self.id = id
        self.windowId = windowId
        self.filePath = filePath
        self.duration = duration
        self.createdAt = createdAt
        self.transcriptStatus = transcriptStatus
        self.transcriptText = transcriptText
        self.sendStatus = sendStatus
        self.errorMessage = errorMessage
        self.isolationReport = isolationReport
        self.routeIdentity = routeIdentity
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var hasAudioFile: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    var isRecoverable: Bool {
        // Missing bytes are themselves a recovery problem that must remain
        // visible. Hiding the draft here lets the user believe it vanished and
        // allows a new recording to overwrite the only metadata we still have.
        sendStatus != .sent
    }
}

enum KycodeConnectionProfileMode: String, Codable, Hashable, Sendable {
    case remoteFirst
    case personal
    case ferminCode
    case all
    // Legacy values remain decodable so existing installs migrate without
    // losing their LAN cache or remote token.
    case bonjourOnly
    case remoteHub
}

enum KycodeCreateSessionAccess: Equatable, Sendable {
    case available
    case profileSelectionRequired
    case credentialsRequired
}

enum KycodeCreateSessionAccessPolicy {
    static func resolve(
        usesCombinedProfile: Bool,
        hasRoutableCredentials: Bool
    ) -> KycodeCreateSessionAccess {
        if usesCombinedProfile {
            return .profileSelectionRequired
        }
        return hasRoutableCredentials ? .available : .credentialsRequired
    }
}

enum KycodeConnectionBootstrapAttempt: Equatable, Sendable {
    case preferred
    case remote
    case cachedBonjour
    case bonjourDiscovery
}

enum KycodeBackendCapabilityPolicy {
    static func isFerminCode(
        selectedProfileId: String,
        routedProfileId: String? = nil,
        routedBaseURL: String? = nil,
        activeBaseURL: String? = nil,
        offlineFallbackBaseURL: String? = nil
    ) -> Bool {
        let profileId = routedProfileId ?? selectedProfileId
        guard profileId == "personal" || profileId == "puky" else { return false }
        if let routedBaseURL = normalized(routedBaseURL) {
            return isFerminEndpoint(routedBaseURL, profileId: profileId)
        }
        if let activeBaseURL = normalized(activeBaseURL) {
            return isFerminEndpoint(activeBaseURL, profileId: profileId)
        }
        guard let offlineFallbackBaseURL = normalized(offlineFallbackBaseURL) else {
            return false
        }
        return isFerminEndpoint(offlineFallbackBaseURL, profileId: profileId)
    }

    private static func normalized(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func isFerminEndpoint(_ rawValue: String, profileId: String) -> Bool {
        let expected: String
        switch profileId {
        case "personal": expected = KycodeRelayConfiguration.primaryBaseURL
        case "puky": expected = KycodeRelayConfiguration.secondaryBaseURL
        default: return false
        }
        return normalizedEndpoint(rawValue) == normalizedEndpoint(expected)
    }

    private static func normalizedEndpoint(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

enum KycodeConnectionTransportPolicy {
    static let internetBootstrapTimeoutSeconds: TimeInterval = 12
    static let internetReconnectTimeoutSeconds: TimeInterval = 10

    static func shouldAttemptBonjour(
        localIPv4Prefix: String?,
        forceInternet: Bool = false
    ) -> Bool {
        guard !forceInternet else { return false }
        return !(localIPv4Prefix ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func bootstrapAttemptOrder(
        profileMode: KycodeConnectionProfileMode,
        canUseBonjour: Bool
    ) -> [KycodeConnectionBootstrapAttempt] {
        switch (profileMode, canUseBonjour) {
        case (.personal, _), (.ferminCode, _):
            return [.remote]
        case (_, false):
            return [.preferred, .remote]
        case (.remoteFirst, true):
            return [.preferred, .remote, .cachedBonjour, .bonjourDiscovery]
        case (.bonjourOnly, true):
            return [.preferred, .cachedBonjour, .bonjourDiscovery, .remote]
        case (.remoteHub, true):
            return [.preferred, .remote]
        case (.all, true):
            return [.preferred, .remote, .bonjourDiscovery]
        }
    }

    static func requestTimeout(
        forBaseURL baseURL: String,
        localTimeout: TimeInterval,
        internetTimeout: TimeInterval
    ) -> TimeInterval {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased() else {
            return internetTimeout
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return localTimeout
        }
        if isPrivateIPv4(host) {
            return localTimeout
        }
        return internetTimeout
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        return false
    }
}

enum KycodeConnectionCredentialMigrationPolicy {
    static func personalRemoteToken(
        current: String?,
        legacyRemoteHub: String?,
        legacyLAN: String?
    ) -> String? {
        let current = normalized(current)
        let legacyRemoteHub = normalized(legacyRemoteHub)
        let legacyLAN = normalized(legacyLAN)

        // A token learned through Bonjour authenticates the direct LAN sidecar;
        // it is not the sync-hub token. The previous migration treated both as
        // interchangeable, which made Mac personal work at home and fail on
        // cellular data. Preserve an explicitly configured remote token, repair
        // the poisoned legacy-LAN value, and otherwise migrate remote-hub only.
        if let current, current != legacyLAN {
            return current
        }
        return legacyRemoteHub
    }

    static func genericTokenDestination(
        storedBaseURL: String,
        legacySelectedProfileId: String?
    ) -> String? {
        let normalizedURL = storedBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedURL.contains("relay.example.com/fermin-code-puky") {
            return "puky"
        }
        if normalizedURL.contains("relay.example.com/sync-hub") ||
            normalizedURL.contains("relay.example.com/fermin-code") {
            return "personal"
        }
        if normalizedURL.contains("desktop.example.com") ||
            normalizedURL.contains("staging.example.com") ||
            normalizedURL.contains("relay.example.com/sidecar") {
            return "puky"
        }

        switch legacySelectedProfileId {
        case "remote-hub":
            return "personal"
        case "puky":
            return "puky"
        default:
            // `this-mac` and raw LAN URLs contain a sidecar token, never a
            // credential for either public route.
            return nil
        }
    }

    private static func normalized(_ token: String?) -> String? {
        let value = token?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum KycodeSSECursorStore {
    static let defaultsKey = "kycode.mobile.sseCursors.v1"

    static func load(baseURL: String, defaults: UserDefaults = .standard) -> String? {
        guard let key = storageKey(baseURL: baseURL) else { return nil }
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: String]
        return stored?[key].flatMap(validatedEventID)
    }

    static func persist(
        eventID: String,
        baseURL: String,
        defaults: UserDefaults = .standard
    ) {
        guard let key = storageKey(baseURL: baseURL),
              let validated = validatedEventID(eventID),
              let sequence = UInt64(validated) else { return }
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let current = stored[key].flatMap(validatedEventID).flatMap(UInt64.init),
           current >= sequence {
            return
        }
        stored[key] = validated
        defaults.set(stored, forKey: defaultsKey)
    }

    static func applyLastEventID(
        to request: inout URLRequest,
        baseURL: String,
        defaults: UserDefaults = .standard
    ) {
        guard let lastEventID = load(baseURL: baseURL, defaults: defaults) else { return }
        request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
    }

    static func clear(baseURL: String, defaults: UserDefaults = .standard) {
        guard let key = storageKey(baseURL: baseURL) else { return }
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: key)
        if stored.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(stored, forKey: defaultsKey)
        }
    }

    static func validatedEventID(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sequence = UInt64(value), sequence > 0 else { return nil }
        return String(sequence)
    }

    private static func storageKey(baseURL: String) -> String? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty, URL(string: value) != nil else { return nil }
        return value
    }
}

struct KycodeSSEDispatchTransaction: Sendable {
    private(set) var requiresReconnect = false

    mutating func commit(eventID: String?, applied: Bool) -> String? {
        guard !requiresReconnect else { return nil }
        guard applied else {
            requiresReconnect = true
            return nil
        }
        guard let eventID else { return nil }
        return KycodeSSECursorStore.validatedEventID(eventID)
    }
}

private enum KycodeSSEStreamDispatchError: Error {
    case replayRequired
}

struct KycodeConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var mode: KycodeConnectionProfileMode
    var remoteBaseURL: String?
    var preferredBonjourServiceHint: String?
    var lastDiscoveredBonjourURL: String?
    var lastDiscoveredBonjourToken: String?
    var lastDiscoveredBonjourNetworkPrefix: String?
}

private struct KycodeConnectionCredentials: Hashable, Sendable {
    let baseURL: String
    let authToken: String
}

struct KycodeSourceConnectionState: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var isLoading: Bool
    var isConnected: Bool
    var sessionCount: Int
    var connectionLabel: String?
    var errorMessage: String?
    var snapshotPhase: KycodeSourceSnapshotPhase = .idle
    var attemptGeneration: UInt64 = 0
    var hasRetainedSnapshot: Bool = false
}

enum KycodeSourceSnapshotPhase: String, Equatable, Sendable {
    case idle
    case loading
    case succeeded
    case failed
}

enum KycodeDashboardSnapshotState: Equatable, Sendable {
    case loading
    case showingCache
    case content
    case partialSourceFailure
    case failedNoData
    case authoritativeEmpty
}

enum KycodeDashboardSnapshotPolicy {
    static func resolve(
        sourceStates: [KycodeSourceConnectionState],
        sessionCount: Int,
        isShowingCachedSessions: Bool,
        isConnected: Bool,
        isBootstrapping: Bool,
        isReconnecting: Bool,
        canRetry: Bool,
        hasError: Bool
    ) -> KycodeDashboardSnapshotState {
        let hasSessions = sessionCount > 0
        let hasFailedSource = sourceStates.contains { $0.snapshotPhase == .failed }
        let hasActiveSource = sourceStates.contains(where: \.isLoading)
        let allSourcesSucceeded = !sourceStates.isEmpty && sourceStates.allSatisfy {
            $0.snapshotPhase == .succeeded
        }

        if hasSessions {
            if isShowingCachedSessions {
                return .showingCache
            }
            if hasFailedSource {
                return .partialSourceFailure
            }
            return .content
        }
        if hasFailedSource || canRetry || hasError {
            return .failedNoData
        }
        if isBootstrapping || isReconnecting || hasActiveSource {
            return .loading
        }
        if allSourcesSucceeded || isConnected {
            return sourceStates.isEmpty || allSourcesSucceeded
                ? .authoritativeEmpty
                : .loading
        }
        return .loading
    }
}

enum KycodeAllSourceCommitPolicy {
    static func shouldCommit(
        requiredProfileIds: [String],
        sourceStates: [KycodeSourceConnectionState],
        attemptGeneration: UInt64
    ) -> Bool {
        let byId = Dictionary(uniqueKeysWithValues: sourceStates.map { ($0.id, $0) })
        return !requiredProfileIds.isEmpty && requiredProfileIds.allSatisfy { profileId in
            guard let state = byId[profileId] else { return false }
            return state.attemptGeneration == attemptGeneration
                && state.snapshotPhase == .succeeded
        }
    }
}

private struct KycodeSessionRoute: Hashable, Sendable {
    let presentedWindowId: String
    let remoteWindowId: String
    let profileId: String
    let profileName: String
    let credentials: KycodeConnectionCredentials
}

private struct KycodeSendAttemptContext: Equatable, Sendable {
    let sendId: String
    let connectionGeneration: UInt64
    let selectedProfileId: String
    let routedProfileId: String
    let presentedWindowId: String
    let remoteWindowId: String
    let credentials: KycodeConnectionCredentials
    let sessionId: String?
    let requiresDurableContract: Bool
    let voiceDraftId: String?
}

struct KycodeCombinedSessionSource: Sendable {
    let profileId: String
    let profileName: String
    let items: [KycodeSessionSummary]
}

struct KycodeCombinedSessionItem: Sendable {
    let summary: KycodeSessionSummary
    let remoteWindowId: String
    let profileId: String
    let profileName: String
}

enum KycodeCombinedSessionPolicy {
    static func presentedWindowId(profileId: String, remoteWindowId: String) -> String {
        "\(profileId)::\(remoteWindowId)"
    }

    static func combine(_ sources: [KycodeCombinedSessionSource]) -> [KycodeCombinedSessionItem] {
        var byPresentedId: [String: KycodeCombinedSessionItem] = [:]
        for source in sources {
            for item in source.items {
                let presentedId = presentedWindowId(
                    profileId: source.profileId,
                    remoteWindowId: item.windowId
                )
                let candidate = KycodeCombinedSessionItem(
                    summary: item.replacingWindowId(presentedId),
                    remoteWindowId: item.windowId,
                    profileId: source.profileId,
                    profileName: source.profileName
                )
                if let existing = byPresentedId[presentedId],
                   existing.summary.updatedAt >= candidate.summary.updatedAt {
                    continue
                }
                byPresentedId[presentedId] = candidate
            }
        }
        return byPresentedId.values.sorted { left, right in
            if left.summary.updatedAt != right.summary.updatedAt {
                return left.summary.updatedAt > right.summary.updatedAt
            }
            if left.profileId != right.profileId {
                return left.profileId < right.profileId
            }
            return left.summary.windowId.localizedStandardCompare(right.summary.windowId) == .orderedAscending
        }
    }
}

/// A session's dashboard position is user-owned state. Live activity, opening
/// a conversation, and refresh timestamps must never reshuffle the dashboard.
enum KycodeSessionDisplayOrderPolicy {
    static func reconcile(
        existingOrder: [String],
        availableWindowIds: [String],
        defaultOrder: [String]
    ) -> [String] {
        let available = Set(availableWindowIds)
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(available.count)

        for windowId in existingOrder where available.contains(windowId) {
            if seen.insert(windowId).inserted {
                result.append(windowId)
            }
        }
        for windowId in defaultOrder where available.contains(windowId) {
            if seen.insert(windowId).inserted {
                result.append(windowId)
            }
        }
        for windowId in availableWindowIds where available.contains(windowId) {
            if seen.insert(windowId).inserted {
                result.append(windowId)
            }
        }
        return result
    }

    static func moving(
        _ existingOrder: [String],
        windowId: String,
        over targetWindowId: String
    ) -> [String] {
        guard windowId != targetWindowId,
              let sourceIndex = existingOrder.firstIndex(of: windowId),
              let targetIndex = existingOrder.firstIndex(of: targetWindowId) else {
            return existingOrder
        }
        var result = existingOrder
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: min(targetIndex, result.count))
        return result
    }
}

private struct KycodeAllSourceResult: Sendable {
    let profile: KycodeConnectionProfile
    let credentials: KycodeConnectionCredentials?
    let snapshot: KycodeSessionsEnvelope?
    let connectionLabel: String?
    let bonjourResult: KycodeBonjourProbeResult?
    let errorMessage: String?
}

/// Last verified state for a concrete Mac. This cache is intentionally
/// process-local: it makes an in-app target handoff immediate without changing
/// cold-launch behavior or persisting another copy of credentials.
private struct KycodeWarmTargetConnection: Sendable {
    let credentials: KycodeConnectionCredentials
    let snapshot: KycodeSessionsEnvelope
    let sourceLabel: String
}

private struct KycodeHistorySourceResult: Sendable {
    let profileId: String
    let profileName: String
    let envelope: KycodeSessionHistoryEnvelope?
    let errorMessage: String?
}

private struct KycodeBonjourProbeResult: Sendable {
    let discovered: KycodeDiscoveredDesktop
    let credentials: KycodeConnectionCredentials
    let snapshot: KycodeSessionsEnvelope
}

private enum KycodeBonjourProbeOutcome: Sendable {
    case invalid(desktop: KycodeDiscoveredDesktop, elapsedMs: Int)
    case success(result: KycodeBonjourProbeResult, elapsedMs: Int)
    case failure(desktop: KycodeDiscoveredDesktop, elapsedMs: Int, description: String)
}

private func kycodeNormalizedAuthToken(_ token: String) -> String {
    token
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func kycodeNormalizedCredentials(baseURL: String, authToken: String) -> KycodeConnectionCredentials? {
    let trimmedBaseURL = baseURL
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let trimmedToken = kycodeNormalizedAuthToken(authToken)
    guard !trimmedBaseURL.isEmpty, !trimmedToken.isEmpty else { return nil }
    return KycodeConnectionCredentials(baseURL: trimmedBaseURL, authToken: trimmedToken)
}

private func kycodeMakeRequest(
    credentials: KycodeConnectionCredentials,
    path: String,
    method: String,
    body: Data?,
    timeout: TimeInterval? = nil
) throws -> URLRequest {
    guard let url = URL(string: credentials.baseURL + path) else {
        throw NSError(domain: "KycodeMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL inválida."])
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(credentials.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.httpBody = body
    if let timeout {
        request.timeoutInterval = timeout
    }
    return request
}

private func kycodePerform<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
        let serverError = String(data: data, encoding: .utf8) ?? "Error del servidor."
        throw NSError(
            domain: "KycodeMobile",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: serverError]
        )
    }
    return try JSONDecoder().decode(T.self, from: data)
}

private func kycodeFetchSessions(
    _ credentials: KycodeConnectionCredentials,
    timeout: TimeInterval? = nil
) async throws -> KycodeSessionsEnvelope {
    let request = try kycodeMakeRequest(
        credentials: credentials,
        path: "/api/mobile/sessions",
        method: "GET",
        body: nil,
        timeout: timeout
    )
    return try await kycodePerform(request, decode: KycodeSessionsEnvelope.self)
}

private func kycodeDescribeError(_ error: Error) -> String {
    let nsError = error as NSError
    if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
        return "\(nsError.localizedDescription) @ \(failingURL)"
    }
    return nsError.localizedDescription
}

private func kycodeElapsedMs(since start: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(start) * 1000))
}

private func kycodeIPv4Prefix(from host: String?) -> String? {
    guard let host, !host.isEmpty else { return nil }
    let octets = host.split(separator: ".")
    guard octets.count == 4 else { return nil }
    return octets.prefix(3).joined(separator: ".")
}

private func kycodeIPv4Prefix(fromBaseURL baseURL: String) -> String? {
    kycodeIPv4Prefix(from: URL(string: baseURL)?.host)
}

private func kycodeCurrentLocalIPv4Prefix() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }

    var current = first
    while true {
        let interface = current.pointee
        let flags = Int32(interface.ifa_flags)
        let isUp = (flags & IFF_UP) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        let name = String(cString: interface.ifa_name)
        if isUp,
           !isLoopback,
           name.hasPrefix("en"),
           let address = interface.ifa_addr,
           address.pointee.sa_family == UInt8(AF_INET) {
            let sockaddrPointer = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
            let ip = String(cString: inet_ntoa(sockaddrPointer.pointee.sin_addr))
            if let prefix = kycodeIPv4Prefix(from: ip) {
                return prefix
            }
        }

        guard let next = interface.ifa_next else { break }
        current = next
    }

    return nil
}

private func kycodeProbeBonjourCandidateAttempt(
    _ desktop: KycodeDiscoveredDesktop,
    timeout: TimeInterval
) async -> KycodeBonjourProbeOutcome {
    let startedAt = Date()
    guard let credentials = kycodeNormalizedCredentials(baseURL: desktop.baseURL, authToken: desktop.authToken) else {
        return .invalid(desktop: desktop, elapsedMs: kycodeElapsedMs(since: startedAt))
    }

    do {
        let snapshot = try await kycodeFetchSessions(credentials, timeout: timeout)
        let result = KycodeBonjourProbeResult(discovered: desktop, credentials: credentials, snapshot: snapshot)
        return .success(result: result, elapsedMs: kycodeElapsedMs(since: startedAt))
    } catch {
        return .failure(
            desktop: desktop,
            elapsedMs: kycodeElapsedMs(since: startedAt),
            description: kycodeDescribeError(error)
        )
    }
}

@MainActor
final class KycodeLatestIntentMutationQueue<Intent> {
    enum SubmissionResult {
        case queued
        case completed(intent: Intent, succeeded: Bool)
    }

    private typealias PendingMutation = (
        intent: Intent,
        apply: (Intent) async -> Bool
    )

    private var pendingMutation: PendingMutation?
    private var isProcessing = false

    func submit(
        _ intent: Intent,
        apply: @escaping (Intent) async -> Bool
    ) async -> SubmissionResult {
        guard !isProcessing else {
            pendingMutation = (intent, apply)
            return .queued
        }

        isProcessing = true
        var mutation: PendingMutation = (intent, apply)
        var finalSucceeded = false

        while true {
            finalSucceeded = await mutation.apply(mutation.intent)
            guard let nextMutation = pendingMutation else { break }
            pendingMutation = nil
            mutation = nextMutation
        }

        isProcessing = false
        return .completed(intent: mutation.intent, succeeded: finalSucceeded)
    }
}

private struct KycodePromptImproverVariantIntent {
    let generation: UInt64
    let connectionGeneration: UInt64
    let ownerProfileId: String
    let targets: [KycodePromptImproverVariantTarget]
    let variant: KycodePromptImproverVariant
}

private struct KycodePromptImproverVariantTarget: Hashable, Sendable {
    let profileId: String
    let credentials: KycodeConnectionCredentials
}

private struct KycodePromptRetryIntentKey: Hashable {
    let windowId: String
    let messageId: String
}

private struct KycodePromptTransformTimeoutContext: Equatable {
    let generation: UInt64
    let profileId: String
    let remoteWindowId: String
    let sessionId: String?
}

@MainActor
final class KycodeConnectionStore: ObservableObject {
    @Published private(set) var profiles: [KycodeConnectionProfile]
    @Published private(set) var selectedProfileId: String
    @Published var baseURLInput: String
    @Published var authTokenInput: String
    @Published private(set) var sessions: [KycodeSessionSummary] = []
    @Published private(set) var sessionDetails: [String: KycodeSessionSummary] = [:]
    @Published private(set) var detailLoadStates: [String: KycodeSessionDetailLoadState] = [:]
    @Published private(set) var sourceConnectionStates: [KycodeSourceConnectionState] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isBootstrapping = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var bootstrapStatusText = "Buscando tu desktop..."
    @Published private(set) var lastConnectionSource: String?
    @Published private(set) var reconnectStatusText: String?
    @Published private(set) var canRetryReconnectManually = false
    @Published private(set) var currentVoiceDraft: VoiceDraft?
    private(set) var recoveredVoiceDraftIdAtLaunch: String?
    @Published private(set) var voiceTranscriptionJobs: [String: VoiceTranscriptionJob] = [:]
    @Published private(set) var recentCreatedSessions: [KycodeRecentCreatedSession] = []
    @Published private(set) var imageUploadProgress: KycodeImageUploadProgress?
    @Published private(set) var goalModeDrafts: [String: Bool] = [:]
    @Published private(set) var lastSessionsRefreshAt: Date?
    @Published private(set) var isShowingCachedSessions = false
    @Published private(set) var fastModeEnabled: Bool
    @Published private(set) var promptImproverVariant: KycodePromptImproverVariant
    @Published private(set) var isUpdatingPromptImproverVariant = false
    @Published private(set) var isRefreshingPromptImproverVariant = false
    @Published private(set) var promptImproverVariantSyncState: KycodePromptImproverVariantSyncState
    @Published private(set) var voiceIsolationMode: VoiceIsolationMode
    @Published private(set) var voiceIsolationThreshold: Float
    @Published private(set) var hasEnrolledVoiceProfile = KycodeKeychain.loadVoiceProfile()?.isEmpty == false
    @Published private(set) var latestVoiceIsolationReport: VoiceIsolationReport? = nil
    @Published var errorMessage: String?
    @Published private(set) var lastBackgroundSyncErrorMessage: String?
    @Published private var pendingPinnedUpdates: [String: KycodePendingPinnedUpdate] = [:]

    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var metadataRefreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var messageReconciliationTasks: [String: Task<Void, Never>] = [:]
    private var pendingPromptRetryIntents: [KycodePromptRetryIntentKey: KycodePromptRetryIntent] = [:]
    @Published private var promptTransformTimeoutContexts:
        [KycodePromptRetryIntentKey: KycodePromptTransformTimeoutContext] = [:]
    private var createdSessionReconciliationTasks: [String: Task<Void, Never>] = [:]
    private var voiceTranscriptionTasks: [String: Task<Void, Never>] = [:]
    private var activeCredentials: KycodeConnectionCredentials?
    private var pendingMinimizedUpdates: [String: KycodePendingMinimizedUpdate] = [:]
    private var pendingRenameUpdates: [String: KycodePendingRenameUpdate] = [:]
    private var pendingCollaborationProjectUpdates: [String: KycodePendingCollaborationProjectUpdate] = [:]
    private var pendingRuntimeSettingsUpdates: [UUID: KycodePendingRuntimeSettingsUpdate] = [:]
    private var pendingGoalModeUpdates: [String: KycodePendingGoalModeUpdate] = [:]
    private var pendingFeatureUpdates: [String: KycodePendingFeatureUpdate] = [:]
    private var pendingDeletions: [String: KycodePendingDeletion] = [:]
    private var pendingOptimisticMessages: [String: [KycodePendingOptimisticMessage]] = [:]
    private var liveMessagePatchCursorByKey: [String: KycodeLiveMessagePatchCursor] = [:]
    private var pendingLiveMessagePatchesByWindowId: [String: KycodeLiveMessagePatch] = [:]
    private var durableCommandTracker = KycodeDurableCommandTracker()
    private var promptImproverVariantMutationQueue =
        KycodeLatestIntentMutationQueue<KycodePromptImproverVariantIntent>()
    private var promptImproverVariantRefreshTask: Task<Void, Never>?
    private var promptImproverVariantMutationGeneration: UInt64 = 0
    private var promptImproverVariantRefreshID: UUID?
    private var confirmedPromptImproverVariantsByProfileId: [String: KycodePromptImproverVariant]
    private var promptImproverVariantSyncFailureMessagesByProfileId: [String: String] = [:]
    private var pendingMetadataRefreshWindowIds: Set<String> = []
    private var detailRefreshInFlight: [String: UUID] = [:]
    private var lastDetailRefreshAtByWindowId: [String: Date] = [:]
    private var missingWindowIdsAwaitingSnapshotRemoval: Set<String> = []
    private var lastStreamActivityAt: Date?
    private var connectionStateGeneration: UInt64 = 0
    private var sourceSnapshotAttemptGeneration: UInt64 = 0
    private var sessionDisplayOrder: [String] = []
    private var sessionDisplayOrdersByProfile: [String: [String]] = [:]
    private var sessionRoutes: [String: KycodeSessionRoute] = [:]
    private var sessionSourceLabels: [String: String] = [:]
    private var allSourceSnapshots: [String: KycodeSessionsEnvelope] = [:]
    private var allSourceCredentials: [String: KycodeConnectionCredentials] = [:]
    private var warmTargetConnections: [String: KycodeWarmTargetConnection] = [:]
    private var hasBootstrapped = false
#if DEBUG
    private let allowsConnectionProfileTestOverrides: Bool
#endif
    private let urlSession: URLSession
    private let requestObserver: ((URLRequest) -> Void)?
    private let runtimeSettingsDefaults: UserDefaults
    private let createSessionConfirmationTimeout: TimeInterval
    private let createSessionForegroundConfirmationTimeout: TimeInterval
    private let automaticallyReconcilesCreatedSessions: Bool
    private let createSessionPollNow: @MainActor () -> TimeInterval
    private let createSessionPollSleep: @MainActor (Duration) async -> Void
    private let messageReconciliationNow: @MainActor () -> TimeInterval
    private let messageReconciliationSleep: @MainActor (Duration) async -> Void
    private let featureReconciliationNow: @MainActor () -> TimeInterval
    private let featureReconciliationSleep: @MainActor (Duration) async -> Void
    private let speakerVerificationService = EagleSpeakerVerificationService()

    private static let profilesDefaultsKey = "kycode.mobile.connectionProfiles"
    private static let selectedProfileIdDefaultsKey = "kycode.mobile.selectedProfileId"
    private static let baseURLDefaultsKey = "kycode.mobile.baseURL"
    private static let authTokenDefaultsKey = "kycode.mobile.authToken"
    private static let credentialMigrationVersionDefaultsKey = "kycode.mobile.connectionCredentialMigrationVersion"
    private static let currentCredentialMigrationVersion = 3
    private static let recentCreatedSessionsDefaultsKey = "kycode.mobile.recentCreatedSessions"
    private static let cachedSessionsDefaultsKey = "kycode.mobile.cachedSessions.v1"
    private static let pendingRuntimeSettingsDefaultsKey = "kycode.mobile.pendingRuntimeSettings.v1"
    private static let sessionDisplayOrdersDefaultsKey = "kycode.mobile.sessionDisplayOrders.v1"
    private static let cachedSessionsSchemaVersion = 1
    private static let cachedSessionsMaximumCount = 120
    private static let cachedSessionsMaximumBytes = 2 * 1_024 * 1_024
    private static let bootstrapStoredRequestTimeout: TimeInterval = 1.8
    private static let bootstrapProbeRequestTimeout: TimeInterval = 1.8
    private static let bootstrapDiscoveryTimeout: Duration = .seconds(3)
    private static let reconnectRequestTimeout: TimeInterval = 2.4
    private static let reconnectBackoffSeconds: [UInt64] = [1, 2, 4, 8, 16]
    private static let sendRequestTimeout: TimeInterval = 5
    private static let sessionHistoryRequestTimeout: TimeInterval = 60
    // A retry may run the complete prompt pipeline synchronously: up to six
    // minutes for improvement and another six for the independent fidelity
    // audit. Keep one small transport margin so iOS never abandons a valid
    // backend operation just before its durable result arrives.
    private static let promptTransformRetryRequestTimeout: TimeInterval = 13 * 60
    private static let imageUploadRequestTimeout: TimeInterval = 30
    // The desktop command bridge may wait up to 90s and the remote hub up to
    // 100s. Keep the client above both limits so the UI receives the server's
    // actionable response instead of manufacturing a 15s network timeout.
    private static let modelCommandRequestTimeout: TimeInterval = 115
    private static let sessionNameMaxLength = 64
    private static let minimizedPendingTTL: TimeInterval = 30
    private static let renamePendingTTL: TimeInterval = 8
    private static let renamePendingProtection: TimeInterval = 1.5
    private static let renameReconcileDelayMilliseconds: [Int64] = [250, 800, 1600, 3000]
    private static let collaborationProjectPendingTTL: TimeInterval = 12
    private static let collaborationProjectPendingProtection: TimeInterval = 1.5
    private static let collaborationProjectReconcileDelayMilliseconds: [Int64] = [250, 800, 1600, 3000, 6000]
    private static let goalModePendingTTL: TimeInterval = 24
    private static let goalModePendingProtection: TimeInterval = 1
    private static let goalModeReconcileDelayMilliseconds: [Int64] = [250, 800, 1600, 3000, 6000, 10000]
    private static let featurePendingTTL: TimeInterval = 24
    private static let featurePendingProtection: TimeInterval = 1
    private static let featureReconcileDelayMilliseconds: [Int64] = [250, 800, 1600, 3000, 6000, 10000]
    private static let deletePendingTTL: TimeInterval = 12
    private static let deleteReconcileDelayMilliseconds: [Int64] = [250, 800, 1600, 3000, 6000]
    private static let resumeSessionPollAttempts = 30
    // Rust creates the App Server thread asynchronously after the durable ACK.
    // A cold or busy host can legitimately need close to the 120-second server
    // deadline, so confirmation uses a bounded monotonic budget instead of a
    // fixed attempt count.
    private static let createSessionPollDelay: Duration = .milliseconds(500)
    private static let createSessionBackgroundPollDelay: Duration = .seconds(3)
    private static let createSessionPendingTransitionTimeout: TimeInterval = 20
    private static let recentCreatedPendingTTL: TimeInterval = 5 * 60
    private static let recentCreatedMaxAge: TimeInterval = 5 * 60
    private static let voiceDraftMetadataFileName = "kycode-voice-draft.json"
    private static let voiceDraftsDirectoryName = "VoiceDrafts"
    private static let remoteHubSnapshotMaxAge: TimeInterval = 120
    private static let pukyProfileId = "puky"
    private static let personalProfileId = "personal"
    private static let allProfileId = "all"
    private static let legacyLocalProfileId = "this-mac"
    private static let legacyRemoteHubProfileId = "remote-hub"
    private static let pukyRemoteBaseURL = KycodeRelayConfiguration.secondaryBaseURL
    private static let remoteHubBaseURL = KycodeRelayConfiguration.primaryBaseURL
    private static let newSessionDefaultModel = "gpt-5.6-sol"
    private static let newSessionDefaultReasoningEffort = "max"

    init(
        urlSession: URLSession = .shared,
        requestObserver: ((URLRequest) -> Void)? = nil,
        initialProfileIdOverride: String? = nil,
        createSessionConfirmationTimeout: TimeInterval = 150,
        createSessionForegroundConfirmationTimeout: TimeInterval = 0,
        automaticallyReconcilesCreatedSessions: Bool = true,
        createSessionPollNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        createSessionPollSleep: @escaping @MainActor (Duration) async -> Void = { delay in
            try? await Task.sleep(for: delay)
        },
        messageReconciliationNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        messageReconciliationSleep: @escaping @MainActor (Duration) async -> Void = { delay in
            try? await Task.sleep(for: delay)
        },
        featureReconciliationNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        featureReconciliationSleep: @escaping @MainActor (Duration) async -> Void = { delay in
            try? await Task.sleep(for: delay)
        },
        runtimeSettingsDefaults: UserDefaults = .standard
    ) {
        self.urlSession = urlSession
        self.requestObserver = requestObserver
        self.runtimeSettingsDefaults = runtimeSettingsDefaults
        self.createSessionConfirmationTimeout = createSessionConfirmationTimeout
        self.createSessionForegroundConfirmationTimeout = createSessionForegroundConfirmationTimeout
        self.automaticallyReconcilesCreatedSessions = automaticallyReconcilesCreatedSessions
        self.createSessionPollNow = createSessionPollNow
        self.createSessionPollSleep = createSessionPollSleep
        self.messageReconciliationNow = messageReconciliationNow
        self.messageReconciliationSleep = messageReconciliationSleep
        self.featureReconciliationNow = featureReconciliationNow
        self.featureReconciliationSleep = featureReconciliationSleep
        let defaults = UserDefaults.standard
        let storedBaseURL = defaults.string(forKey: Self.baseURLDefaultsKey) ?? "http://127.0.0.1:8787"
        let legacyToken = defaults.string(forKey: Self.authTokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychainToken = KycodeKeychain.loadAuthToken()
        let resolvedToken = (keychainToken?.isEmpty == false ? keychainToken : legacyToken) ?? ""
        let loadedProfiles = Self.reconciledProfiles(from: defaults)
        let legacySelectedProfileId = defaults.string(forKey: Self.selectedProfileIdDefaultsKey)
        Self.migrateLegacyConnectionCredentials(
            defaults: defaults,
            storedBaseURL: storedBaseURL,
            legacySelectedProfileId: legacySelectedProfileId,
            genericToken: resolvedToken
        )
        let selectedProfileId = Self.resolveSelectedProfileId(
            initialProfileIdOverride ?? legacySelectedProfileId ?? Self.allProfileId,
            profiles: loadedProfiles
        )

        self.profiles = loadedProfiles
        self.selectedProfileId = selectedProfileId
#if DEBUG
        self.allowsConnectionProfileTestOverrides = initialProfileIdOverride != nil
#endif
        self.fastModeEnabled = KycodeFastModePreference.load(from: defaults)
        if selectedProfileId != Self.allProfileId {
            KycodePromptImproverPreferenceStore.migrateLegacyValueIfNeeded(
                to: selectedProfileId,
                in: runtimeSettingsDefaults
            )
        }
        let storedPromptImproverVariants = Dictionary(
            uniqueKeysWithValues: [Self.pukyProfileId, Self.personalProfileId].compactMap { profileId in
                KycodePromptImproverPreferenceStore.load(
                    profileId: profileId,
                    from: runtimeSettingsDefaults
                ).map { (profileId, $0) }
            }
        )
        self.confirmedPromptImproverVariantsByProfileId = storedPromptImproverVariants
        let initialPromptImproverVariants: [KycodePromptImproverVariant]
        if selectedProfileId == Self.allProfileId {
            initialPromptImproverVariants = [Self.pukyProfileId, Self.personalProfileId].compactMap {
                storedPromptImproverVariants[$0]
            }
        } else {
            initialPromptImproverVariants = [storedPromptImproverVariants[selectedProfileId]].compactMap { $0 }
        }
        self.promptImproverVariant = initialPromptImproverVariants.first ?? .standard
        if selectedProfileId == Self.allProfileId {
            if initialPromptImproverVariants.count < 2 {
                self.promptImproverVariantSyncState = .partial
            } else if Set(initialPromptImproverVariants).count > 1 {
                self.promptImproverVariantSyncState = .mixed
            } else {
                self.promptImproverVariantSyncState = .cached
            }
        } else {
            self.promptImproverVariantSyncState = .cached
        }
        self.voiceIsolationMode = VoiceIsolationPreferences.loadMode(from: defaults)
        self.voiceIsolationThreshold = VoiceIsolationPreferences.loadThreshold(from: defaults)

        if keychainToken == nil, let legacyToken, !legacyToken.isEmpty {
            KycodeKeychain.saveAuthToken(legacyToken)
            defaults.removeObject(forKey: Self.authTokenDefaultsKey)
        }
        let selectedProfile = loadedProfiles.first(where: { $0.id == selectedProfileId })
        self.baseURLInput = selectedProfile?.remoteBaseURL ?? ""
        self.authTokenInput = selectedProfileId == Self.allProfileId
            ? ""
            : KycodeKeychain.loadAuthToken(profileId: selectedProfileId) ?? ""
        self.sourceConnectionStates = Self.primaryProfiles(from: loadedProfiles).map {
            KycodeSourceConnectionState(
                id: $0.id,
                name: $0.name,
                isLoading: false,
                isConnected: false,
                sessionCount: 0,
                connectionLabel: nil,
                errorMessage: nil
            )
        }
        self.currentVoiceDraft = nil
        self.currentVoiceDraft = loadVoiceDraft()
        self.recoveredVoiceDraftIdAtLaunch = self.currentVoiceDraft?.id
        self.latestVoiceIsolationReport = self.currentVoiceDraft?.isolationReport
        self.recentCreatedSessions = Self.loadRecentCreatedSessions(from: defaults)
        self.sessionDisplayOrdersByProfile = Self.loadSessionDisplayOrders(from: defaults)
        self.pendingRuntimeSettingsUpdates = Self.loadPendingRuntimeSettingsUpdates(
            from: runtimeSettingsDefaults
        )
        if let cached = Self.loadCachedSessions(from: defaults, profileId: selectedProfileId) {
            let defaultOrder = cached.sessions.map(\.windowId)
            let restoredOrder = KycodeSessionDisplayOrderPolicy.reconcile(
                existingOrder: self.sessionDisplayOrdersByProfile[selectedProfileId] ?? defaultOrder,
                availableWindowIds: defaultOrder,
                defaultOrder: defaultOrder
            )
            let cachedByWindowId = Dictionary(
                uniqueKeysWithValues: cached.sessions.map { ($0.windowId, $0) }
            )
            self.sessions = restoredOrder.compactMap { cachedByWindowId[$0] }
            self.sessionDisplayOrder = restoredOrder
            self.sessionDisplayOrdersByProfile[selectedProfileId] = restoredOrder
            self.lastSessionsRefreshAt = cached.cachedAt
            self.isShowingCachedSessions = !cached.sessions.isEmpty
        }
        persistProfilesState(persistSelection: initialProfileIdOverride == nil)
        restorePendingRuntimeSettingsTracking()
        sessions = sessions.map(applyingPendingRuntimeSettingsUpdate)
#if DEBUG
        configureDashboardUITestFixtureIfNeeded()
#endif
    }

#if DEBUG
    private func configureDashboardUITestFixtureIfNeeded() {
        guard ProcessInfo.processInfo.environment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] == "1" else {
            return
        }

        let personalCredentials = KycodeConnectionCredentials(
            baseURL: "https://fixture.invalid/personal",
            authToken: "fixture-personal-token"
        )
        let pukyCredentials = KycodeConnectionCredentials(
            baseURL: "https://fixture.invalid/puky",
            authToken: "fixture-puky-token"
        )
        let now = Date().timeIntervalSince1970 * 1_000
        let fixtureSessions = (0..<6).map { index in
            let profileId = index.isMultiple(of: 2) ? Self.personalProfileId : Self.pukyProfileId
            let profileName = profileId == Self.personalProfileId ? "Mac personal" : "Puky"
            let windowId = "messaging-fixture-\(index)"
            let messages = [
                KycodeMessage(
                    id: "fixture-user-\(index)",
                    role: "user",
                    type: "text",
                    content: "Revisá la experiencia de la sesión \(index + 1).",
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: now - Double((index + 1) * 120_000),
                    status: "sent",
                    imageAttachments: nil
                ),
                KycodeMessage(
                    id: "fixture-assistant-\(index)",
                    role: "assistant",
                    type: "text",
                    content: "La sesión de prueba está lista para validar búsqueda, acciones y navegación.",
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: now - Double(index * 120_000),
                    status: "completed",
                    imageAttachments: nil
                ),
            ]
            return KycodeSessionSummary(
                windowId: windowId,
                sessionId: "fixture-session-\(index)",
                engine: "codex",
                model: index.isMultiple(of: 2) ? "gpt-5.6-sol" : "gpt-5.6-luna",
                reasoningEffort: "max",
                providerSessionId: nil,
                providerSessionPath: nil,
                projectKey: "fixture-project-\(index % 2)",
                projectPath: "/tmp/fixture-project-\(index % 2)",
                projectName: index.isMultiple(of: 2) ? "Producto" : "Calidad",
                windowName: "Sesión de prueba \(index + 1)",
                displayName: "Sesión de prueba \(index + 1)",
                sidecarMode: "app-server",
                sidecarUrl: nil,
                activityStatus: index == 0 ? "working" : "ready",
                runtimeStatus: index == 0 ? "working" : "idle",
                runtimeStatusDetail: nil,
                features: KycodeSessionFeatures(
                    promptImproverEnabled: true,
                    explainerEnabled: false,
                    codeContextEnabled: true
                ),
                runMode: nil,
                goalStartedAt: nil,
                messageCount: messages.count,
                updatedAt: now - Double(index * 120_000),
                createdAt: now - Double((index + 1) * 600_000),
                rawPrompt: nil,
                originalPrompt: nil,
                improvedPrompt: nil,
                lastMessagePreview: messages.last?.content,
                isMinimized: false,
                canSend: true,
                canControlFeatures: true,
                unsupportedReason: nil,
                messages: messages,
                sessionName: "Sesión de prueba \(index + 1)"
            )
        }

        selectedProfileId = Self.allProfileId
        syncInputsFromSelectedProfile()
        hasBootstrapped = true
        isConnected = true
        isStreaming = true
        isConnecting = false
        isBootstrapping = false
        isReconnecting = false
        canRetryReconnectManually = false
        reconnectStatusText = nil
        errorMessage = nil
        lastBackgroundSyncErrorMessage = nil
        // Seed non-published routing metadata before publishing the sessions.
        // Otherwise SwiftUI can render the first dashboard frame without an
        // origin label and never receive a source-only invalidation.
        sessionSourceLabels = Dictionary(uniqueKeysWithValues: fixtureSessions.enumerated().map { index, summary in
            (summary.windowId, index.isMultiple(of: 2) ? "Mac personal" : "Puky")
        })
        sessions = fixtureSessions
        sessionDisplayOrder = fixtureSessions.map(\.windowId)
        sessionDetails = Dictionary(uniqueKeysWithValues: fixtureSessions.map { ($0.windowId, $0) })
        detailLoadStates = Dictionary(
            uniqueKeysWithValues: fixtureSessions.map { ($0.windowId, .loaded) }
        )
        allSourceCredentials = [
            Self.personalProfileId: personalCredentials,
            Self.pukyProfileId: pukyCredentials,
        ]
        sourceConnectionStates = [
            KycodeSourceConnectionState(
                id: Self.personalProfileId,
                name: "Mac personal",
                isLoading: false,
                isConnected: true,
                sessionCount: 3,
                connectionLabel: "Fixture",
                errorMessage: nil,
                snapshotPhase: .succeeded,
                attemptGeneration: 1,
                hasRetainedSnapshot: true
            ),
            KycodeSourceConnectionState(
                id: Self.pukyProfileId,
                name: "Puky",
                isLoading: false,
                isConnected: true,
                sessionCount: 3,
                connectionLabel: "Fixture",
                errorMessage: nil,
                snapshotPhase: .succeeded,
                attemptGeneration: 1,
                hasRetainedSnapshot: true
            ),
        ]
        sessionRoutes = Dictionary(uniqueKeysWithValues: fixtureSessions.enumerated().map { index, summary in
            let profileId = index.isMultiple(of: 2) ? Self.personalProfileId : Self.pukyProfileId
            let profileName = profileId == Self.personalProfileId ? "Mac personal" : "Puky"
            let credentials = profileId == Self.personalProfileId ? personalCredentials : pukyCredentials
            return (
                summary.windowId,
                KycodeSessionRoute(
                    presentedWindowId: summary.windowId,
                    remoteWindowId: summary.windowId,
                    profileId: profileId,
                    profileName: profileName,
                    credentials: credentials
                )
            )
        })
        for (index, summary) in fixtureSessions.enumerated() {
            let profileId = index.isMultiple(of: 2) ? Self.personalProfileId : Self.pukyProfileId
            for draftProfileId in [profileId, Self.allProfileId] {
                UserDefaults.standard.removeObject(
                    forKey: KycodeComposerDraftStoragePolicy.storageKey(
                        profileId: draftProfileId,
                        remoteWindowId: summary.windowId
                    )
                )
            }
            UserDefaults.standard.removeObject(
                forKey: KycodeComposerDraftStoragePolicy.legacyStorageKey(windowId: summary.windowId)
            )
        }
        lastSessionsRefreshAt = Date()
        isShowingCachedSessions = false
        lastConnectionSource = "Todo · prueba local"
        confirmedPromptImproverVariantsByProfileId = [
            Self.personalProfileId: .standard,
            Self.pukyProfileId: .standard,
        ]
        promptImproverVariant = .standard
        promptImproverVariantSyncState = .synchronized
        isRefreshingPromptImproverVariant = false
        isUpdatingPromptImproverVariant = false
    }
#endif

    private static func primaryProfiles(from profiles: [KycodeConnectionProfile]) -> [KycodeConnectionProfile] {
        profiles.filter { $0.id == Self.pukyProfileId || $0.id == Self.personalProfileId }
    }

    deinit {
        promptImproverVariantRefreshTask?.cancel()
        streamTask?.cancel()
        refreshTask?.cancel()
        metadataRefreshTask?.cancel()
        reconnectTask?.cancel()
        bootstrapTask?.cancel()
        for task in createdSessionReconciliationTasks.values {
            task.cancel()
        }
        for task in voiceTranscriptionTasks.values {
            task.cancel()
        }
    }

    var selectedProfile: KycodeConnectionProfile? {
        profiles.first(where: { $0.id == selectedProfileId })
    }

    var userSelectableProfiles: [KycodeConnectionProfile] {
        [Self.pukyProfileId, Self.personalProfileId, Self.allProfileId].compactMap { profileId in
            profiles.first(where: { $0.id == profileId })
        }
    }

    var selectedProfileName: String {
        selectedProfile?.name ?? "Desktop"
    }

    var selectedProfileUsesBonjourOnly: Bool {
        selectedProfile?.mode == .bonjourOnly
    }

    var selectedProfileUsesRemoteHub: Bool {
        selectedProfile?.mode == .remoteHub || selectedProfile?.mode == .personal || selectedProfile?.mode == .ferminCode
    }

    var selectedProfileUsesAll: Bool {
        selectedProfile?.mode == .all
    }

    var promptImproverVariantSelection: KycodePromptImproverVariant? {
        if selectedProfileUsesAll,
           promptImproverVariantSyncState == .mixed || promptImproverVariantSyncState == .partial {
            return nil
        }
        return promptImproverVariant
    }

    var isPromptImproverVariantSynchronizing: Bool {
        isUpdatingPromptImproverVariant || isRefreshingPromptImproverVariant
    }

    var promptImproverVariantAccessibilityValue: String {
        if promptImproverVariantSyncState == .mixed {
            return isPromptImproverVariantSynchronizing
                ? "Configuraciones diferentes, sincronizando"
                : "Configuraciones diferentes entre Puky y Personal"
        }
        if selectedProfileUsesAll, promptImproverVariantSyncState == .partial {
            return isPromptImproverVariantSynchronizing
                ? "Configuración incompleta, sincronizando"
                : "No se pudieron confirmar Puky y Personal"
        }
        if isPromptImproverVariantSynchronizing {
            return "\(promptImproverVariant.title), sincronizando con \(promptImproverVariantRuntimeLabel)"
        }
        switch promptImproverVariantSyncState {
        case .cached:
            return "\(promptImproverVariant.title), valor guardado sin confirmar"
        case .synchronized:
            return "\(promptImproverVariant.title), sincronizado con \(promptImproverVariantRuntimeLabel)"
        case .partial:
            return "\(promptImproverVariant.title), falta confirmar un runtime"
        case .unavailable:
            return "\(promptImproverVariant.title), no se pudo confirmar"
        case .mixed:
            return "Configuraciones diferentes entre Puky y Personal"
        }
    }

    var promptImproverVariantSummary: String {
        switch promptImproverVariantSyncState {
        case .mixed:
            return "Puky y Personal usan tipos distintos. Elegí uno para unificarlos de forma explícita."
        case .partial where selectedProfileUsesAll:
            return "Falta confirmar uno de los dos runtimes. Podés reintentar o elegir un tipo para unificarlos."
        default:
            return promptImproverVariant.summary
        }
    }

    var promptImproverVariantStatusText: String {
        if isPromptImproverVariantSynchronizing {
            return "Sincronizando con \(promptImproverVariantRuntimeLabel)…"
        }
        switch promptImproverVariantSyncState {
        case .cached:
            return "Valor guardado · se confirmará con \(promptImproverVariantRuntimeLabel)."
        case .synchronized:
            return "\(promptImproverVariantRuntimeLabel) · se aplica al próximo prompt mejorado."
        case .mixed:
            return "Elegí Preciso o Impulso para unificar ambos runtimes."
        case .partial:
            return selectedProfileUsesAll
                ? "No pudimos confirmar ambos runtimes. Reintentá o elegí un tipo para unificarlos."
                : "Falta confirmar este valor con \(promptImproverVariantRuntimeLabel)."
        case .unavailable:
            return "No pudimos confirmar este valor. Reintentá cuando quieras."
        }
    }

    private var promptImproverVariantRuntimeLabel: String {
        selectedProfileUsesAll ? "Puky y Personal" : selectedProfileName
    }

    var dashboardSnapshotState: KycodeDashboardSnapshotState {
        let relevantSourceStates: [KycodeSourceConnectionState]
        if selectedProfileUsesAll {
            let requiredIds = Set([Self.pukyProfileId, Self.personalProfileId])
            relevantSourceStates = sourceConnectionStates.filter { requiredIds.contains($0.id) }
        } else {
            relevantSourceStates = sourceConnectionStates.filter { $0.id == selectedProfileId }
        }
        return KycodeDashboardSnapshotPolicy.resolve(
            sourceStates: relevantSourceStates,
            sessionCount: sessions.count,
            isShowingCachedSessions: isShowingCachedSessions,
            isConnected: isConnected,
            isBootstrapping: isBootstrapping,
            isReconnecting: isReconnecting,
            canRetry: canRetryReconnectManually,
            hasError: errorMessage?.isEmpty == false
        )
    }

    var dashboardFailedSourceNames: [String] {
        let relevantIds = selectedProfileUsesAll
            ? Set([Self.pukyProfileId, Self.personalProfileId])
            : Set([selectedProfileId])
        return sourceConnectionStates.compactMap { state in
            guard relevantIds.contains(state.id), state.snapshotPhase == .failed else {
                return nil
            }
            return state.name
        }
    }

    var selectedProfileSupportsManualFields: Bool {
        selectedProfile?.mode == .remoteFirst
    }

    var selectedProfileSummary: String {
        guard let selectedProfile else {
            return "Elegí un desktop."
        }
        switch selectedProfile.mode {
        case .remoteFirst:
            if let remoteBaseURL = selectedProfile.remoteBaseURL, !remoteBaseURL.isEmpty {
                return "Remoto por \(remoteBaseURL). Si estás en la misma red, también aprende el token por Bonjour."
            }
            return "Remoto con fallback por Bonjour."
        case .bonjourOnly:
            return "Busca esta computadora por Bonjour en tu red local."
        case .remoteHub:
            return "Conecta este desktop por un relay remoto."
        case .personal:
            return "Conecta tu Mac personal únicamente por el relay remoto seguro de Fermín Code."
        case .ferminCode:
            return "Conecta Puky únicamente por el relay remoto seguro de Fermín Code."
        case .all:
            return "Muestra Puky y tu Mac personal juntas, manteniendo cada acción en su Mac de origen."
        }
    }

    var hasCredentials: Bool {
        selectedProfileUsesBonjourOnly || selectedProfileUsesAll || draftCredentials != nil
    }

    var createSessionAccess: KycodeCreateSessionAccess {
        let credentials = sessionCreationCredentials
        let hasRoutableCredentials: Bool
#if DEBUG
        if allowsConnectionProfileTestOverrides {
            hasRoutableCredentials = credentials != nil
        } else {
            hasRoutableCredentials = credentials.map {
                KycodeBackendCapabilityPolicy.isFerminCode(
                    selectedProfileId: selectedProfileId,
                    activeBaseURL: $0.baseURL
                )
            } ?? false
        }
#else
        hasRoutableCredentials = credentials.map {
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: selectedProfileId,
                activeBaseURL: $0.baseURL
            )
        } ?? false
#endif
        return KycodeCreateSessionAccessPolicy.resolve(
            usesCombinedProfile: selectedProfileUsesAll,
            hasRoutableCredentials: hasRoutableCredentials
        )
    }

    func sessionSourceLabel(for windowId: String) -> String? {
        if let routedLabel = sessionSourceLabels[windowId] ?? sessionRoutes[windowId]?.profileName {
            return routedLabel
        }
        guard !selectedProfileUsesAll,
              selectedProfileId == Self.pukyProfileId || selectedProfileId == Self.personalProfileId,
              sessions.contains(where: { $0.windowId == windowId }) else {
            return nil
        }
        return selectedProfile?.name
    }

    func composerDraftStorageKey(
        for windowId: String,
        sourceWindowId: String? = nil
    ) -> String {
        let route = sessionRoutes[windowId]
        let sourceProfileId = sourceWindowId.flatMap { sessionRoutes[$0]?.profileId }
        return KycodeComposerDraftStoragePolicy.storageKey(
            profileId: route?.profileId ?? sourceProfileId ?? selectedProfileId,
            remoteWindowId: route?.remoteWindowId ?? windowId
        )
    }

    func supportsClaudeSubagents(windowId: String) -> Bool {
        !targetsFerminCode(windowId: windowId)
    }

    func supportsCollaborationProjects(windowId: String) -> Bool {
        !targetsFerminCode(windowId: windowId)
    }

    func moveSession(windowId: String, over targetWindowId: String) {
        let nextOrder = KycodeSessionDisplayOrderPolicy.moving(
            sessionDisplayOrder,
            windowId: windowId,
            over: targetWindowId
        )
        guard nextOrder != sessionDisplayOrder else { return }
        sessionDisplayOrder = nextOrder
        let sessionsByWindowId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.windowId, $0) })
        sessions = sessionDisplayOrder.compactMap { sessionsByWindowId[$0] }
        persistSessionDisplayOrder()
        persistCachedSessions(sessions, cachedAt: Date())
    }

    var hasConnectionNotice: Bool {
        if let reconnectStatusText, !reconnectStatusText.isEmpty {
            return true
        }
        return false
    }

    func selectProfile(id: String) async {
        guard id != selectedProfileId else { return }
        guard id == Self.pukyProfileId || id == Self.personalProfileId || id == Self.allProfileId else { return }
        guard profiles.contains(where: { $0.id == id }) else { return }
        suspendConnectionForTargetHandoff()
        selectedProfileId = id
        syncInputsFromSelectedProfile()
        persistProfilesState()
        preparePromptImproverVariantForSelectedProfile()
        if !activateWarmTargetConnectionIfAvailable() {
            await autoConnect()
        }
        promptImproverVariantRefreshTask?.cancel()
        promptImproverVariantRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshPromptImproverVariant()
        }
    }

    func selectRemoteHubProfile(token: String) async {
        prepareForManualConnectionInteraction()
        guard let profile = selectedProfile,
              profile.mode == .personal || profile.mode == .ferminCode || profile.mode == .remoteHub,
              let canonicalRemoteBaseURL = profile.remoteBaseURL else {
            errorMessage = "Elegí Puky o Mac personal."
            return
        }
#if DEBUG
        let testOverride = allowsConnectionProfileTestOverrides
            ? baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let remoteBaseURL = testOverride.isEmpty ? canonicalRemoteBaseURL : testOverride
#else
        let remoteBaseURL = canonicalRemoteBaseURL
#endif
        let trimmedToken = kycodeNormalizedAuthToken(token)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Pegá el token de Fermín Code."
            return
        }

        baseURLInput = remoteBaseURL
        authTokenInput = trimmedToken
        guard let credentials = normalizedCredentials(baseURL: remoteBaseURL, authToken: trimmedToken) else {
            errorMessage = "No pude preparar la conexión remota."
            return
        }

        invalidatePromptImproverVariantRoute(presentsCachedState: true)
        let didConnect = await connect(
            using: credentials,
            persist: true,
            persistBaseURL: false,
            sourceLabel: "\(profile.name) · Internet"
        )
        if didConnect {
            persistProfilesState()
        }
    }

    func getRemoteHubToken() -> String? {
        guard selectedProfileUsesRemoteHub else { return nil }
        return KycodeKeychain.loadAuthToken(profileId: selectedProfileId)
    }

    func clearRemoteHubToken() {
        guard selectedProfileUsesRemoteHub else { return }
        KycodeKeychain.deleteAuthToken(profileId: selectedProfileId)
        authTokenInput = ""
    }

    func isRemoteHubSelected() -> Bool {
        selectedProfileUsesRemoteHub
    }

    func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.autoConnect()
            await MainActor.run {
                self?.bootstrapTask = nil
            }
        }
    }

    func connect() async {
        prepareForManualConnectionInteraction()
        if selectedProfileUsesRemoteHub {
            await selectRemoteHubProfile(token: authTokenInput)
            return
        }
        guard let credentials = draftCredentials else {
            errorMessage = "Completá URL y token."
            return
        }
        invalidatePromptImproverVariantRoute(presentsCachedState: true)
        _ = await connect(using: credentials, persist: true, persistBaseURL: true, sourceLabel: "Manual · \(selectedProfileName)")
    }

    func retryAutoConnect() async {
#if DEBUG
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_RETRY_REQUIRED"] == "1" {
            seedComposerReconnectUITestFixture()
            return
        }
#endif
        log("Retry manual de autoconexion solicitado")
        cancelReconnect()
        await autoConnect()
    }

    func cancelReconnect() {
        clearConnectionIssueState(cancelReconnectTask: true)
        for state in sourceConnectionStates where state.isLoading {
            guard let profile = profiles.first(where: { $0.id == state.id }) else { continue }
            updateSourceState(
                profile: profile,
                isLoading: false,
                isConnected: state.isConnected,
                sessionCount: state.sessionCount,
                connectionLabel: state.connectionLabel,
                errorMessage: "Reconexión pausada.",
                snapshotPhase: .failed,
                attemptGeneration: state.attemptGeneration,
                hasRetainedSnapshot: state.hasRetainedSnapshot
            )
        }
        if !isConnected, !sessions.isEmpty {
            isShowingCachedSessions = true
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func setFastModeEnabled(_ enabled: Bool) {
        guard fastModeEnabled != enabled else { return }
        fastModeEnabled = enabled
        KycodeFastModePreference.save(enabled)
    }

    func refreshPromptImproverVariant() async {
        guard !isUpdatingPromptImproverVariant else { return }
        let ownerProfileId = selectedProfileId
        let connectionGeneration = connectionStateGeneration
        let targets = promptImproverPreferenceTargets
        let expectedProfileIds = promptImproverExpectedProfileIds
        guard Set(targets.map(\.profileId)) == Set(expectedProfileIds) else {
            promptImproverVariantSyncState = selectedProfileUsesAll ? .partial : .unavailable
            return
        }
        let mutationGeneration = promptImproverVariantMutationGeneration
        let refreshID = UUID()
        promptImproverVariantRefreshID = refreshID
        isRefreshingPromptImproverVariant = true
        defer {
            if promptImproverVariantRefreshID == refreshID {
                promptImproverVariantRefreshID = nil
                isRefreshingPromptImproverVariant = false
            }
        }
        do {
            var refreshedVariants: [String: KycodePromptImproverVariant] = [:]
            for target in targets {
                let envelope = try await fetchPromptImproverPreference(target.credentials)
                guard envelope.ok else {
                    throw URLError(.cannotParseResponse)
                }
                refreshedVariants[target.profileId] = envelope.preference.variant
            }
            guard ownsPromptImproverVariantRoute(
                      profileId: ownerProfileId,
                      connectionGeneration: connectionGeneration,
                      targets: targets
                  ),
                  promptImproverVariantRefreshID == refreshID,
                  !isUpdatingPromptImproverVariant,
                  mutationGeneration == promptImproverVariantMutationGeneration else { return }
            for (profileId, variant) in refreshedVariants {
                confirmedPromptImproverVariantsByProfileId[profileId] = variant
                KycodePromptImproverPreferenceStore.save(
                    variant,
                    profileId: profileId,
                    to: runtimeSettingsDefaults
                )
            }
            applyPromptImproverVariantPresentation(
                profileId: ownerProfileId,
                synchronized: true
            )
        } catch {
            guard ownsPromptImproverVariantRoute(
                      profileId: ownerProfileId,
                      connectionGeneration: connectionGeneration,
                      targets: targets
                  ),
                  promptImproverVariantRefreshID == refreshID,
                  !isUpdatingPromptImproverVariant,
                  mutationGeneration == promptImproverVariantMutationGeneration else { return }
            promptImproverVariantSyncState = selectedProfileUsesAll ? .partial : .unavailable
        }
    }

    @discardableResult
    func setPromptImproverVariant(_ variant: KycodePromptImproverVariant) async -> Bool {
        promptImproverVariantMutationGeneration &+= 1
        let intent = KycodePromptImproverVariantIntent(
            generation: promptImproverVariantMutationGeneration,
            connectionGeneration: connectionStateGeneration,
            ownerProfileId: selectedProfileId,
            targets: promptImproverPreferenceTargets,
            variant: variant
        )
        promptImproverVariantRefreshTask?.cancel()
        promptImproverVariantRefreshTask = nil
        promptImproverVariantRefreshID = nil
        isRefreshingPromptImproverVariant = false
        isUpdatingPromptImproverVariant = true
        promptImproverVariant = variant
        promptImproverVariantSyncState = .cached

        let result = await promptImproverVariantMutationQueue.submit(intent) { [weak self] intent in
            guard let self else { return false }
            return await self.syncPromptImproverVariant(intent)
        }

        guard case let .completed(finalIntent, succeeded) = result else {
            return true
        }
        guard finalIntent.generation == promptImproverVariantMutationGeneration else {
            return succeeded
        }
        guard ownsPromptImproverVariantRoute(
            profileId: finalIntent.ownerProfileId,
            connectionGeneration: finalIntent.connectionGeneration,
            targets: finalIntent.targets
        ) else {
            return succeeded
        }

        isUpdatingPromptImproverVariant = false
        if succeeded {
            applyPromptImproverVariantPresentation(
                profileId: finalIntent.ownerProfileId,
                synchronized: true
            )
            return true
        }

        applyPromptImproverVariantPresentation(
            profileId: finalIntent.ownerProfileId,
            synchronized: false
        )
        promptImproverVariantSyncState = selectedProfileUsesAll ? .partial : .unavailable
        errorMessage = promptImproverVariantSyncFailureMessagesByProfileId[finalIntent.ownerProfileId]
            ?? "No pude guardar el tipo de mejorador de prompt."
        return false
    }

    private func syncPromptImproverVariant(_ intent: KycodePromptImproverVariantIntent) async -> Bool {
        guard ownsPromptImproverVariantRoute(
            profileId: intent.ownerProfileId,
            connectionGeneration: intent.connectionGeneration,
            targets: intent.targets
        ) else {
            return true
        }
        guard Set(intent.targets.map(\.profileId)) == Set(promptImproverExpectedProfileIds) else {
            promptImproverVariantSyncFailureMessagesByProfileId[intent.ownerProfileId] =
                "Conectate a un runtime para cambiar el tipo de mejorador de prompt."
            return false
        }

        var failedTargetCount = 0
        for target in intent.targets {
            guard ownsPromptImproverVariantRoute(
                profileId: intent.ownerProfileId,
                connectionGeneration: intent.connectionGeneration,
                targets: intent.targets
            ) else {
                return true
            }
            do {
                let envelope = try await postPromptImproverPreference(
                    target.credentials,
                    variant: intent.variant
                )
                guard ownsPromptImproverVariantRoute(
                    profileId: intent.ownerProfileId,
                    connectionGeneration: intent.connectionGeneration,
                    targets: intent.targets
                ) else {
                    return true
                }
                guard envelope.ok, envelope.preference.variant == intent.variant else {
                    failedTargetCount += 1
                    continue
                }
                confirmedPromptImproverVariantsByProfileId[target.profileId] = intent.variant
                KycodePromptImproverPreferenceStore.save(
                    intent.variant,
                    profileId: target.profileId,
                    to: runtimeSettingsDefaults
                )
            } catch {
                guard ownsPromptImproverVariantRoute(
                    profileId: intent.ownerProfileId,
                    connectionGeneration: intent.connectionGeneration,
                    targets: intent.targets
                ) else {
                    return true
                }
                failedTargetCount += 1
            }
        }

        guard failedTargetCount == 0 else {
            promptImproverVariantSyncFailureMessagesByProfileId[intent.ownerProfileId] = intent.targets.count > 1
                ? "El tipo de mejorador no pudo sincronizarse con todos los runtimes. Revisá la conexión y reintentá."
                : "No pude guardar el tipo de mejorador de prompt."
            return false
        }

        promptImproverVariantSyncFailureMessagesByProfileId[intent.ownerProfileId] = nil
        return true
    }

    private func preparePromptImproverVariantForSelectedProfile() {
        if selectedProfileId != Self.allProfileId {
            KycodePromptImproverPreferenceStore.migrateLegacyValueIfNeeded(
                to: selectedProfileId,
                in: runtimeSettingsDefaults
            )
        }
        invalidatePromptImproverVariantRoute(presentsCachedState: false)
        applyPromptImproverVariantPresentation(
            profileId: selectedProfileId,
            synchronized: false
        )
    }

    private func invalidatePromptImproverVariantRoute(
        presentsCachedState: Bool
    ) {
        promptImproverVariantMutationGeneration &+= 1
        promptImproverVariantRefreshTask?.cancel()
        promptImproverVariantRefreshTask = nil
        promptImproverVariantRefreshID = nil
        isUpdatingPromptImproverVariant = false
        isRefreshingPromptImproverVariant = false
        promptImproverVariantMutationQueue = KycodeLatestIntentMutationQueue()
        if presentsCachedState {
            applyPromptImproverVariantPresentation(
                profileId: selectedProfileId,
                synchronized: false
            )
        }
    }

    private func applyPromptImproverVariantPresentation(
        profileId: String,
        synchronized: Bool
    ) {
        let relevantProfileIds = profileId == Self.allProfileId
            ? [Self.pukyProfileId, Self.personalProfileId]
            : [profileId]
        let variants = relevantProfileIds.compactMap {
            confirmedPromptImproverVariantsByProfileId[$0]
                ?? KycodePromptImproverPreferenceStore.load(
                    profileId: $0,
                    from: runtimeSettingsDefaults
                )
        }
        if profileId == Self.allProfileId {
            promptImproverVariant = variants.first ?? .standard
            if variants.count < relevantProfileIds.count {
                promptImproverVariantSyncState = .partial
            } else if Set(variants).count > 1 {
                promptImproverVariantSyncState = .mixed
            } else {
                promptImproverVariantSyncState = synchronized ? .synchronized : .cached
            }
            return
        }
        promptImproverVariant = variants.first ?? .standard
        promptImproverVariantSyncState = synchronized ? .synchronized : .cached
    }

    func prepareForManualConnectionInteraction() {
        guard reconnectTask != nil || bootstrapTask != nil || isReconnecting || isBootstrapping || canRetryReconnectManually else {
            return
        }
        cancelReconnect()
    }

    func disconnect() {
        resetConnectionState(
            clearsWarmTargetConnections: true,
            removesPersistedSessionCache: true
        )
    }

    /// A target change is not a logout. Stop work owned by the old transport,
    /// but retain the last verified snapshots for Puky and Mac personal so a
    /// return trip can paint and route immediately while the live stream
    /// reconnects in the background.
    private func suspendConnectionForTargetHandoff() {
        resetConnectionState(
            clearsWarmTargetConnections: false,
            removesPersistedSessionCache: false
        )
    }

    private func ownsConnectionAttempt(
        connectionGeneration: UInt64,
        selectedProfileId: String
    ) -> Bool {
        self.connectionStateGeneration == connectionGeneration
            && self.selectedProfileId == selectedProfileId
    }

    private func ownsAsyncSnapshotMutation(
        connectionGeneration: UInt64,
        attemptGeneration: UInt64,
        selectedProfileId: String,
        credentials: KycodeConnectionCredentials,
        sourceProfileId: String?
    ) -> Bool {
        guard ownsConnectionAttempt(
            connectionGeneration: connectionGeneration,
            selectedProfileId: selectedProfileId
        ), sourceSnapshotAttemptGeneration == attemptGeneration else {
            return false
        }
        if let sourceProfileId {
            return selectedProfileUsesAll
                && allSourceCredentials[sourceProfileId] == credentials
        }
        return !selectedProfileUsesAll
            && (activeCredentials ?? draftCredentials) == credentials
    }

    private func resetConnectionState(
        clearsWarmTargetConnections: Bool,
        removesPersistedSessionCache: Bool
    ) {
        connectionStateGeneration &+= 1
        invalidatePromptImproverVariantRoute(presentsCachedState: true)
        sourceSnapshotAttemptGeneration &+= 1
        streamTask?.cancel()
        refreshTask?.cancel()
        metadataRefreshTask?.cancel()
        reconnectTask?.cancel()
        bootstrapTask?.cancel()
        for task in messageReconciliationTasks.values {
            task.cancel()
        }
        for task in createdSessionReconciliationTasks.values {
            task.cancel()
        }
        streamTask = nil
        refreshTask = nil
        metadataRefreshTask = nil
        reconnectTask = nil
        bootstrapTask = nil
        messageReconciliationTasks.removeAll()
        pendingPromptRetryIntents.removeAll()
        promptTransformTimeoutContexts.removeAll()
        createdSessionReconciliationTasks.removeAll()
        activeCredentials = nil
        isConnected = false
        isStreaming = false
        isConnecting = false
        clearConnectionIssueState(cancelReconnectTask: false)
        errorMessage = nil
        sessions = []
        sessionDetails = [:]
        detailLoadStates = [:]
        pendingDeletions = [:]
        pendingPinnedUpdates = [:]
        pendingGoalModeUpdates = [:]
        pendingFeatureUpdates = [:]
        pendingOptimisticMessages = [:]
        imageUploadProgress = nil
        liveMessagePatchCursorByKey = [:]
        pendingLiveMessagePatchesByWindowId = [:]
        durableCommandTracker.removeAll()
        restorePendingRuntimeSettingsTracking()
        pendingMetadataRefreshWindowIds = []
        detailRefreshInFlight = [:]
        lastDetailRefreshAtByWindowId = [:]
        missingWindowIdsAwaitingSnapshotRemoval = []
        lastStreamActivityAt = nil
        sessionDisplayOrder = []
        sessionRoutes = [:]
        sessionSourceLabels = [:]
        allSourceSnapshots = [:]
        allSourceCredentials = [:]
        if clearsWarmTargetConnections {
            warmTargetConnections = [:]
        }
        sourceConnectionStates = Self.primaryProfiles(from: profiles).map {
            KycodeSourceConnectionState(
                id: $0.id,
                name: $0.name,
                isLoading: false,
                isConnected: false,
                sessionCount: 0,
                connectionLabel: nil,
                errorMessage: nil
            )
        }
        lastConnectionSource = nil
        isShowingCachedSessions = false
        if removesPersistedSessionCache {
            UserDefaults.standard.removeObject(forKey: Self.cachedSessionsDefaultsKey)
        }
    }

    func reconnect() async {
        disconnect()
        await autoConnect()
    }

    func refreshSessionsNow() async {
        if selectedProfileUsesAll {
            await refreshAllSessionsNow()
            return
        }
        guard let credentials = activeCredentials ?? draftCredentials else { return }
        let profileId = selectedProfileId
        let generation = connectionStateGeneration
        let profile = selectedProfile
        let attemptGeneration = profile.map {
            beginSourceSnapshotAttempt(for: [$0])
        }
        do {
            let snapshot = try await fetchSessions(credentials)
            guard connectionStateGeneration == generation,
                  selectedProfileId == profileId,
                  (activeCredentials ?? draftCredentials) == credentials,
                  attemptGeneration.map({ sourceSnapshotAttemptGeneration == $0 }) ?? true else {
                return
            }
            try validateSnapshotFreshness(snapshot, for: credentials)
            clearConnectionIssueState(cancelReconnectTask: false)
            applySessions(snapshot)
            isConnected = true
            if let profile, let attemptGeneration {
                updateSourceState(
                    profile: profile,
                    isLoading: false,
                    isConnected: true,
                    sessionCount: snapshot.items.count,
                    connectionLabel: lastConnectionSource,
                    errorMessage: nil,
                    snapshotPhase: .succeeded,
                    attemptGeneration: attemptGeneration,
                    hasRetainedSnapshot: true
                )
            }
        } catch {
            guard connectionStateGeneration == generation,
                  selectedProfileId == profileId,
                  (activeCredentials ?? draftCredentials) == credentials,
                  attemptGeneration.map({ sourceSnapshotAttemptGeneration == $0 }) ?? true else {
                return
            }
            if let profile, let attemptGeneration {
                let current = sourceConnectionStates.first(where: { $0.id == profile.id })
                updateSourceState(
                    profile: profile,
                    isLoading: false,
                    isConnected: false,
                    sessionCount: sessions.count,
                    connectionLabel: current?.connectionLabel,
                    errorMessage: error.localizedDescription,
                    snapshotPhase: .failed,
                    attemptGeneration: attemptGeneration,
                    hasRetainedSnapshot: current?.hasRetainedSnapshot ?? false
                )
            }
            if await handleRecoverableConnectionFailure(error, source: "refresh", credentials: credentials) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func refreshDetail(windowId: String) async {
#if DEBUG
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] == "1"
            || ProcessInfo.processInfo.environment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] == "1" {
            detailLoadStates[windowId] = .loaded
            return
        }
#endif
        guard pendingDeletions[windowId] == nil else { return }
        guard !missingWindowIdsAwaitingSnapshotRemoval.contains(windowId) else { return }
        guard let target = routedTarget(for: windowId) else {
            if selectedProfileUsesAll {
                errorMessage = "La Mac de origen no está conectada. Revisá su estado y reintentá."
            }
            return
        }
        let credentials = target.credentials
        let remoteWindowId = target.remoteWindowId
        let profileId = selectedProfileId
        let generation = connectionStateGeneration
        let requestId = UUID()
        guard detailRefreshInFlight[windowId] == nil else { return }
        detailRefreshInFlight[windowId] = requestId
        detailLoadStates[windowId] = .loading
        defer {
            if detailRefreshInFlight[windowId] == requestId {
                detailRefreshInFlight.removeValue(forKey: windowId)
            }
        }
        do {
            let detail = try await fetchDetail(credentials, windowId: remoteWindowId)
            guard connectionStateGeneration == generation,
                  selectedProfileId == profileId,
                  let currentTarget = routedTarget(for: windowId),
                  currentTarget.credentials == credentials,
                  currentTarget.remoteWindowId == remoteWindowId else { return }
            guard pendingDeletions[windowId] == nil else { return }
            detailLoadStates[windowId] = .loaded
            if !selectedProfileUsesAll {
                clearConnectionIssueState(cancelReconnectTask: false)
            }
            let reconciled = reconcilePendingSessionUpdates(
                with: detail.item.replacingWindowId(windowId),
                goalModeSource: .detail,
                featureSource: .detail
            )
            let monotonic = KycodeSessionDetailReconciliationPolicy.merging(
                // Older sidecars can legitimately omit newer presentation
                // metadata from the detail response even though the sessions
                // snapshot already knows it. Seed the first detail merge from
                // that summary so opening or refreshing a chat cannot erase
                // its collaboration project from the dashboard.
                current: sessionDetails[windowId]
                    ?? sessions.first(where: { $0.windowId == windowId }),
                incoming: reconciled
            )
            let resolvedDetail = reconcileOptimisticMessages(
                with: monotonic,
                authoritativeMessages: reconciled.messages ?? []
            )
            sessionDetails[windowId] = resolvedDetail
            reconcilePromptTransformTimeouts(windowId: windowId)
            if pendingOptimisticMessages[windowId]?.isEmpty ?? true,
               let summaryIndex = sessions.firstIndex(where: { $0.windowId == windowId }) {
                sessions[summaryIndex] = mergeDetail(sessions[summaryIndex], with: resolvedDetail)
            }
            lastDetailRefreshAtByWindowId[windowId] = Date()
            if let pendingPatch = pendingLiveMessagePatchesByWindowId.removeValue(forKey: windowId) {
                applyLiveMessagePatch(pendingPatch)
            }
        } catch {
            guard connectionStateGeneration == generation,
                  selectedProfileId == profileId,
                  let currentTarget = routedTarget(for: windowId),
                  currentTarget.credentials == credentials,
                  currentTarget.remoteWindowId == remoteWindowId else { return }
            if KycodeSessionRefreshErrorPolicy.isMissingWindow(error) {
                reconcileMissingWindow(windowId)
                return
            }
            detailLoadStates[windowId] = .failed(
                "La sesión sigue ahí. Reintentá para recuperar los mensajes más recientes."
            )
            if await handleRecoverableConnectionFailure(error, source: "detail", credentials: credentials) {
                return
            }
            recordBackgroundSyncFailure(error.localizedDescription, source: "detail")
        }
    }

    func recoverForegroundState() async {
#if DEBUG
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] == "1" {
            return
        }
#endif
        await refreshSessionsNow()
        for windowId in sessionDetails.keys.sorted() {
            await refreshDetail(windowId: windowId)
        }
    }

    func detail(for windowId: String) -> KycodeSessionSummary? {
        guard pendingDeletions[windowId] == nil else { return nil }
        let summary = sessions.first(where: { $0.windowId == windowId })
        let item: KycodeSessionSummary?
        if let detail = sessionDetails[windowId], let summary {
            // The list snapshot is authoritative for lightweight card
            // metadata; the detail is authoritative for the transcript. A
            // merged presentation prevents asynchronous responses from
            // making project labels flicker between assigned and empty.
            item = mergeDetail(detail, with: summary)
        } else {
            item = sessionDetails[windowId] ?? summary
        }
        guard let item else {
            return nil
        }
        return applyingPendingSessionUpdates(to: item)
    }

    func detailLoadState(for windowId: String) -> KycodeSessionDetailLoadState {
        detailLoadStates[windowId] ?? .idle
    }

    func transcriptUpdatedAt(for windowId: String) -> Double {
        sessionDetails[windowId]?.updatedAt
            ?? sessions.first(where: { $0.windowId == windowId })?.updatedAt
            ?? 0
    }

#if DEBUG
    func seedComposerActionPriorityUITestFixture() {
        let windowId = "composer-action-priority"
        let isLongSessionPerformanceFixture =
            ProcessInfo.processInfo.environment["KYCODE_UI_TEST_LONG_SESSION_PERFORMANCE"] == "1"
        let messages: [KycodeMessage]
        if isLongSessionPerformanceFixture {
            messages = (0..<1_395).map { index in
                let role = index.isMultiple(of: 3) ? "user" : "assistant"
                let targetLength = index.isMultiple(of: 50) ? 4_000 : 320
                let seed = "Mensaje de rendimiento \(index). Texto estable para representar una conversación larga de Fermín Code Mobile. "
                let repetitions = max(1, targetLength / seed.count)
                return KycodeMessage(
                    id: "long-session-message-\(index)",
                    role: role,
                    type: role == "user" ? "text" : "codex",
                    content: String(repeating: seed, count: repetitions),
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: 1_786_000_000_000 + Double(index * 1_000),
                    status: "completed",
                    imageAttachments: nil
                )
            }
        } else {
            messages = [
                KycodeMessage(
                    id: "composer-action-priority-message",
                    role: "assistant",
                    type: "codex",
                    content: "El composer está listo para escribir.",
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: 1_786_000_000_000,
                    status: nil,
                    imageAttachments: nil
                )
            ]
        }
        let fixture = KycodeSessionSummary(
            windowId: windowId,
            sessionId: "composer-action-priority-session",
            engine: "codex",
            model: "gpt-5.6-luna",
            reasoningEffort: "low",
            providerSessionId: "composer-action-priority-provider",
            providerSessionPath: nil,
            projectKey: "kycode-mobile",
            projectPath: "/tmp/kycode-mobile",
            projectName: "Fermín Code Mobile",
            windowName: "Composer QA",
            displayName: "Composer QA",
            sidecarMode: "mobile",
            sidecarUrl: nil,
            activityStatus: "ready",
            runtimeStatus: "READY",
            runtimeStatusDetail: nil,
            features: KycodeSessionFeatures(
                promptImproverEnabled: true,
                explainerEnabled: false,
                codeContextEnabled: false
            ),
            messageCount: messages.count,
            updatedAt: messages.last?.timestamp ?? 1_786_000_000_000,
            createdAt: 1_786_000_000_000,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: messages.last?.content,
            isMinimized: false,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: messages
        )
        sessions = [fixture]
        sessionDetails = [windowId: fixture]
        detailLoadStates = [windowId: .loaded]
        isShowingCachedSessions = false
        isConnected = true
        isStreaming = true
        isConnecting = false
        isBootstrapping = false
        isReconnecting = false
        canRetryReconnectManually = false
        errorMessage = nil
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_STALE_RECONNECT_WITH_LIVE_STREAM"] == "1" {
            // Reproduces the physical-device screenshot: an unrelated request
            // left recovery flags behind while the authenticated stream was
            // still current and delivering the conversation.
            isConnecting = true
            isBootstrapping = true
            isReconnecting = true
            reconnectStatusText = "Reconectando... intento 3/5"
        }
    }

    func seedComposerReconnectUITestFixture() {
        isShowingCachedSessions = true
        isConnected = false
        isStreaming = false
        isConnecting = false
        isBootstrapping = false
        isReconnecting = true
        canRetryReconnectManually = false
        reconnectStatusText = "Reconectando... intento 3/5"
        errorMessage = nil
    }

    func seedComposerRetryRequiredUITestFixture() {
        isShowingCachedSessions = true
        isConnected = false
        isStreaming = false
        isConnecting = false
        isBootstrapping = false
        isReconnecting = false
        canRetryReconnectManually = true
        reconnectStatusText = "Reconexión automática falló. Tocá para reintentar."
        errorMessage = nil
    }

    func resolveComposerReconnectUITestFixture() {
        isShowingCachedSessions = false
        isConnected = true
        isStreaming = true
        isConnecting = false
        isBootstrapping = false
        isReconnecting = false
        canRetryReconnectManually = false
        reconnectStatusText = nil
        errorMessage = nil
    }
#endif

    func hasAuthoritativeDetail(for windowId: String) -> Bool {
        sessionDetails[windowId] != nil
    }

    func fetchProjects() async throws -> [KycodeProjectDirectory] {
        guard !selectedProfileUsesAll else {
            throw NSError(
                domain: "KycodeMobile",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Elegí Puky o Mac personal antes de crear una sesión."]
            )
        }
        guard let credentials = sessionCreationCredentials else {
            throw NSError(domain: "KycodeMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta la conexión."])
        }
        let envelope = try await fetchProjects(credentials)
        return Self.projectsWithRootOption(items: envelope.items, rootPath: envelope.rootPath)
    }

    func fetchDefaultProject() async throws -> KycodeProjectDirectory {
        guard let project = (try await fetchProjects()).first else {
            throw NSError(
                domain: "KycodeMobile",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No encontré la carpeta Project en tu desktop."]
            )
        }
        return project
    }

    func cachedSessionHistory(
        matching query: KycodeSessionHistoryQuery
    ) -> (items: [KycodeSessionHistoryItem], cachedAt: Date, isFresh: Bool)? {
        guard let snapshot = KycodeSessionHistoryCache.load(profileId: selectedProfileId) else {
            return nil
        }
        return (
            KycodeSessionHistorySearch.cachedResults(snapshot.items, query: query),
            snapshot.cachedAt,
            snapshot.isFresh()
        )
    }

    func cachedSessionHistoryCorpus()
        -> (items: [KycodeSessionHistoryItem], cachedAt: Date, isFresh: Bool)?
    {
        guard let snapshot = KycodeSessionHistoryCache.load(profileId: selectedProfileId) else {
            return nil
        }
        return (snapshot.items, snapshot.cachedAt, snapshot.isFresh())
    }

    func recentSessionHistorySearches() -> [String] {
        KycodeSessionHistoryRecents.load(profileId: selectedProfileId)
    }

    func clearRecentSessionHistorySearches() {
        KycodeSessionHistoryRecents.clear(profileId: selectedProfileId)
    }

    func fetchSessionHistory(
        matching query: KycodeSessionHistoryQuery
    ) async throws -> KycodeSessionHistoryEnvelope {
        let envelope: KycodeSessionHistoryEnvelope
        if selectedProfileUsesAll {
            envelope = try await fetchCombinedSessionHistory(matching: query)
        } else {
            guard let credentials = activeCredentials ?? draftCredentials else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Falta la conexión. Mostrando la copia guardada."]
                )
            }
            envelope = try await fetchSessionHistory(
                credentials,
                query: query,
                profileId: selectedProfileId
            )
        }
        let historyProfileId = selectedProfileId
        await Task.detached(priority: .utility) {
            KycodeSessionHistoryCache.save(
                profileId: historyProfileId,
                incoming: envelope.items,
                total: envelope.total,
                libraryUpdatedAt: envelope.updatedAt
            )
        }.value
        if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KycodeSessionHistoryRecents.record(query.text, profileId: selectedProfileId)
        }
        return envelope
    }

    func resumeSessionHistoryItem(_ item: KycodeSessionHistoryItem) async throws -> String? {
        guard item.canResume else {
            throw NSError(
                domain: "KycodeMobile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Esta sesión no tiene datos suficientes para reanudarse."]
            )
        }
        if let windowId = item.windowId, sessions.contains(where: { $0.windowId == windowId }) {
            return windowId
        }
        let sourceProfileId = selectedProfileUsesAll ? item.sourceProfileId : nil
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedAttemptGeneration = sourceSnapshotAttemptGeneration
        let expectedSelectedProfileId = selectedProfileId
        let credentials: KycodeConnectionCredentials?
        if let sourceProfileId {
            credentials = allSourceCredentials[sourceProfileId]
        } else {
            credentials = activeCredentials ?? draftCredentials
        }
        guard let credentials else {
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: sourceProfileId == nil
                        ? "Conectá tu desktop para reabrir esta sesión."
                        : "La Mac de origen no está conectada. Reintentá cuando vuelva a estar disponible."
                ]
            )
        }
        let remoteHistoryId = item.sourceHistoryId ?? item.id
        let ack = try await postResumeSessionHistoryItem(credentials, id: remoteHistoryId)
        guard ownsAsyncSnapshotMutation(
            connectionGeneration: expectedConnectionGeneration,
            attemptGeneration: expectedAttemptGeneration,
            selectedProfileId: expectedSelectedProfileId,
            credentials: credentials,
            sourceProfileId: sourceProfileId
        ) else {
            return nil
        }
        let commandState = ack.state == "queued"
            ? KycodeDurableCommandState.accepted
            : KycodeDurableCommandState(rawValue: ack.state)
        try registerDurableCommandAcknowledgement(
            ok: ack.ok,
            commandId: ack.commandId,
            commandState: commandState,
            inserted: nil,
            durable: nil,
            queuedAt: ack.queuedAt,
            context: KycodeTrackedCommandContext(
                operation: .resumeHistory,
                windowId: ack.windowId.map { remoteWindowId in
                    sourceProfileId.map {
                        presentedWindowId(profileId: $0, remoteWindowId: remoteWindowId)
                    } ?? remoteWindowId
                },
                messageId: nil,
                sessionId: ack.sessionId
            ),
            requiresDurableContract: false
        )
        if let windowId = ack.windowId, !windowId.isEmpty {
            return sourceProfileId.map {
                presentedWindowId(profileId: $0, remoteWindowId: windowId)
            } ?? windowId
        }
        for attempt in 0..<Self.resumeSessionPollAttempts {
            guard ownsAsyncSnapshotMutation(
                connectionGeneration: expectedConnectionGeneration,
                attemptGeneration: expectedAttemptGeneration,
                selectedProfileId: expectedSelectedProfileId,
                credentials: credentials,
                sourceProfileId: sourceProfileId
            ) else {
                return nil
            }
            if attempt > 0 {
                try? await Task.sleep(for: Self.createSessionPollDelay)
            }
            do {
                let snapshot = try await fetchSessions(credentials, timeout: Self.sendRequestTimeout)
                guard ownsAsyncSnapshotMutation(
                    connectionGeneration: expectedConnectionGeneration,
                    attemptGeneration: expectedAttemptGeneration,
                    selectedProfileId: expectedSelectedProfileId,
                    credentials: credentials,
                    sourceProfileId: sourceProfileId
                ) else {
                    return nil
                }
                try validateSnapshotFreshness(snapshot, for: credentials)
                clearConnectionIssueState(cancelReconnectTask: false)
                if let sourceProfileId {
                    allSourceSnapshots[sourceProfileId] = snapshot
                    if let profile = profiles.first(where: { $0.id == sourceProfileId }) {
                        let current = sourceConnectionStates.first(where: { $0.id == sourceProfileId })
                        updateSourceState(
                            profile: profile,
                            isLoading: false,
                            isConnected: true,
                            sessionCount: snapshot.items.count,
                            connectionLabel: current?.connectionLabel,
                            errorMessage: nil,
                            snapshotPhase: .succeeded,
                            attemptGeneration: current?.attemptGeneration
                                ?? sourceSnapshotAttemptGeneration,
                            hasRetainedSnapshot: true
                        )
                    }
                    rebuildAllSessions()
                } else {
                    applySessions(snapshot)
                }
                isConnected = true
                if let resumed = snapshot.items.first(where: {
                    $0.sessionId == ack.sessionId &&
                        ($0.projectKey == item.projectKey || $0.projectPath == item.sessionPath)
                }) {
                    return sourceProfileId.map {
                        presentedWindowId(profileId: $0, remoteWindowId: resumed.windowId)
                    } ?? resumed.windowId
                }
            } catch {
                log(
                    "No pude confirmar la sesión reanudada \(ack.sessionId) " +
                    "en intento \(attempt + 1): \(describe(error))"
                )
            }
        }
        return nil
    }

    private func fetchCombinedSessionHistory(
        matching query: KycodeSessionHistoryQuery
    ) async throws -> KycodeSessionHistoryEnvelope {
        let requiredPrefixCount = max(1, query.offset + query.limit)
        let profileLookup = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let sources = [Self.pukyProfileId, Self.personalProfileId].compactMap {
            profileId -> (KycodeConnectionProfile, KycodeConnectionCredentials)? in
            guard let profile = profileLookup[profileId],
                  let credentials = allSourceCredentials[profileId] else { return nil }
            return (profile, credentials)
        }
        guard !sources.isEmpty else {
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Puky y Mac personal están sin conexión."]
            )
        }

        var results: [KycodeHistorySourceResult] = []
        await withTaskGroup(of: KycodeHistorySourceResult.self) { group in
            for (profile, credentials) in sources {
                group.addTask { @MainActor [weak self] in
                    guard let self else {
                        return KycodeHistorySourceResult(
                            profileId: profile.id,
                            profileName: profile.name,
                            envelope: nil,
                            errorMessage: "La conexión se cerró."
                        )
                    }
                    do {
                        let envelope = try await self.fetchSessionHistoryPrefix(
                            credentials,
                            query: query,
                            profileId: profile.id,
                            count: requiredPrefixCount
                        )
                        return KycodeHistorySourceResult(
                            profileId: profile.id,
                            profileName: profile.name,
                            envelope: envelope,
                            errorMessage: nil
                        )
                    } catch {
                        return KycodeHistorySourceResult(
                            profileId: profile.id,
                            profileName: profile.name,
                            envelope: nil,
                            errorMessage: self.describe(error)
                        )
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        let successful = results.compactMap { result -> KycodeCombinedSessionHistorySource? in
            guard let envelope = result.envelope else { return nil }
            return KycodeCombinedSessionHistorySource(
                profileId: result.profileId,
                profileName: result.profileName,
                envelope: envelope
            )
        }
        guard !successful.isEmpty else {
            let detail = results.compactMap(\.errorMessage).joined(separator: " · ")
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "No pude cargar el historial." : detail]
            )
        }
        return KycodeCombinedSessionHistoryPolicy.combine(successful, query: query)
    }

    private func fetchSessionHistoryPrefix(
        _ credentials: KycodeConnectionCredentials,
        query: KycodeSessionHistoryQuery,
        profileId: String,
        count: Int
    ) async throws -> KycodeSessionHistoryEnvelope {
        var items: [KycodeSessionHistoryItem] = []
        var latest: KycodeSessionHistoryEnvelope?
        let targetCount = max(1, count)

        while items.count < targetCount {
            var pageQuery = query
            pageQuery.offset = items.count
            pageQuery.limit = min(100, targetCount - items.count)
            let page = try await fetchSessionHistory(
                credentials,
                query: pageQuery,
                profileId: profileId
            )
            latest = page
            let existingIds = Set(items.map(\.id))
            let additions = page.items.filter { !existingIds.contains($0.id) }
            items.append(contentsOf: additions)
            if additions.isEmpty || !page.hasMore { break }
        }

        guard let latest else {
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "El historial no devolvió una respuesta."]
            )
        }
        return KycodeSessionHistoryEnvelope(
            ok: latest.ok,
            items: items,
            offset: 0,
            limit: targetCount,
            total: latest.total,
            hasMore: items.count < latest.total,
            updatedAt: latest.updatedAt,
            searchMs: latest.searchMs,
            indexBuildMs: latest.indexBuildMs,
            indexedSessions: latest.indexedSessions,
            indexedTerms: latest.indexedTerms
        )
    }

    private static func projectsWithRootOption(
        items: [KycodeProjectDirectory],
        rootPath: String?
    ) -> [KycodeProjectDirectory] {
        let normalizedRoot = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRoot = normalizedRoot?.isEmpty == false ? normalizedRoot : inferredProjectsRootPath(from: items)
        guard let resolvedRoot, !resolvedRoot.isEmpty else {
            return items
        }

        let rootItem = KycodeProjectDirectory(
            name: "~/projects",
            path: resolvedRoot,
            kind: "root"
        )
        let withoutDuplicateRoot = items.filter { $0.path != resolvedRoot }
        return [rootItem] + withoutDuplicateRoot
    }

    private static func inferredProjectsRootPath(from items: [KycodeProjectDirectory]) -> String? {
        for item in items {
            let components = URL(fileURLWithPath: item.path).pathComponents
            guard let projectsIndex = components.lastIndex(of: "projects"), projectsIndex > 0 else {
                continue
            }
            let rootComponents = Array(components.prefix(projectsIndex + 1))
            let rootPath = NSString.path(withComponents: rootComponents)
            if !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rootPath
            }
        }
        return nil
    }

    func createSession(projectPath: String, sessionName: String) async throws -> KycodeCreateSessionResult {
        guard !selectedProfileUsesAll else {
            throw NSError(
                domain: "KycodeMobile",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Elegí Puky o Mac personal antes de crear una sesión."]
            )
        }
        guard let credentials = sessionCreationCredentials else {
            throw NSError(domain: "KycodeMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta la conexión."])
        }

        let normalizedProjectPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectPath.isEmpty else {
            throw NSError(domain: "KycodeMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Elegí un proyecto."])
        }

        let normalizedSessionName = KycodeSessionNameRules.normalized(sessionName)
        if let validationMessage = KycodeSessionNameRules.validationMessage(for: sessionName) {
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: validationMessage]
            )
        }

        let requestedSessionId = "sess_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
        log("Create session requested project=\(normalizedProjectPath) requestedSessionId=\(requestedSessionId)")
        let ack = try await postCreateSession(
            credentials,
            projectPath: normalizedProjectPath,
            sessionId: requestedSessionId,
            sessionName: normalizedSessionName
        )
        try registerDurableCommandAcknowledgement(
            ok: ack.ok,
            commandId: ack.commandId,
            commandState: ack.commandState,
            inserted: ack.inserted,
            durable: ack.durable,
            queuedAt: ack.queuedAt,
            context: KycodeTrackedCommandContext(
                operation: .createSession,
                windowId: nil,
                messageId: nil,
                sessionId: ack.sessionId
            ),
            requiresDurableContract: targetsFerminCode(profileId: selectedProfileId)
        )
        log(
            "Create session ack project=\(ack.projectPath) ackSessionId=\(ack.sessionId) " +
            "commandId=\(ack.commandId)"
        )

        let createdAtMs = ack.queuedAt ?? (Date().timeIntervalSince1970 * 1000)
        upsertRecentCreatedSession(
            KycodeRecentCreatedSession(
                sessionId: ack.sessionId,
                windowId: nil,
                projectPath: ack.projectPath,
                projectName: ack.projectName,
                sessionName: normalizedSessionName,
                profileId: selectedProfileId,
                createdAt: Date(timeIntervalSince1970: createdAtMs / 1000),
                status: "creating"
            )
        )

        if createSessionForegroundConfirmationTimeout > 0,
           let summary = await waitForCreatedSession(
            sessionId: ack.sessionId,
            credentials: credentials,
            expectedSessionName: normalizedSessionName,
            confirmationTimeout: createSessionForegroundConfirmationTimeout
        ) {
            removeRecentCreatedSession(sessionId: ack.sessionId)
            log("Create session confirmed sessionId=\(summary.sessionId) windowId=\(summary.windowId)")
            return KycodeCreateSessionResult(
                sessionId: summary.sessionId,
                windowId: summary.windowId,
                projectName: summary.projectName ?? ack.projectName,
                status: summary.activityStatus
            )
        }

        markRecentCreatedSessionStatus(sessionId: ack.sessionId, status: "pending")
        log("Create session timed out waiting for sessionId=\(ack.sessionId)")
        scheduleCreatedSessionReconciliation(
            sessionId: ack.sessionId,
            credentials: credentials,
            expectedSessionName: normalizedSessionName
        )

        return KycodeCreateSessionResult(
            sessionId: ack.sessionId,
            windowId: nil,
            projectName: ack.projectName,
            status: "pending"
        )
    }

    func createSubagent(
        windowId: String,
        text: String,
        engine: KycodeAgentEngine? = nil
    ) async -> KycodeCreateSubagentResult? {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión original."
            return nil
        }
        guard !trimmed.isEmpty else {
            errorMessage = "El mensaje está vacío."
            return nil
        }
        guard engine != .claude || supportsClaudeSubagents(windowId: normalizedWindowId) else {
            errorMessage = "Fermín Code crea sub-agentes con Codex."
            return nil
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return nil
        }
        let credentials = target.credentials
        let remoteWindowId = target.remoteWindowId
        let routeProfileId = sessionRoutes[normalizedWindowId]?.profileId

        let requestedSessionId = "sess_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
        let inheritedEngine =
            sessionDetails[normalizedWindowId]?.agentEngine ??
            sessions.first(where: { $0.windowId == normalizedWindowId })?.agentEngine
        let expectedEngine = engine ?? inheritedEngine
        log(
            "Create sub-agent requested sourceWindow=\(normalizedWindowId) " +
            "requestedSessionId=\(requestedSessionId) engine=\(engine?.rawValue ?? "inherit") " +
            "expectedEngine=\(expectedEngine?.rawValue ?? "unknown") chars=\(trimmed.count)"
        )

        do {
            let ack = try await postCreateSubagent(
                credentials,
                windowId: remoteWindowId,
                message: trimmed,
                sessionId: requestedSessionId,
                engine: engine
            )
            try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .createSubagent,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: ack.sessionId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )
            log(
                "Create sub-agent ack sourceWindow=\(ack.sourceWindowId) ackSessionId=\(ack.sessionId) " +
                "commandId=\(ack.commandId)"
            )

            let resolvedProjectPath = ack.projectPath
                ?? sessionDetails[normalizedWindowId]?.projectPath
                ?? sessions.first(where: { $0.windowId == normalizedWindowId })?.projectPath
                ?? ""
            let createdAtMs = ack.queuedAt ?? (Date().timeIntervalSince1970 * 1000)
            upsertRecentCreatedSession(
                KycodeRecentCreatedSession(
                    sessionId: ack.sessionId,
                    windowId: nil,
                    projectPath: resolvedProjectPath,
                    projectName: ack.projectName,
                    profileId: routeProfileId ?? selectedProfileId,
                    createdAt: Date(timeIntervalSince1970: createdAtMs / 1000),
                    status: "creating sub-agent"
                )
            )

            if let summary = await waitForCreatedSession(
                sessionId: ack.sessionId,
                credentials: credentials,
                expectedEngine: expectedEngine,
                profileId: routeProfileId
            ) {
                removeRecentCreatedSession(sessionId: ack.sessionId)
                log("Create sub-agent confirmed sessionId=\(summary.sessionId) windowId=\(summary.windowId)")
                return KycodeCreateSubagentResult(
                    sessionId: summary.sessionId,
                    windowId: summary.windowId,
                    projectName: summary.projectName ?? ack.projectName,
                    status: summary.activityStatus,
                    engine: summary.engine ?? ack.engine
                )
            }

            removeRecentCreatedSession(sessionId: ack.sessionId)
            let timeoutMessage = "El relay aceptó el subagente, pero no confirmó el inicio de su ejecución."
            log("Create sub-agent timed out waiting for execution sessionId=\(ack.sessionId)")
            errorMessage = timeoutMessage
            return nil
        } catch {
            if await handleRecoverableConnectionFailure(error, source: "create_subagent", credentials: credentials) {
                return nil
            }
            let description = presentableConnectionError(error, for: credentials)
            log("Create sub-agent failed sourceWindow=\(normalizedWindowId): \(description)")
            errorMessage = description
            return nil
        }
    }

    @discardableResult
    func createVoiceDraft(
        windowId: String,
        fileURL: URL,
        duration: TimeInterval,
        routeIdentity: VoiceTranscriptionRouteIdentity? = nil
    ) -> VoiceDraft {
        let draftURL = durableVoiceDraftURL(for: fileURL)
        do {
            if draftURL.path != fileURL.path {
                if FileManager.default.fileExists(atPath: draftURL.path) {
                    try FileManager.default.removeItem(at: draftURL)
                }
                try FileManager.default.moveItem(at: fileURL, to: draftURL)
            }
        } catch {
            logTranscription("No pude mover el audio a storage durable: \(describe(error))", level: .error)
        }

        let storedURL = FileManager.default.fileExists(atPath: draftURL.path) ? draftURL : fileURL
        let draft = VoiceDraft(
            id: UUID().uuidString,
            windowId: windowId,
            filePath: storedURL.path,
            duration: duration,
            createdAt: Date(),
            transcriptStatus: .pending,
            transcriptText: nil,
            sendStatus: .idle,
            errorMessage: nil,
            isolationReport: nil,
            routeIdentity: routeIdentity
        )
        currentVoiceDraft = draft
        persistVoiceDraft(draft)
        logTranscription("Voice draft creado window=\(windowId) file=\(storedURL.lastPathComponent)")
        return draft
    }

    func persistVoiceDraft(_ draft: VoiceDraft) {
        guard let metadataURL = Self.voiceDraftMetadataURL() else {
            logTranscription("No pude persistir el voice draft: falta contenedor", level: .error)
            return
        }

        do {
            let data = try JSONEncoder().encode(draft)
            if let sidecarURL = Self.voiceDraftSidecarURL(for: draft.id) {
                try data.write(to: sidecarURL, options: .atomic)
            }
            try data.write(to: metadataURL, options: .atomic)
            currentVoiceDraft = draft
            logTranscription("Voice draft persistido id=\(draft.id)")
        } catch {
            logTranscription("No pude guardar el voice draft: \(describe(error))", level: .error)
        }
    }

    func loadVoiceDraft() -> VoiceDraft? {
        guard let metadataURL = Self.voiceDraftMetadataURL() else {
            return loadVoiceDraftFromSidecars()
        }
        guard let data = try? Data(contentsOf: metadataURL) else {
            return loadVoiceDraftFromSidecars()
        }

        do {
            var draft = try JSONDecoder().decode(VoiceDraft.self, from: data)
            guard draft.hasAudioFile else {
                draft.transcriptStatus = .failed
                draft.sendStatus = .failed
                draft.errorMessage = "Encontré el registro del audio, pero el archivo no está disponible. Conservé la metadata para diagnóstico y no voy a descartarla automáticamente."
                persistVoiceDraft(draft)
                logTranscription("Voice draft conserva metadata aunque falte el archivo", level: .error)
                return draft
            }

            if draft.sendStatus == .sending {
                draft.sendStatus = .failed
                draft.errorMessage = "La app se cerró antes de confirmar el envío."
                persistVoiceDraft(draft)
            } else {
                currentVoiceDraft = draft
            }

            logTranscription("Voice draft recuperado id=\(draft.id) status=\(draft.sendStatus.rawValue)")
            return draft
        } catch {
            logTranscription("No pude cargar el voice draft: \(describe(error))", level: .error)
            // Never erase corrupt metadata automatically. It may be the only
            // link to audio bytes still present in VoiceDrafts.
            return loadVoiceDraftFromSidecars()
        }
    }

    func deleteVoiceDraft(_ draft: VoiceDraft) {
        if FileManager.default.fileExists(atPath: draft.filePath) {
            try? FileManager.default.removeItem(at: draft.fileURL)
        }
        if let metadataURL = Self.voiceDraftMetadataURL(),
           currentVoiceDraft?.id == draft.id
            || ((try? Data(contentsOf: metadataURL))
                .flatMap { try? JSONDecoder().decode(VoiceDraft.self, from: $0) }?.id == draft.id) {
            try? FileManager.default.removeItem(at: metadataURL)
        }
        if let sidecarURL = Self.voiceDraftSidecarURL(for: draft.id) {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        if currentVoiceDraft?.id == draft.id {
            currentVoiceDraft = nil
        }
        if recoveredVoiceDraftIdAtLaunch == draft.id {
            recoveredVoiceDraftIdAtLaunch = nil
        }
        logTranscription("Voice draft eliminado id=\(draft.id)")
    }

    func updateVoiceDraftStatus(transcriptStatus: TranscriptStatus?, sendStatus: SendStatus?) {
        guard var draft = currentVoiceDraft else { return }
        if let transcriptStatus {
            draft.transcriptStatus = transcriptStatus
        }
        if let sendStatus {
            draft.sendStatus = sendStatus
        }
        persistVoiceDraft(draft)
    }

    private func voiceTranscriptionRouteIdentity(
        for windowId: String
    ) -> VoiceTranscriptionRouteIdentity? {
        guard let target = routedTarget(for: windowId) else { return nil }
        let routedProfileId = sessionRoutes[windowId]?.profileId ?? selectedProfileId
        let rawSessionId = sessionDetails[windowId]?.sessionId
            ?? sessions.first(where: { $0.windowId == windowId })?.sessionId
        let sessionId = rawSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty else { return nil }
        return VoiceTranscriptionRouteIdentity(
            selectedProfileId: selectedProfileId,
            routedProfileId: routedProfileId,
            presentedWindowId: windowId,
            remoteWindowId: target.remoteWindowId,
            baseURL: target.credentials.baseURL,
            sessionId: sessionId
        )
    }

    private func voiceTranscriptionOwner(for windowId: String) -> VoiceTranscriptionOwner? {
        guard let route = voiceTranscriptionRouteIdentity(for: windowId) else { return nil }
        return VoiceTranscriptionOwner(
            connectionGeneration: connectionStateGeneration,
            route: route,
            requiresDurableContract: targetsFerminCode(windowId: windowId)
        )
    }

    private func ownsVoiceTranscription(_ job: VoiceTranscriptionJob) -> Bool {
        VoiceTranscriptionOwnershipPolicy.owns(
            expected: job.owner,
            current: voiceTranscriptionOwner(for: job.windowId)
        )
    }

    func voiceDraftBelongsToCurrentTarget(_ draft: VoiceDraft, windowId: String) -> Bool {
        guard draft.windowId == windowId else { return false }
        return VoiceTranscriptionOwnershipPolicy.routeMatches(
            expected: draft.routeIdentity,
            current: voiceTranscriptionRouteIdentity(for: windowId)
        )
    }

    func voiceJobBelongsToCurrentTarget(
        _ job: VoiceTranscriptionJob,
        windowId: String
    ) -> Bool {
        guard job.windowId == windowId else { return false }
        return ownsVoiceTranscription(job)
    }

    /// Publishes the pending bubble synchronously. No file I/O or network work
    /// happens before this returns, so the recorder's Stop interaction can
    /// release the view in the same frame.
    @discardableResult
    func beginVoiceTranscription(windowId: String, duration: TimeInterval) -> VoiceTranscriptionJob {
        let job = VoiceTranscriptionJob.pending(
            windowId: windowId,
            duration: duration,
            owner: voiceTranscriptionOwner(for: windowId)
        )
        voiceTranscriptionJobs[job.id] = job
        applyOptimisticSend(
            windowId: windowId,
            message: "",
            attachments: [],
            messageId: job.messageId,
            status: job.phase.messageStatus,
            previewOverride: "Transcribiendo audio…"
        )
        logTranscription("Ack visual voice job=\(job.id) window=\(windowId)")
        return job
    }

    /// Moves the recorder output into durable storage and starts work owned by
    /// the connection store. The task therefore survives detail navigation.
    func attachRecordingAndStartVoiceTranscription(
        jobId: String,
        fileURL: URL,
        duration: TimeInterval
    ) {
        guard var job = voiceTranscriptionJobs[jobId] else {
            logTranscription(
                "Conservo audio sin job asociado file=\(fileURL.lastPathComponent) job=\(jobId)",
                level: .error
            )
            return
        }
        let draft = createVoiceDraft(
            windowId: job.windowId,
            fileURL: fileURL,
            duration: duration,
            routeIdentity: job.owner?.route
        )
        job.filePath = draft.filePath
        job.voiceDraftId = draft.id
        job.updatedAt = Date()
        job.phase = .transcribing
        voiceTranscriptionJobs[jobId] = job
        updateOptimisticVoiceMessage(job)
        startVoiceTranscriptionTask(jobId: jobId)
    }

    func failVoiceTranscriptionPreparation(jobId: String, message: String) {
        guard let job = voiceTranscriptionJobs[jobId] else { return }
        let failed = job.failing(with: message)
        voiceTranscriptionJobs[jobId] = failed
        if ownsVoiceTranscription(failed) {
            updateOptimisticVoiceMessage(failed)
        }
        if let draftId = job.voiceDraftId,
           var draft = currentVoiceDraft,
           draft.id == draftId {
            draft.transcriptStatus = .failed
            draft.errorMessage = message
            persistVoiceDraft(draft)
        }
    }

    func retryVoiceTranscription(messageId: String) {
        guard let current = voiceTranscriptionJobs.values.first(where: {
            $0.messageId == messageId && $0.phase == .failed
        }), let filePath = current.filePath,
              FileManager.default.fileExists(atPath: filePath) else {
            return
        }
        var retrying = current
        guard let currentOwner = voiceTranscriptionOwner(for: current.windowId),
              VoiceTranscriptionOwnershipPolicy.routeMatches(
                  expected: current.owner?.route,
                  current: currentOwner.route
              ) else {
            return
        }
        retrying.owner = currentOwner
        retrying.attemptId = UUID()
        retrying.phase = .transcribing
        retrying.transcriptText = ""
        retrying.errorMessage = nil
        retrying.updatedAt = Date()
        voiceTranscriptionJobs[current.id] = retrying
        updateOptimisticVoiceMessage(retrying)
        startVoiceTranscriptionTask(jobId: current.id)
    }

    private func startVoiceTranscriptionTask(jobId: String) {
        guard let attemptId = voiceTranscriptionJobs[jobId]?.attemptId else { return }
        voiceTranscriptionTasks[jobId]?.cancel()
        voiceTranscriptionTasks[jobId] = Task { [weak self] in
            await self?.runVoiceTranscriptionJob(jobId: jobId, attemptId: attemptId)
        }
    }

    private func runVoiceTranscriptionJob(jobId: String, attemptId: UUID) async {
        guard let initialJob = voiceTranscriptionJobs[jobId],
              initialJob.attemptId == attemptId,
              let filePath = initialJob.filePath else {
            failVoiceTranscriptionPreparation(
                jobId: jobId,
                message: "No encontré el audio para transcribir."
            )
            return
        }

        do {
            let service = try MistralTranscriptionService.configured()
            let mode = voiceIsolationMode
            let threshold = voiceIsolationThreshold
            let verifier = speakerVerificationService
            let report = try await VoiceTranscriptionTimeout.run(
                for: VoiceIsolationPolicy.transcriptionTimeout
            ) {
                let transcription = try await service.transcribeAudioFileDetailed(
                    filePath: filePath,
                    diarize: mode.usesSpeakerVerification
                )
                return await VoiceIsolationProcessor.apply(
                    transcription: transcription,
                    waveFileURL: URL(fileURLWithPath: filePath),
                    mode: mode,
                    threshold: threshold,
                    verifier: verifier
                )
            }
            let transcript = report.selectedText
            _ = await completeVoiceTranscription(
                jobId: jobId,
                attemptId: attemptId,
                transcript: transcript,
                isolationReport: report
            )
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            failVoiceTranscriptionJob(
                jobId: jobId,
                attemptId: attemptId,
                message: message
            )
        }
        if voiceTranscriptionJobs[jobId] == nil
            || voiceTranscriptionJobs[jobId]?.attemptId == attemptId {
            voiceTranscriptionTasks.removeValue(forKey: jobId)
        }
    }

    @discardableResult
    func completeVoiceTranscription(jobId: String, transcript: String) async -> Bool {
        guard let attemptId = voiceTranscriptionJobs[jobId]?.attemptId else { return false }
        return await completeVoiceTranscription(
            jobId: jobId,
            attemptId: attemptId,
            transcript: transcript,
            isolationReport: nil
        )
    }

    private func completeVoiceTranscription(
        jobId: String,
        attemptId: UUID,
        transcript: String,
        isolationReport: VoiceIsolationReport?
    ) async -> Bool {
        guard var job = voiceTranscriptionJobs[jobId],
              job.attemptId == attemptId else { return false }
        guard ownsVoiceTranscription(job) else {
            failVoiceTranscriptionJob(
                jobId: jobId,
                attemptId: attemptId,
                message: "La sesión cambió. Volvé a la Mac original para reintentar el audio."
            )
            return false
        }

        if let isolationReport {
            latestVoiceIsolationReport = isolationReport
        }
        job = job.replacingTranscript(with: transcript)
        voiceTranscriptionJobs[jobId] = job
        updateOptimisticVoiceMessage(job)
        if let draftId = job.voiceDraftId,
           var draft = currentVoiceDraft,
           draft.id == draftId {
            draft.transcriptStatus = .success
            draft.transcriptText = transcript
            draft.sendStatus = .sending
            draft.errorMessage = nil
            draft.isolationReport = isolationReport
            persistVoiceDraft(draft)
        }

        do {
            try await sendCompletedVoiceTranscription(job)
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            failVoiceTranscriptionJob(
                jobId: jobId,
                attemptId: attemptId,
                message: message
            )
            return false
        }
    }

    private func failVoiceTranscriptionJob(
        jobId: String,
        attemptId: UUID,
        message: String
    ) {
        guard let job = voiceTranscriptionJobs[jobId],
              job.attemptId == attemptId else { return }
        let failed = job.failing(with: message)
        voiceTranscriptionJobs[jobId] = failed
        if ownsVoiceTranscription(failed) {
            updateOptimisticVoiceMessage(failed)
        }
        if let draftId = job.voiceDraftId,
           var draft = currentVoiceDraft,
           draft.id == draftId {
            draft.transcriptStatus = .failed
            draft.sendStatus = .failed
            draft.errorMessage = message
            persistVoiceDraft(draft)
        }
        logTranscription("Voice job falló id=\(jobId): \(message)", level: .error)
    }

    private func sendCompletedVoiceTranscription(_ job: VoiceTranscriptionJob) async throws {
        guard let owner = job.owner,
              ownsVoiceTranscription(job) else {
            throw VoiceTranscriptionError.ownerChanged
        }
        try await commitGoalModeDraftIfNeeded(windowId: job.windowId)
        guard ownsVoiceTranscription(job),
              let target = routedTarget(for: job.windowId) else {
            throw VoiceTranscriptionError.ownerChanged
        }
        let ack = try await postMessage(
            target.credentials,
            windowId: target.remoteWindowId,
            message: job.transcriptText,
            clientMessageId: job.messageId,
            attachments: [],
            timeout: Self.sendRequestTimeout
        )
        guard let currentJob = voiceTranscriptionJobs[job.id],
              currentJob.attemptId == job.attemptId,
              ownsVoiceTranscription(currentJob) else {
            throw VoiceTranscriptionError.ownerChanged
        }
        try registerDurableCommandAcknowledgement(
            ok: ack.ok,
            commandId: ack.commandId,
            commandState: ack.commandState,
            inserted: ack.inserted,
            durable: ack.durable,
            queuedAt: ack.queuedAt,
            context: KycodeTrackedCommandContext(
                operation: .sendMessage,
                windowId: job.windowId,
                messageId: job.messageId,
                sessionId: owner.route.sessionId
            ),
            requiresDurableContract: owner.requiresDurableContract
        )
        updateOptimisticMessage(
            windowId: job.windowId,
            messageId: job.messageId,
            content: job.transcriptText,
            status: "sent"
        )
        scheduleMessageReconciliation(windowId: job.windowId)
        if let draftId = job.voiceDraftId,
           let draft = currentVoiceDraft,
           draft.id == draftId {
            deleteVoiceDraft(draft)
        }
        if voiceTranscriptionJobs[job.id]?.attemptId == job.attemptId {
            voiceTranscriptionJobs.removeValue(forKey: job.id)
        }
        logTranscription("Voice job enviado id=\(job.id) chars=\(job.transcriptText.count)")
    }

    private func updateOptimisticVoiceMessage(_ job: VoiceTranscriptionJob) {
        updateOptimisticMessage(
            windowId: job.windowId,
            messageId: job.messageId,
            content: job.transcriptText,
            status: job.phase.messageStatus
        )
    }

    func retryPromptImprover(windowId: String, messageId: String) async -> KycodeSendResult {
        let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageId.isEmpty else {
            return .failure("No encontré el mensaje que querés reintentar.")
        }
        guard let target = routedTarget(for: windowId) else {
            return .failure(
                selectedProfileUsesAll
                    ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                    : "Falta la conexión."
            )
        }
        let profileId = selectedProfileId
        let generation = connectionStateGeneration
        let baselineDetail = sessionDetails[windowId]
            ?? sessions.first(where: { $0.windowId == windowId })
        let baselineMessage = baselineDetail?.messages?.first(where: {
            $0.id == normalizedMessageId
        })
        let routedProfileId = sessionRoutes[windowId]?.profileId ?? selectedProfileId
        let attemptId = UUID()

        do {
            let result = try await postPromptTransformRetry(
                target.credentials,
                windowId: target.remoteWindowId,
                messageId: normalizedMessageId
            )
            guard result.ok else {
                return .failure("Desktop no pudo reintentar la mejora del prompt.")
            }
            guard connectionStateGeneration == generation,
                  selectedProfileId == profileId,
                  (sessionRoutes[windowId]?.profileId ?? selectedProfileId) == routedProfileId,
                  let currentTarget = routedTarget(for: windowId),
                  currentTarget.credentials == target.credentials,
                  currentTarget.remoteWindowId == target.remoteWindowId else {
                // The command may already be durable on the original target,
                // but a profile handoff owns no local observer for it.
                return .success
            }
            try registerDurableCommandAcknowledgement(
                ok: result.ok,
                commandId: result.commandId,
                commandState: result.commandState,
                inserted: result.inserted,
                durable: result.durable,
                queuedAt: result.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .retryPromptTransform,
                    windowId: windowId,
                    messageId: normalizedMessageId,
                    sessionId: sessionDetails[windowId]?.sessionId
                        ?? sessions.first(where: { $0.windowId == windowId })?.sessionId,
                    mutationId: attemptId
                ),
                requiresDurableContract: targetsFerminCode(windowId: windowId)
            )
            clearPromptTransformTimeout(
                windowId: windowId,
                messageId: normalizedMessageId
            )
            let intent = KycodePromptRetryIntent(
                attemptId: attemptId,
                windowId: windowId,
                profileId: routedProfileId,
                remoteWindowId: target.remoteWindowId,
                sessionId: baselineDetail?.sessionId,
                messageId: normalizedMessageId,
                generation: generation,
                baselineDetailUpdatedAt: baselineDetail?.updatedAt ?? 0,
                baselineTransformStatus: baselineMessage?.transformStatus,
                baselineTransformErrorReason: baselineMessage?.transformErrorReason,
                baselineTransformedPrompt: baselineMessage?.transformedPrompt,
                baselineImprovedPrompt: baselineMessage?.improvedPrompt,
                baselineSessionImprovedPrompt: baselineDetail?.improvedPrompt,
                expiresAt: messageReconciliationNow()
                    + Double(KycodeMessageReconciliationPolicy.retryDelayMilliseconds.reduce(0, +)) / 1_000,
                phase: .awaitingAttempt
            )
            pendingPromptRetryIntents[
                KycodePromptRetryIntentKey(
                    windowId: windowId,
                    messageId: normalizedMessageId
                )
            ] = intent
            await refreshDetail(windowId: windowId)
            reconcilePromptRetryIntents(windowId: windowId)
            scheduleMessageReconciliation(windowId: windowId)
            return .success
        } catch {
            let description = describe(error)
            if isRecoverableConnectionError(error) {
                return .failure("No se pudo reintentar. Revisá la conexión y probá de nuevo.")
            }
            return .failure(description)
        }
    }

    private func sendSessionId(windowId: String) -> String? {
        let rawSessionId = sessionDetails[windowId]?.sessionId
            ?? sessions.first(where: { $0.windowId == windowId })?.sessionId
        let normalizedSessionId = rawSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedSessionId.isEmpty ? nil : normalizedSessionId
    }

    private func ownsSendAttempt(_ context: KycodeSendAttemptContext) -> Bool {
        guard connectionStateGeneration == context.connectionGeneration,
              selectedProfileId == context.selectedProfileId,
              let target = routedTarget(for: context.presentedWindowId),
              target.credentials == context.credentials,
              target.remoteWindowId == context.remoteWindowId,
              (sessionRoutes[context.presentedWindowId]?.profileId ?? selectedProfileId)
                == context.routedProfileId else {
            return false
        }
        guard let expectedSessionId = context.sessionId else { return true }
        return sendSessionId(windowId: context.presentedWindowId) == expectedSessionId
    }

    func displayedGoalModeEnabled(windowId: String) -> Bool {
        goalModeDrafts[windowId] ?? committedGoalModeEnabled(windowId: windowId)
    }

    func hasGoalModeDraft(windowId: String) -> Bool {
        goalModeDrafts[windowId] != nil
    }

    func stageGoalMode(windowId: String, enabled: Bool) {
        if enabled == committedGoalModeEnabled(windowId: windowId) {
            goalModeDrafts.removeValue(forKey: windowId)
        } else {
            goalModeDrafts[windowId] = enabled
        }
        errorMessage = nil
    }

    private func committedGoalModeEnabled(windowId: String) -> Bool {
        sessionDetails[windowId]?.goalModeEnabled
            ?? sessions.first(where: { $0.windowId == windowId })?.goalModeEnabled
            ?? false
    }

    private func commitGoalModeDraftIfNeeded(windowId: String) async throws {
        guard let desiredGoalMode = goalModeDrafts[windowId] else { return }
        if committedGoalModeEnabled(windowId: windowId) != desiredGoalMode {
            let succeeded = await setGoalMode(windowId: windowId, enabled: desiredGoalMode)
            guard succeeded else {
                throw NSError(
                    domain: "KycodeMobile.GoalDraft",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: errorMessage
                            ?? "No se pudo preparar GOAL. El mensaje no fue enviado."
                    ]
                )
            }
        }
        goalModeDrafts.removeValue(forKey: windowId)
    }

    func sendMessage(
        windowId: String,
        text: String,
        attachments: [KycodeImageAttachmentDraft] = [],
        parentNotificationPrompt: String? = nil
    ) async -> KycodeSendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            return .failure("El mensaje está vacío.")
        }
        do {
            try KycodeImageAttachmentPolicy.validate(attachments)
        } catch {
            return .failure(error.localizedDescription)
        }
        do {
            try await commitGoalModeDraftIfNeeded(windowId: windowId)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard let target = routedTarget(for: windowId) else {
            return .failure(
                selectedProfileUsesAll
                    ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                    : "Falta la conexión."
            )
        }
        let credentials = target.credentials
        let remoteWindowId = target.remoteWindowId
        let clientMessageId = "mobile-user-\(UUID().uuidString.lowercased())"
        let routedProfileId = sessionRoutes[windowId]?.profileId ?? selectedProfileId
        let trackedVoiceDraftId = currentVoiceDraft.flatMap { draft in
            draft.transcriptStatus == .success
                && voiceDraftBelongsToCurrentTarget(draft, windowId: windowId)
                ? draft.id
                : nil
        }
        let sendContext = KycodeSendAttemptContext(
            sendId: clientMessageId,
            connectionGeneration: connectionStateGeneration,
            selectedProfileId: selectedProfileId,
            routedProfileId: routedProfileId,
            presentedWindowId: windowId,
            remoteWindowId: remoteWindowId,
            credentials: credentials,
            sessionId: sendSessionId(windowId: windowId),
            requiresDurableContract: targetsFerminCode(windowId: windowId),
            voiceDraftId: trackedVoiceDraftId
        )

        // Intencionalmente sigue el mismo patrón del switch de features:
        // un POST corto con ack rápido y luego consistencia eventual por snapshot/stream.
        // No disparo la máquina de reconnect desde acá porque eso fue lo que generó
        // los ciclos falsos de "processing -> reconnecting" en el flujo normal de envío.
        let startedAt = Date()
        let attachmentBytes = attachments.reduce(0) { $0 + $1.size }
        let attachmentTypes = Set(attachments.map(\.mimeType)).sorted().joined(separator: ",")
        log(
            "Envio iniciado window=\(windowId) chars=\(trimmed.count) "
                + "images=\(attachments.count) imageBytes=\(attachmentBytes) "
                + "imageTypes=\(attachmentTypes.isEmpty ? "none" : attachmentTypes)"
        )
        if let voiceDraftId = sendContext.voiceDraftId,
           var draft = currentVoiceDraft,
           draft.id == voiceDraftId {
            draft.sendStatus = .sending
            draft.errorMessage = nil
            persistVoiceDraft(draft)
        }
        let optimisticMessage = applyOptimisticSend(
            windowId: windowId,
            message: trimmed,
            attachments: attachments,
            messageId: clientMessageId
        )

        do {
            var uploadedAttachments: [KycodeMessageAttachmentPayload] = []
            uploadedAttachments.reserveCapacity(attachments.count)
            if !attachments.isEmpty {
                imageUploadProgress = KycodeImageUploadProgress(
                    sendId: clientMessageId,
                    windowId: windowId,
                    completed: 0,
                    total: attachments.count
                )
            }
            defer {
                if imageUploadProgress?.sendId == clientMessageId {
                    imageUploadProgress = nil
                }
            }
            for (index, attachment) in attachments.enumerated() {
                log(
                    "Imagen upload inicio window=\(windowId) index=\(index + 1)/\(attachments.count) "
                        + "bytes=\(attachment.size) mime=\(attachment.mimeType)"
                )
                let uploaded = try await postImageAttachment(
                    credentials,
                    windowId: remoteWindowId,
                    attachment: attachment
                )
                log(
                    "Imagen upload ack window=\(windowId) index=\(index + 1)/\(attachments.count) "
                        + "bytes=\(uploaded.bytes) mime=\(uploaded.mimeType)"
                )
                uploadedAttachments.append(
                    KycodeMessageAttachmentPayload(
                        path: uploaded.path,
                        name: attachment.name,
                        size: uploaded.bytes,
                        mimeType: uploaded.mimeType
                    )
                )
                if ownsSendAttempt(sendContext),
                   imageUploadProgress?.sendId == clientMessageId {
                    imageUploadProgress = KycodeImageUploadProgress(
                        sendId: clientMessageId,
                        windowId: windowId,
                        completed: index + 1,
                        total: attachments.count
                    )
                }
            }
            let ack = try await postMessage(
                credentials,
                windowId: remoteWindowId,
                message: trimmed,
                clientMessageId: clientMessageId,
                attachments: uploadedAttachments,
                timeout: Self.sendRequestTimeout,
                parentNotificationPrompt: parentNotificationPrompt
            )
            guard ownsSendAttempt(sendContext) else {
                log(
                    "Envio ack ignorado tras cambio de destino "
                        + "window=\(windowId) send=\(sendContext.sendId)"
                )
                return .ignoredAfterHandoff(sent: true)
            }
            try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .sendMessage,
                    windowId: windowId,
                    messageId: clientMessageId,
                    sessionId: sendContext.sessionId
                ),
                requiresDurableContract: sendContext.requiresDurableContract
            )
            let ackMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log("Envio ack window=\(windowId) ackMs=\(ackMs)")
            scheduleMessageReconciliation(windowId: windowId)
            errorMessage = nil
            if let voiceDraftId = sendContext.voiceDraftId,
               let draft = currentVoiceDraft,
               draft.id == voiceDraftId,
               voiceDraftBelongsToCurrentTarget(draft, windowId: windowId) {
                var sentDraft = draft
                sentDraft.sendStatus = .sent
                sentDraft.errorMessage = nil
                persistVoiceDraft(sentDraft)
                deleteVoiceDraft(sentDraft)
            }
            return .success
        } catch {
            guard ownsSendAttempt(sendContext) else {
                log(
                    "Envio fallo ignorado tras cambio de destino "
                        + "window=\(windowId) send=\(sendContext.sendId): \(describe(error))"
                )
                return .ignoredAfterHandoff(sent: false)
            }
            removeOptimisticSend(windowId: windowId, messageId: optimisticMessage.id)
            let description = describe(error)
            let presentableError = presentableSendError(error, attachmentCount: attachments.count)
            log(
                "Envio fallo window=\(windowId) images=\(attachments.count) "
                    + "imageBytes=\(attachmentBytes): \(description)"
            )
            if let voiceDraftId = sendContext.voiceDraftId,
               var draft = currentVoiceDraft,
               draft.id == voiceDraftId,
               voiceDraftBelongsToCurrentTarget(draft, windowId: windowId) {
                draft.sendStatus = .failed
                draft.errorMessage = "No se pudo enviar. Reintentá."
                persistVoiceDraft(draft)
            }

            if isRecoverableConnectionError(error) {
                return .failure("No se pudo enviar. Revisá la conexión y reintentá.")
            }
            return .failure(presentableError)
        }
    }

    func isPinningSession(_ windowId: String) -> Bool {
        pendingPinnedUpdates[windowId] != nil
    }

    @discardableResult
    func setSessionPinned(windowId: String, pinned: Bool) async -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] == "1" {
            applyPinnedState(pinned, windowId: windowId)
            return true
        }
#endif
        guard pendingPinnedUpdates[windowId] == nil,
              let session = sessions.first(where: { $0.windowId == windowId }),
              let target = routedTarget(for: windowId) else { return false }
        let mutation = KycodePendingPinnedUpdate(id: UUID(), pinned: pinned, previous: session.isPinned)
        pendingPinnedUpdates[windowId] = mutation
        applyPinnedState(pinned, windowId: windowId)
        do {
            let request = try makeRequest(
                credentials: target.credentials,
                path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(target.remoteWindowId))/pinned",
                method: "PUT",
                body: try JSONSerialization.data(withJSONObject: [
                    "pinned": pinned, "idempotencyKey": mutation.id.uuidString
                ]),
                timeout: Self.sendRequestTimeout
            )
            requestObserver?(request)
            let ack = try await perform(request, decode: KycodeWindowCommandEnvelope.self)
            guard pendingPinnedUpdates[windowId]?.id == mutation.id else { return false }
            try registerDurableCommandAcknowledgement(
                ok: ack.ok, commandId: ack.commandId, commandState: ack.commandState,
                inserted: ack.inserted, durable: ack.durable, queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .setPinned, windowId: windowId, messageId: nil,
                    sessionId: session.sessionId, mutationId: mutation.id
                ),
                requiresDurableContract: true
            )
            return true
        } catch {
            guard pendingPinnedUpdates[windowId]?.id == mutation.id else { return false }
            pendingPinnedUpdates.removeValue(forKey: windowId)
            applyPinnedState(mutation.previous, windowId: windowId)
            errorMessage = "No se pudo sincronizar el estado fijado de la sesión. \(describe(error))"
            return false
        }
    }

    private func applyPinnedState(_ pinned: Bool?, windowId: String) {
        if let index = sessions.firstIndex(where: { $0.windowId == windowId }) {
            sessions[index].isPinned = pinned
        }
        if sessionDetails[windowId] != nil {
            sessionDetails[windowId]?.isPinned = pinned
        }
    }

    func setSessionMinimized(windowId: String, minimized: Bool) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials

        let previousSession = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]

        // Keep the interaction immediate, but do not confuse the relay's
        // acceptance with completion by dropping this pending marker early.
        recordPendingMinimizedUpdate(windowId: normalizedWindowId, minimized: minimized)
        applyOptimisticMinimized(windowId: normalizedWindowId, minimized: minimized)

        do {
            let ack = try await postMinimized(
                credentials,
                windowId: target.remoteWindowId,
                minimized: minimized
            )
            try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .minimize,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: sessionDetails[normalizedWindowId]?.sessionId
                        ?? sessions.first(where: { $0.windowId == normalizedWindowId })?.sessionId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )
            errorMessage = nil
            applyOptimisticMinimized(windowId: normalizedWindowId, minimized: minimized)
            return true
        } catch {
            if pendingMinimizedUpdates[normalizedWindowId]?.minimized == minimized {
                pendingMinimizedUpdates.removeValue(forKey: normalizedWindowId)
                rollbackMinimizedUpdate(
                    windowId: normalizedWindowId,
                    previousSession: previousSession,
                    previousDetail: previousDetail
                )
            }
            if await handleRecoverableConnectionFailure(error, source: "set_minimized", credentials: credentials) {
                return false
            }
            let description = describe(error)
            log("Minimized update failed window=\(normalizedWindowId) minimized=\(minimized): \(description)")
            errorMessage = description
            return false
        }
    }

    func renameSession(windowId: String, newName: String) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials

        let normalizedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            errorMessage = "El nombre no puede estar vacío."
            return false
        }
        guard normalizedName.count <= Self.sessionNameMaxLength else {
            errorMessage = "El nombre puede tener hasta \(Self.sessionNameMaxLength) caracteres."
            return false
        }

        let previousSession = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]
        let currentName = (previousDetail ?? previousSession)?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentName == normalizedName {
            errorMessage = nil
            return true
        }

        recordPendingRenameUpdate(windowId: normalizedWindowId, name: normalizedName)
        applyOptimisticRename(windowId: normalizedWindowId, name: normalizedName)

        do {
            let ack = try await postRename(
                credentials,
                windowId: target.remoteWindowId,
                name: normalizedName
            )
            try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .rename,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: previousDetail?.sessionId ?? previousSession?.sessionId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )
            errorMessage = nil
            scheduleRenameReconciliation(windowId: normalizedWindowId)
            return true
        } catch {
            let isLatestRename = pendingRenameUpdates[normalizedWindowId]?.name == normalizedName
            if isLatestRename {
                pendingRenameUpdates.removeValue(forKey: normalizedWindowId)
                rollbackRename(windowId: normalizedWindowId, previousSession: previousSession, previousDetail: previousDetail)
            }
            if await handleRecoverableConnectionFailure(error, source: "rename_session", credentials: credentials) {
                return false
            }
            let description = describe(error)
            log("Rename failed window=\(normalizedWindowId): \(description)")
            errorMessage = description
            return false
        }
    }

    func fetchCollaborationProjects(windowId: String) async -> [KycodeCollaborationProject]? {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión."
            return nil
        }
        guard supportsCollaborationProjects(windowId: normalizedWindowId) else {
            errorMessage = "Los proyectos de colaboración no están disponibles en Fermín Code."
            return nil
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return nil
        }

        do {
            var credentials = [target.credentials]
            func addCredentials(_ candidate: KycodeConnectionCredentials?) {
                guard let candidate, !credentials.contains(candidate) else { return }
                credentials.append(candidate)
            }
            addCredentials(activeCredentials)
            for candidate in allSourceCredentials.values {
                addCredentials(candidate)
            }
            for profile in Self.primaryProfiles(from: profiles) {
                addCredentials(storedRemoteCredentials(for: profile))
            }

            let targetEnvelope = try await getCollaborationProjects(target.credentials)
            var orderedIds: [String] = []
            var projectsById: [String: KycodeCollaborationProject] = [:]
            func merge(_ project: KycodeCollaborationProject) {
                let id = project.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !name.isEmpty else { return }
                if let existing = projectsById[id] {
                    let combinedCount: Int?
                    if existing.activeSessionCount != nil || project.activeSessionCount != nil {
                        // The same Mac can be reachable through LAN and relay.
                        // Keep the strongest observation without double-counting
                        // one source merely because two transports answered.
                        combinedCount = max(existing.activeSessionCount ?? 0, project.activeSessionCount ?? 0)
                    } else {
                        combinedCount = nil
                    }
                    projectsById[id] = KycodeCollaborationProject(
                        id: id,
                        name: existing.name,
                        activeSessionCount: combinedCount
                    )
                } else {
                    orderedIds.append(id)
                    projectsById[id] = KycodeCollaborationProject(
                        id: id,
                        name: name,
                        activeSessionCount: project.activeSessionCount
                    )
                }
            }
            for project in targetEnvelope.items {
                merge(project)
            }
            for candidate in credentials where candidate != target.credentials {
                guard let envelope = try? await getCollaborationProjects(
                    candidate,
                    timeout: Self.bootstrapStoredRequestTimeout
                ) else { continue }
                for project in envelope.items {
                    merge(project)
                }
            }
            errorMessage = nil
            return orderedIds.compactMap { projectsById[$0] }
        } catch {
            if await handleRecoverableConnectionFailure(
                error,
                source: "collaboration_projects",
                credentials: target.credentials
            ) {
                return nil
            }
            let description = describe(error)
            log("Collaboration project list failed window=\(normalizedWindowId): \(description)")
            errorMessage = description
            return nil
        }
    }

    func assignCollaborationProject(
        windowId: String,
        project: KycodeCollaborationProject
    ) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión."
            return false
        }
        guard supportsCollaborationProjects(windowId: normalizedWindowId) else {
            errorMessage = "Los proyectos de colaboración no están disponibles en Fermín Code."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let normalizedProjectId = project.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectId.isEmpty, !normalizedProjectName.isEmpty else {
            errorMessage = "El proyecto no es válido."
            return false
        }
        let normalizedProject = KycodeCollaborationProject(
            id: normalizedProjectId,
            name: normalizedProjectName,
            activeSessionCount: project.activeSessionCount
        )
        let previousSession = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]
        if (previousDetail ?? previousSession)?.collaborationProjectId == normalizedProject.id {
            errorMessage = nil
            return true
        }

        recordPendingCollaborationProjectUpdate(
            windowId: normalizedWindowId,
            project: normalizedProject
        )
        applyOptimisticCollaborationProject(
            windowId: normalizedWindowId,
            project: normalizedProject
        )

        do {
            _ = try await postCollaborationProject(
                target.credentials,
                windowId: target.remoteWindowId,
                projectId: normalizedProject.id,
                projectName: normalizedProject.name
            )
            errorMessage = nil
            scheduleCollaborationProjectReconciliation(windowId: normalizedWindowId)
            return true
        } catch {
            pendingCollaborationProjectUpdates.removeValue(forKey: normalizedWindowId)
            rollbackCollaborationProject(
                windowId: normalizedWindowId,
                previousSession: previousSession,
                previousDetail: previousDetail
            )
            if await handleRecoverableConnectionFailure(
                error,
                source: "assign_collaboration_project",
                credentials: target.credentials
            ) {
                return false
            }
            let description = describe(error)
            log("Collaboration project assignment failed window=\(normalizedWindowId): \(description)")
            errorMessage = description
            return false
        }
    }

    func deleteSession(windowId: String) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "No encontré la sesión."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials

        let previousSession = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]
        guard previousSession != nil || previousDetail != nil else {
            errorMessage = "La sesión ya no está disponible."
            return false
        }
        let previousVisibleIndex = sessions.firstIndex(where: { $0.windowId == normalizedWindowId })
        let previousDisplayIndex = sessionDisplayOrder.firstIndex(of: normalizedWindowId)

        pendingDeletions[normalizedWindowId] = KycodePendingDeletion(
            expiresAt: Date().addingTimeInterval(Self.deletePendingTTL)
        )
        applyOptimisticDeletion(windowId: normalizedWindowId)

        do {
            let ack = try await postDelete(credentials, windowId: target.remoteWindowId)
            let tracksDurableCompletion = try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .archive,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: previousSession?.sessionId ?? previousDetail?.sessionId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )
            if !tracksDurableCompletion {
                finalizeDeletedSessionLocalArtifacts(
                    windowId: normalizedWindowId,
                    sessionId: previousSession?.sessionId ?? previousDetail?.sessionId
                )
            }
            errorMessage = nil
            scheduleDeleteReconciliation()
            return true
        } catch {
            pendingDeletions.removeValue(forKey: normalizedWindowId)
            rollbackDeletion(
                windowId: normalizedWindowId,
                previousSession: previousSession,
                previousDetail: previousDetail,
                visibleIndex: previousVisibleIndex,
                displayIndex: previousDisplayIndex
            )
            if await handleRecoverableConnectionFailure(error, source: "delete_session", credentials: credentials) {
                return false
            }
            let description = describe(error)
            log("Delete failed window=\(normalizedWindowId): \(description)")
            errorMessage = description
            return false
        }
    }

    func transcribeAudioFile(filePath: String) async -> String? {
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if currentVoiceDraft?.filePath == fileURL.path, var draft = currentVoiceDraft {
                draft.transcriptStatus = .failed
                draft.errorMessage = "No encontré el audio guardado."
                persistVoiceDraft(draft)
            }
            logTranscription("Archivo de audio inexistente: \(fileURL.path)", level: .error)
            return nil
        }

        let transcriptionService: MistralTranscriptionService
        do {
            transcriptionService = try MistralTranscriptionService.configured()
        } catch {
            if currentVoiceDraft?.filePath == fileURL.path, var draft = currentVoiceDraft {
                draft.transcriptStatus = .failed
                draft.errorMessage = "Falta MISTRAL_API_KEY para transcribir."
                persistVoiceDraft(draft)
            }
            logTranscription("No pude configurar Mistral Voxtral: \(describe(error))", level: .error)
            return nil
        }

        logTranscription("Inicio transcripcion Voxtral file=\(fileURL.lastPathComponent)")
        if currentVoiceDraft?.filePath == fileURL.path {
            updateVoiceDraftStatus(transcriptStatus: .pending, sendStatus: .idle)
        }

        do {
            let mode = voiceIsolationMode
            let transcription = try await transcriptionService.transcribeAudioFileDetailed(
                filePath: fileURL.path,
                diarize: mode.usesSpeakerVerification
            )
            let report = await VoiceIsolationProcessor.apply(
                transcription: transcription,
                waveFileURL: fileURL,
                mode: mode,
                threshold: voiceIsolationThreshold,
                verifier: speakerVerificationService
            )
            let transcript = report.selectedText
            latestVoiceIsolationReport = report

            if currentVoiceDraft?.filePath == fileURL.path, var draft = currentVoiceDraft {
                draft.transcriptStatus = .success
                draft.transcriptText = transcript
                draft.sendStatus = .idle
                draft.errorMessage = nil
                draft.isolationReport = report
                persistVoiceDraft(draft)
            }
            logTranscription("Transcripcion completa chars=\(transcript.count)")
            return transcript
        } catch {
            if currentVoiceDraft?.filePath == fileURL.path, var draft = currentVoiceDraft {
                draft.transcriptStatus = .failed
                draft.errorMessage = describe(error)
                persistVoiceDraft(draft)
            }
            logTranscription("Fallo la transcripcion Voxtral: \(describe(error))", level: .error)
            return nil
        }
    }

    func setVoiceIsolationMode(_ mode: VoiceIsolationMode) {
        guard voiceIsolationMode != mode else { return }
        voiceIsolationMode = mode
        VoiceIsolationPreferences.saveMode(mode)
    }

    func setVoiceIsolationThreshold(_ threshold: Float) {
        let normalized = VoiceIsolationPreferences.clampedThreshold(threshold)
        guard voiceIsolationThreshold != normalized else { return }
        voiceIsolationThreshold = normalized
        VoiceIsolationPreferences.saveThreshold(normalized)
    }

    var isVoiceProfileEngineConfigured: Bool {
        speakerVerificationService.isConfigured
    }

    func enrollVoiceProfile(
        from fileURL: URL,
        onProgress: @Sendable (Float) async -> Void = { _ in }
    ) async throws -> VoiceEnrollmentResult {
        let result = try await speakerVerificationService.enroll(
            waveFileURL: fileURL,
            onProgress: onProgress
        )
        hasEnrolledVoiceProfile = true
        return result
    }

    func deleteVoiceProfile() async {
        await speakerVerificationService.deleteProfile()
        hasEnrolledVoiceProfile = false
    }

    func setFeatures(
        windowId: String,
        promptImproverEnabled: Bool,
        explainerEnabled: Bool,
        codeContextEnabled: Bool? = nil
    ) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "La sesión no es válida."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials
        let routedProfileId = sessionRoutes[normalizedWindowId]?.profileId ?? selectedProfileId
        let generation = connectionStateGeneration
        var previousSummary = sessions.first(where: { $0.windowId == normalizedWindowId })
        var previousDetail = sessionDetails[normalizedWindowId]
        var sessionId = previousDetail?.sessionId ?? previousSummary?.sessionId
        if sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            await refreshDetail(windowId: normalizedWindowId)
            guard connectionStateGeneration == generation,
                  let currentTarget = routedTarget(for: normalizedWindowId),
                  currentTarget.credentials == credentials,
                  currentTarget.remoteWindowId == target.remoteWindowId,
                  (sessionRoutes[normalizedWindowId]?.profileId ?? selectedProfileId)
                    == routedProfileId else {
                // The tap belongs to the route that initiated the identity
                // load. Never retarget it to a same-named window after handoff.
                return false
            }
            previousSummary = sessions.first(where: { $0.windowId == normalizedWindowId })
            previousDetail = sessionDetails[normalizedWindowId]
            sessionId = previousDetail?.sessionId ?? previousSummary?.sessionId
        }
        guard let sessionId,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                errorMessage = "La sesión todavía se está identificando. Esperá un momento y reintentá."
            }
            return false
        }
        let mutationId = recordPendingFeatureUpdate(
            windowId: normalizedWindowId,
            profileId: routedProfileId,
            remoteWindowId: target.remoteWindowId,
            credentials: credentials,
            sessionId: sessionId,
            generation: generation,
            promptImproverEnabled: promptImproverEnabled,
            explainerEnabled: explainerEnabled,
            codeContextEnabled: codeContextEnabled,
            previousSummaryFeatures: previousSummary?.features,
            previousDetailFeatures: previousDetail?.features
        )
        applyFeaturesOptimistically(windowId: normalizedWindowId)
        errorMessage = nil

        do {
            let ack = try await postFeatures(
                credentials,
                windowId: target.remoteWindowId,
                promptImproverEnabled: promptImproverEnabled,
                explainerEnabled: explainerEnabled,
                codeContextEnabled: codeContextEnabled
            )
            guard isCurrentFeatureMutation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            ) else {
                // The command can already be accepted on its original target,
                // but a newer intent or profile handoff owns the local UI now.
                return true
            }
            try registerDurableCommandAcknowledgement(
                ok: ack.ok,
                commandId: ack.commandId,
                commandState: ack.commandState,
                inserted: ack.inserted,
                durable: ack.durable,
                queuedAt: ack.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .setFeatures,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: sessionId,
                    mutationId: mutationId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )
            guard isCurrentFeatureMutation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            ) else {
                return true
            }
            scheduleFeatureReconciliation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            )
            await featureReconciliationSleep(.milliseconds(350))
            guard isCurrentFeatureMutation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            ) else {
                return true
            }
            await refreshDetail(windowId: normalizedWindowId)
            await refreshSessionsNow()
            return true
        } catch {
            let ownsCurrentIntent = isCurrentFeatureMutation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            )
            if ownsCurrentIntent {
                rollbackPendingFeatureUpdate(
                    windowId: normalizedWindowId,
                    mutationId: mutationId
                )
            } else {
                return false
            }
            if await handleRecoverableConnectionFailure(error, source: "set_features", credentials: credentials) {
                return false
            }
            errorMessage = describe(error)
            return false
        }
    }

    func setGoalMode(windowId: String, enabled: Bool) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowId.isEmpty else {
            errorMessage = "La sesión no es válida."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials
        let previousSummary = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]
        let nextMode = enabled ? "goal" : "normal"
        let nextStartedAt = enabled ? Date().timeIntervalSince1970 * 1_000 : nil
        let mutationId = recordPendingGoalModeUpdate(
            windowId: normalizedWindowId,
            enabled: enabled,
            goalStartedAt: nextStartedAt
        )
        applyRunModeOptimistically(
            windowId: normalizedWindowId,
            runMode: nextMode,
            goalStartedAt: nextStartedAt
        )
        errorMessage = nil

        do {
            let acknowledgement = try await postGoalMode(
                credentials,
                windowId: target.remoteWindowId,
                enabled: enabled
            )
            guard acknowledgement.ok,
                  acknowledgement.windowId == target.remoteWindowId,
                  acknowledgement.runMode == nextMode else {
                throw NSError(
                    domain: "KycodeMobile.GoalMode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "El desktop rechazó el cambio de GOAL."]
                )
            }
            try registerDurableCommandAcknowledgement(
                ok: acknowledgement.ok,
                commandId: acknowledgement.commandId,
                commandState: acknowledgement.commandState,
                inserted: acknowledgement.inserted,
                durable: acknowledgement.durable,
                queuedAt: acknowledgement.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .setRunMode,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: previousDetail?.sessionId ?? previousSummary?.sessionId
                ),
                requiresDurableContract: targetsFerminCode(windowId: normalizedWindowId)
            )

            guard pendingGoalModeUpdates[normalizedWindowId]?.mutationId == mutationId else {
                return true
            }

            updatePendingGoalModeAcknowledgement(
                windowId: normalizedWindowId,
                mutationId: mutationId,
                goalStartedAt: acknowledgement.goalStartedAt
            )
            applyRunModeOptimistically(
                windowId: normalizedWindowId,
                runMode: acknowledgement.runMode,
                goalStartedAt: acknowledgement.goalStartedAt
            )
            scheduleGoalModeReconciliation(
                windowId: normalizedWindowId,
                mutationId: mutationId
            )
            return true
        } catch {
            let isLatestMutation = pendingGoalModeUpdates[normalizedWindowId]?.mutationId == mutationId
            guard isLatestMutation else {
                return false
            }
            pendingGoalModeUpdates.removeValue(forKey: normalizedWindowId)
            rollbackGoalMode(
                windowId: normalizedWindowId,
                previousSession: previousSummary,
                previousDetail: previousDetail
            )
            if await handleRecoverableConnectionFailure(error, source: "set_goal_mode", credentials: credentials) {
                return false
            }
            let description = describe(error)
            log("Goal Mode update failed window=\(normalizedWindowId) enabled=\(enabled): \(description)")
            errorMessage = description
            return false
        }
    }

    func modelCatalog(windowId: String) async throws -> [KycodeAvailableModel] {
        guard let target = routedTarget(for: windowId) else {
            throw NSError(
                domain: "KycodeMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: selectedProfileUsesAll
                    ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                    : "Falta la conexión."]
            )
        }
        let catalog = try await fetchModelCatalog(
            target.credentials,
            windowId: target.remoteWindowId
        ).data
        return KycodeRuntimeModelPolicy.supportedModels(from: catalog)
    }

    func setRuntimeModelSettings(
        windowId: String,
        model: String,
        reasoningEffort: String
    ) async -> Bool {
        let normalizedWindowId = windowId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEffort = reasoningEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedWindowId.isEmpty, !normalizedModel.isEmpty, !normalizedEffort.isEmpty else {
            errorMessage = "Modelo o razonamiento inválido."
            return false
        }
        guard KycodeRuntimeModelPolicy.isSupported(normalizedModel) else {
            errorMessage = "Fermín Code sólo admite modelos GPT."
            return false
        }
        guard let target = routedTarget(for: normalizedWindowId) else {
            errorMessage = selectedProfileUsesAll
                ? "La Mac de origen no está conectada. Revisá su estado y reintentá."
                : "Falta la conexión."
            return false
        }
        let credentials = target.credentials
        let requiresDurableContract = targetsFerminCode(windowId: normalizedWindowId)

        let previousSummary = sessions.first(where: { $0.windowId == normalizedWindowId })
        let previousDetail = sessionDetails[normalizedWindowId]
        let mutationId = recordPendingRuntimeSettingsUpdate(
            windowId: normalizedWindowId,
            remoteWindowId: target.remoteWindowId,
            profileId: sessionRoutes[normalizedWindowId]?.profileId ?? selectedProfileId,
            sessionId: previousDetail?.sessionId ?? previousSummary?.sessionId,
            model: normalizedModel,
            reasoningEffort: normalizedEffort,
            previousModel: previousDetail?.model ?? previousSummary?.model,
            previousReasoningEffort: previousDetail?.reasoningEffort ?? previousSummary?.reasoningEffort,
            persistsAcrossRelaunch: requiresDurableContract
        )
        applyRuntimeSettingsOptimistically(
            windowId: normalizedWindowId,
            model: normalizedModel,
            reasoningEffort: normalizedEffort
        )

        do {
            let ack = try await postRuntimeModelSettings(
                credentials,
                windowId: target.remoteWindowId,
                model: normalizedModel,
                reasoningEffort: normalizedEffort
            )
            bindPendingRuntimeSettingsCommand(
                mutationId: mutationId,
                commandId: ack.command?.commandId,
                requiresDurableContract: requiresDurableContract
            )
            try registerDurableCommandAcknowledgement(
                ok: ack.command?.ok ?? ack.ok,
                commandId: ack.command?.commandId,
                commandState: ack.command?.commandState,
                inserted: ack.command?.inserted,
                durable: ack.command?.durable,
                queuedAt: ack.command?.queuedAt,
                context: KycodeTrackedCommandContext(
                    operation: .setModel,
                    windowId: normalizedWindowId,
                    messageId: nil,
                    sessionId: previousDetail?.sessionId ?? previousSummary?.sessionId,
                    mutationId: mutationId
                ),
                requiresDurableContract: requiresDurableContract
            )
            let confirmedModel = ack.modelSettings.model ?? normalizedModel
            let confirmedEffort = ack.modelSettings.effort ?? normalizedEffort
            guard updatePendingRuntimeSettingsAcknowledgement(
                mutationId: mutationId,
                model: confirmedModel,
                reasoningEffort: confirmedEffort
            ) else {
                return true
            }
            applyRuntimeSettingsOptimistically(
                windowId: normalizedWindowId,
                model: confirmedModel,
                reasoningEffort: confirmedEffort
            )
            errorMessage = nil
            await refreshSessionsNow()
            await refreshDetail(windowId: normalizedWindowId)
            return true
        } catch {
            rollbackPendingRuntimeSettingsUpdate(
                windowId: normalizedWindowId,
                mutationId: mutationId,
                previousSummary: previousSummary,
                previousDetail: previousDetail
            )
            if await handleRecoverableConnectionFailure(
                error,
                source: "set_runtime_model",
                credentials: credentials
            ) {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private static func defaultProfiles() -> [KycodeConnectionProfile] {
        [
            KycodeConnectionProfile(
                id: Self.pukyProfileId,
                name: "Puky",
                mode: .ferminCode,
                remoteBaseURL: Self.pukyRemoteBaseURL,
                preferredBonjourServiceHint: nil,
                lastDiscoveredBonjourURL: nil,
                lastDiscoveredBonjourToken: nil,
                lastDiscoveredBonjourNetworkPrefix: nil
            ),
            KycodeConnectionProfile(
                id: Self.personalProfileId,
                name: "Mac personal",
                mode: .personal,
                remoteBaseURL: Self.remoteHubBaseURL,
                preferredBonjourServiceHint: nil,
                lastDiscoveredBonjourURL: nil,
                lastDiscoveredBonjourToken: nil,
                lastDiscoveredBonjourNetworkPrefix: nil
            ),
            KycodeConnectionProfile(
                id: Self.allProfileId,
                name: "Todo",
                mode: .all,
                remoteBaseURL: nil,
                preferredBonjourServiceHint: nil,
                lastDiscoveredBonjourURL: nil,
                lastDiscoveredBonjourToken: nil,
                lastDiscoveredBonjourNetworkPrefix: nil
            ),
        ]
    }

    private static func reconciledProfiles(from defaults: UserDefaults) -> [KycodeConnectionProfile] {
        let persisted = (Self.loadPersistedProfiles(from: defaults) ?? []).map(Self.migratedProfile)
        let persistedById = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })

        return Self.defaultProfiles().map { defaultProfile in
            let persistedProfile: KycodeConnectionProfile?
            if defaultProfile.id == Self.personalProfileId {
                persistedProfile = persistedById[Self.personalProfileId]
                    ?? persistedById[Self.legacyLocalProfileId]
            } else {
                persistedProfile = persistedById[defaultProfile.id]
            }
            let source = persistedProfile ?? defaultProfile
            var profile = KycodeConnectionProfile(
                id: defaultProfile.id,
                name: defaultProfile.name,
                mode: defaultProfile.mode,
                remoteBaseURL: source.remoteBaseURL,
                preferredBonjourServiceHint: source.preferredBonjourServiceHint,
                lastDiscoveredBonjourURL: source.lastDiscoveredBonjourURL,
                lastDiscoveredBonjourToken: source.lastDiscoveredBonjourToken,
                lastDiscoveredBonjourNetworkPrefix: source.lastDiscoveredBonjourNetworkPrefix
            )
            switch defaultProfile.mode {
            case .remoteFirst:
                if (profile.remoteBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.remoteBaseURL = defaultProfile.remoteBaseURL
                }
                if (profile.preferredBonjourServiceHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.preferredBonjourServiceHint = defaultProfile.preferredBonjourServiceHint
                }
            case .bonjourOnly:
                profile.remoteBaseURL = nil
                if (profile.preferredBonjourServiceHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.preferredBonjourServiceHint = defaultProfile.preferredBonjourServiceHint
                }
            case .remoteHub:
                profile.remoteBaseURL = Self.remoteHubBaseURL
                profile.preferredBonjourServiceHint = nil
                profile.lastDiscoveredBonjourURL = nil
                profile.lastDiscoveredBonjourToken = nil
                profile.lastDiscoveredBonjourNetworkPrefix = nil
            case .personal:
                profile.remoteBaseURL = Self.remoteHubBaseURL
                profile.preferredBonjourServiceHint = nil
                profile.lastDiscoveredBonjourURL = nil
                profile.lastDiscoveredBonjourToken = nil
                profile.lastDiscoveredBonjourNetworkPrefix = nil
            case .ferminCode:
                profile.remoteBaseURL = Self.pukyRemoteBaseURL
                profile.preferredBonjourServiceHint = nil
                profile.lastDiscoveredBonjourURL = nil
                profile.lastDiscoveredBonjourToken = nil
                profile.lastDiscoveredBonjourNetworkPrefix = nil
            case .all:
                profile.remoteBaseURL = nil
                profile.preferredBonjourServiceHint = nil
                profile.lastDiscoveredBonjourURL = nil
                profile.lastDiscoveredBonjourToken = nil
                profile.lastDiscoveredBonjourNetworkPrefix = nil
            }
            return profile
        }
    }

    private static func loadPersistedProfiles(from defaults: UserDefaults) -> [KycodeConnectionProfile]? {
        guard let data = defaults.data(forKey: Self.profilesDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([KycodeConnectionProfile].self, from: data)
    }

    private static func migrateLegacyConnectionCredentials(
        defaults: UserDefaults,
        storedBaseURL: String,
        legacySelectedProfileId: String?,
        genericToken: String
    ) {
        guard defaults.integer(forKey: credentialMigrationVersionDefaultsKey) < currentCredentialMigrationVersion else {
            return
        }

        let currentPersonal = KycodeKeychain.loadAuthToken(profileId: personalProfileId)
        let legacyRemoteHub = KycodeKeychain.loadAuthToken(profileId: legacyRemoteHubProfileId)
        let legacyLAN = KycodeKeychain.loadAuthToken(profileId: legacyLocalProfileId)
        if let personalToken = KycodeConnectionCredentialMigrationPolicy.personalRemoteToken(
            current: currentPersonal,
            legacyRemoteHub: legacyRemoteHub,
            legacyLAN: legacyLAN
        ) {
            KycodeKeychain.saveAuthToken(personalToken, profileId: personalProfileId)
        } else if currentPersonal != nil {
            KycodeKeychain.deleteAuthToken(profileId: personalProfileId)
        }

        let normalizedGenericToken = kycodeNormalizedAuthToken(genericToken)
        if !normalizedGenericToken.isEmpty,
           let destination = KycodeConnectionCredentialMigrationPolicy.genericTokenDestination(
               storedBaseURL: storedBaseURL,
               legacySelectedProfileId: legacySelectedProfileId
           ),
           KycodeKeychain.loadAuthToken(profileId: destination) == nil {
            KycodeKeychain.saveAuthToken(normalizedGenericToken, profileId: destination)
        }

        if let personalToken = KycodeKeychain.loadAuthToken(profileId: personalProfileId),
           !kycodeNormalizedAuthToken(personalToken).isEmpty {
            KycodeKeychain.saveAuthToken(personalToken, profileId: pukyProfileId)
        } else {
            KycodeKeychain.deleteAuthToken(profileId: pukyProfileId)
        }

        defaults.set(currentCredentialMigrationVersion, forKey: credentialMigrationVersionDefaultsKey)
    }

    private static func migratedProfile(_ profile: KycodeConnectionProfile) -> KycodeConnectionProfile {
        var migrated = profile
        switch profile.id {
        case Self.pukyProfileId:
            migrated.mode = .ferminCode
            migrated.remoteBaseURL = Self.pukyRemoteBaseURL
            migrated.preferredBonjourServiceHint = nil
            migrated.lastDiscoveredBonjourURL = nil
            migrated.lastDiscoveredBonjourToken = nil
            migrated.lastDiscoveredBonjourNetworkPrefix = nil
        case Self.legacyRemoteHubProfileId:
            migrated.remoteBaseURL = Self.remoteHubBaseURL
            migrated.preferredBonjourServiceHint = nil
            migrated.lastDiscoveredBonjourURL = nil
            migrated.lastDiscoveredBonjourToken = nil
            migrated.lastDiscoveredBonjourNetworkPrefix = nil
        default:
            break
        }
        return migrated
    }

    private static func normalizedRelayURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func resolveSelectedProfileId(_ candidate: String, profiles: [KycodeConnectionProfile]) -> String {
        let migratedCandidate: String
        switch candidate {
        case Self.legacyLocalProfileId, Self.legacyRemoteHubProfileId:
            migratedCandidate = Self.personalProfileId
        default:
            migratedCandidate = candidate
        }
        if profiles.contains(where: { $0.id == migratedCandidate }) {
            return migratedCandidate
        }
        return profiles.first?.id ?? Self.pukyProfileId
    }

    private var draftCredentials: KycodeConnectionCredentials? {
        normalizedCredentials(baseURL: baseURLInput, authToken: authTokenInput)
    }

    private var sessionCreationCredentials: KycodeConnectionCredentials? {
        activeCredentials ?? draftCredentials ?? selectedProfileStoredCredentials
    }

    private var selectedProfileStoredCredentials: KycodeConnectionCredentials? {
        guard let selectedProfile else {
            return nil
        }
        return storedRemoteCredentials(for: selectedProfile)
    }

    private var selectedProfileStoredBonjourCredentials: KycodeConnectionCredentials? {
        guard let selectedProfile else {
            return nil
        }
        return storedBonjourCredentials(for: selectedProfile)
    }

    private func storedRemoteCredentials(
        for profile: KycodeConnectionProfile
    ) -> KycodeConnectionCredentials? {
        guard profile.mode != .all,
              let remoteBaseURL = profile.remoteBaseURL,
              let authToken = KycodeKeychain.loadAuthToken(profileId: profile.id) else {
            return nil
        }
        return kycodeNormalizedCredentials(baseURL: remoteBaseURL, authToken: authToken)
    }

    private func storedBonjourCredentials(
        for profile: KycodeConnectionProfile
    ) -> KycodeConnectionCredentials? {
        guard profile.mode == .bonjourOnly || profile.mode == .remoteFirst,
              let baseURL = profile.lastDiscoveredBonjourURL else {
            return nil
        }

        let cachedNetworkPrefix = profile.lastDiscoveredBonjourNetworkPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentNetworkPrefix = kycodeCurrentLocalIPv4Prefix()
        if let cachedNetworkPrefix, !cachedNetworkPrefix.isEmpty, currentNetworkPrefix != cachedNetworkPrefix {
            log("Salteo cache Bonjour local: red actual \(currentNetworkPrefix ?? "sin-ip") != cache \(cachedNetworkPrefix)")
            return nil
        }

        let cachedToken = profile.lastDiscoveredBonjourToken
            ?? (profile.mode == .bonjourOnly ? KycodeKeychain.loadAuthToken(profileId: profile.id) : nil)
        guard let cachedToken else { return nil }
        return kycodeNormalizedCredentials(baseURL: baseURL, authToken: cachedToken)
    }

    private func normalizedCredentials(baseURL: String, authToken: String) -> KycodeConnectionCredentials? {
        kycodeNormalizedCredentials(baseURL: baseURL, authToken: authToken)
    }

    private func persistProfilesState(persistSelection: Bool = true) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesDefaultsKey)
        }
        if persistSelection {
            defaults.set(selectedProfileId, forKey: Self.selectedProfileIdDefaultsKey)
        }
    }

    private func syncInputsFromSelectedProfile() {
        baseURLInput = selectedProfile?.remoteBaseURL ?? ""
        authTokenInput = selectedProfileUsesAll
            ? ""
            : KycodeKeychain.loadAuthToken(profileId: selectedProfileId) ?? ""
    }

    private func updateSelectedProfile(_ mutate: (inout KycodeConnectionProfile) -> Void) {
        updateProfile(id: selectedProfileId, mutate)
    }

    private func updateProfile(
        id: String,
        _ mutate: (inout KycodeConnectionProfile) -> Void
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var profile = profiles[index]
        mutate(&profile)
        profiles[index] = profile
        persistProfilesState()
    }

    private func persistCredentials(_ credentials: KycodeConnectionCredentials, persistBaseURL: Bool) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.authTokenDefaultsKey)
        defaults.removeObject(forKey: Self.baseURLDefaultsKey)
        let shouldPersistProfileToken =
            selectedProfile?.mode != .personal || isCanonicalFerminRelayCredentials(credentials)
        if shouldPersistProfileToken {
            KycodeKeychain.saveAuthToken(credentials.authToken, profileId: selectedProfileId)
        }
        if persistBaseURL {
            updateSelectedProfile { profile in
                if profile.mode == .remoteFirst {
                    profile.remoteBaseURL = credentials.baseURL
                }
            }
        } else {
            persistProfilesState()
        }
        syncInputsFromSelectedProfile()
    }

    private func persistBonjourCache(_ result: KycodeBonjourProbeResult) {
        persistBonjourCache(result, profileId: selectedProfileId)
    }

    private func persistBonjourCache(
        _ result: KycodeBonjourProbeResult,
        profileId: String
    ) {
        let networkPrefix = kycodeCurrentLocalIPv4Prefix() ?? kycodeIPv4Prefix(fromBaseURL: result.credentials.baseURL)
        updateProfile(id: profileId) { profile in
            guard profile.mode == .bonjourOnly || profile.mode == .remoteFirst else { return }
            profile.lastDiscoveredBonjourURL = result.credentials.baseURL
            profile.lastDiscoveredBonjourToken = result.credentials.authToken
            profile.lastDiscoveredBonjourNetworkPrefix = networkPrefix
        }
        log("Cache Bonjour actualizado \(result.discovered.serviceName) -> \(result.credentials.baseURL) red=\(networkPrefix ?? "desconocida")")
    }

    private func shouldPreProbeBonjourCandidate(_ desktop: KycodeDiscoveredDesktop, for profile: KycodeConnectionProfile?) -> Bool {
        let filtered = filteredBonjourCandidates([desktop], for: profile)
        return !filtered.isEmpty
    }

    private func filteredBonjourCandidates(_ discovered: [KycodeDiscoveredDesktop], for profile: KycodeConnectionProfile?) -> [KycodeDiscoveredDesktop] {
        guard let hint = profile?.preferredBonjourServiceHint?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else {
            return discovered
        }
        return discovered.filter {
            $0.serviceName.range(of: hint, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func reconnectCandidates(
        for credentials: KycodeConnectionCredentials
    ) -> [(credentials: KycodeConnectionCredentials, profileId: String?)] {
        guard let profile = selectedProfile, profile.mode == .personal else {
            return [(credentials: credentials, profileId: nil)]
        }
        var candidates: [(credentials: KycodeConnectionCredentials, profileId: String?)] = []
        if isCanonicalFerminRelayCredentials(credentials) {
            candidates.append((credentials: credentials, profileId: nil))
        }
        if let remote = storedRemoteCredentials(for: profile),
           !candidates.contains(where: { $0.credentials == remote }) {
            candidates.append((credentials: remote, profileId: profile.id))
        }
        return candidates
    }

    private func isCanonicalFerminRelayCredentials(_ credentials: KycodeConnectionCredentials) -> Bool {
        credentials.baseURL.caseInsensitiveCompare(Self.remoteHubBaseURL) == .orderedSame
            || credentials.baseURL.caseInsensitiveCompare(Self.pukyRemoteBaseURL) == .orderedSame
    }

    private func shouldAttemptBonjour() -> Bool {
#if DEBUG
        let forceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"] == "1"
#else
        let forceInternet = false
#endif
        return KycodeConnectionTransportPolicy.shouldAttemptBonjour(
            localIPv4Prefix: kycodeCurrentLocalIPv4Prefix(),
            forceInternet: forceInternet
        )
    }

    private func connectionRequestTimeout(
        for credentials: KycodeConnectionCredentials,
        localTimeout: TimeInterval,
        internetTimeout: TimeInterval
    ) -> TimeInterval {
        KycodeConnectionTransportPolicy.requestTimeout(
            forBaseURL: credentials.baseURL,
            localTimeout: localTimeout,
            internetTimeout: internetTimeout
        )
    }

    private func presentedWindowId(profileId: String, remoteWindowId: String) -> String {
        KycodeCombinedSessionPolicy.presentedWindowId(
            profileId: profileId,
            remoteWindowId: remoteWindowId
        )
    }

    private func routedTarget(
        for presentedWindowId: String
    ) -> (credentials: KycodeConnectionCredentials, remoteWindowId: String)? {
        if let route = sessionRoutes[presentedWindowId] {
            return (route.credentials, route.remoteWindowId)
        }
        guard !selectedProfileUsesAll,
              let credentials = activeCredentials ?? draftCredentials else {
            return nil
        }
        return (credentials, presentedWindowId)
    }

    private func targetsFerminCode(windowId: String) -> Bool {
        let route = sessionRoutes[windowId]
        let profileId = route?.profileId ?? selectedProfileId
        let profile = profiles.first(where: { $0.id == profileId })
        let selectedCredentials = activeCredentials ?? draftCredentials
        return KycodeBackendCapabilityPolicy.isFerminCode(
            selectedProfileId: selectedProfileId,
            routedProfileId: route?.profileId,
            routedBaseURL: route?.credentials.baseURL,
            activeBaseURL: route == nil ? selectedCredentials?.baseURL : nil,
            offlineFallbackBaseURL: route == nil && selectedCredentials == nil
                ? profile?.remoteBaseURL
                : nil
        )
    }

    private func targetsFerminCode(profileId: String) -> Bool {
        let profile = profiles.first(where: { $0.id == profileId })
        let selectedCredentials = profileId == selectedProfileId
            ? activeCredentials ?? draftCredentials
            : nil
        return KycodeBackendCapabilityPolicy.isFerminCode(
            selectedProfileId: profileId,
            activeBaseURL: selectedCredentials?.baseURL,
            offlineFallbackBaseURL: selectedCredentials == nil ? profile?.remoteBaseURL : nil
        )
    }

    @discardableResult
    private func registerDurableCommandAcknowledgement(
        ok: Bool,
        commandId: String?,
        commandState: KycodeDurableCommandState?,
        inserted: Bool?,
        durable: Bool?,
        queuedAt: Double?,
        context: KycodeTrackedCommandContext,
        requiresDurableContract: Bool
    ) throws -> Bool {
        let normalizedCommandId = commandId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requiresDurableContract {
            guard !normalizedCommandId.isEmpty,
                  commandState != nil,
                  inserted != nil,
                  durable == true,
                  let queuedAt,
                  queuedAt > 0 else {
                throw NSError(
                    domain: "KycodeMobile.Command",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Fermín Code devolvió una confirmación durable incompleta. Reintentá la operación."
                    ]
                )
            }
        }

        if durable == false {
            throw NSError(
                domain: "KycodeMobile.Command",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Fermín Code no pudo guardar la operación de forma durable. Reintentá."
                ]
            )
        }

        guard ok else {
            if let commandState, commandState.isTerminal, !normalizedCommandId.isEmpty {
                _ = durableCommandTracker.register(
                    commandId: normalizedCommandId,
                    state: commandState,
                    context: context
                )
            }
            let message = KycodeCommandFailurePresentation.message(
                operation: context.operation,
                state: commandState ?? .failed,
                serverError: nil
            )
            throw NSError(
                domain: "KycodeMobile.Command",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard let commandState else {
            return false
        }
        guard !normalizedCommandId.isEmpty else {
            throw NSError(
                domain: "KycodeMobile.Command",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "El desktop no informó el identificador de la operación. Reintentá."
                ]
            )
        }

        let outcome = durableCommandTracker.register(
            commandId: normalizedCommandId,
            state: commandState,
            context: context
        )
        if case let .failed(_, state, serverError) = outcome {
            applyDurableCommandTransition(outcome)
            let message = KycodeCommandFailurePresentation.message(
                operation: context.operation,
                state: state,
                serverError: serverError
            )
            throw NSError(
                domain: "KycodeMobile.Command",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        applyDurableCommandTransition(outcome)
        return true
    }

    private func applyDurableCommandTransition(_ outcome: KycodeCommandTransitionOutcome) {
        switch outcome {
        case .ignored, .pending:
            return

        case let .completed(context):
            if let context, context.operation == .setPinned, let windowId = context.windowId,
               pendingPinnedUpdates[windowId]?.id == context.mutationId {
                pendingPinnedUpdates.removeValue(forKey: windowId)
            }
            if let context, context.operation == .archive, let windowId = context.windowId {
                finalizeDeletedSessionLocalArtifacts(
                    windowId: windowId,
                    sessionId: context.sessionId
                )
            }
            if let context, context.operation == .setModel, let windowId = context.windowId {
                completePendingRuntimeSettingsUpdate(
                    windowId: windowId,
                    mutationId: context.mutationId
                )
            }
            scheduleMetadataRefresh(windowId: context?.windowId)

        case let .failed(context, state, serverError):
            if let context {
                clearPendingStateAfterCommandFailure(context)
            }
            let message = KycodeCommandFailurePresentation.message(
                operation: context?.operation,
                state: state,
                serverError: serverError
            )
            errorMessage = message
            log("Command terminal failure state=\(state.rawValue): \(message)")
            scheduleMetadataRefresh(windowId: context?.windowId)
        }
    }

    func applyDurableCommandStateChanged(_ event: KycodeCommandStateChangedEvent) {
        applyDurableCommandTransition(durableCommandTracker.apply(event))
    }

    private func clearPendingStateAfterCommandFailure(_ context: KycodeTrackedCommandContext) {
        if let sessionId = context.sessionId,
           context.operation == .createSession || context.operation == .createSubagent {
            markRecentCreatedSessionStatus(sessionId: sessionId, status: "failed")
        }
        guard let windowId = context.windowId else { return }
        switch context.operation {
        case .sendMessage:
            if let messageId = context.messageId,
               let pending = pendingOptimisticMessages[windowId]?
                .first(where: { $0.message.id == messageId })?.message {
                updateOptimisticMessage(
                    windowId: windowId,
                    messageId: messageId,
                    content: pending.content,
                    status: "failed"
                )
                var remaining = pendingOptimisticMessages[windowId] ?? []
                remaining.removeAll { $0.message.id == messageId }
                if remaining.isEmpty {
                    pendingOptimisticMessages.removeValue(forKey: windowId)
                } else {
                    pendingOptimisticMessages[windowId] = remaining
                }
            }
        case .minimize:
            pendingMinimizedUpdates.removeValue(forKey: windowId)
        case .setPinned:
            if let pending = pendingPinnedUpdates[windowId], pending.id == context.mutationId {
                pendingPinnedUpdates.removeValue(forKey: windowId)
                applyPinnedState(pending.previous, windowId: windowId)
            }
        case .rename:
            pendingRenameUpdates.removeValue(forKey: windowId)
        case .archive:
            pendingDeletions.removeValue(forKey: windowId)
        case .setRunMode:
            pendingGoalModeUpdates.removeValue(forKey: windowId)
        case .setFeatures:
            rollbackPendingFeatureUpdate(
                windowId: windowId,
                mutationId: context.mutationId
            )
        case .setModel:
            rollbackPendingRuntimeSettingsUpdate(
                windowId: windowId,
                mutationId: context.mutationId
            )
        case .retryPromptTransform:
            removePromptRetryIntent(
                windowId: windowId,
                messageId: context.messageId,
                attemptId: context.mutationId
            )
        case .createSession, .createSubagent, .resumeHistory:
            break
        }
    }

    private func scheduleMetadataRefresh(windowId: String? = nil) {
        if let windowId = windowId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowId.isEmpty {
            pendingMetadataRefreshWindowIds.insert(windowId)
        }
        guard metadataRefreshTask == nil else { return }
        metadataRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.flushMetadataRefresh()
        }
    }

    private func flushMetadataRefresh() async {
        let windowIds = pendingMetadataRefreshWindowIds
        pendingMetadataRefreshWindowIds.removeAll(keepingCapacity: true)
        await refreshSessionsNow()
        for windowId in windowIds where
            sessions.contains(where: { $0.windowId == windowId }) || sessionDetails[windowId] != nil {
            await refreshDetail(windowId: windowId)
        }
        metadataRefreshTask = nil
        if !pendingMetadataRefreshWindowIds.isEmpty {
            scheduleMetadataRefresh()
        }
    }

    private func updateSourceState(
        profile: KycodeConnectionProfile,
        isLoading: Bool,
        isConnected: Bool,
        sessionCount: Int,
        connectionLabel: String?,
        errorMessage: String?,
        snapshotPhase: KycodeSourceSnapshotPhase? = nil,
        attemptGeneration: UInt64? = nil,
        hasRetainedSnapshot: Bool? = nil
    ) {
        let current = sourceConnectionStates.first(where: { $0.id == profile.id })
        let next = KycodeSourceConnectionState(
            id: profile.id,
            name: profile.name,
            isLoading: isLoading,
            isConnected: isConnected,
            sessionCount: sessionCount,
            connectionLabel: connectionLabel,
            errorMessage: errorMessage,
            snapshotPhase: snapshotPhase ?? current?.snapshotPhase ?? .idle,
            attemptGeneration: attemptGeneration ?? current?.attemptGeneration ?? 0,
            hasRetainedSnapshot: hasRetainedSnapshot
                ?? current?.hasRetainedSnapshot
                ?? false
        )
        if let index = sourceConnectionStates.firstIndex(where: { $0.id == profile.id }) {
            sourceConnectionStates[index] = next
        } else {
            sourceConnectionStates.append(next)
        }
        sourceConnectionStates.sort { left, right in
            let order = [Self.pukyProfileId, Self.personalProfileId]
            return (order.firstIndex(of: left.id) ?? .max) < (order.firstIndex(of: right.id) ?? .max)
        }
    }

    private func beginSourceSnapshotAttempt(
        for profiles: [KycodeConnectionProfile]
    ) -> UInt64 {
        sourceSnapshotAttemptGeneration &+= 1
        let attemptGeneration = sourceSnapshotAttemptGeneration
        for profile in profiles {
            markSourceLoading(profile, attemptGeneration: attemptGeneration)
        }
        return attemptGeneration
    }

    private func markSourceLoading(
        _ profile: KycodeConnectionProfile,
        attemptGeneration: UInt64
    ) {
        let current = sourceConnectionStates.first(where: { $0.id == profile.id })
        updateSourceState(
            profile: profile,
            isLoading: true,
            isConnected: current?.isConnected ?? false,
            sessionCount: current?.sessionCount ?? allSourceSnapshots[profile.id]?.items.count ?? 0,
            connectionLabel: current?.connectionLabel,
            errorMessage: nil,
            snapshotPhase: .loading,
            attemptGeneration: attemptGeneration,
            hasRetainedSnapshot: current?.hasRetainedSnapshot
                ?? (allSourceSnapshots[profile.id] != nil)
        )
    }

    private func publishSourceResult(
        _ result: KycodeAllSourceResult,
        attemptGeneration: UInt64
    ) {
        if let snapshot = result.snapshot, result.credentials != nil {
            updateSourceState(
                profile: result.profile,
                isLoading: false,
                isConnected: true,
                sessionCount: snapshot.items.count,
                connectionLabel: result.connectionLabel,
                errorMessage: nil,
                snapshotPhase: .succeeded,
                attemptGeneration: attemptGeneration,
                hasRetainedSnapshot: true
            )
        } else {
            updateSourceState(
                profile: result.profile,
                isLoading: false,
                isConnected: false,
                sessionCount: allSourceSnapshots[result.profile.id]?.items.count ?? 0,
                connectionLabel: nil,
                errorMessage: result.errorMessage,
                snapshotPhase: .failed,
                attemptGeneration: attemptGeneration,
                hasRetainedSnapshot: allSourceSnapshots[result.profile.id] != nil
            )
        }
    }

    private func resolveAndApplyAllSources(
        _ primaryProfiles: [KycodeConnectionProfile],
        attemptGeneration: UInt64
    ) async -> Bool {
        let connectionGeneration = connectionStateGeneration
        var resultsByProfileId: [String: KycodeAllSourceResult] = [:]
        await withTaskGroup(of: KycodeAllSourceResult?.self) { group in
            for profile in primaryProfiles {
                let preferredCredentials = allSourceCredentials[profile.id]
                group.addTask { @MainActor [weak self] in
                    guard let self else { return nil }
                    return await self.resolveSourceSnapshot(
                        profile: profile,
                        preferredCredentials: preferredCredentials
                    )
                }
            }

            for await result in group {
                guard selectedProfileUsesAll,
                      connectionStateGeneration == connectionGeneration,
                      sourceSnapshotAttemptGeneration == attemptGeneration else {
                    group.cancelAll()
                    return
                }
                if let result {
                    resultsByProfileId[result.profile.id] = result
                    publishSourceResult(
                        result,
                        attemptGeneration: attemptGeneration
                    )
                }
            }
        }
        guard selectedProfileUsesAll,
              connectionStateGeneration == connectionGeneration,
              sourceSnapshotAttemptGeneration == attemptGeneration,
              primaryProfiles.allSatisfy({ resultsByProfileId[$0.id] != nil }) else {
            return false
        }

        let requiredProfileIds = primaryProfiles.map(\.id)
        let shouldCommit = KycodeAllSourceCommitPolicy.shouldCommit(
            requiredProfileIds: requiredProfileIds,
            sourceStates: sourceConnectionStates,
            attemptGeneration: attemptGeneration
        )
        for profile in primaryProfiles {
            guard let result = resultsByProfileId[profile.id] else { continue }
            if let credentials = result.credentials, let snapshot = result.snapshot {
                allSourceCredentials[profile.id] = credentials
                rememberWarmTargetConnection(
                    profileId: profile.id,
                    credentials: credentials,
                    snapshot: snapshot,
                    sourceLabel: result.connectionLabel ?? profile.name
                )
                if let bonjourResult = result.bonjourResult {
                    persistBonjourCache(bonjourResult, profileId: profile.id)
                }
                if shouldCommit {
                    allSourceSnapshots[profile.id] = snapshot
                }
            } else {
                allSourceCredentials.removeValue(forKey: profile.id)
            }
        }
        rebuildAllSessions(commitSnapshot: shouldCommit)
        return sourceConnectionStates.contains(where: \.isConnected)
    }

    private func resolveSourceSnapshot(
        profile: KycodeConnectionProfile,
        preferredCredentials: KycodeConnectionCredentials? = nil
    ) async -> KycodeAllSourceResult {
        var attempted = Set<KycodeConnectionCredentials>()
        var lastError: Error?

        func attempt(
            _ credentials: KycodeConnectionCredentials?,
            label: String
        ) async -> KycodeAllSourceResult? {
            guard let credentials, attempted.insert(credentials).inserted else { return nil }
            do {
                let snapshot = try await fetchSessions(
                    credentials,
                    timeout: connectionRequestTimeout(
                        for: credentials,
                        localTimeout: Self.reconnectRequestTimeout,
                        internetTimeout: KycodeConnectionTransportPolicy.internetBootstrapTimeoutSeconds
                    )
                )
                try validateSnapshotFreshness(snapshot, for: credentials)
                return KycodeAllSourceResult(
                    profile: profile,
                    credentials: credentials,
                    snapshot: snapshot,
                    connectionLabel: label,
                    bonjourResult: nil,
                    errorMessage: nil
                )
            } catch {
                lastError = error
                return nil
            }
        }

        let bootstrapOrder = KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
            profileMode: profile.mode,
            canUseBonjour: shouldAttemptBonjour()
        )
        for bootstrapAttempt in bootstrapOrder {
            switch bootstrapAttempt {
            case .preferred:
                if let resolved = await attempt(
                    preferredCredentials,
                    label: "\(profile.name) · Conexión activa"
                ) {
                    return resolved
                }
            case .remote:
                if let resolved = await attempt(
                    storedRemoteCredentials(for: profile),
                    label: "\(profile.name) · Internet"
                ) {
                    return resolved
                }
            case .cachedBonjour:
                if let resolved = await attempt(
                    storedBonjourCredentials(for: profile),
                    label: "\(profile.name) · Red local"
                ) {
                    return resolved
                }
            case .bonjourDiscovery:
                let discovery = KycodeBonjourDiscovery()
                let discovered = filteredBonjourCandidates(
                    await discovery.discoverCandidates(timeout: Self.bootstrapDiscoveryTimeout),
                    for: profile
                )
                if let winner = await probeBonjourCandidates(discovered) {
                    return KycodeAllSourceResult(
                        profile: profile,
                        credentials: winner.credentials,
                        snapshot: winner.snapshot,
                        connectionLabel: "\(profile.name) · Red local",
                        bonjourResult: winner,
                        errorMessage: nil
                    )
                }
            }
        }

        let fallbackMessage: String
        if profile.mode == .personal || profile.mode == .ferminCode {
            fallbackMessage = KycodeKeychain.loadAuthToken(profileId: profile.id) == nil
                ? "Falta configurar el token remoto de Fermín Code para \(profile.name)."
                : "No pude alcanzar \(profile.name) por el relay remoto de Fermín Code."
        } else {
            fallbackMessage = "No pude conectar con \(profile.name)."
        }
        return KycodeAllSourceResult(
            profile: profile,
            credentials: nil,
            snapshot: nil,
            connectionLabel: nil,
            bonjourResult: nil,
            errorMessage: lastError.map(describe) ?? fallbackMessage
        )
    }

    private func rememberWarmTargetConnection(
        profileId: String,
        credentials: KycodeConnectionCredentials,
        snapshot: KycodeSessionsEnvelope,
        sourceLabel: String
    ) {
        guard profileId == Self.pukyProfileId || profileId == Self.personalProfileId else {
            return
        }
        warmTargetConnections[profileId] = KycodeWarmTargetConnection(
            credentials: credentials,
            snapshot: snapshot,
            sourceLabel: sourceLabel
        )
    }

    /// Restores the last verified target synchronously. Network freshness is
    /// then maintained by the ordinary stream/refresh loops started below;
    /// the user never waits for Bonjour or the remote hub just to see a Mac
    /// that was already connected during this app session.
    private func activateWarmTargetConnectionIfAvailable() -> Bool {
        if selectedProfileUsesAll {
            let primaryProfiles = Self.primaryProfiles(from: profiles)
            guard !primaryProfiles.isEmpty,
                  primaryProfiles.allSatisfy({ warmTargetConnections[$0.id] != nil }) else {
                // The aggregate view promises both Macs. A partial warm cache
                // must fall through to the ordinary bootstrap so the missing
                // source is discovered instead of silently disappearing.
                return false
            }
            let attemptGeneration = beginSourceSnapshotAttempt(for: primaryProfiles)
            for profile in primaryProfiles {
                guard let warm = warmTargetConnections[profile.id] else { continue }
                allSourceCredentials[profile.id] = warm.credentials
                allSourceSnapshots[profile.id] = warm.snapshot
                updateSourceState(
                    profile: profile,
                    isLoading: false,
                    isConnected: true,
                    sessionCount: warm.snapshot.items.count,
                    connectionLabel: warm.sourceLabel,
                    errorMessage: nil,
                    snapshotPhase: .succeeded,
                    attemptGeneration: attemptGeneration,
                    hasRetainedSnapshot: true
                )
            }
            clearConnectionIssueState(cancelReconnectTask: false)
            rebuildAllSessions()
            startAllRefreshLoop()
            errorMessage = nil
            log("Handoff caliente activado para Todo")
            return true
        }

        guard let warm = warmTargetConnections[selectedProfileId] else {
            return false
        }
        applySuccessfulConnection(
            warm.credentials,
            snapshot: warm.snapshot,
            persist: false,
            persistBaseURL: false,
            sourceLabel: "\(warm.sourceLabel) · Handoff inmediato"
        )
        errorMessage = nil
        log("Handoff caliente activado para \(selectedProfileName)")
        return true
    }

    private func rebuildAllSessions(commitSnapshot: Bool = true) {
        guard selectedProfileUsesAll else { return }
        sessionRoutes.removeAll(keepingCapacity: true)
        sessionSourceLabels.removeAll(keepingCapacity: true)
        let profilesById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let sources = [Self.pukyProfileId, Self.personalProfileId].compactMap { profileId -> KycodeCombinedSessionSource? in
            guard let profile = profilesById[profileId],
                  let snapshot = allSourceSnapshots[profileId] else { return nil }
            return KycodeCombinedSessionSource(
                profileId: profileId,
                profileName: profile.name,
                items: snapshot.items
            )
        }
        let combinedItems = KycodeCombinedSessionPolicy.combine(sources)
        for item in combinedItems {
            sessionSourceLabels[item.summary.windowId] = item.profileName
            if let credentials = allSourceCredentials[item.profileId] {
                sessionRoutes[item.summary.windowId] = KycodeSessionRoute(
                    presentedWindowId: item.summary.windowId,
                    remoteWindowId: item.remoteWindowId,
                    profileId: item.profileId,
                    profileName: item.profileName,
                    credentials: credentials
                )
            }
        }
        if commitSnapshot {
            let combined = combinedItems.map(\.summary)
            applySessions(
                KycodeSessionsEnvelope(
                    ok: true,
                    now: Date().timeIntervalSince1970 * 1_000,
                    exportedAt: nil,
                    items: combined
                )
            )
        }
        isConnected = sourceConnectionStates.contains(where: \.isConnected)
        isStreaming = false
        lastConnectionSource = "Puky + Mac personal"
    }

    private func performAllAutoConnect() async -> Bool {
        guard selectedProfileUsesAll else { return false }
        let primaryProfiles = Self.primaryProfiles(from: profiles)
        let attemptGeneration = beginSourceSnapshotAttempt(for: primaryProfiles)
        let connected = await resolveAndApplyAllSources(
            primaryProfiles,
            attemptGeneration: attemptGeneration
        )
        guard selectedProfileUsesAll,
              sourceSnapshotAttemptGeneration == attemptGeneration else { return false }
        if connected {
            clearConnectionIssueState(cancelReconnectTask: false)
            startAllRefreshLoop()
            errorMessage = nil
        } else {
            errorMessage = "No pude conectar con ninguna de las dos Macs. Revisá el estado de cada fuente."
        }
        return connected
    }

    private func startAllRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.selectedProfileUsesAll {
                try? await Task.sleep(for: .seconds(KycodeSessionRefreshPolicy.fallbackIntervalSeconds))
                if Task.isCancelled { return }
                await self.refreshAllSessionsNow()
                for windowId in self.workingTrackedWindowIds() {
                    await self.refreshDetail(windowId: windowId)
                }
            }
        }
    }

    private func refreshAllSessionsNow() async {
        guard selectedProfileUsesAll else { return }
        let primaryProfiles = Self.primaryProfiles(from: profiles)
        let attemptGeneration = beginSourceSnapshotAttempt(for: primaryProfiles)
        _ = await resolveAndApplyAllSources(
            primaryProfiles,
            attemptGeneration: attemptGeneration
        )
    }

    private func autoConnect() async {
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedProfileId = selectedProfileId
        let didConnect = await performAutoConnectAttempt(resetIssueState: true)
        guard ownsConnectionAttempt(
            connectionGeneration: expectedConnectionGeneration,
            selectedProfileId: expectedProfileId
        ) else {
            return
        }
        guard !didConnect else { return }
        guard shouldScheduleBootstrapReconnectLoop else { return }
        scheduleBootstrapReconnectLoopIfNeeded()
    }

    private func performAutoConnectAttempt(resetIssueState: Bool) async -> Bool {
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedProfileId = selectedProfileId
        let bootstrapStartedAt = Date()
        isBootstrapping = true
        if resetIssueState {
            clearConnectionIssueState(cancelReconnectTask: false)
        }
        log("Bootstrap de conexion iniciado t0=\(bootstrapStartedAt.timeIntervalSince1970)")
        defer {
            log("Bootstrap finalizado totalMs=\(kycodeElapsedMs(since: bootstrapStartedAt)) connected=\(isConnected)")
            if ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) {
                isBootstrapping = false
            }
        }

        let profile = selectedProfile

        if profile?.mode == .all {
            bootstrapStatusText = "Conectando Puky y Mac personal..."
            return await performAllAutoConnect()
        }

        if let profile, profile.mode == .personal || profile.mode == .ferminCode {
            let attemptGeneration = beginSourceSnapshotAttempt(for: [profile])
            bootstrapStatusText = "Buscando \(profile.name)..."
            let result = await resolveSourceSnapshot(
                profile: profile,
                preferredCredentials: activeCredentials
            )
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ), sourceSnapshotAttemptGeneration == attemptGeneration else {
                return false
            }
            guard let credentials = result.credentials, let snapshot = result.snapshot else {
                updateSourceState(
                    profile: profile,
                    isLoading: false,
                    isConnected: false,
                    sessionCount: sourceConnectionStates.first(where: { $0.id == profile.id })?.sessionCount ?? 0,
                    connectionLabel: nil,
                    errorMessage: result.errorMessage,
                    snapshotPhase: .failed,
                    attemptGeneration: attemptGeneration,
                    hasRetainedSnapshot: sourceConnectionStates.first(where: { $0.id == profile.id })?.hasRetainedSnapshot ?? false
                )
                errorMessage = result.errorMessage ?? "No pude conectar con \(profile.name)."
                return false
            }
            if let bonjourResult = result.bonjourResult {
                persistBonjourCache(bonjourResult, profileId: profile.id)
            }
            applySuccessfulConnection(
                credentials,
                snapshot: snapshot,
                persist: true,
                persistBaseURL: isCanonicalFerminRelayCredentials(credentials),
                sourceLabel: result.connectionLabel ?? profile.name
            )
            return true
        }

        if let stored = selectedProfileStoredCredentials {
            bootstrapStatusText = "Reconectando con \(selectedProfileName)..."
            log("Intentando ultima conexion del perfil \(selectedProfileName) en \(stored.baseURL)")
            if await connect(
                using: stored,
                persist: true,
                persistBaseURL: true,
                sourceLabel: "Perfil · \(selectedProfileName)",
                requestTimeout: connectionRequestTimeout(
                    for: stored,
                    localTimeout: Self.bootstrapStoredRequestTimeout,
                    internetTimeout: KycodeConnectionTransportPolicy.internetBootstrapTimeoutSeconds
                )
            ) {
                return true
            }
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) else { return false }
            log("La conexion guardada del perfil \(selectedProfileName) fallo. Paso a discovery Bonjour.")
        }

        if let storedBonjour = selectedProfileStoredBonjourCredentials {
            bootstrapStatusText = "Reconectando con \(selectedProfileName)..."
            log("Intentando ultimo Bonjour cacheado de \(selectedProfileName) en \(storedBonjour.baseURL)")
            if await connect(
                using: storedBonjour,
                persist: true,
                persistBaseURL: false,
                sourceLabel: "Bonjour cache · \(selectedProfileName)",
                requestTimeout: Self.bootstrapStoredRequestTimeout
            ) {
                return true
            }
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) else { return false }
            log("El Bonjour cacheado de \(selectedProfileName) fallo. Paso a discovery Bonjour.")
        }

        if profile?.mode == .remoteHub {
            if getRemoteHubToken() == nil {
                errorMessage = "Pegá el token de tu Mac para usar Fermín Code remoto."
            } else if errorMessage == nil || errorMessage?.isEmpty == true {
                errorMessage = "No pude conectarme a Mi Mac (remota). Revisá el token o el relay de Fermín Code."
            }
            return false
        }

        errorMessage = nil
        bootstrapStatusText = "Buscando \(selectedProfileName)..."
        let discovery = KycodeBonjourDiscovery()
        let discoveryStartedAt = Date()
        let discovered = filteredBonjourCandidates(
            await discovery.discoverCandidates(
                timeout: Self.bootstrapDiscoveryTimeout,
                onResolvedDesktop: { [weak self, weak discovery] desktop in
                    guard let self, let discovery else { return }
                    guard self.shouldPreProbeBonjourCandidate(desktop, for: profile) else { return }
                    Task {
                        let outcome = await kycodeProbeBonjourCandidateAttempt(desktop, timeout: Self.bootstrapProbeRequestTimeout)
                        guard case let .success(result, elapsedMs) = outcome, !result.snapshot.items.isEmpty else { return }
                        self.log("Bonjour early winner \(desktop.serviceName) listo en \(elapsedMs)ms. Cierro discovery.")
                        discovery.finishEarly(reason: "candidato valido \(desktop.serviceName)")
                    }
                }
            ),
            for: profile
        )
        guard ownsConnectionAttempt(
            connectionGeneration: expectedConnectionGeneration,
            selectedProfileId: expectedProfileId
        ) else { return false }
        log("Discovery Bonjour finalizado ms=\(kycodeElapsedMs(since: discoveryStartedAt)) candidatos=\(discovered.count)")
        if let winner = await probeBonjourCandidates(discovered) {
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) else { return false }
            persistBonjourCache(winner)
            applySuccessfulConnection(
                winner.credentials,
                snapshot: winner.snapshot,
                persist: true,
                persistBaseURL: false,
                sourceLabel: "Bonjour · \(winner.discovered.serviceName)"
            )
            return true
        }

#if targetEnvironment(simulator)
        errorMessage = nil
        if let token = authTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : authTokenInput.trimmingCharacters(in: .whitespacesAndNewlines) {
            bootstrapStatusText = "Probando localhost del simulador..."
            let localhost = KycodeConnectionCredentials(baseURL: "http://127.0.0.1:8787", authToken: token)
            log("Intentando localhost del simulador en \(localhost.baseURL)")
            if await connect(
                using: localhost,
                persist: true,
                persistBaseURL: false,
                sourceLabel: "Simulator localhost",
                requestTimeout: Self.bootstrapStoredRequestTimeout
            ) {
                return true
            }
        }
#endif

        log("Fallback a entrada manual")
        if selectedProfileUsesBonjourOnly {
            errorMessage = "No pude conectarme a \(selectedProfileName). Si no estás en la misma red Wi‑Fi, probá Puky."
        } else {
            errorMessage = "No pude conectarme a \(selectedProfileName). Revisá la conexión remota."
        }
        return false
    }

    private func scheduleBootstrapReconnectLoopIfNeeded() {
        guard reconnectTask == nil, !isConnected else { return }

        isReconnecting = true
        reconnectStatusText = "Reconectando..."
        canRetryReconnectManually = false
        errorMessage = nil

        let profileId = selectedProfileId
        reconnectTask = Task { [weak self] in
            await self?.runBootstrapReconnectLoop(profileId: profileId)
        }
    }

    private func runBootstrapReconnectLoop(profileId: String) async {
        var attempt = 0

        while !Task.isCancelled {
            let delaySeconds = Self.reconnectBackoffSeconds[min(attempt, Self.reconnectBackoffSeconds.count - 1)]
            let visibleAttempt = min(attempt + 1, Self.reconnectBackoffSeconds.count)
            reconnectStatusText = "Reconectando... intento \(visibleAttempt)/\(Self.reconnectBackoffSeconds.count)"
            log("Bootstrap reconnect en segundo plano para \(profileId) en \(delaySeconds)s")

            try? await Task.sleep(for: .seconds(delaySeconds))
            if Task.isCancelled { return }

            guard !isConnected else {
                reconnectTask = nil
                return
            }

            guard selectedProfileId == profileId else {
                reconnectTask = nil
                return
            }

            let didConnect = await performAutoConnectAttempt(resetIssueState: false)
            if didConnect {
                reconnectTask = nil
                return
            }

            errorMessage = nil
            attempt += 1
        }
    }

    private func connect(
        using credentials: KycodeConnectionCredentials,
        persist: Bool,
        persistBaseURL: Bool,
        sourceLabel: String,
        requestTimeout: TimeInterval? = nil
    ) async -> Bool {
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedProfileId = selectedProfileId
        isConnecting = true
        errorMessage = nil
        log("Intentando conectar a \(credentials.baseURL) via \(sourceLabel)")
        defer {
            if ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) {
                isConnecting = false
            }
        }

        do {
            let snapshot = try await fetchSessions(credentials, timeout: requestTimeout)
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) else { return false }
            try validateSnapshotFreshness(snapshot, for: credentials)
            applySuccessfulConnection(
                credentials,
                snapshot: snapshot,
                persist: persist,
                persistBaseURL: persistBaseURL,
                sourceLabel: sourceLabel
            )
            return true
        } catch {
            guard ownsConnectionAttempt(
                connectionGeneration: expectedConnectionGeneration,
                selectedProfileId: expectedProfileId
            ) else { return false }
            if activeCredentials == credentials {
                disconnect()
            }
            isConnected = false
            errorMessage = presentableConnectionError(error, for: credentials)
            log("Fallo de conexion a \(credentials.baseURL): \(describe(error))")
            return false
        }
    }

    private func applySuccessfulConnection(
        _ credentials: KycodeConnectionCredentials,
        snapshot: KycodeSessionsEnvelope,
        persist: Bool,
        persistBaseURL: Bool,
        sourceLabel: String
    ) {
        activeCredentials = credentials
        rememberWarmTargetConnection(
            profileId: selectedProfileId,
            credentials: credentials,
            snapshot: snapshot,
            sourceLabel: sourceLabel
        )
        if persist {
            persistCredentials(credentials, persistBaseURL: persistBaseURL)
        }
        clearConnectionIssueState(cancelReconnectTask: false)
        applySessions(snapshot)
        isConnected = true
        lastConnectionSource = sourceLabel
        if let profile = selectedProfile,
           (profile.id == Self.pukyProfileId || profile.id == Self.personalProfileId) {
            let current = sourceConnectionStates.first(where: { $0.id == profile.id })
            updateSourceState(
                profile: profile,
                isLoading: false,
                isConnected: true,
                sessionCount: snapshot.items.count,
                connectionLabel: sourceLabel,
                errorMessage: nil,
                snapshotPhase: .succeeded,
                attemptGeneration: current?.attemptGeneration
                    ?? sourceSnapshotAttemptGeneration,
                hasRetainedSnapshot: true
            )
        }
        startRefreshLoop(credentials)
        startStream(credentials)
        resumeCreatedSessionReconciliations(credentials: credentials)
        log("Conectado exitosamente a \(credentials.baseURL) via \(sourceLabel). Sesiones: \(snapshot.items.count)")
    }

    private func probeBonjourCandidates(_ discovered: [KycodeDiscoveredDesktop]) async -> KycodeBonjourProbeResult? {
        guard !discovered.isEmpty else { return nil }
        return await withTaskGroup(of: KycodeBonjourProbeOutcome.self, returning: KycodeBonjourProbeResult?.self) { group in
            var fallbackResult: KycodeBonjourProbeResult?

            for desktop in discovered {
                log("Probando candidato Bonjour \(desktop.serviceName) en \(desktop.baseURL)")
                group.addTask {
                    await kycodeProbeBonjourCandidateAttempt(desktop, timeout: Self.bootstrapProbeRequestTimeout)
                }
            }

            while let outcome = await group.next() {
                switch outcome {
                case let .invalid(desktop, elapsedMs):
                    log("Descarto candidato Bonjour \(desktop.serviceName): credenciales invalidas (\(elapsedMs)ms)")

                case let .success(result, elapsedMs):
                    log("Candidato Bonjour \(result.discovered.serviceName) respondio en \(elapsedMs)ms con \(result.snapshot.items.count) sesiones")
                    if result.snapshot.items.isEmpty {
                        fallbackResult = fallbackResult ?? result
                        continue
                    }
                    group.cancelAll()
                    return result

                case let .failure(desktop, elapsedMs, description):
                    log("Candidato Bonjour \(desktop.serviceName) fallo en \(elapsedMs)ms: \(description)")
                }
            }

            if let fallbackResult, fallbackResult.snapshot.items.isEmpty {
                log("Uso candidato Bonjour de fallback \(fallbackResult.discovered.serviceName) aunque no tenga sesiones activas")
            }
            return fallbackResult
        }
    }

    private func startRefreshLoop(_ credentials: KycodeConnectionCredentials) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(KycodeSessionRefreshPolicy.fallbackIntervalSeconds))
                if Task.isCancelled { return }
                guard self.activeCredentials == credentials else { return }
                let now = Date()

                if KycodeSessionRefreshPolicy.shouldRestartStream(
                    isStreaming: self.isStreaming,
                    isReconnecting: self.isReconnecting,
                    lastStreamActivityAt: self.lastStreamActivityAt,
                    now: now
                ) {
                    self.log("Stream silencioso por más de \(Int(KycodeSessionRefreshPolicy.streamSilenceTimeoutSeconds))s; reconectando.")
                    self.isStreaming = false
                    self.lastStreamActivityAt = now
                    self.startStream(credentials)
                }

                if KycodeSessionRefreshPolicy.shouldPoll(
                    isStreaming: self.isStreaming,
                    isReconnecting: self.isReconnecting,
                    lastStreamActivityAt: self.lastStreamActivityAt,
                    now: now
                ) {
                    await self.refreshSessionsNow()
                }

                for windowId in self.workingTrackedWindowIds() where
                    KycodeSessionRefreshPolicy.shouldRefreshWorkingDetail(
                        isWorking: true,
                        lastRefreshAt: self.lastDetailRefreshAtByWindowId[windowId],
                        now: now
                    ) {
                    await self.refreshDetail(windowId: windowId)
                }
            }
        }
    }

    private func startStream(_ credentials: KycodeConnectionCredentials) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runStream(credentials)
        }
    }

    private func runStream(_ credentials: KycodeConnectionCredentials) async {
        while !Task.isCancelled {
            do {
                var request = try makeRequest(
                    credentials: credentials,
                    path: "/api/mobile/stream",
                    method: "GET",
                    body: nil
                )
                request.timeoutInterval = 0
                KycodeSSECursorStore.applyLastEventID(
                    to: &request,
                    baseURL: credentials.baseURL
                )
                requestObserver?(request)
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard httpResponse.statusCode == 200 else {
                    throw NSError(
                        domain: "KycodeMobile",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "La API devolvió \(httpResponse.statusCode)."]
                    )
                }
                isStreaming = true
                lastStreamActivityAt = Date()
                restoreConnectionFromVerifiedStreamActivity(
                    credentials,
                    source: "stream conectado"
                )

                var eventName = "message"
                var eventID: String?
                var dataLines: [String] = []
                var dispatchTransaction = KycodeSSEDispatchTransaction()

                func dispatch() async -> Bool {
                    guard !Task.isCancelled,
                          activeCredentials == credentials else {
                        return false
                    }
                    guard !dataLines.isEmpty else {
                        eventName = "message"
                        eventID = nil
                        return true
                    }
                    let payload = dataLines.joined(separator: "\n")
                    dataLines = []
                    let dispatchedEventID = eventID
                    var cursorToCommit = dispatchedEventID
                    var applied = false
                    defer {
                        eventName = "message"
                        eventID = nil
                        if let committed = dispatchTransaction.commit(
                            eventID: cursorToCommit,
                            applied: applied
                        ) {
                            KycodeSSECursorStore.persist(
                                eventID: committed,
                                baseURL: credentials.baseURL
                            )
                        }
                    }

                    switch eventName {
                    case "snapshot":
                        guard let data = payload.data(using: .utf8),
                              let snapshot = KycodeSSESnapshotDecoder.decode(data) else {
                            recordBackgroundSyncFailure(
                                "El stream devolvió un snapshot con formato inválido.",
                                source: "stream snapshot"
                            )
                            return false
                        }
                        do {
                            try validateSnapshotFreshness(snapshot, for: credentials)
                        } catch {
                            recordBackgroundSyncFailure(
                                describe(error),
                                source: "stream snapshot"
                            )
                            return false
                        }
                        if let cursor = snapshot.cursor {
                            cursorToCommit = String(cursor)
                        }
                        clearConnectionIssueState(cancelReconnectTask: false)
                        applySessions(snapshot)
                        applied = true
                    case "message_patch":
                        guard let data = payload.data(using: .utf8),
                              let patch = try? JSONDecoder().decode(
                                  KycodeLiveMessagePatch.self,
                                  from: data
                              ) else {
                            recordBackgroundSyncFailure(
                                "El stream devolvió un parche de mensaje inválido.",
                                source: "stream message patch"
                            )
                            return false
                        }
                        applyLiveMessagePatch(patch)
                        applied = true
                    case "command_state_changed":
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(
                                  KycodeCommandStateChangedEvent.self,
                                  from: data
                              ) else {
                            recordBackgroundSyncFailure(
                                "El stream devolvió un estado de comando inválido.",
                                source: "stream command"
                            )
                            return false
                        }
                        applyDurableCommandStateChanged(event)
                        applied = true
                    case "session_upserted":
                        guard let data = payload.data(using: .utf8),
                              let session = try? JSONDecoder().decode(
                                  KycodeSessionSummary.self,
                                  from: data
                              ) else {
                            recordBackgroundSyncFailure(
                                "El stream devolvió una sesión inválida.",
                                source: "stream session upsert"
                            )
                            return false
                        }
                        applyStreamSessionUpsert(session)
                        applied = true
                    case "session_removed":
                        guard let data = payload.data(using: .utf8),
                              let removed = try? JSONDecoder().decode(
                                  KycodeSessionRemovedEvent.self,
                                  from: data
                              ) else {
                            recordBackgroundSyncFailure(
                                "El stream devolvió una eliminación de sesión inválida.",
                                source: "stream session removal"
                            )
                            return false
                        }
                        applyStreamSessionRemoval(removed)
                        applied = true
                    case "turn_started", "turn_completed", "turn_interrupted",
                         "item_started", "item_updated", "item_completed",
                         "approval_requested", "approval_resolved",
                         "user_input_requested", "user_input_resolved",
                         "model_catalog_updated", "goal_updated", "subagent_updated",
                         "runtime_status":
                        let target = payload.data(using: .utf8).flatMap {
                            try? JSONDecoder().decode(KycodeSSEEventTarget.self, from: $0)
                        }
                        scheduleMetadataRefresh(windowId: streamWindowId(for: target))
                        applied = true
                    case "error":
                        if let streamError = KycodeSessionRefreshErrorPolicy.streamDiagnosticMessage(from: payload) {
                            recordBackgroundSyncFailure(streamError, source: "stream event")
                        }
                        if let currentError = errorMessage,
                           KycodeSessionRefreshErrorPolicy.isMissingWindowMessage(currentError) {
                            errorMessage = nil
                        }
                        applied = true
                    default:
                        applied = true
                    }
                    return true
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard activeCredentials == credentials else { return }
                    lastStreamActivityAt = Date()
                    restoreConnectionFromVerifiedStreamActivity(
                        credentials,
                        source: "actividad del stream"
                    )
                    if line.isEmpty {
                        guard await dispatch() else {
                            throw KycodeSSEStreamDispatchError.replayRequired
                        }
                        continue
                    }
                    if line.hasPrefix(":") {
                        continue
                    }
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count))
                            .trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    if line.hasPrefix("id:") {
                        let value = String(line.dropFirst("id:".count))
                            .trimmingCharacters(in: .whitespaces)
                        eventID = KycodeSSECursorStore.validatedEventID(value)
                        continue
                    }
                    if line.hasPrefix("data:") {
                        let value = String(line.dropFirst("data:".count))
                            .trimmingCharacters(in: .whitespaces)
                        dataLines.append(value)
                    }
                }

                guard await dispatch() else {
                    throw KycodeSSEStreamDispatchError.replayRequired
                }
                isStreaming = false
                lastStreamActivityAt = nil
            } catch {
                if Task.isCancelled { return }
                guard activeCredentials == credentials else { return }
                isStreaming = false
                lastStreamActivityAt = nil
                if error is KycodeSSEStreamDispatchError {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                if await handleRecoverableConnectionFailure(error, source: "stream", credentials: credentials) {
                    return
                }
                recordBackgroundSyncFailure(describe(error), source: "stream transport")
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    func applyStreamSessionUpsert(_ incoming: KycodeSessionSummary) {
        if incoming.runtimeStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == "ARCHIVED" {
            finalizeDeletedSessionLocalArtifacts(
                windowId: incoming.windowId,
                sessionId: incoming.sessionId
            )
            reconcileMissingWindow(incoming.windowId)
            scheduleMetadataRefresh()
            return
        }

        var items = sessions
        if let index = items.firstIndex(where: { $0.windowId == incoming.windowId }) {
            items[index] = incoming
        } else {
            items.append(incoming)
        }
        applySessions(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: items
            )
        )
        scheduleMetadataRefresh(windowId: incoming.windowId)
    }

    private func applyStreamSessionRemoval(_ removed: KycodeSessionRemovedEvent) {
        let windowId = removed.windowId
            ?? removed.sessionId.flatMap { sessionId in
                sessions.first(where: { $0.sessionId == sessionId })?.windowId
                    ?? sessionDetails.first(where: { $0.value.sessionId == sessionId })?.key
            }
        if let windowId, !windowId.isEmpty {
            let sessionId = removed.sessionId
                ?? sessions.first(where: { $0.windowId == windowId })?.sessionId
                ?? sessionDetails[windowId]?.sessionId
            finalizeDeletedSessionLocalArtifacts(windowId: windowId, sessionId: sessionId)
            reconcileMissingWindow(windowId)
        }
        scheduleMetadataRefresh()
    }

    private func streamWindowId(for target: KycodeSSEEventTarget?) -> String? {
        if let windowId = target?.windowId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !windowId.isEmpty {
            return windowId
        }
        guard let sessionId = target?.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty else {
            return nil
        }
        return sessions.first(where: { $0.sessionId == sessionId })?.windowId
            ?? sessionDetails.first(where: { $0.value.sessionId == sessionId })?.key
    }

    private func applySessions(_ snapshot: KycodeSessionsEnvelope) {
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.windowId, $0) })
        let now = Date()
        pendingDeletions = pendingDeletions.filter { $0.value.expiresAt > now }
        let snapshotWindowIds = Set(snapshot.items.map(\.windowId))
        missingWindowIdsAwaitingSnapshotRemoval = Set(
            missingWindowIdsAwaitingSnapshotRemoval.filter { snapshotWindowIds.contains($0) }
        )
        for windowId in Array(pendingDeletions.keys) where !snapshotWindowIds.contains(windowId) {
            pendingDeletions.removeValue(forKey: windowId)
        }
        let visibleSnapshotItems = snapshot.items.filter {
            pendingDeletions[$0.windowId] == nil
                && !missingWindowIdsAwaitingSnapshotRemoval.contains($0.windowId)
        }
        let visibleWindowIds = Set(visibleSnapshotItems.map(\.windowId))
        pruneUnavailableSessionSnapshotState(retaining: visibleWindowIds)
        var nextItems: [KycodeSessionSummary] = []
        nextItems.reserveCapacity(visibleSnapshotItems.count)
        let defaultItems = visibleSnapshotItems.sorted { left, right in
            let leftCreatedAt = left.createdAt ?? 0
            let rightCreatedAt = right.createdAt ?? 0
            if leftCreatedAt != rightCreatedAt {
                return leftCreatedAt > rightCreatedAt
            }
            return left.windowId.localizedStandardCompare(right.windowId) == .orderedAscending
        }
        sessionDisplayOrder = KycodeSessionDisplayOrderPolicy.reconcile(
            existingOrder: sessionDisplayOrdersByProfile[selectedProfileId] ?? sessionDisplayOrder,
            availableWindowIds: visibleSnapshotItems.map(\.windowId),
            defaultOrder: defaultItems.map(\.windowId)
        )
        persistSessionDisplayOrder()
        let itemsByWindowId = Dictionary(uniqueKeysWithValues: visibleSnapshotItems.map { ($0.windowId, $0) })
        for windowId in sessionDisplayOrder {
            guard let item = itemsByWindowId[windowId] else { continue }
            let reconciled = reconcilePendingSessionUpdates(
                with: item,
                now: now,
                goalModeSource: .sessions,
                featureSource: .sessions
            )
            nextItems.append(reconcileOptimisticMessages(with: reconciled))
        }

        sessions = nextItems
        let refreshedAt = Date()
        lastSessionsRefreshAt = refreshedAt
        isShowingCachedSessions = false
        persistCachedSessions(nextItems, cachedAt: refreshedAt)
        if !selectedProfileUsesAll, let credentials = activeCredentials {
            rememberWarmTargetConnection(
                profileId: selectedProfileId,
                credentials: credentials,
                snapshot: snapshot,
                sourceLabel: lastConnectionSource ?? selectedProfileName
            )
        }
        syncRecentCreatedSessions(with: nextItems)
        for item in nextItems {
            if let existing = sessionDetails[item.windowId] {
                sessionDetails[item.windowId] = mergeDetail(existing, with: item)
                if existing.updatedAt != item.updatedAt || existing.messageCount != item.messageCount {
                    Task { [weak self] in
                        await self?.refreshDetail(windowId: item.windowId)
                    }
                }
            } else if previous[item.windowId]?.updatedAt != item.updatedAt || previous[item.windowId]?.messageCount != item.messageCount {
                Task { [weak self] in
                    await self?.refreshDetail(windowId: item.windowId)
                }
            }
        }
    }

    private func reconcileMissingWindow(_ windowId: String) {
        missingWindowIdsAwaitingSnapshotRemoval.insert(windowId)
        removePendingRuntimeSettingsUpdates(windowId: windowId)
        sessions.removeAll { $0.windowId == windowId }
        pendingOptimisticMessages.removeValue(forKey: windowId)
        pruneUnavailableSessionRuntimeState(windowId: windowId)
        persistCachedSessions(sessions, cachedAt: Date())

        if let currentError = errorMessage,
           KycodeSessionRefreshErrorPolicy.isMissingWindowMessage(currentError) {
            errorMessage = nil
        }
        log("Ventana obsoleta reconciliada sin mostrar error global window=\(windowId)")
    }

    private func pruneUnavailableSessionSnapshotState(retaining windowIds: Set<String>) {
        let trackedWindowIds = Set(sessionDisplayOrder)
            .union(sessionDetails.keys)
            .union(detailLoadStates.keys)
            .union(sessionRoutes.keys)
            .union(sessionSourceLabels.keys)
            .union(pendingLiveMessagePatchesByWindowId.keys)
            .union(lastDetailRefreshAtByWindowId.keys)
        for windowId in trackedWindowIds where !windowIds.contains(windowId) {
            pruneUnavailableSessionSnapshotState(windowId: windowId)
        }
    }

    private func pruneUnavailableSessionSnapshotState(windowId: String) {
        sessionDetails.removeValue(forKey: windowId)
        detailLoadStates.removeValue(forKey: windowId)
        sessionDisplayOrder.removeAll { $0 == windowId }
        sessionRoutes.removeValue(forKey: windowId)
        sessionSourceLabels.removeValue(forKey: windowId)
        pendingLiveMessagePatchesByWindowId.removeValue(forKey: windowId)
        liveMessagePatchCursorByKey = liveMessagePatchCursorByKey.filter {
            !$0.key.hasPrefix("\(windowId):")
        }
        lastDetailRefreshAtByWindowId.removeValue(forKey: windowId)
    }

    private func pruneUnavailableSessionRuntimeState(windowId: String) {
        pruneUnavailableSessionSnapshotState(windowId: windowId)
        pendingFeatureUpdates.removeValue(forKey: windowId)
        messageReconciliationTasks[windowId]?.cancel()
        messageReconciliationTasks.removeValue(forKey: windowId)
        removePromptRetryIntents(windowId: windowId)
        removePromptTransformTimeouts(windowId: windowId)
    }

    private func applyLiveMessagePatch(_ patch: KycodeLiveMessagePatch) {
        guard pendingDeletions[patch.windowId] == nil else { return }
        lastDetailRefreshAtByWindowId[patch.windowId] = Date()

        guard let detail =
            sessionDetails[patch.windowId]
                ?? sessions.first(where: { $0.windowId == patch.windowId }) else {
            pendingLiveMessagePatchesByWindowId[patch.windowId] = patch
            Task { [weak self] in
                await self?.refreshDetail(windowId: patch.windowId)
            }
            return
        }

        let patchKey = "\(patch.windowId):\(patch.message.id)"
        let currentContent = detail.messages?.first(where: { $0.id == patch.message.id })?.content
        guard KycodeLiveMessagePatchOrderingPolicy.shouldApply(
            patch,
            after: liveMessagePatchCursorByKey[patchKey],
            currentContent: currentContent
        ) else {
            return
        }
        liveMessagePatchCursorByKey[patchKey] = KycodeLiveMessagePatchOrderingPolicy.cursor(for: patch)
        let reconciled = KycodeLiveMessageReducer.applying(patch, to: detail)
        sessionDetails[patch.windowId] = reconcileOptimisticMessages(with: reconciled)
        pendingLiveMessagePatchesByWindowId.removeValue(forKey: patch.windowId)
        reconcilePromptTransformTimeouts(windowId: patch.windowId)
    }

    private func workingTrackedWindowIds() -> [String] {
        let trackedWindowIds = Set(sessionDetails.keys)
            .union(pendingOptimisticMessages.keys)
            .union(pendingPromptRetryIntents.keys.map(\.windowId))
        return trackedWindowIds.filter { windowId in
            let item = sessionDetails[windowId]
                ?? sessions.first(where: { $0.windowId == windowId })
            return KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: !(pendingOptimisticMessages[windowId]?.isEmpty ?? true),
                hasPendingPromptTransform: KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(
                    in: item?.messages,
                    sessionImprovedPrompt: item?.improvedPrompt
                ),
                activityStatus: item?.activityStatus,
                runtimeStatus: item?.runtimeStatus,
                hasPendingPromptRetry: hasPendingPromptRetryIntent(windowId: windowId)
            )
        }
        .sorted()
    }

    private func hasPendingPromptRetryIntent(windowId: String) -> Bool {
        pendingPromptRetryIntents.contains { key, intent in
            key.windowId == windowId && intent.generation == connectionStateGeneration
        }
    }

    private func removePromptRetryIntents(windowId: String) {
        pendingPromptRetryIntents = pendingPromptRetryIntents.filter {
            $0.key.windowId != windowId
        }
    }

    func promptTransformTimedOutMessageIds(windowId: String) -> Set<String> {
        let detail = sessionDetails[windowId]
            ?? sessions.first(where: { $0.windowId == windowId })
        let candidateContexts = promptTransformTimeoutContexts.filter { key, _ in
            key.windowId == windowId
        }
        // This accessor is evaluated while the composer changes. Most sessions
        // have no timed-out transforms, so avoid walking a potentially very
        // large transcript unless there is actually a timeout to validate.
        guard !candidateContexts.isEmpty else { return [] }
        let unresolvedMessageIds = KycodePromptTransformStatePolicy.unresolvedPendingMessageIDs(
            in: detail?.messages,
            sessionImprovedPrompt: detail?.improvedPrompt
        )
        guard !unresolvedMessageIds.isEmpty,
              let target = routedTarget(for: windowId) else {
            return []
        }
        let profileId = sessionRoutes[windowId]?.profileId ?? selectedProfileId
        let sessionId = detail?.sessionId

        return Set(candidateContexts.compactMap { key, context in
            guard unresolvedMessageIds.contains(key.messageId),
                  context.generation == connectionStateGeneration,
                  context.profileId == profileId,
                  context.remoteWindowId == target.remoteWindowId,
                  context.sessionId == sessionId else {
                return nil
            }
            return key.messageId
        })
    }

    private func recordPromptTransformTimeouts(windowId: String) {
        let detail = sessionDetails[windowId]
            ?? sessions.first(where: { $0.windowId == windowId })
        let unresolvedMessageIds = KycodePromptTransformStatePolicy.unresolvedPendingMessageIDs(
            in: detail?.messages,
            sessionImprovedPrompt: detail?.improvedPrompt
        )
        var nextContexts = promptTransformTimeoutContexts.filter {
            $0.key.windowId != windowId
        }
        if let target = routedTarget(for: windowId), !unresolvedMessageIds.isEmpty {
            let context = KycodePromptTransformTimeoutContext(
                generation: connectionStateGeneration,
                profileId: sessionRoutes[windowId]?.profileId ?? selectedProfileId,
                remoteWindowId: target.remoteWindowId,
                sessionId: detail?.sessionId
            )
            for messageId in unresolvedMessageIds {
                nextContexts[
                    KycodePromptRetryIntentKey(
                        windowId: windowId,
                        messageId: messageId
                    )
                ] = context
            }
        }
        if nextContexts != promptTransformTimeoutContexts {
            promptTransformTimeoutContexts = nextContexts
        }
    }

    private func reconcilePromptTransformTimeouts(windowId: String) {
        let activeMessageIds = promptTransformTimedOutMessageIds(windowId: windowId)
        let nextContexts = promptTransformTimeoutContexts.filter { key, _ in
            key.windowId != windowId || activeMessageIds.contains(key.messageId)
        }
        if nextContexts != promptTransformTimeoutContexts {
            promptTransformTimeoutContexts = nextContexts
        }
    }

    private func clearPromptTransformTimeout(windowId: String, messageId: String) {
        promptTransformTimeoutContexts.removeValue(
            forKey: KycodePromptRetryIntentKey(
                windowId: windowId,
                messageId: messageId
            )
        )
    }

    private func removePromptTransformTimeouts(windowId: String) {
        let nextContexts = promptTransformTimeoutContexts.filter {
            $0.key.windowId != windowId
        }
        if nextContexts != promptTransformTimeoutContexts {
            promptTransformTimeoutContexts = nextContexts
        }
    }

    private func removePromptRetryIntent(
        windowId: String,
        messageId: String?,
        attemptId: UUID?
    ) {
        guard let messageId else { return }
        let key = KycodePromptRetryIntentKey(
            windowId: windowId,
            messageId: messageId
        )
        guard let current = pendingPromptRetryIntents[key],
              attemptId == nil || current.attemptId == attemptId else {
            return
        }
        pendingPromptRetryIntents.removeValue(forKey: key)
    }

    @discardableResult
    private func reconcilePromptRetryIntents(windowId: String) -> Bool {
        let now = messageReconciliationNow()
        let detail = sessionDetails[windowId]
            ?? sessions.first(where: { $0.windowId == windowId })
        let candidates = pendingPromptRetryIntents.filter {
            $0.key.windowId == windowId
        }

        for (key, intent) in candidates {
            let currentProfileId = sessionRoutes[windowId]?.profileId ?? selectedProfileId
            guard intent.generation == connectionStateGeneration,
                  intent.profileId == currentProfileId,
                  routedTarget(for: windowId)?.remoteWindowId == intent.remoteWindowId else {
                pendingPromptRetryIntents.removeValue(forKey: key)
                continue
            }
            var observedIntent = intent
            observedIntent.phase = KycodePromptRetryReconciliationPolicy.phase(
                after: detail,
                for: intent
            )
            if observedIntent.phase != intent.phase,
               pendingPromptRetryIntents[key]?.attemptId == intent.attemptId {
                pendingPromptRetryIntents[key] = observedIntent
            }
            let decision = KycodePromptRetryReconciliationPolicy.decision(
                intent: observedIntent,
                detail: detail,
                now: now
            )
            guard decision != .keepWaiting,
                  pendingPromptRetryIntents[key]?.attemptId == intent.attemptId else {
                continue
            }
            pendingPromptRetryIntents.removeValue(forKey: key)
            log("Prompt retry reconciliado window=\(windowId) message=\(observedIntent.messageId) decision=\(decision)")
        }

        return hasPendingPromptRetryIntent(windowId: windowId)
    }

    private func recordPendingMinimizedUpdate(windowId: String, minimized: Bool) {
        let now = Date()
        pendingMinimizedUpdates[windowId] = KycodePendingMinimizedUpdate(
            minimized: minimized,
            expiresAt: now.addingTimeInterval(Self.minimizedPendingTTL)
        )
    }

    private func applyingPendingMinimizedUpdate(to item: KycodeSessionSummary) -> KycodeSessionSummary {
        guard let pending = pendingMinimizedUpdates[item.windowId],
              pending.expiresAt > Date(),
              item.minimized != pending.minimized else {
            return item
        }
        return item.replacingMinimized(pending.minimized)
    }

    private func reconcilePendingMinimizedUpdate(
        with item: KycodeSessionSummary,
        now: Date = Date()
    ) -> KycodeSessionSummary {
        guard let pending = pendingMinimizedUpdates[item.windowId] else {
            return item
        }
        guard pending.expiresAt > now else {
            pendingMinimizedUpdates.removeValue(forKey: item.windowId)
            return item
        }
        return item.minimized == pending.minimized
            ? item
            : item.replacingMinimized(pending.minimized)
    }

    private func recordPendingRenameUpdate(windowId: String, name: String) {
        let now = Date()
        pendingRenameUpdates[windowId] = KycodePendingRenameUpdate(
            name: name,
            protectUntil: now.addingTimeInterval(Self.renamePendingProtection),
            expiresAt: now.addingTimeInterval(Self.renamePendingTTL)
        )
    }

    private func applyingPendingSessionUpdates(to item: KycodeSessionSummary) -> KycodeSessionSummary {
        let minimizedItem = applyingPendingMinimizedUpdate(to: item)
        let renamedItem = applyingPendingRenameUpdate(to: minimizedItem)
        let collaborationItem = applyingPendingCollaborationProjectUpdate(to: renamedItem)
        let runtimeItem = applyingPendingRuntimeSettingsUpdate(to: collaborationItem)
        let featureItem = applyingPendingFeatureUpdate(to: runtimeItem)
        return applyingPendingGoalModeUpdate(to: featureItem)
    }

    private func reconcilePendingSessionUpdates(
        with item: KycodeSessionSummary,
        now: Date = Date(),
        goalModeSource: KycodePendingGoalModeSource,
        featureSource: KycodePendingFeatureSource
    ) -> KycodeSessionSummary {
        var item = item
        if let pending = pendingPinnedUpdates[item.windowId] {
            item.isPinned = pending.pinned
        }
        let minimizedItem = reconcilePendingMinimizedUpdate(with: item, now: now)
        let renamedItem = reconcilePendingRenameUpdate(with: minimizedItem, now: now)
        let collaborationItem = reconcilePendingCollaborationProjectUpdate(
            with: renamedItem,
            now: now
        )
        let runtimeItem = reconcilePendingRuntimeSettingsUpdate(with: collaborationItem, now: now)
        let featureItem = reconcilePendingFeatureUpdate(
            with: runtimeItem,
            source: featureSource
        )
        return reconcilePendingGoalModeUpdate(
            with: featureItem,
            now: now,
            source: goalModeSource
        )
    }

    @discardableResult
    private func recordPendingFeatureUpdate(
        windowId: String,
        profileId: String,
        remoteWindowId: String,
        credentials: KycodeConnectionCredentials,
        sessionId: String?,
        generation: UInt64,
        promptImproverEnabled: Bool,
        explainerEnabled: Bool,
        codeContextEnabled: Bool?,
        previousSummaryFeatures: KycodeSessionFeatures?,
        previousDetailFeatures: KycodeSessionFeatures?
    ) -> UUID {
        let now = featureReconciliationNow()
        let mutationId = UUID()
        pendingFeatureUpdates[windowId] = KycodePendingFeatureUpdate(
            promptImproverEnabled: promptImproverEnabled,
            explainerEnabled: explainerEnabled,
            codeContextEnabled: codeContextEnabled,
            previousSummaryFeatures: previousSummaryFeatures,
            previousDetailFeatures: previousDetailFeatures,
            mutationId: mutationId,
            profileId: profileId,
            remoteWindowId: remoteWindowId,
            credentials: credentials,
            sessionId: sessionId,
            generation: generation,
            protectUntil: now + Self.featurePendingProtection,
            expiresAt: now + Self.featurePendingTTL,
            sessionsConfirmed: false,
            detailConfirmed: false
        )
        return mutationId
    }

    private func featureValues(
        applying pending: KycodePendingFeatureUpdate,
        to item: KycodeSessionSummary
    ) -> KycodeSessionFeatures {
        KycodeSessionFeatures(
            promptImproverEnabled: pending.promptImproverEnabled,
            explainerEnabled: pending.explainerEnabled,
            codeContextEnabled: pending.codeContextEnabled
                ?? item.features?.codeContextEnabled
                ?? pending.previousDetailFeatures?.codeContextEnabled
                ?? pending.previousSummaryFeatures?.codeContextEnabled
                ?? false
        )
    }

    private func featureValuesMatch(
        _ item: KycodeSessionSummary,
        pending: KycodePendingFeatureUpdate
    ) -> Bool {
        guard let features = item.features,
              features.promptImproverEnabled == pending.promptImproverEnabled,
              features.explainerEnabled == pending.explainerEnabled else {
            return false
        }
        return pending.codeContextEnabled == nil
            || features.codeContextEnabled == pending.codeContextEnabled
    }

    private func featureRouteIsCurrent(
        windowId: String,
        pending: KycodePendingFeatureUpdate
    ) -> Bool {
        guard pending.generation == connectionStateGeneration else { return false }
        if let route = sessionRoutes[windowId] {
            return route.profileId == pending.profileId
                && route.remoteWindowId == pending.remoteWindowId
                && route.credentials == pending.credentials
        }
        return !selectedProfileUsesAll
            && selectedProfileId == pending.profileId
            && windowId == pending.remoteWindowId
            && (activeCredentials ?? draftCredentials) == pending.credentials
    }

    private func isCurrentFeatureMutation(windowId: String, mutationId: UUID) -> Bool {
        guard let pending = pendingFeatureUpdates[windowId],
              pending.mutationId == mutationId,
              featureRouteIsCurrent(windowId: windowId, pending: pending) else {
            return false
        }
        guard let sessionId = pending.sessionId else { return true }
        let currentSessionId = sessionDetails[windowId]?.sessionId
            ?? sessions.first(where: { $0.windowId == windowId })?.sessionId
        return currentSessionId == sessionId
    }

    private func applyingPendingFeatureUpdate(
        to item: KycodeSessionSummary,
        now: TimeInterval? = nil
    ) -> KycodeSessionSummary {
        let now = now ?? featureReconciliationNow()
        guard let pending = pendingFeatureUpdates[item.windowId],
              pending.expiresAt > now,
              featureRouteIsCurrent(windowId: item.windowId, pending: pending),
              pending.sessionId == nil || pending.sessionId == item.sessionId else {
            return item
        }
        return item.replacingFeatures(featureValues(applying: pending, to: item))
    }

    private func reconcilePendingFeatureUpdate(
        with item: KycodeSessionSummary,
        now: TimeInterval? = nil,
        source: KycodePendingFeatureSource
    ) -> KycodeSessionSummary {
        let now = now ?? featureReconciliationNow()
        guard var pending = pendingFeatureUpdates[item.windowId] else { return item }
        guard pending.expiresAt > now,
              featureRouteIsCurrent(windowId: item.windowId, pending: pending),
              pending.sessionId == nil || pending.sessionId == item.sessionId else {
            pendingFeatureUpdates.removeValue(forKey: item.windowId)
            return item
        }

        if featureValuesMatch(item, pending: pending) {
            switch source {
            case .sessions:
                pending.sessionsConfirmed = true
            case .detail:
                pending.detailConfirmed = true
            }
        }

        if pending.sessionsConfirmed,
           pending.detailConfirmed,
           pending.protectUntil <= now {
            pendingFeatureUpdates.removeValue(forKey: item.windowId)
            return item
        }

        pendingFeatureUpdates[item.windowId] = pending
        return item.replacingFeatures(featureValues(applying: pending, to: item))
    }

    private func scheduleFeatureReconciliation(windowId: String, mutationId: UUID) {
        Task { [weak self] in
            for delayMs in Self.featureReconcileDelayMilliseconds {
                await self?.featureReconciliationSleep(.milliseconds(delayMs))
                if Task.isCancelled { return }
                guard self?.pendingFeatureUpdates[windowId]?.mutationId == mutationId else {
                    return
                }
                await self?.refreshSessionsNow()
                await self?.refreshDetail(windowId: windowId)
            }
            guard let self,
                  let pending = pendingFeatureUpdates[windowId],
                  pending.mutationId == mutationId else {
                return
            }
            let remaining = max(0, pending.expiresAt - featureReconciliationNow())
            if remaining > 0 {
                let milliseconds = Int64((remaining * 1_000).rounded(.up))
                await featureReconciliationSleep(.milliseconds(milliseconds))
            }
            guard !Task.isCancelled,
                  let current = pendingFeatureUpdates[windowId],
                  current.mutationId == mutationId,
                  current.expiresAt <= featureReconciliationNow() else {
                return
            }
            pendingFeatureUpdates.removeValue(forKey: windowId)
            await refreshSessionsNow()
            await refreshDetail(windowId: windowId)
        }
    }

    @discardableResult
    private func recordPendingGoalModeUpdate(
        windowId: String,
        enabled: Bool,
        goalStartedAt: Double?
    ) -> UUID {
        let now = Date()
        let mutationId = UUID()
        pendingGoalModeUpdates[windowId] = KycodePendingGoalModeUpdate(
            enabled: enabled,
            goalStartedAt: goalStartedAt,
            mutationId: mutationId,
            protectUntil: now.addingTimeInterval(Self.goalModePendingProtection),
            expiresAt: now.addingTimeInterval(Self.goalModePendingTTL),
            sessionsConfirmed: false,
            detailConfirmed: false
        )
        return mutationId
    }

    private func updatePendingGoalModeAcknowledgement(
        windowId: String,
        mutationId: UUID,
        goalStartedAt: Double?
    ) {
        guard let pending = pendingGoalModeUpdates[windowId],
              pending.mutationId == mutationId else {
            return
        }
        pendingGoalModeUpdates[windowId] = KycodePendingGoalModeUpdate(
            enabled: pending.enabled,
            goalStartedAt: pending.enabled ? (goalStartedAt ?? pending.goalStartedAt) : nil,
            mutationId: pending.mutationId,
            protectUntil: pending.protectUntil,
            expiresAt: pending.expiresAt,
            sessionsConfirmed: pending.sessionsConfirmed,
            detailConfirmed: pending.detailConfirmed
        )
    }

    private func applyingPendingGoalModeUpdate(
        to item: KycodeSessionSummary,
        now: Date = Date()
    ) -> KycodeSessionSummary {
        guard let pending = pendingGoalModeUpdates[item.windowId],
              pending.expiresAt > now else {
            return item
        }
        return item.replacingRunMode(
            pending.enabled ? "goal" : "normal",
            goalStartedAt: pending.enabled ? pending.goalStartedAt : nil
        )
    }

    private func reconcilePendingGoalModeUpdate(
        with item: KycodeSessionSummary,
        now: Date,
        source: KycodePendingGoalModeSource
    ) -> KycodeSessionSummary {
        guard var pending = pendingGoalModeUpdates[item.windowId] else {
            return item
        }
        guard pending.expiresAt > now else {
            pendingGoalModeUpdates.removeValue(forKey: item.windowId)
            return item
        }

        if item.goalModeEnabled == pending.enabled {
            switch source {
            case .sessions:
                pending.sessionsConfirmed = true
            case .detail:
                pending.detailConfirmed = true
            }
        }

        if pending.sessionsConfirmed,
           pending.detailConfirmed,
           pending.protectUntil <= now {
            pendingGoalModeUpdates.removeValue(forKey: item.windowId)
            return item
        }

        pendingGoalModeUpdates[item.windowId] = pending
        return item.replacingRunMode(
            pending.enabled ? "goal" : "normal",
            goalStartedAt: pending.enabled ? pending.goalStartedAt : nil
        )
    }

    private func scheduleGoalModeReconciliation(windowId: String, mutationId: UUID) {
        Task { [weak self] in
            for delayMs in Self.goalModeReconcileDelayMilliseconds {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
                guard self?.pendingGoalModeUpdates[windowId]?.mutationId == mutationId else {
                    return
                }
                await self?.refreshSessionsNow()
                await self?.refreshDetail(windowId: windowId)
            }
        }
    }

    private func applyingPendingRenameUpdate(to item: KycodeSessionSummary) -> KycodeSessionSummary {
        guard let pending = pendingRenameUpdates[item.windowId],
              pending.expiresAt > Date(),
              item.displayName.trimmingCharacters(in: .whitespacesAndNewlines) != pending.name else {
            return item
        }
        return item.replacingWindowName(pending.name)
    }

    private func reconcilePendingRenameUpdate(
        with item: KycodeSessionSummary,
        now: Date = Date()
    ) -> KycodeSessionSummary {
        guard let pending = pendingRenameUpdates[item.windowId] else {
            return item
        }
        guard pending.expiresAt > now else {
            pendingRenameUpdates.removeValue(forKey: item.windowId)
            return item
        }

        let currentWindowName = item.windowName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDisplayName = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let didConfirm = currentWindowName == pending.name || currentDisplayName == pending.name
        if didConfirm, pending.protectUntil <= now {
            pendingRenameUpdates.removeValue(forKey: item.windowId)
            return item
        }
        return item.replacingWindowName(pending.name)
    }

    private func recordPendingCollaborationProjectUpdate(
        windowId: String,
        project: KycodeCollaborationProject
    ) {
        let now = Date()
        pendingCollaborationProjectUpdates[windowId] = KycodePendingCollaborationProjectUpdate(
            project: project,
            protectUntil: now.addingTimeInterval(Self.collaborationProjectPendingProtection),
            expiresAt: now.addingTimeInterval(Self.collaborationProjectPendingTTL)
        )
    }

    private func applyingPendingCollaborationProjectUpdate(
        to item: KycodeSessionSummary
    ) -> KycodeSessionSummary {
        guard let pending = pendingCollaborationProjectUpdates[item.windowId],
              pending.expiresAt > Date(),
              item.collaborationProjectId != pending.project.id else {
            return item
        }
        return item.replacingCollaborationProject(pending.project)
    }

    private func reconcilePendingCollaborationProjectUpdate(
        with item: KycodeSessionSummary,
        now: Date = Date()
    ) -> KycodeSessionSummary {
        guard let pending = pendingCollaborationProjectUpdates[item.windowId] else {
            return item
        }
        guard pending.expiresAt > now else {
            pendingCollaborationProjectUpdates.removeValue(forKey: item.windowId)
            return item
        }
        if item.collaborationProjectId == pending.project.id,
           pending.protectUntil <= now {
            pendingCollaborationProjectUpdates.removeValue(forKey: item.windowId)
            return item
        }
        return item.replacingCollaborationProject(pending.project)
    }

    @discardableResult
    private func recordPendingRuntimeSettingsUpdate(
        windowId: String,
        remoteWindowId: String,
        profileId: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        previousModel: String?,
        previousReasoningEffort: String?,
        persistsAcrossRelaunch: Bool
    ) -> UUID {
        let mutationId = UUID()
        pendingRuntimeSettingsUpdates = pendingRuntimeSettingsUpdates.filter { _, pending in
            pending.profileId != profileId || pending.remoteWindowId != remoteWindowId
        }
        pendingRuntimeSettingsUpdates[mutationId] = KycodePendingRuntimeSettingsUpdate(
            mutationId: mutationId,
            profileId: profileId,
            remoteWindowId: remoteWindowId,
            presentedWindowId: windowId,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            previousModel: previousModel,
            previousReasoningEffort: previousReasoningEffort,
            commandId: nil,
            phase: .awaitingAcknowledgement,
            persistsAcrossRelaunch: persistsAcrossRelaunch
        )
        return mutationId
    }

    private func bindPendingRuntimeSettingsCommand(
        mutationId: UUID,
        commandId: String?,
        requiresDurableContract: Bool
    ) {
        guard var pending = pendingRuntimeSettingsUpdates[mutationId] else { return }
        let normalizedCommandId = commandId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pending.commandId = normalizedCommandId?.isEmpty == false ? normalizedCommandId : nil
        pending.phase = requiresDurableContract ? .awaitingTerminal : .awaitingAuthority
        pendingRuntimeSettingsUpdates[mutationId] = pending
        persistPendingRuntimeSettingsUpdates()
    }

    @discardableResult
    private func updatePendingRuntimeSettingsAcknowledgement(
        mutationId: UUID,
        model: String,
        reasoningEffort: String
    ) -> Bool {
        guard var pending = pendingRuntimeSettingsUpdates[mutationId] else { return false }
        pending.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.reasoningEffort = reasoningEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        pendingRuntimeSettingsUpdates[mutationId] = pending
        persistPendingRuntimeSettingsUpdates()
        return true
    }

    private func applyingPendingRuntimeSettingsUpdate(
        to item: KycodeSessionSummary
    ) -> KycodeSessionSummary {
        guard let (_, pending) = pendingRuntimeSettingsUpdate(for: item) else {
            return item
        }
        return item.replacingRuntimeSettings(
            model: pending.model,
            reasoningEffort: pending.reasoningEffort
        )
    }

    private func reconcilePendingRuntimeSettingsUpdate(
        with item: KycodeSessionSummary,
        now _: Date
    ) -> KycodeSessionSummary {
        guard let (mutationId, originalPending) = pendingRuntimeSettingsUpdate(for: item) else {
            return item
        }
        var pending = originalPending
        if pending.presentedWindowId != item.windowId {
            pending.presentedWindowId = item.windowId
            pendingRuntimeSettingsUpdates[mutationId] = pending
            persistPendingRuntimeSettingsUpdates()
        }
        let authorityMatches =
            item.model?.caseInsensitiveCompare(pending.model) == .orderedSame &&
            item.reasoningEffort?.caseInsensitiveCompare(pending.reasoningEffort) == .orderedSame
        if authorityMatches, pending.phase == .awaitingAuthority {
            pendingRuntimeSettingsUpdates.removeValue(forKey: mutationId)
            persistPendingRuntimeSettingsUpdates()
            return item
        }
        return item.replacingRuntimeSettings(
            model: pending.model,
            reasoningEffort: pending.reasoningEffort
        )
    }

    private func pendingRuntimeSettingsUpdate(
        for item: KycodeSessionSummary
    ) -> (UUID, KycodePendingRuntimeSettingsUpdate)? {
        let sessionId = item.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionId.isEmpty,
           let match = pendingRuntimeSettingsUpdates.first(where: {
               $0.value.sessionId?.caseInsensitiveCompare(sessionId) == .orderedSame
           }) {
            return match
        }
        let route = sessionRoutes[item.windowId]
        let profileId = route?.profileId ?? selectedProfileId
        let remoteWindowId = route?.remoteWindowId ?? item.windowId
        return pendingRuntimeSettingsUpdates.first(where: {
            $0.value.profileId == profileId && $0.value.remoteWindowId == remoteWindowId
        })
    }

    private func pendingRuntimeSettingsUpdate(
        windowId: String,
        mutationId: UUID?
    ) -> (UUID, KycodePendingRuntimeSettingsUpdate)? {
        if let mutationId, let pending = pendingRuntimeSettingsUpdates[mutationId] {
            return (mutationId, pending)
        }
        if let match = pendingRuntimeSettingsUpdates.first(where: {
            $0.value.presentedWindowId == windowId
        }) {
            return match
        }
        let route = sessionRoutes[windowId]
        let profileId = route?.profileId ?? selectedProfileId
        let remoteWindowId = route?.remoteWindowId ?? windowId
        return pendingRuntimeSettingsUpdates.first(where: {
            $0.value.profileId == profileId && $0.value.remoteWindowId == remoteWindowId
        })
    }

    private func completePendingRuntimeSettingsUpdate(
        windowId: String,
        mutationId: UUID?
    ) {
        guard let (pendingId, originalPending) = pendingRuntimeSettingsUpdate(
            windowId: windowId,
            mutationId: mutationId
        ) else { return }
        var pending = originalPending
        pending.phase = .awaitingAuthority
        pendingRuntimeSettingsUpdates[pendingId] = pending
        persistPendingRuntimeSettingsUpdates()
    }

    private func rollbackPendingRuntimeSettingsUpdate(
        windowId: String,
        mutationId: UUID?,
        previousSummary: KycodeSessionSummary? = nil,
        previousDetail: KycodeSessionSummary? = nil
    ) {
        guard let (pendingId, pending) = pendingRuntimeSettingsUpdate(
            windowId: windowId,
            mutationId: mutationId
        ) else { return }
        pendingRuntimeSettingsUpdates.removeValue(forKey: pendingId)
        persistPendingRuntimeSettingsUpdates()

        if let previousSummary,
           let index = sessions.firstIndex(where: { $0.windowId == windowId }) {
            sessions[index] = previousSummary
        } else if let previousModel = pending.previousModel,
                  let previousReasoningEffort = pending.previousReasoningEffort {
            sessions = sessions.map { item in
                item.windowId == windowId
                    ? item.replacingRuntimeSettings(
                        model: previousModel,
                        reasoningEffort: previousReasoningEffort
                    )
                    : item
            }
        }
        if let previousDetail {
            sessionDetails[windowId] = previousDetail
        } else if let previousModel = pending.previousModel,
                  let previousReasoningEffort = pending.previousReasoningEffort,
                  let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingRuntimeSettings(
                model: previousModel,
                reasoningEffort: previousReasoningEffort
            )
        }
        persistCachedSessions(sessions, cachedAt: Date())
    }

    private func removePendingRuntimeSettingsUpdates(windowId: String) {
        let matchingIds = pendingRuntimeSettingsUpdates.compactMap { mutationId, pending in
            pending.presentedWindowId == windowId ? mutationId : nil
        }
        guard !matchingIds.isEmpty else { return }
        for mutationId in matchingIds {
            pendingRuntimeSettingsUpdates.removeValue(forKey: mutationId)
        }
        persistPendingRuntimeSettingsUpdates()
    }

    private func applyRuntimeSettingsOptimistically(
        windowId: String,
        model: String,
        reasoningEffort: String
    ) {
        sessions = sessions.map { item in
            item.windowId == windowId
                ? item.replacingRuntimeSettings(model: model, reasoningEffort: reasoningEffort)
                : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingRuntimeSettings(
                model: model,
                reasoningEffort: reasoningEffort
            )
        }
        persistCachedSessions(sessions, cachedAt: Date())
    }

    private func applyOptimisticRename(windowId: String, name: String) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        sessions = sessions.map { item in
            item.windowId == windowId ? item.replacingWindowName(name, updatedAt: nowMs) : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingWindowName(name, updatedAt: nowMs)
        }
    }

    private func applyRunModeOptimistically(
        windowId: String,
        runMode: String,
        goalStartedAt: Double?
    ) {
        sessions = sessions.map { item in
            item.windowId == windowId
                ? item.replacingRunMode(runMode, goalStartedAt: goalStartedAt)
                : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingRunMode(
                runMode,
                goalStartedAt: goalStartedAt
            )
        }
    }

    private func applyFeaturesOptimistically(windowId: String) {
        guard let pending = pendingFeatureUpdates[windowId] else { return }
        sessions = sessions.map { item in
            item.windowId == windowId
                ? item.replacingFeatures(featureValues(applying: pending, to: item))
                : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingFeatures(
                featureValues(applying: pending, to: detail)
            )
        }
    }

    private func rollbackPendingFeatureUpdate(windowId: String, mutationId: UUID?) {
        guard let pending = pendingFeatureUpdates[windowId],
              mutationId == nil || pending.mutationId == mutationId else {
            return
        }
        pendingFeatureUpdates.removeValue(forKey: windowId)
        let currentSessionId = sessionDetails[windowId]?.sessionId
            ?? sessions.first(where: { $0.windowId == windowId })?.sessionId
        guard featureRouteIsCurrent(windowId: windowId, pending: pending),
              pending.sessionId == nil || pending.sessionId == currentSessionId else {
            return
        }
        let summaryFeatures = pending.previousSummaryFeatures ?? pending.previousDetailFeatures
        let detailFeatures = pending.previousDetailFeatures ?? pending.previousSummaryFeatures
        sessions = sessions.map { item in
            item.windowId == windowId
                ? item.replacingFeatures(summaryFeatures)
                : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingFeatures(detailFeatures)
        }
    }

    private func rollbackGoalMode(
        windowId: String,
        previousSession: KycodeSessionSummary?,
        previousDetail: KycodeSessionSummary?
    ) {
        if let previousSession {
            sessions = sessions.map { item in
                item.windowId == windowId ? previousSession : item
            }
        }
        if let previousDetail {
            sessionDetails[windowId] = previousDetail
        } else {
            sessionDetails.removeValue(forKey: windowId)
        }
    }

    private func rollbackRename(
        windowId: String,
        previousSession: KycodeSessionSummary?,
        previousDetail: KycodeSessionSummary?
    ) {
        if let previousSession {
            sessions = sessions.map { item in
                item.windowId == windowId ? previousSession : item
            }
        }

        if let previousDetail {
            sessionDetails[windowId] = previousDetail
        } else {
            sessionDetails.removeValue(forKey: windowId)
        }
    }

    private func applyOptimisticCollaborationProject(
        windowId: String,
        project: KycodeCollaborationProject
    ) {
        sessions = sessions.map { item in
            item.windowId == windowId ? item.replacingCollaborationProject(project) : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingCollaborationProject(project)
        }
        persistCachedSessions(sessions, cachedAt: Date())
    }

    private func rollbackCollaborationProject(
        windowId: String,
        previousSession: KycodeSessionSummary?,
        previousDetail: KycodeSessionSummary?
    ) {
        if let previousSession {
            sessions = sessions.map { item in
                item.windowId == windowId ? previousSession : item
            }
        }
        if let previousDetail {
            sessionDetails[windowId] = previousDetail
        } else {
            sessionDetails.removeValue(forKey: windowId)
        }
    }

    private func scheduleRenameReconciliation(windowId: String) {
        Task { [weak self] in
            for delayMs in Self.renameReconcileDelayMilliseconds {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
                await self?.refreshSessionsNow()
                await self?.refreshDetail(windowId: windowId)
            }
        }
    }

    private func scheduleCollaborationProjectReconciliation(windowId: String) {
        Task { [weak self] in
            for delayMs in Self.collaborationProjectReconcileDelayMilliseconds {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
                await self?.refreshSessionsNow()
                await self?.refreshDetail(windowId: windowId)
            }
        }
    }

    private func applyOptimisticDeletion(windowId: String) {
        removePendingRuntimeSettingsUpdates(windowId: windowId)
        sessions.removeAll { $0.windowId == windowId }
        sessionDetails.removeValue(forKey: windowId)
        sessionDisplayOrder.removeAll { $0 == windowId }
        pendingMinimizedUpdates.removeValue(forKey: windowId)
        pendingRenameUpdates.removeValue(forKey: windowId)
        pendingCollaborationProjectUpdates.removeValue(forKey: windowId)
        pendingGoalModeUpdates.removeValue(forKey: windowId)
        pendingFeatureUpdates.removeValue(forKey: windowId)
        pendingOptimisticMessages.removeValue(forKey: windowId)
        liveMessagePatchCursorByKey = liveMessagePatchCursorByKey.filter {
            !$0.key.hasPrefix("\(windowId):")
        }
        messageReconciliationTasks[windowId]?.cancel()
        messageReconciliationTasks.removeValue(forKey: windowId)
        removePromptRetryIntents(windowId: windowId)
        persistCachedSessions(sessions, cachedAt: Date())
    }

    private func finalizeDeletedSessionLocalArtifacts(windowId: String, sessionId: String?) {
        recentCreatedSessions.removeAll {
            $0.windowId == windowId || (sessionId != nil && $0.sessionId == sessionId)
        }
        if currentVoiceDraft?.windowId == windowId, let draft = currentVoiceDraft {
            deleteVoiceDraft(draft)
        }
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.composerDraft.\(windowId)")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.savedMessages.\(windowId)")
        persistRecentCreatedSessions()
    }

    private func rollbackDeletion(
        windowId: String,
        previousSession: KycodeSessionSummary?,
        previousDetail: KycodeSessionSummary?,
        visibleIndex: Int?,
        displayIndex: Int?
    ) {
        if let previousSession, !sessions.contains(where: { $0.windowId == windowId }) {
            sessions.insert(previousSession, at: min(visibleIndex ?? sessions.count, sessions.count))
        }
        if let previousDetail {
            sessionDetails[windowId] = previousDetail
        }
        if !sessionDisplayOrder.contains(windowId) {
            sessionDisplayOrder.insert(
                windowId,
                at: min(displayIndex ?? sessionDisplayOrder.count, sessionDisplayOrder.count)
            )
        }
        persistCachedSessions(sessions, cachedAt: Date())
    }

    private func scheduleDeleteReconciliation() {
        Task { [weak self] in
            for delayMs in Self.deleteReconcileDelayMilliseconds {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
                await self?.refreshSessionsNow()
            }
        }
    }

    private func mergeDetail(_ existing: KycodeSessionSummary, with summary: KycodeSessionSummary) -> KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: summary.windowId,
            sessionId: summary.sessionId,
            engine: summary.engine,
            model: summary.model,
            reasoningEffort: summary.reasoningEffort,
            providerSessionId: summary.providerSessionId,
            providerSessionPath: summary.providerSessionPath,
            projectKey: summary.projectKey,
            projectPath: summary.projectPath,
            projectName: summary.projectName,
            windowName: summary.windowName,
            displayName: summary.displayName,
            sidecarMode: summary.sidecarMode,
            sidecarUrl: summary.sidecarUrl,
            activityStatus: summary.activityStatus,
            runtimeStatus: summary.runtimeStatus,
            runtimeStatusDetail: summary.runtimeStatusDetail,
            features: summary.features,
            runMode: summary.runMode,
            goalStartedAt: summary.goalStartedAt,
            messageCount: summary.messageCount,
            updatedAt: summary.updatedAt,
            createdAt: summary.createdAt,
            rawPrompt: summary.rawPrompt,
            originalPrompt: summary.originalPrompt,
            improvedPrompt: summary.improvedPrompt,
            lastMessagePreview: summary.lastMessagePreview,
            isMinimized: summary.isMinimized,
            canSend: summary.canSend,
            canControlFeatures: summary.canControlFeatures,
            unsupportedReason: summary.unsupportedReason,
            messages: existing.messages,
            pendingSubagent: summary.pendingSubagent ?? existing.pendingSubagent,
            collaborationProjectId: summary.collaborationProjectId ?? existing.collaborationProjectId,
            collaborationProjectName: summary.collaborationProjectName ?? existing.collaborationProjectName,
            sessionName: summary.sessionName ?? existing.sessionName,
            isPinned: summary.isPinned ?? existing.isPinned
        )
    }

    @discardableResult
    private func applyOptimisticSend(
        windowId: String,
        message: String,
        attachments: [KycodeImageAttachmentDraft],
        messageId: String? = nil,
        status: String = "sent",
        previewOverride: String? = nil
    ) -> KycodeMessage {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let optimisticAttachments = attachments.map { attachment in
            KycodeMessageImageAttachment(
                id: attachment.id,
                name: attachment.name,
                path: nil,
                size: attachment.size,
                mimeType: attachment.mimeType,
                previewData: attachment.data
            )
        }
        let preview = previewOverride ?? (message.isEmpty
            ? "\(attachments.count) \(attachments.count == 1 ? "imagen" : "imágenes")"
            : message)
        let optimisticMessage = KycodeMessage(
            id: messageId ?? "optimistic-\(UUID().uuidString)",
            role: "user",
            type: "text",
            content: message,
            originalPrompt: message,
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: nowMs,
            status: status,
            imageAttachments: optimisticAttachments.isEmpty ? nil : optimisticAttachments
        )
        pendingOptimisticMessages[windowId, default: []].append(
            KycodePendingOptimisticMessage(message: optimisticMessage)
        )

        if let detail = sessionDetails[windowId] ?? sessions.first(where: { $0.windowId == windowId }) {
            let nextMessages = (detail.messages ?? []) + [optimisticMessage]
            sessionDetails[windowId] = KycodeSessionSummary(
                windowId: detail.windowId,
                sessionId: detail.sessionId,
                engine: detail.engine,
                model: detail.model,
                reasoningEffort: detail.reasoningEffort,
                providerSessionId: detail.providerSessionId,
                providerSessionPath: detail.providerSessionPath,
                projectKey: detail.projectKey,
                projectPath: detail.projectPath,
                projectName: detail.projectName,
                windowName: detail.windowName,
                displayName: detail.displayName,
                sidecarMode: detail.sidecarMode,
                sidecarUrl: detail.sidecarUrl,
                activityStatus: "working",
                runtimeStatus: "WORKING",
                runtimeStatusDetail: detail.runtimeStatusDetail,
                features: detail.features,
                runMode: detail.runMode,
                goalStartedAt: detail.goalStartedAt,
                messageCount: max(detail.messageCount, nextMessages.count),
                updatedAt: nowMs,
                createdAt: detail.createdAt,
                rawPrompt: detail.rawPrompt ?? (message.isEmpty ? nil : message),
                originalPrompt: detail.originalPrompt ?? (message.isEmpty ? nil : message),
                improvedPrompt: detail.improvedPrompt,
                lastMessagePreview: preview,
                isMinimized: detail.isMinimized,
                canSend: detail.canSend,
                canControlFeatures: detail.canControlFeatures,
                unsupportedReason: detail.unsupportedReason,
                messages: nextMessages,
                pendingSubagent: detail.pendingSubagent,
                collaborationProjectId: detail.collaborationProjectId,
                collaborationProjectName: detail.collaborationProjectName,
                sessionName: detail.sessionName,
                isPinned: detail.isPinned
            )
        }

        sessions = sessions.map { item in
            guard item.windowId == windowId else { return item }
            return KycodeSessionSummary(
                windowId: item.windowId,
                sessionId: item.sessionId,
                engine: item.engine,
                model: item.model,
                reasoningEffort: item.reasoningEffort,
                providerSessionId: item.providerSessionId,
                providerSessionPath: item.providerSessionPath,
                projectKey: item.projectKey,
                projectPath: item.projectPath,
                projectName: item.projectName,
                windowName: item.windowName,
                displayName: item.displayName,
                sidecarMode: item.sidecarMode,
                sidecarUrl: item.sidecarUrl,
                activityStatus: "working",
                runtimeStatus: "WORKING",
                runtimeStatusDetail: item.runtimeStatusDetail,
                features: item.features,
                runMode: item.runMode,
                goalStartedAt: item.goalStartedAt,
                messageCount: item.messageCount + 1,
                updatedAt: nowMs,
                createdAt: item.createdAt,
                rawPrompt: item.rawPrompt ?? (message.isEmpty ? nil : message),
                originalPrompt: item.originalPrompt ?? (message.isEmpty ? nil : message),
                improvedPrompt: item.improvedPrompt,
                lastMessagePreview: preview,
                isMinimized: item.isMinimized,
                canSend: item.canSend,
                canControlFeatures: item.canControlFeatures,
                unsupportedReason: item.unsupportedReason,
                messages: item.messages,
                pendingSubagent: item.pendingSubagent,
                collaborationProjectId: item.collaborationProjectId,
                collaborationProjectName: item.collaborationProjectName,
                sessionName: item.sessionName,
                isPinned: item.isPinned
            )
        }
        return optimisticMessage
    }

    private func updateOptimisticMessage(
        windowId: String,
        messageId: String,
        content: String,
        status: String
    ) {
        if var pending = pendingOptimisticMessages[windowId],
           let index = pending.firstIndex(where: { $0.message.id == messageId }) {
            pending[index].message = pending[index].message.replacingVoiceContent(
                content,
                status: status
            )
            pendingOptimisticMessages[windowId] = pending
        }

        guard let detail = sessionDetails[windowId],
              let messages = detail.messages,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        var updatedMessages = messages
        updatedMessages[index] = updatedMessages[index].replacingVoiceContent(
            content,
            status: status
        )
        let nowMs = Date().timeIntervalSince1970 * 1000
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Transcribiendo audio…"
            : content
        sessionDetails[windowId] = KycodeSessionSummary(
            windowId: detail.windowId,
            sessionId: detail.sessionId,
            engine: detail.engine,
            model: detail.model,
            reasoningEffort: detail.reasoningEffort,
            providerSessionId: detail.providerSessionId,
            providerSessionPath: detail.providerSessionPath,
            projectKey: detail.projectKey,
            projectPath: detail.projectPath,
            projectName: detail.projectName,
            windowName: detail.windowName,
            displayName: detail.displayName,
            sidecarMode: detail.sidecarMode,
            sidecarUrl: detail.sidecarUrl,
            activityStatus: detail.activityStatus,
            runtimeStatus: detail.runtimeStatus,
            runtimeStatusDetail: detail.runtimeStatusDetail,
            features: detail.features,
            runMode: detail.runMode,
            goalStartedAt: detail.goalStartedAt,
            messageCount: detail.messageCount,
            updatedAt: nowMs,
            createdAt: detail.createdAt,
            rawPrompt: detail.rawPrompt,
            originalPrompt: detail.originalPrompt,
            improvedPrompt: detail.improvedPrompt,
            lastMessagePreview: preview,
            isMinimized: detail.isMinimized,
            canSend: detail.canSend,
            canControlFeatures: detail.canControlFeatures,
            unsupportedReason: detail.unsupportedReason,
            messages: updatedMessages,
            pendingSubagent: detail.pendingSubagent,
            collaborationProjectId: detail.collaborationProjectId,
            collaborationProjectName: detail.collaborationProjectName,
            sessionName: detail.sessionName,
            isPinned: detail.isPinned
        )
    }

    private func reconcileOptimisticMessages(
        with item: KycodeSessionSummary,
        authoritativeMessages: [KycodeMessage] = []
    ) -> KycodeSessionSummary {
        guard let pending = pendingOptimisticMessages[item.windowId], !pending.isEmpty else {
            return item
        }

        var messages = item.messages ?? []
        var consumedServerMessageIds = Set<String>()
        var unresolved: [KycodePendingOptimisticMessage] = []
        for entry in pending {
            let optimistic = entry.message
            let matchingServerMessage = KycodeOptimisticMessageReconciliationPolicy
                .matchingAuthoritativeMessage(
                    for: optimistic,
                    in: authoritativeMessages,
                    excluding: consumedServerMessageIds
                )
            let shouldResolve = KycodeOptimisticSendActivityPolicy.shouldResolvePendingMessage(
                hasMatchingServerMessage: matchingServerMessage != nil,
                hasAssistantResponse: false,
                activityStatus: item.activityStatus,
                runtimeStatus: item.runtimeStatus
            )
            if shouldResolve {
                if let matchingServerMessage {
                    consumedServerMessageIds.insert(matchingServerMessage.id)
                }
            } else {
                unresolved.append(entry)
                if matchingServerMessage == nil,
                   !messages.contains(where: { $0.id == optimistic.id }) {
                    messages.append(optimistic)
                }
            }
        }

        if unresolved.isEmpty {
            pendingOptimisticMessages.removeValue(forKey: item.windowId)
            return item
        }
        pendingOptimisticMessages[item.windowId] = unresolved
        let latestOptimistic = unresolved.last?.message
        return KycodeSessionSummary(
            windowId: item.windowId,
            sessionId: item.sessionId,
            engine: item.engine,
            model: item.model,
            reasoningEffort: item.reasoningEffort,
            providerSessionId: item.providerSessionId,
            providerSessionPath: item.providerSessionPath,
            projectKey: item.projectKey,
            projectPath: item.projectPath,
            projectName: item.projectName,
            windowName: item.windowName,
            displayName: item.displayName,
            sidecarMode: item.sidecarMode,
            sidecarUrl: item.sidecarUrl,
            activityStatus: "working",
            runtimeStatus: "WORKING",
            runtimeStatusDetail: item.runtimeStatusDetail,
            features: item.features,
            runMode: item.runMode,
            goalStartedAt: item.goalStartedAt,
            messageCount: max(item.messageCount, messages.count),
            updatedAt: max(item.updatedAt, latestOptimistic?.timestamp ?? item.updatedAt),
            createdAt: item.createdAt,
            rawPrompt: item.rawPrompt ?? latestOptimistic?.content,
            originalPrompt: item.originalPrompt ?? latestOptimistic?.content,
            improvedPrompt: item.improvedPrompt,
            lastMessagePreview: latestOptimistic?.content ?? item.lastMessagePreview,
            isMinimized: item.isMinimized,
            canSend: item.canSend,
            canControlFeatures: item.canControlFeatures,
            unsupportedReason: item.unsupportedReason,
            messages: messages,
            pendingSubagent: item.pendingSubagent,
            collaborationProjectId: item.collaborationProjectId,
            collaborationProjectName: item.collaborationProjectName,
            sessionName: item.sessionName,
            isPinned: item.isPinned
        )
    }

    private func removeOptimisticSend(windowId: String, messageId: String) {
        if var pending = pendingOptimisticMessages[windowId] {
            pending.removeAll { $0.message.id == messageId }
            if pending.isEmpty {
                pendingOptimisticMessages.removeValue(forKey: windowId)
            } else {
                pendingOptimisticMessages[windowId] = pending
            }
        }
        guard let detail = sessionDetails[windowId],
              let messages = detail.messages,
              messages.contains(where: { $0.id == messageId }) else {
            return
        }
        let nextMessages = messages.filter { $0.id != messageId }
        sessionDetails[windowId] = KycodeSessionSummary(
            windowId: detail.windowId,
            sessionId: detail.sessionId,
            engine: detail.engine,
            model: detail.model,
            reasoningEffort: detail.reasoningEffort,
            providerSessionId: detail.providerSessionId,
            providerSessionPath: detail.providerSessionPath,
            projectKey: detail.projectKey,
            projectPath: detail.projectPath,
            projectName: detail.projectName,
            windowName: detail.windowName,
            displayName: detail.displayName,
            sidecarMode: detail.sidecarMode,
            sidecarUrl: detail.sidecarUrl,
            activityStatus: detail.activityStatus,
            runtimeStatus: detail.runtimeStatus,
            runtimeStatusDetail: detail.runtimeStatusDetail,
            features: detail.features,
            runMode: detail.runMode,
            goalStartedAt: detail.goalStartedAt,
            messageCount: max(0, detail.messageCount - 1),
            updatedAt: detail.updatedAt,
            createdAt: detail.createdAt,
            rawPrompt: detail.rawPrompt,
            originalPrompt: detail.originalPrompt,
            improvedPrompt: detail.improvedPrompt,
            lastMessagePreview: nextMessages.last?.content,
            isMinimized: detail.isMinimized,
            canSend: detail.canSend,
            canControlFeatures: detail.canControlFeatures,
            unsupportedReason: detail.unsupportedReason,
            messages: nextMessages,
            pendingSubagent: detail.pendingSubagent,
            collaborationProjectId: detail.collaborationProjectId,
            collaborationProjectName: detail.collaborationProjectName,
            sessionName: detail.sessionName,
            isPinned: detail.isPinned
        )
    }

    private func scheduleMessageReconciliation(windowId: String) {
        messageReconciliationTasks[windowId]?.cancel()
        messageReconciliationTasks[windowId] = Task { [weak self] in
            guard let self else { return }

            for delayMilliseconds in KycodeMessageReconciliationPolicy.retryDelayMilliseconds {
                await self.messageReconciliationSleep(.milliseconds(delayMilliseconds))
                guard !Task.isCancelled else { return }

                await self.refreshDetail(windowId: windowId)
                guard !Task.isCancelled else { return }

                let detail = self.sessionDetails[windowId]
                let hasPendingOptimisticMessage =
                    !(self.pendingOptimisticMessages[windowId]?.isEmpty ?? true)
                let hasPendingPromptRetry = self.reconcilePromptRetryIntents(windowId: windowId)
                let shouldContinue = KycodeMessageReconciliationPolicy.shouldContinue(
                    hasPendingOptimisticMessage: hasPendingOptimisticMessage,
                    hasPendingPromptTransform: KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(
                        in: detail?.messages,
                        sessionImprovedPrompt: detail?.improvedPrompt
                    ),
                    activityStatus: detail?.activityStatus,
                    runtimeStatus: detail?.runtimeStatus,
                    hasPendingPromptRetry: hasPendingPromptRetry
                )
                if !shouldContinue {
                    self.log("Envio reconciliado window=\(windowId)")
                    self.messageReconciliationTasks.removeValue(forKey: windowId)
                    return
                }
            }

            guard !Task.isCancelled else { return }
            self.log("Envio reconciliation timeout window=\(windowId)")
            self.recordPromptTransformTimeouts(windowId: windowId)
            self.removePromptRetryIntents(windowId: windowId)
            self.messageReconciliationTasks.removeValue(forKey: windowId)
        }
    }

    private func applyOptimisticMinimized(windowId: String, minimized: Bool) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        sessions = sessions.map { item in
            item.windowId == windowId ? item.replacingMinimized(minimized, updatedAt: nowMs) : item
        }
        if let detail = sessionDetails[windowId] {
            sessionDetails[windowId] = detail.replacingMinimized(minimized, updatedAt: nowMs)
        }
    }

    private func rollbackMinimizedUpdate(
        windowId: String,
        previousSession: KycodeSessionSummary?,
        previousDetail: KycodeSessionSummary?
    ) {
        guard let previousMinimized = (previousDetail ?? previousSession)?.minimized else { return }
        // Restore only the field owned by this mutation. Other session state
        // may legitimately have changed while the durable command was pending.
        applyOptimisticMinimized(windowId: windowId, minimized: previousMinimized)
    }

    private func fetchSessions(
        _ credentials: KycodeConnectionCredentials,
        timeout: TimeInterval? = nil
    ) async throws -> KycodeSessionsEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions",
            method: "GET",
            body: nil,
            timeout: timeout
        )
        return try await perform(request, decode: KycodeSessionsEnvelope.self)
    }

    private func fetchSessionHistory(
        _ credentials: KycodeConnectionCredentials,
        query: KycodeSessionHistoryQuery,
        profileId: String
    ) async throws -> KycodeSessionHistoryEnvelope {
        var components = URLComponents()
        components.queryItems = query.queryItems()
        let queryString = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let representationKey = "/api/mobile/session-history\(queryString)"
        var request = try makeRequest(
            credentials: credentials,
            path: representationKey,
            method: "GET",
            body: nil,
            timeout: Self.sessionHistoryRequestTimeout
        )
        KycodeSessionHistoryHTTPResponse.applyValidator(
            to: &request,
            profileId: profileId,
            representationKey: representationKey
        )
        requestObserver?(request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let statusCode = httpResponse.statusCode
        let responseETag = httpResponse.value(forHTTPHeaderField: "ETag")
        return try await Task.detached(priority: .userInitiated) {
            try KycodeSessionHistoryHTTPResponse.resolve(
                statusCode: statusCode,
                data: data,
                etag: responseETag,
                profileId: profileId,
                representationKey: representationKey
            )
        }.value
    }

    private func postResumeSessionHistoryItem(
        _ credentials: KycodeConnectionCredentials,
        id: String
    ) async throws -> KycodeSessionHistoryResumeEnvelope {
        let body = try JSONEncoder().encode(["id": id])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/session-history/resume",
            method: "POST",
            body: body,
            timeout: Self.sessionHistoryRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeSessionHistoryResumeEnvelope.self)
    }

    private func postPromptTransformRetry(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        messageId: String
    ) async throws -> KycodePromptTransformRetryEnvelope {
        let body = try JSONEncoder().encode(["messageId": messageId])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/messages/\(kycodeEncodedPathComponent(messageId))/retry-prompt-transform",
            method: "POST",
            body: body,
            timeout: Self.promptTransformRetryRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodePromptTransformRetryEnvelope.self)
    }

    private func fetchProjects(_ credentials: KycodeConnectionCredentials) async throws -> KycodeProjectDirectoryEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/projects",
            method: "GET",
            body: nil
        )
        return try await perform(request, decode: KycodeProjectDirectoryEnvelope.self)
    }

    private func fetchDetail(_ credentials: KycodeConnectionCredentials, windowId: String) async throws -> KycodeSessionDetailEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))",
            method: "GET",
            body: nil
        )
        return try await perform(request, decode: KycodeSessionDetailEnvelope.self)
    }

    private func postCreateSession(
        _ credentials: KycodeConnectionCredentials,
        projectPath: String,
        sessionId: String,
        sessionName: String
    ) async throws -> KycodeCreateSessionEnvelope {
        var parameters = [
            "projectPath": projectPath,
            "sessionId": sessionId,
            "sessionName": sessionName,
            "model": Self.newSessionDefaultModel,
            "reasoningEffort": Self.newSessionDefaultReasoningEffort
        ]
        #if DEBUG
        // Live UI checks must never spend tokens on the user's normal model.
        let environment = ProcessInfo.processInfo.environment
        if environment["KYCODE_UI_TEST_LIVE_PERSONAL"] == "1" || environment["KYCODE_UI_TEST_LIVE_PUKY"] == "1" {
            parameters["model"] = "gpt-5.6-luna"
            parameters["reasoningEffort"] = "low"
        }
        #endif
        let body = try JSONEncoder().encode(parameters)
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions",
            method: "POST",
            body: body
        )
        return try await perform(request, decode: KycodeCreateSessionEnvelope.self)
    }

    private func postImageAttachment(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        attachment: KycodeImageAttachmentDraft
    ) async throws -> KycodeImageUploadEnvelope {
        let boundary = "KycodeBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        let safeName = attachment.name.replacingOccurrences(of: "\"", with: "")
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"image\"; filename=\"\(safeName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/attachments",
            method: "POST",
            body: body,
            timeout: Self.imageUploadRequestTimeout
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        requestObserver?(request)
        return try await perform(request, decode: KycodeImageUploadEnvelope.self)
    }

    private func postMessage(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        message: String,
        clientMessageId: String? = nil,
        attachments: [KycodeMessageAttachmentPayload],
        timeout: TimeInterval? = nil,
        parentNotificationPrompt: String? = nil
    ) async throws -> KycodeSendEnvelope {
        let body = try JSONEncoder().encode(
            KycodeMessagePayload(
                message: message,
                clientMessageId: clientMessageId,
                attachments: attachments,
                fastModeEnabled: fastModeEnabled,
                parentNotificationPrompt: parentNotificationPrompt
            )
        )
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/message",
            method: "POST",
            body: body,
            timeout: timeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeSendEnvelope.self)
    }

    func fetchAttachmentData(path: String, windowId: String? = nil) async throws -> Data {
        let credentials: KycodeConnectionCredentials?
        if let windowId {
            credentials = routedTarget(for: windowId)?.credentials
        } else {
            credentials = activeCredentials ?? draftCredentials
        }
        guard let credentials else {
            throw NSError(
                domain: "KycodeMobile",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "La Mac de origen no está conectada."]
            )
        }
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.remove(charactersIn: "&+=?#")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? path
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/attachments/content?path=\(encodedPath)",
            method: "GET",
            body: nil,
            timeout: Self.sendRequestTimeout
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "KycodeMobile",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo cargar la imagen."]
            )
        }
        return data
    }

    func fetchFilePreview(path: String, windowId: String? = nil) async throws -> KycodeFilePreview {
        let credentials: KycodeConnectionCredentials?
        if let windowId {
            credentials = routedTarget(for: windowId)?.credentials
        } else {
            credentials = activeCredentials ?? draftCredentials
        }
        guard let credentials else {
            throw NSError(
                domain: "KycodeMobile",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "La Mac de origen no está conectada."]
            )
        }
        let body = try JSONEncoder().encode(["path": path])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/file-preview",
            method: "POST",
            body: body,
            timeout: 8
        )
        requestObserver?(request)
        do {
            return try await perform(request, decode: KycodeFilePreview.self)
        } catch {
            guard KycodeLegacyFilePreviewPolicy.shouldFallback(after: error) else {
                throw error
            }
        }

        // Puky can temporarily lag behind Esta Mac while its read-only runtime
        // is being updated. Older bridges expose the same authenticated file
        // read through this endpoint, so keep document links usable without
        // weakening auth or changing the server. The modern endpoint remains
        // authoritative and real 404s never fall through to the legacy path.
        let legacyRequest = try makeRequest(
            credentials: credentials,
            path: "/api/files/read-text",
            method: "POST",
            body: body,
            timeout: 8
        )
        requestObserver?(legacyRequest)
        let legacy = try await perform(
            legacyRequest,
            decode: KycodeLegacyFilePreviewEnvelope.self
        )
        guard legacy.ok else {
            throw NSError(
                domain: "KycodeMobile",
                code: 502,
                userInfo: [NSLocalizedDescriptionKey: "La Mac no pudo preparar el archivo."]
            )
        }

        let sizeBytes = legacy.content.utf8.count
        guard sizeBytes <= KycodeLegacyFilePreviewPolicy.maximumBytes else {
            throw NSError(
                domain: "KycodeMobile",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "El archivo supera el límite de 10 MB."]
            )
        }

        let resolvedPath = legacy.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? path
            : legacy.path
        let type = KycodeFileTypeDetector.detect(path: resolvedPath)
        return KycodeFilePreview(
            path: resolvedPath,
            name: URL(fileURLWithPath: resolvedPath).lastPathComponent,
            content: legacy.content,
            kind: type.kind,
            language: type.language,
            sizeBytes: sizeBytes
        )
    }

    private func postMinimized(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        minimized: Bool
    ) async throws -> KycodeMinimizedEnvelope {
        let body = try JSONEncoder().encode(["minimized": minimized])
        let endpoint = minimized ? "minimize" : "restore"
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/\(endpoint)",
            method: "POST",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        return try await perform(request, decode: KycodeMinimizedEnvelope.self)
    }

    private func postRename(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        name: String
    ) async throws -> KycodeRenameEnvelope {
        let body = try JSONEncoder().encode(["name": name])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/rename",
            method: "POST",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        return try await perform(request, decode: KycodeRenameEnvelope.self)
    }

    private func getCollaborationProjects(
        _ credentials: KycodeConnectionCredentials,
        timeout: TimeInterval? = nil
    ) async throws -> KycodeCollaborationProjectsEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/collaboration-projects",
            method: "GET",
            body: nil,
            timeout: timeout ?? Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeCollaborationProjectsEnvelope.self)
    }

    private func postCollaborationProject(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        projectId: String,
        projectName: String
    ) async throws -> KycodeCollaborationProjectAssignmentEnvelope {
        let body = try JSONEncoder().encode([
            "projectId": projectId,
            "projectName": projectName,
        ])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/collaboration-project",
            method: "PUT",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(
            request,
            decode: KycodeCollaborationProjectAssignmentEnvelope.self
        )
    }

    private func postGoalMode(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        enabled: Bool
    ) async throws -> KycodeRunModeEnvelope {
        let body = try JSONEncoder().encode(["goalEnabled": enabled])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/run-mode",
            method: "POST",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeRunModeEnvelope.self)
    }

    private func postDelete(
        _ credentials: KycodeConnectionCredentials,
        windowId: String
    ) async throws -> KycodeWindowCommandEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/permanent",
            method: "DELETE",
            body: nil,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeWindowCommandEnvelope.self)
    }

    private func postCreateSubagent(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        message: String,
        sessionId: String,
        engine: KycodeAgentEngine?
    ) async throws -> KycodeCreateSubagentEnvelope {
        let payload: [String: Any] = [
            "message": message,
            "sessionId": sessionId,
            "engine": engine?.rawValue as Any? ?? NSNull()
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/create-subagent",
            method: "POST",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        return try await perform(request, decode: KycodeCreateSubagentEnvelope.self)
    }

    private func postFeatures(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        promptImproverEnabled: Bool,
        explainerEnabled: Bool,
        codeContextEnabled: Bool?
    ) async throws -> KycodeFeaturesEnvelope {
        var payload: [String: Any] = [
            "promptImproverEnabled": promptImproverEnabled,
            "explainerEnabled": explainerEnabled,
        ]
        if let codeContextEnabled {
            payload["codeContextEnabled"] = codeContextEnabled
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/features",
            method: "POST",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeFeaturesEnvelope.self)
    }

    private func fetchModelCatalog(
        _ credentials: KycodeConnectionCredentials,
        windowId: String
    ) async throws -> KycodeModelCatalogEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/models",
            method: "GET",
            body: nil,
            timeout: Self.modelCommandRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeModelCatalogEnvelope.self)
    }

    private func postRuntimeModelSettings(
        _ credentials: KycodeConnectionCredentials,
        windowId: String,
        model: String,
        reasoningEffort: String
    ) async throws -> KycodeModelSettingsEnvelope {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "model": model,
                "reasoningEffort": reasoningEffort,
            ],
            options: []
        )
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/sessions/\(kycodeEncodedPathComponent(windowId))/model-settings",
            method: "POST",
            body: body,
            timeout: Self.modelCommandRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodeModelSettingsEnvelope.self)
    }

    private var promptImproverExpectedProfileIds: [String] {
        selectedProfileUsesAll
            ? [Self.pukyProfileId, Self.personalProfileId]
            : [selectedProfileId]
    }

    private var promptImproverPreferenceTargets: [KycodePromptImproverVariantTarget] {
        let candidates: [KycodePromptImproverVariantTarget]
        if selectedProfileUsesAll {
            candidates = allSourceCredentials
                .sorted(by: { $0.key < $1.key })
                .map {
                    KycodePromptImproverVariantTarget(
                        profileId: $0.key,
                        credentials: $0.value
                    )
                }
        } else if let credentials = activeCredentials ?? draftCredentials {
            candidates = [
                KycodePromptImproverVariantTarget(
                    profileId: selectedProfileId,
                    credentials: credentials
                ),
            ]
        } else {
            candidates = []
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.credentials.baseURL).inserted }
    }

    private func ownsPromptImproverVariantRoute(
        profileId: String,
        connectionGeneration: UInt64,
        targets: [KycodePromptImproverVariantTarget]
    ) -> Bool {
        guard selectedProfileId == profileId,
              connectionStateGeneration == connectionGeneration else {
            return false
        }
        if selectedProfileUsesAll {
            return targets.allSatisfy {
                allSourceCredentials[$0.profileId] == $0.credentials
            }
        }
        guard targets.count <= 1 else { return false }
        return targets.first.map {
            (activeCredentials ?? draftCredentials) == $0.credentials
        } ?? true
    }

    private func fetchPromptImproverPreference(
        _ credentials: KycodeConnectionCredentials
    ) async throws -> KycodePromptImproverPreferenceEnvelope {
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/preferences/prompt-improver",
            method: "GET",
            body: nil,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodePromptImproverPreferenceEnvelope.self)
    }

    private func postPromptImproverPreference(
        _ credentials: KycodeConnectionCredentials,
        variant: KycodePromptImproverVariant
    ) async throws -> KycodePromptImproverPreferenceEnvelope {
        let body = try JSONEncoder().encode(["variant": variant.rawValue])
        let request = try makeRequest(
            credentials: credentials,
            path: "/api/mobile/preferences/prompt-improver",
            method: "PUT",
            body: body,
            timeout: Self.sendRequestTimeout
        )
        requestObserver?(request)
        return try await perform(request, decode: KycodePromptImproverPreferenceEnvelope.self)
    }

    private func makeRequest(
        credentials: KycodeConnectionCredentials,
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: credentials.baseURL + path) else {
            throw NSError(domain: "KycodeMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL inválida."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let requestPath = request.url?.path ?? ""
        if requestPath.hasSuffix("/attachments") || requestPath.hasSuffix("/message") {
            log(
                "HTTP envio method=\(request.httpMethod ?? "?") path=\(requestPath) "
                    + "status=\(httpResponse.statusCode) responseBytes=\(data.count)"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverError: String
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let jsonObject,
               let errorText = jsonObject["error"] as? String,
               !errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                serverError = errorText
            } else {
                serverError = String(data: data, encoding: .utf8) ?? "Error del servidor."
            }
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: serverError]
            if let serverCode = jsonObject?["code"] as? String,
               !serverCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userInfo[KycodeSessionRefreshErrorPolicy.serverErrorCodeUserInfoKey] = serverCode
            }
            throw NSError(
                domain: "KycodeMobile",
                code: httpResponse.statusCode,
                userInfo: userInfo
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validateSnapshotFreshness(
        _ snapshot: KycodeSessionsEnvelope,
        for credentials: KycodeConnectionCredentials
    ) throws {
        guard isCanonicalFerminRelayCredentials(credentials) else { return }

        let timestampMs = snapshot.now ?? snapshot.exportedAt
        guard let timestampMs, timestampMs > 0 else {
            throw NSError(
                domain: "KycodeMobile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Fermín Code no informó cuándo se actualizó el estado de tu Mac."]
            )
        }

        let snapshotDate = Date(timeIntervalSince1970: timestampMs / 1000)
        let age = Date().timeIntervalSince(snapshotDate)
        guard age <= Self.remoteHubSnapshotMaxAge else {
            throw NSError(
                domain: "KycodeMobile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Mi Mac (remota) está conectada a Fermín Code, pero el estado tiene \(Int(age))s de atraso. Revisá que el motor de esta Mac esté corriendo."]
            )
        }
    }

    private func presentableConnectionError(_ error: Error, for credentials: KycodeConnectionCredentials) -> String {
        let nsError = error as NSError
        let raw = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.lowercased()

        if isCanonicalFerminRelayCredentials(credentials), normalized == "invalid token" {
            return "El token de Mi Mac (remota) no coincide con el relay actual. Copiá de nuevo el token desde esta Mac y volvé a conectar."
        }

        if isCanonicalFerminRelayCredentials(credentials), nsError.code == 404 {
            return "El relay de Fermín Code no soporta todavía crear sub-agentes. Actualizá el motor y el relay de esta Mac."
        }

        if normalized == "not found" {
            return "No encontré el endpoint remoto. Revisá la URL o el hub."
        }

        return raw.isEmpty ? "No pude conectarme." : raw
    }

    private func waitForCreatedSession(
        sessionId: String,
        credentials: KycodeConnectionCredentials,
        expectedEngine: KycodeAgentEngine? = nil,
        profileId: String? = nil,
        expectedSessionName: String? = nil,
        confirmationTimeout: TimeInterval? = nil,
        pollDelay: Duration = .milliseconds(500)
    ) async -> KycodeSessionSummary? {
        guard let historyEntry = recentCreatedSessions.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedAttemptGeneration = sourceSnapshotAttemptGeneration
        let expectedSelectedProfileId = selectedProfileId

        let startedAt = createSessionPollNow()
        let resolvedConfirmationTimeout = confirmationTimeout ?? createSessionConfirmationTimeout
        var attempt = 0
        while !Task.isCancelled {
            guard ownsAsyncSnapshotMutation(
                connectionGeneration: expectedConnectionGeneration,
                attemptGeneration: expectedAttemptGeneration,
                selectedProfileId: expectedSelectedProfileId,
                credentials: credentials,
                sourceProfileId: profileId
            ) else {
                return nil
            }
            attempt += 1

            if !selectedProfileUsesAll,
               let created = matchedCreatedSession(for: historyEntry, in: sessions),
               createdSessionMatchesExpectations(
                   created,
                   expectedEngine: expectedEngine,
                   expectedSessionName: expectedSessionName,
                   attempt: attempt
               ) {
                return created
            }

            do {
                let snapshot = try await fetchSessions(credentials, timeout: Self.sendRequestTimeout)
                guard !Task.isCancelled else { return nil }
                guard ownsAsyncSnapshotMutation(
                    connectionGeneration: expectedConnectionGeneration,
                    attemptGeneration: expectedAttemptGeneration,
                    selectedProfileId: expectedSelectedProfileId,
                    credentials: credentials,
                    sourceProfileId: profileId
                ) else {
                    return nil
                }
                try validateSnapshotFreshness(snapshot, for: credentials)
                if let profileId,
                   selectedProfileUsesAll,
                   let profile = profiles.first(where: { $0.id == profileId }) {
                    allSourceCredentials[profileId] = credentials
                    allSourceSnapshots[profileId] = snapshot
                    updateSourceState(
                        profile: profile,
                        isLoading: false,
                        isConnected: true,
                        sessionCount: snapshot.items.count,
                        connectionLabel: sourceConnectionStates.first(where: { $0.id == profileId })?.connectionLabel,
                        errorMessage: nil,
                        snapshotPhase: .succeeded,
                        attemptGeneration: sourceConnectionStates.first(where: { $0.id == profileId })?.attemptGeneration
                            ?? sourceSnapshotAttemptGeneration,
                        hasRetainedSnapshot: true
                    )
                    rebuildAllSessions()
                } else {
                    clearConnectionIssueState(cancelReconnectTask: false)
                    applySessions(snapshot)
                    isConnected = true
                }
                if let created = matchedCreatedSession(for: historyEntry, in: snapshot.items) {
                    if createdSessionMatchesExpectations(
                        created,
                        expectedEngine: expectedEngine,
                        expectedSessionName: expectedSessionName,
                        attempt: attempt
                    ) {
                        log(
                            "Create poll success attempt=\(attempt) sessionId=\(created.sessionId) " +
                            "windowId=\(created.windowId) project=\(created.projectPath ?? "-")"
                        )
                        if let profileId, selectedProfileUsesAll {
                            return created.replacingWindowId(
                                presentedWindowId(profileId: profileId, remoteWindowId: created.windowId)
                            )
                        }
                        return created
                    }
                }
                let visibleIds = snapshot.items.prefix(4).map(\.sessionId).joined(separator: ",")
                log("Create poll miss attempt=\(attempt) target=\(sessionId) visible=[\(visibleIds)]")
            } catch {
                log("No pude confirmar la nueva sesion \(sessionId) en intento \(attempt): \(describe(error))")
            }

            if recentCreatedSessions.first(where: { $0.sessionId == sessionId })?.status == "failed" {
                return nil
            }
            guard createSessionPollNow() - startedAt < resolvedConfirmationTimeout else {
                break
            }
            await createSessionPollSleep(pollDelay)
        }
        return nil
    }

    private func scheduleCreatedSessionReconciliation(
        sessionId: String,
        credentials: KycodeConnectionCredentials,
        expectedSessionName: String?
    ) {
        guard automaticallyReconcilesCreatedSessions,
              createdSessionReconciliationTasks[sessionId] == nil else { return }
        createdSessionReconciliationTasks[sessionId] = Task { [weak self] in
            guard let self else { return }
            let summary = await self.waitForCreatedSession(
                sessionId: sessionId,
                credentials: credentials,
                expectedSessionName: expectedSessionName,
                confirmationTimeout: self.createSessionConfirmationTimeout,
                pollDelay: Self.createSessionBackgroundPollDelay
            )
            guard !Task.isCancelled else { return }
            if let summary {
                self.removeRecentCreatedSession(sessionId: sessionId)
                self.log(
                    "Create session reconciled in background sessionId=\(summary.sessionId) " +
                    "windowId=\(summary.windowId)"
                )
            } else if self.recentCreatedSessions.contains(where: { $0.sessionId == sessionId }) {
                self.markRecentCreatedSessionStatus(sessionId: sessionId, status: "delayed")
            }
            self.createdSessionReconciliationTasks.removeValue(forKey: sessionId)
        }
    }

    private func resumeCreatedSessionReconciliations(
        credentials: KycodeConnectionCredentials
    ) {
        guard automaticallyReconcilesCreatedSessions else { return }
        for entry in recentCreatedSessions where
            entry.profileId == nil || entry.profileId == selectedProfileId {
            scheduleCreatedSessionReconciliation(
                sessionId: entry.sessionId,
                credentials: credentials,
                expectedSessionName: entry.sessionName
            )
        }
    }

    private func createdSessionMatchesExpectations(
        _ created: KycodeSessionSummary,
        expectedEngine: KycodeAgentEngine?,
        expectedSessionName: String?,
        attempt: Int
    ) -> Bool {
        if let expectedEngine, created.agentEngine != expectedEngine {
            log(
                "Create poll engine mismatch attempt=\(attempt) sessionId=\(created.sessionId) " +
                "expected=\(expectedEngine.rawValue) actual=\(created.engine ?? "missing")"
            )
            return false
        }
        if let expectedSessionName {
            let visibleName = KycodeSessionNameRules.normalized(created.windowName ?? created.displayName)
            if visibleName != expectedSessionName {
                log("Create poll name pending attempt=\(attempt) sessionId=\(created.sessionId)")
                return false
            }
        }
        return true
    }

    private func syncRecentCreatedSessions(with items: [KycodeSessionSummary]) {
        guard !recentCreatedSessions.isEmpty else { return }

        let now = Date()
        let next = recentCreatedSessions.compactMap { entry -> KycodeRecentCreatedSession? in
            if matchedCreatedSession(for: entry, in: items) != nil {
                return nil
            }

            if entry.status == "creating",
               now.timeIntervalSince(entry.createdAt) > Self.createSessionPendingTransitionTimeout {
                var stale = entry
                stale.status = "pending"
                return stale
            }

            return entry
        }

        let pruned = Self.prunedRecentCreatedSessions(next, now: now)
        if pruned != recentCreatedSessions {
            recentCreatedSessions = pruned
            persistRecentCreatedSessions()
        }
    }

    private func matchedCreatedSession(
        for entry: KycodeRecentCreatedSession,
        in items: [KycodeSessionSummary]
    ) -> KycodeSessionSummary? {
        if let direct = items.first(where: { $0.sessionId == entry.sessionId }) {
            return direct
        }

        let createdAtMs = entry.createdAt.timeIntervalSince1970 * 1000
        let candidates = items
            .filter { item in
                guard item.projectPath == entry.projectPath else { return false }
                guard let itemCreatedAt = item.createdAt else { return false }
                return abs(itemCreatedAt - createdAtMs) <= 15_000
            }
            .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }

        return candidates.first
    }

    private func upsertRecentCreatedSession(_ entry: KycodeRecentCreatedSession) {
        var next = recentCreatedSessions.filter { $0.sessionId != entry.sessionId }
        next.insert(entry, at: 0)
        recentCreatedSessions = Self.prunedRecentCreatedSessions(Array(next.prefix(4)), now: Date())
        persistRecentCreatedSessions()
    }

    private func markRecentCreatedSessionStatus(sessionId: String, status: String) {
        guard let index = recentCreatedSessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return
        }
        recentCreatedSessions[index].status = status
        persistRecentCreatedSessions()
    }

    private func removeRecentCreatedSession(sessionId: String) {
        let next = recentCreatedSessions.filter { $0.sessionId != sessionId }
        guard next != recentCreatedSessions else { return }
        recentCreatedSessions = next
        persistRecentCreatedSessions()
    }

    private func persistRecentCreatedSessions() {
        do {
            recentCreatedSessions = Self.prunedRecentCreatedSessions(recentCreatedSessions, now: Date())
            let data = try JSONEncoder().encode(recentCreatedSessions)
            UserDefaults.standard.set(data, forKey: Self.recentCreatedSessionsDefaultsKey)
        } catch {
            log("No pude persistir recentCreatedSessions: \(describe(error))")
        }
    }

    private static func loadRecentCreatedSessions(from defaults: UserDefaults) -> [KycodeRecentCreatedSession] {
        guard let data = defaults.data(forKey: recentCreatedSessionsDefaultsKey) else {
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([KycodeRecentCreatedSession].self, from: data)
            return prunedRecentCreatedSessions(Array(decoded.sorted(by: { $0.createdAt > $1.createdAt }).prefix(4)), now: Date())
        } catch {
            return []
        }
    }

    private func persistPendingRuntimeSettingsUpdates() {
        let updates = pendingRuntimeSettingsUpdates.values
            .filter {
                $0.persistsAcrossRelaunch
                    && $0.commandId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            .sorted {
                if $0.profileId != $1.profileId { return $0.profileId < $1.profileId }
                return $0.remoteWindowId < $1.remoteWindowId
            }
        guard !updates.isEmpty else {
            runtimeSettingsDefaults.removeObject(forKey: Self.pendingRuntimeSettingsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(updates) else { return }
        runtimeSettingsDefaults.set(data, forKey: Self.pendingRuntimeSettingsDefaultsKey)
    }

    private static func loadPendingRuntimeSettingsUpdates(
        from defaults: UserDefaults
    ) -> [UUID: KycodePendingRuntimeSettingsUpdate] {
        guard let data = defaults.data(forKey: pendingRuntimeSettingsDefaultsKey),
              data.count <= 256 * 1_024,
              let decoded = try? JSONDecoder().decode(
                  [KycodePendingRuntimeSettingsUpdate].self,
                  from: data
              ) else {
            return [:]
        }
        let valid = decoded.filter { pending in
            pending.persistsAcrossRelaunch
                && pending.phase != .awaitingAcknowledgement
                && pending.commandId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && !pending.profileId.isEmpty
                && !pending.remoteWindowId.isEmpty
                && KycodeRuntimeModelPolicy.isSupported(pending.model)
                && !pending.reasoningEffort.isEmpty
        }
        return Dictionary(uniqueKeysWithValues: valid.map { ($0.mutationId, $0) })
    }

    private func restorePendingRuntimeSettingsTracking() {
        for pending in pendingRuntimeSettingsUpdates.values
        where pending.phase == .awaitingTerminal {
            guard let commandId = pending.commandId else { continue }
            _ = durableCommandTracker.register(
                commandId: commandId,
                state: .accepted,
                context: KycodeTrackedCommandContext(
                    operation: .setModel,
                    windowId: pending.presentedWindowId,
                    messageId: nil,
                    sessionId: pending.sessionId,
                    mutationId: pending.mutationId
                )
            )
        }
    }

    private func persistCachedSessions(_ items: [KycodeSessionSummary], cachedAt: Date) {
        var lightweight = Array(
            items
                .prefix(Self.cachedSessionsMaximumCount)
                .map(\.lightweightCachedCopy)
        )

        guard !lightweight.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.cachedSessionsDefaultsKey)
            return
        }

        let encoder = JSONEncoder()
        while !lightweight.isEmpty {
            let snapshot = KycodeCachedSessionsSnapshot(
                schemaVersion: Self.cachedSessionsSchemaVersion,
                profileId: selectedProfileId,
                cachedAt: cachedAt,
                sessions: lightweight
            )
            guard let data = try? encoder.encode(snapshot) else {
                return
            }
            if data.count <= Self.cachedSessionsMaximumBytes {
                UserDefaults.standard.set(data, forKey: Self.cachedSessionsDefaultsKey)
                return
            }
            lightweight = Array(lightweight.prefix(max(0, lightweight.count / 2)))
        }
    }

    private func persistSessionDisplayOrder() {
        sessionDisplayOrdersByProfile[selectedProfileId] = Array(
            sessionDisplayOrder.prefix(Self.cachedSessionsMaximumCount)
        )
        do {
            let data = try JSONEncoder().encode(sessionDisplayOrdersByProfile)
            UserDefaults.standard.set(data, forKey: Self.sessionDisplayOrdersDefaultsKey)
        } catch {
            log("No pude persistir el orden de sesiones: \(describe(error))")
        }
    }

    private static func loadSessionDisplayOrders(from defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: sessionDisplayOrdersDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { order in
            var seen = Set<String>()
            return order.prefix(cachedSessionsMaximumCount).filter { seen.insert($0).inserted }
        }
    }

    private static func loadCachedSessions(
        from defaults: UserDefaults,
        profileId: String
    ) -> KycodeCachedSessionsSnapshot? {
        guard let data = defaults.data(forKey: cachedSessionsDefaultsKey) else {
            return nil
        }
        guard data.count <= cachedSessionsMaximumBytes,
              let snapshot = try? JSONDecoder().decode(KycodeCachedSessionsSnapshot.self, from: data) else {
            defaults.removeObject(forKey: cachedSessionsDefaultsKey)
            return nil
        }
        guard snapshot.schemaVersion == cachedSessionsSchemaVersion,
              snapshot.profileId == profileId else {
            return nil
        }
        guard snapshot.sessions.count <= cachedSessionsMaximumCount,
              KycodeCachedSessionIdentityPolicy.accepts(snapshot.sessions) else {
            defaults.removeObject(forKey: cachedSessionsDefaultsKey)
            return nil
        }
        return snapshot
    }

    private static func prunedRecentCreatedSessions(
        _ entries: [KycodeRecentCreatedSession],
        now: Date
    ) -> [KycodeRecentCreatedSession] {
        entries
            .filter { entry in
                let age = now.timeIntervalSince(entry.createdAt)
                guard age < recentCreatedMaxAge else { return false }
                if entry.status.lowercased() == "pending" && age >= recentCreatedPendingTTL {
                    return false
                }
                return true
            }
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(4)
            .map { $0 }
    }

    private func clearConnectionIssueState(cancelReconnectTask: Bool) {
        if cancelReconnectTask {
            reconnectTask?.cancel()
            reconnectTask = nil
            bootstrapTask?.cancel()
            bootstrapTask = nil
        }
        if cancelReconnectTask {
            isBootstrapping = false
        }
        isReconnecting = false
        reconnectStatusText = nil
        canRetryReconnectManually = false
        // A healthy stream clears connection feedback, not an action failure
        // the user still needs to see (for example, a rejected archive).
    }

    private var shouldScheduleBootstrapReconnectLoop: Bool {
        guard let profile = selectedProfile else { return false }
        switch profile.mode {
        case .remoteHub, .personal, .ferminCode:
            return selectedProfileStoredCredentials != nil
        case .bonjourOnly, .remoteFirst, .all:
            return true
        }
    }

    private func handleRecoverableConnectionFailure(
        _ error: Error,
        source: String,
        credentials: KycodeConnectionCredentials
    ) async -> Bool {
        guard activeCredentials == credentials else { return false }
        guard isRecoverableConnectionError(error) else { return false }

        let description = describe(error)
        recordBackgroundSyncFailure(description, source: source)

        // A timeout from an auxiliary endpoint must not downgrade the whole
        // composer while the authenticated SSE channel is actively delivering
        // data. The stream is stronger, newer evidence than that isolated
        // failure; keep the composer usable and let the normal refresh loop
        // retry the secondary request.
        if KycodeSessionRefreshPolicy.hasRecentVerifiedStreamActivity(
            isStreaming: isStreaming,
            lastStreamActivityAt: lastStreamActivityAt,
            now: Date()
        ) {
            restoreConnectionFromVerifiedStreamActivity(
                credentials,
                source: "stream válido tras fallo en \(source)"
            )
            return true
        }

        if reconnectTask != nil {
            return true
        }

        isStreaming = false
        isReconnecting = true
        isShowingCachedSessions = !sessions.isEmpty
        reconnectStatusText = "Reconectando..."
        canRetryReconnectManually = false
        errorMessage = nil
        refreshTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(credentials)
        }
        return true
    }

    private func restoreConnectionFromVerifiedStreamActivity(
        _ credentials: KycodeConnectionCredentials,
        source: String
    ) {
        guard activeCredentials == credentials else { return }
        let wasRecovering = isReconnecting
            || reconnectTask != nil
            || isShowingCachedSessions
            || canRetryReconnectManually
            || !isConnected

        reconnectTask?.cancel()
        reconnectTask = nil
        isConnected = true
        isStreaming = true
        isConnecting = false
        isBootstrapping = false
        isShowingCachedSessions = false
        clearConnectionIssueState(cancelReconnectTask: false)

        if let profile = selectedProfile,
           profile.id == Self.pukyProfileId || profile.id == Self.personalProfileId {
            let current = sourceConnectionStates.first(where: { $0.id == profile.id })
            updateSourceState(
                profile: profile,
                isLoading: false,
                isConnected: true,
                sessionCount: sessions.count,
                connectionLabel: current?.connectionLabel ?? lastConnectionSource,
                errorMessage: nil,
                snapshotPhase: .succeeded,
                attemptGeneration: current?.attemptGeneration
                    ?? sourceSnapshotAttemptGeneration,
                hasRetainedSnapshot: !sessions.isEmpty || current?.hasRetainedSnapshot == true
            )
        }

        if wasRecovering {
            startRefreshLoop(credentials)
            log("Conexión restaurada por \(source); se canceló el reconnect obsoleto.")
        }
    }

    private func runReconnectLoop(_ credentials: KycodeConnectionCredentials) async {
        let expectedConnectionGeneration = connectionStateGeneration
        let expectedProfileId = selectedProfileId
        for (index, delaySeconds) in Self.reconnectBackoffSeconds.enumerated() {
            if Task.isCancelled { return }
            let attempt = index + 1
            reconnectStatusText = "Reconectando... intento \(attempt)/\(Self.reconnectBackoffSeconds.count)"
            log("Reintentando conexión (intento \(attempt)/\(Self.reconnectBackoffSeconds.count)) en \(delaySeconds)s...")
            try? await Task.sleep(for: .seconds(delaySeconds))
            if Task.isCancelled { return }
            guard activeCredentials == credentials else {
                reconnectTask = nil
                return
            }

            for candidate in reconnectCandidates(for: credentials) {
                do {
                    let snapshot = try await fetchSessions(
                        candidate.credentials,
                        timeout: connectionRequestTimeout(
                            for: candidate.credentials,
                            localTimeout: Self.reconnectRequestTimeout,
                            internetTimeout: KycodeConnectionTransportPolicy.internetReconnectTimeoutSeconds
                        )
                    )
                    guard ownsConnectionAttempt(
                        connectionGeneration: expectedConnectionGeneration,
                        selectedProfileId: expectedProfileId
                    ), activeCredentials == credentials else {
                        return
                    }
                    try validateSnapshotFreshness(snapshot, for: candidate.credentials)
                    reconnectTask = nil
                    applySuccessfulConnection(
                        candidate.credentials,
                        snapshot: snapshot,
                        persist: true,
                        persistBaseURL: candidate.credentials.baseURL == (selectedProfile?.remoteBaseURL ?? ""),
                        sourceLabel: lastConnectionSource ?? "Reconnect"
                    )
                    log("Reconectado exitosamente.")
                    return
                } catch {
                    guard ownsConnectionAttempt(
                        connectionGeneration: expectedConnectionGeneration,
                        selectedProfileId: expectedProfileId
                    ), activeCredentials == credentials else {
                        return
                    }
                    let description = describe(error)
                    log("Reintento \(attempt)/\(Self.reconnectBackoffSeconds.count) fallo en \(candidate.credentials.baseURL): \(description)")
                    guard isRecoverableConnectionError(error) else {
                        reconnectTask = nil
                        isReconnecting = false
                        reconnectStatusText = nil
                        canRetryReconnectManually = false
                        errorMessage = description
                        return
                    }
                }
            }
        }

        reconnectTask = nil
        isReconnecting = false
        canRetryReconnectManually = true
        reconnectStatusText = "Reconexión automática falló. Tocá para reintentar."
        log("Reconexión automática agotada.")
    }

    private func isRecoverableConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.networkConnectionLost.rawValue,
                URLError.notConnectedToInternet.rawValue,
                URLError.timedOut.rawValue,
                URLError.cannotConnectToHost.rawValue,
                URLError.cannotFindHost.rawValue,
                URLError.dnsLookupFailed.rawValue,
                URLError.internationalRoamingOff.rawValue,
                URLError.callIsActive.rawValue,
                URLError.dataNotAllowed.rawValue,
                URLError.secureConnectionFailed.rawValue:
                return true
            default:
                return false
            }
        }
        if nsError.domain == "KycodeMobile", nsError.code >= 500 {
            return true
        }
        return false
    }

    private func recordBackgroundSyncFailure(_ message: String, source: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastBackgroundSyncErrorMessage = trimmed
        log("Fallo de sincronizacion en \(source): \(trimmed)")
    }

    private func log(_ message: String) {
        NSLog("%@", "[Connection] \(message)")
    }

    private func logTranscription(_ message: String, level: LogLevel = .debug) {
        let line = "[Transcription] \(message)"
        LoggingService.logToFile(level: level, message: line)
        NSLog("%@", line)
    }

    private static func voiceDraftMetadataURL() -> URL? {
        if let container = SharedInbox.containerURL() {
            return container.appendingPathComponent(voiceDraftMetadataFileName)
        }
        guard let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback.appendingPathComponent(voiceDraftMetadataFileName)
    }

    private static func voiceDraftsDirectoryURL() -> URL? {
        if let appGroupDirectory = try? SharedInbox.ensureDirectory(named: voiceDraftsDirectoryName) {
            return appGroupDirectory
        }
        guard let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = fallback.appendingPathComponent(voiceDraftsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func voiceDraftSidecarURL(for id: String) -> URL? {
        voiceDraftsDirectoryURL()?.appendingPathComponent("voice-draft-\(id).json")
    }

    private func loadVoiceDraftFromSidecars() -> VoiceDraft? {
        guard let directory = Self.voiceDraftsDirectoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return nil }
        let drafts = urls
            .filter { $0.lastPathComponent.hasPrefix("voice-draft-") && $0.pathExtension == "json" }
            .compactMap { url -> VoiceDraft? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(VoiceDraft.self, from: data)
            }
            .filter { $0.sendStatus != .sent }
            .sorted { $0.createdAt > $1.createdAt }
        guard var draft = drafts.first else { return nil }
        if !draft.hasAudioFile {
            draft.transcriptStatus = .failed
            draft.sendStatus = .failed
            draft.errorMessage = "Recuperé el registro secundario del audio, pero el archivo no está disponible. No eliminé la evidencia."
        } else if draft.sendStatus == .sending {
            draft.sendStatus = .failed
            draft.errorMessage = "La app se cerró antes de confirmar el envío."
        }
        currentVoiceDraft = draft
        persistVoiceDraft(draft)
        logTranscription("Voice draft recuperado desde sidecar id=\(draft.id)")
        return draft
    }

    private func durableVoiceDraftURL(for fileURL: URL) -> URL {
        let fileName = "voice_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).\(fileURL.pathExtension)"
        let directory = Self.voiceDraftsDirectoryURL() ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(fileName)
    }

    private func presentableSendError(_ error: Error, attachmentCount: Int) -> String {
        let nsError = error as NSError
        if attachmentCount > 0 {
            switch nsError.code {
            case 404:
                return "La conexión todavía no admite imágenes. Actualizá KyCode Desktop y reintentá."
            case 413:
                return "Una imagen supera 20 MiB o el total supera 50 MiB."
            case 415:
                return "Una imagen no es PNG, JPEG, GIF o WebP válida."
            case 502:
                return "Tu Mac rechazó la imagen. Verificá que KyCode Desktop esté abierto y reintentá."
            case 503:
                return "Tu Mac está desconectada. Reconectala y reintentá sin perder las imágenes."
            case 504:
                return "La carga tardó demasiado. Las imágenes siguen adjuntas; tocá Reintentar."
            default:
                break
            }
        }
        let description = describe(error)
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No se pudo enviar. Reintentá."
        }
        return "No se pudo enviar: \(description)"
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            return "\(nsError.localizedDescription) @ \(failingURL)"
        }
        return nsError.localizedDescription
    }
}
