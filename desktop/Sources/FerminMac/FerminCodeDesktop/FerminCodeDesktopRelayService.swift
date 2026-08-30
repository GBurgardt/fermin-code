import Foundation
import FerminCore

protocol FerminCodeDesktopRelayServing: Sendable {
    func fetchHealth(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayHealth

    func fetchSessions(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelaySessionsEnvelope

    func fetchSession(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelaySessionDetailEnvelope

    func fetchModels(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayModelCatalogEnvelope

    func fetchProjects(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayProjectDirectoryEnvelope

    func fetchHistory(
        source: FerminCodeRelaySource,
        token: String,
        query: FerminRelaySessionHistoryQuery
    ) async throws -> FerminRelaySessionHistoryEnvelope

    func fetchRecoverableSessions(
        source: FerminCodeRelaySource,
        token: String,
        query: FerminRelaySessionRecoveryQuery
    ) async throws -> FerminRelaySessionRecoveryEnvelope

    func fetchPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope

    func filePreview(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayFilePreview

    func fetchAttachmentContent(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayAttachmentContent

    func createSession(
        source: FerminCodeRelaySource,
        token: String,
        request: FerminRelayCreateSessionRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func sendMessage(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelaySendMessageRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func interrupt(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func rename(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        name: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setMinimized(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        minimized: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setPinned(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        pinned: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func archive(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func deletePermanently(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setFeatures(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        patch: FerminRelayFeaturePatch
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setRunMode(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        enabled: Bool,
        idempotencyKey: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setModelSettings(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayModelSettingsRequest
    ) async throws -> FerminRelayModelSettingsEnvelope

    func createSubagent(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayCreateSubagentRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func retryPromptTransform(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        messageID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement

    func setPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String,
        variant: FerminRelayPromptImproverVariant
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope

    func resumeHistory(
        source: FerminCodeRelaySource,
        token: String,
        id: String
    ) async throws -> FerminRelayHistoryResumeEnvelope

    func recoverSession(
        source: FerminCodeRelaySource,
        token: String,
        id: String
    ) async throws -> FerminRelayRecoverSessionEnvelope

    func uploadAttachment(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        attachment: FerminRelayAttachmentUpload
    ) async throws -> FerminRelayAttachmentUploadEnvelope

    func stream(
        source: FerminCodeRelaySource,
        token: String,
        lastEventID: UInt64?
    ) async throws -> AsyncThrowingStream<FerminRelayStreamDelivery, Error>
}

extension FerminCodeDesktopRelayServing {
    func setPinned(
        source _: FerminCodeRelaySource,
        token _: String,
        windowID _: String,
        pinned _: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        throw URLError(.unsupportedURL)
    }

    func fetchRecoverableSessions(
        source _: FerminCodeRelaySource,
        token _: String,
        query _: FerminRelaySessionRecoveryQuery
    ) async throws -> FerminRelaySessionRecoveryEnvelope {
        throw URLError(.unsupportedURL)
    }

    func recoverSession(
        source _: FerminCodeRelaySource,
        token _: String,
        id _: String
    ) async throws -> FerminRelayRecoverSessionEnvelope {
        throw URLError(.unsupportedURL)
    }
}

struct FerminCodeDesktopRelayService: FerminCodeDesktopRelayServing {
    private let transport: FerminRelayURLSessionTransport
    private let configuration: FerminRelayHTTPConfiguration

    init(
        transport: FerminRelayURLSessionTransport = FerminRelayURLSessionTransport(),
        configuration: FerminRelayHTTPConfiguration = FerminRelayHTTPConfiguration()
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    func fetchHealth(source: FerminCodeRelaySource, token: String) async throws -> FerminRelayHealth {
        try await client(source: source, token: token).fetchHealth()
    }

    func fetchSessions(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelaySessionsEnvelope {
        try await client(source: source, token: token).fetchSessions()
    }

    func fetchSession(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelaySessionDetailEnvelope {
        try await client(source: source, token: token).fetchSession(windowID: windowID)
    }

    func fetchModels(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayModelCatalogEnvelope {
        try await client(source: source, token: token).fetchModels(windowID: windowID)
    }

    func fetchProjects(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayProjectDirectoryEnvelope {
        try await client(source: source, token: token).fetchProjects()
    }

    func fetchHistory(
        source: FerminCodeRelaySource,
        token: String,
        query: FerminRelaySessionHistoryQuery
    ) async throws -> FerminRelaySessionHistoryEnvelope {
        try await client(source: source, token: token).fetchHistory(query)
    }

    func fetchRecoverableSessions(
        source: FerminCodeRelaySource,
        token: String,
        query: FerminRelaySessionRecoveryQuery
    ) async throws -> FerminRelaySessionRecoveryEnvelope {
        try await client(source: source, token: token).fetchRecoverableSessions(query)
    }

    func fetchPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope {
        try await client(source: source, token: token).fetchPromptImproverPreference()
    }

    func filePreview(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayFilePreview {
        try await client(source: source, token: token).filePreview(path: path)
    }

    func fetchAttachmentContent(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayAttachmentContent {
        try await client(source: source, token: token).fetchAttachmentContent(path: path)
    }

    func createSession(
        source: FerminCodeRelaySource,
        token: String,
        request: FerminRelayCreateSessionRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).createSession(request)
    }

    func sendMessage(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelaySendMessageRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).sendMessage(
            windowID: windowID,
            request: request
        )
    }

    func interrupt(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).interrupt(windowID: windowID)
    }

    func rename(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        name: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).rename(
            windowID: windowID,
            name: name,
            idempotencyKey: UUID().uuidString
        )
    }

    func setMinimized(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        minimized: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).setMinimized(
            windowID: windowID,
            minimized: minimized
        )
    }

    func setPinned(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        pinned: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).setPinned(
            windowID: windowID,
            pinned: pinned
        )
    }

    func archive(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).archive(windowID: windowID)
    }

    func deletePermanently(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).deletePermanently(windowID: windowID)
    }

    func setFeatures(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        patch: FerminRelayFeaturePatch
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).setFeatures(
            windowID: windowID,
            patch: patch
        )
    }

    func setRunMode(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        enabled: Bool,
        idempotencyKey: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).setRunMode(
            windowID: windowID,
            request: FerminRelayRunModeRequest(
                goalEnabled: enabled,
                idempotencyKey: idempotencyKey
            )
        )
    }

    func setModelSettings(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayModelSettingsRequest
    ) async throws -> FerminRelayModelSettingsEnvelope {
        try await client(source: source, token: token).setModelSettings(
            windowID: windowID,
            request: request
        )
    }

    func createSubagent(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayCreateSubagentRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).createSubagent(
            windowID: windowID,
            request: request
        )
    }

    func retryPromptTransform(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        messageID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await client(source: source, token: token).retryPromptTransform(
            windowID: windowID,
            messageID: messageID,
            idempotencyKey: UUID().uuidString
        )
    }

    func setPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String,
        variant: FerminRelayPromptImproverVariant
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope {
        try await client(source: source, token: token).setPromptImproverPreference(variant)
    }

    func resumeHistory(
        source: FerminCodeRelaySource,
        token: String,
        id: String
    ) async throws -> FerminRelayHistoryResumeEnvelope {
        try await client(source: source, token: token).resumeHistory(
            id: id,
            idempotencyKey: UUID().uuidString
        )
    }

    func recoverSession(
        source: FerminCodeRelaySource,
        token: String,
        id: String
    ) async throws -> FerminRelayRecoverSessionEnvelope {
        try await client(source: source, token: token).recoverSession(
            id: id,
            idempotencyKey: UUID().uuidString
        )
    }

    func uploadAttachment(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        attachment: FerminRelayAttachmentUpload
    ) async throws -> FerminRelayAttachmentUploadEnvelope {
        try await client(source: source, token: token).uploadAttachment(
            windowID: windowID,
            attachment: attachment
        )
    }

    func stream(
        source: FerminCodeRelaySource,
        token: String,
        lastEventID: UInt64?
    ) async throws -> AsyncThrowingStream<FerminRelayStreamDelivery, Error> {
        try client(source: source, token: token).stream(lastEventID: lastEventID)
    }

    private func client(
        source: FerminCodeRelaySource,
        token: String
    ) throws -> FerminCodeRelayClient {
        try FerminCodeRelayClient(
            source: source,
            token: token,
            transport: transport,
            streamTransport: transport,
            configuration: configuration
        )
    }
}
