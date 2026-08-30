import Foundation

struct KycodeLiveMessagePatch: Codable, Sendable {
    let windowId: String
    let message: KycodeMessage
    let revision: Int
    let updatedAt: Double
    let final: Bool
}

struct KycodeLiveMessagePatchCursor: Equatable, Sendable {
    let revision: Int
    let updatedAt: Double
    let final: Bool
}

enum KycodeLiveMessagePatchOrderingPolicy {
    static func shouldApply(
        _ patch: KycodeLiveMessagePatch,
        after cursor: KycodeLiveMessagePatchCursor?,
        currentContent: String?
    ) -> Bool {
        let current = currentContent ?? ""
        let candidate = patch.message.content

        // A late SSE frame or a reconnect replay must never replace a richer
        // transcript value with an older prefix. This was the source of the
        // "messages disappear, then come back" behavior in long sessions.
        if !current.isEmpty, current.hasPrefix(candidate), current != candidate {
            return false
        }
        guard let cursor else {
            return current.isEmpty || candidate != current || patch.final
        }
        if patch.revision > cursor.revision { return true }
        if patch.updatedAt > cursor.updatedAt { return true }
        return patch.final && !cursor.final && patch.revision >= cursor.revision
    }

    static func cursor(for patch: KycodeLiveMessagePatch) -> KycodeLiveMessagePatchCursor {
        KycodeLiveMessagePatchCursor(
            revision: patch.revision,
            updatedAt: patch.updatedAt,
            final: patch.final
        )
    }
}

enum KycodeMessageChronologyPolicy {
    static func ordered(_ messages: [KycodeMessage]) -> [KycodeMessage] {
        guard messages.count > 1 else { return messages }
        let containsInversion = zip(messages, messages.dropFirst()).contains { left, right in
            sortTimestampMilliseconds(left.timestamp) > sortTimestampMilliseconds(right.timestamp)
        }
        guard containsInversion else { return messages }

        return messages.enumerated().sorted { left, right in
            let leftTimestamp = sortTimestampMilliseconds(left.element.timestamp)
            let rightTimestamp = sortTimestampMilliseconds(right.element.timestamp)
            if leftTimestamp == rightTimestamp {
                return left.offset < right.offset
            }
            return leftTimestamp < rightTimestamp
        }.map(\.element)
    }

    private static func sortTimestampMilliseconds(_ timestamp: Double) -> Double {
        guard timestamp.isFinite, timestamp > 0 else {
            return .greatestFiniteMagnitude
        }
        return timestamp < 100_000_000_000 ? timestamp * 1_000 : timestamp
    }
}

enum KycodePromptTransformStatePolicy {
    private static let pendingStatuses: Set<String> = [
        "pending",
        "queued",
        "processing",
        "running",
        "in_progress",
        "in-progress",
        "started",
    ]

    private static let failedStatuses: Set<String> = [
        "error",
        "failed",
        "failure",
        "cancelled",
        "canceled",
        "aborted",
    ]

    static func hasResolvedOutput(_ message: KycodeMessage) -> Bool {
        hasText(message.transformedPrompt) || hasText(message.improvedPrompt)
    }

    static func isPending(_ message: KycodeMessage) -> Bool {
        guard let status = normalizedStatus(message.transformStatus) else { return false }
        return pendingStatuses.contains(status)
    }

    static func isFailed(_ message: KycodeMessage) -> Bool {
        guard !hasResolvedOutput(message) else { return false }
        if hasText(message.transformErrorReason) { return true }
        guard let status = normalizedStatus(message.transformStatus) else { return false }
        return failedStatuses.contains(status)
    }

    static func shouldShowPendingIndicator(
        for message: KycodeMessage,
        responseIsProcessing _: Bool,
        hasResolvedFallbackOutput: Bool = false
    ) -> Bool {
        guard isPending(message) else { return false }
        // The improved text is authoritative even if the broader assistant
        // turn is still running. A stale `processing` status must not leave
        // "Mejorando el prompt" beside an answer that already used it.
        return !hasResolvedOutput(message) && !hasResolvedFallbackOutput
    }

    static func hasUnresolvedPendingTransform(
        in messages: [KycodeMessage]?,
        sessionImprovedPrompt: String? = nil
    ) -> Bool {
        !unresolvedPendingMessageIDs(
            in: messages,
            sessionImprovedPrompt: sessionImprovedPrompt
        ).isEmpty
    }

    static func unresolvedPendingMessageIDs(
        in messages: [KycodeMessage]?,
        sessionImprovedPrompt: String? = nil
    ) -> Set<String> {
        guard let messages else { return [] }
        let orderedMessages = KycodeMessageChronologyPolicy.ordered(messages)
        let latestUserMessageId = orderedMessages.last(where: {
            $0.role.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("user") == .orderedSame
        })?.id
        let hasSessionFallback = hasText(sessionImprovedPrompt)

        return Set(orderedMessages.compactMap { message in
            guard message.role.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("user") == .orderedSame,
                  isPending(message),
                  !hasResolvedOutput(message) else {
                return nil
            }
            return message.id != latestUserMessageId || !hasSessionFallback
                ? message.id
                : nil
        })
    }

    static func shouldPreserveResolvedOutput(
        existing: KycodeMessage,
        incoming: KycodeMessage
    ) -> Bool {
        hasResolvedOutput(existing)
            && isPending(incoming)
            && !hasResolvedOutput(incoming)
    }

    private static func hasText(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func normalizedStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct KycodePromptRetryIntent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case awaitingAttempt
        case observedActive
    }

    let attemptId: UUID
    let windowId: String
    let profileId: String
    let remoteWindowId: String
    let sessionId: String?
    let messageId: String
    let generation: UInt64
    let baselineDetailUpdatedAt: Double
    let baselineTransformStatus: String?
    let baselineTransformErrorReason: String?
    let baselineTransformedPrompt: String?
    let baselineImprovedPrompt: String?
    let baselineSessionImprovedPrompt: String?
    let expiresAt: TimeInterval
    var phase: Phase
}

enum KycodePromptRetryReconciliationPolicy {
    enum Decision: Equatable, Sendable {
        case keepWaiting
        case resolved
        case failed
        case expired
    }

    static func decision(
        intent: KycodePromptRetryIntent,
        detail: KycodeSessionSummary?,
        now: TimeInterval
    ) -> Decision {
        guard now < intent.expiresAt else { return .expired }
        guard let detail else {
            return .keepWaiting
        }
        if let expectedSessionId = intent.sessionId,
           detail.sessionId != expectedSessionId {
            return .expired
        }

        if let message = detail.messages?.first(where: { $0.id == intent.messageId }) {
            let transformedPrompt = normalizedText(message.transformedPrompt)
            let improvedPrompt = normalizedText(message.improvedPrompt)
            if transformedPrompt != normalizedText(intent.baselineTransformedPrompt),
               transformedPrompt != nil {
                return .resolved
            }
            if improvedPrompt != normalizedText(intent.baselineImprovedPrompt),
               improvedPrompt != nil {
                return .resolved
            }

            if KycodePromptTransformStatePolicy.isFailed(message),
               intent.phase == .observedActive,
               detail.updatedAt > intent.baselineDetailUpdatedAt {
                return .failed
            }
        }

        let latestUserMessageId = KycodeMessageChronologyPolicy
            .ordered(detail.messages ?? [])
            .last(where: {
                $0.role.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("user") == .orderedSame
            })?.id
        let sessionImprovedPrompt = normalizedText(detail.improvedPrompt)
        if latestUserMessageId == intent.messageId,
           sessionImprovedPrompt != normalizedText(intent.baselineSessionImprovedPrompt),
           sessionImprovedPrompt != nil {
            return .resolved
        }

        return .keepWaiting
    }

    static func phase(
        after detail: KycodeSessionSummary?,
        for intent: KycodePromptRetryIntent
    ) -> KycodePromptRetryIntent.Phase {
        guard intent.phase == .awaitingAttempt,
              let detail,
              detail.sessionId == intent.sessionId || intent.sessionId == nil,
              let message = detail.messages?.first(where: { $0.id == intent.messageId }),
              KycodePromptTransformStatePolicy.isPending(message) else {
            return intent.phase
        }
        return .observedActive
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum KycodeLiveMessageReducer {
    static func applying(
        _ patch: KycodeLiveMessagePatch,
        to detail: KycodeSessionSummary
    ) -> KycodeSessionSummary {
        var messages = detail.messages ?? []
        if let index = messages.firstIndex(where: { $0.id == patch.message.id }) {
            let existing = messages[index]
            let patchRole = patch.message.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedRole = patchRole.isEmpty ? existing.role : patch.message.role
            let hasTransformUpdate = patch.message.transformStatus != nil
                || patch.message.transformedPrompt != nil
                || patch.message.improvedPrompt != nil
                || patch.message.promptTransformNote != nil
            let preservesResolvedPromptTransform =
                KycodePromptTransformStatePolicy.shouldPreserveResolvedOutput(
                    existing: existing,
                    incoming: patch.message
                )
            let mergedStatus: String?
            if patch.final {
                mergedStatus = patch.message.status == "streaming" ? nil : patch.message.status
            } else {
                mergedStatus = patch.message.status ?? existing.status ?? "streaming"
            }
            messages[index] = KycodeMessage(
                id: patch.message.id,
                role: mergedRole,
                type: patch.message.type ?? existing.type,
                content: patch.message.content,
                originalPrompt: patch.message.originalPrompt ?? existing.originalPrompt,
                transformedPrompt: preservesResolvedPromptTransform
                    ? existing.transformedPrompt
                    : (patch.message.transformedPrompt ?? existing.transformedPrompt),
                improvedPrompt: preservesResolvedPromptTransform
                    ? existing.improvedPrompt
                    : (patch.message.improvedPrompt ?? existing.improvedPrompt),
                timestamp: patch.message.timestamp > 0 ? patch.message.timestamp : existing.timestamp,
                status: mergedStatus,
                imageAttachments: patch.message.imageAttachments ?? existing.imageAttachments,
                transformStatus: preservesResolvedPromptTransform
                    ? existing.transformStatus
                    : (patch.message.transformStatus ?? existing.transformStatus),
                transformErrorReason: preservesResolvedPromptTransform
                    ? existing.transformErrorReason
                    : hasTransformUpdate
                    ? patch.message.transformErrorReason
                    : existing.transformErrorReason,
                promptTransformNote: preservesResolvedPromptTransform
                    ? existing.promptTransformNote
                    : (patch.message.promptTransformNote ?? existing.promptTransformNote)
            )
        } else {
            messages.append(patch.message)
        }
        messages = KycodeMessageChronologyPolicy.ordered(messages)

        let mergedMessage = messages.first(where: { $0.id == patch.message.id }) ?? patch.message
        let completesAssistantTurn = patch.final
            && mergedMessage.role.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("assistant") == .orderedSame

        return KycodeSessionSummary(
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
            activityStatus: completesAssistantTurn
                ? "ready"
                : (patch.final ? detail.activityStatus : "working"),
            runtimeStatus: completesAssistantTurn
                ? "WAITING"
                : (patch.final ? detail.runtimeStatus : "WORKING"),
            runtimeStatusDetail: completesAssistantTurn ? nil : detail.runtimeStatusDetail,
            features: detail.features,
            runMode: detail.runMode,
            goalStartedAt: detail.goalStartedAt,
            messageCount: max(detail.messageCount, messages.count),
            updatedAt: max(detail.updatedAt, patch.updatedAt),
            createdAt: detail.createdAt,
            rawPrompt: detail.rawPrompt,
            originalPrompt: detail.originalPrompt,
            improvedPrompt: detail.improvedPrompt,
            lastMessagePreview: messages.last?.content ?? mergedMessage.content,
            isMinimized: detail.isMinimized,
            canSend: detail.canSend,
            canControlFeatures: detail.canControlFeatures,
            unsupportedReason: detail.unsupportedReason,
            messages: messages,
            pendingSubagent: detail.pendingSubagent,
            collaborationProjectId: detail.collaborationProjectId,
            collaborationProjectName: detail.collaborationProjectName,
            sessionName: detail.sessionName
        )
    }
}

enum KycodeSessionDetailReconciliationPolicy {
    static func merging(
        current: KycodeSessionSummary?,
        incoming: KycodeSessionSummary
    ) -> KycodeSessionSummary {
        guard let current else { return incoming }
        let messages = mergeMessages(
            current: current.messages ?? [],
            incoming: incoming.messages ?? []
        )
        return KycodeSessionSummary(
            windowId: incoming.windowId,
            sessionId: incoming.sessionId,
            engine: incoming.engine ?? current.engine,
            model: incoming.model ?? current.model,
            reasoningEffort: incoming.reasoningEffort ?? current.reasoningEffort,
            providerSessionId: incoming.providerSessionId ?? current.providerSessionId,
            providerSessionPath: incoming.providerSessionPath ?? current.providerSessionPath,
            projectKey: incoming.projectKey,
            projectPath: incoming.projectPath ?? current.projectPath,
            projectName: incoming.projectName ?? current.projectName,
            windowName: incoming.windowName ?? current.windowName,
            displayName: incoming.displayName,
            sidecarMode: incoming.sidecarMode,
            sidecarUrl: incoming.sidecarUrl ?? current.sidecarUrl,
            activityStatus: incoming.activityStatus,
            runtimeStatus: incoming.runtimeStatus,
            runtimeStatusDetail: incoming.runtimeStatusDetail,
            features: incoming.features ?? current.features,
            runMode: incoming.runMode ?? current.runMode,
            goalStartedAt: incoming.goalStartedAt ?? current.goalStartedAt,
            messageCount: max(incoming.messageCount, current.messageCount, messages.count),
            updatedAt: max(incoming.updatedAt, current.updatedAt),
            createdAt: incoming.createdAt ?? current.createdAt,
            rawPrompt: incoming.rawPrompt ?? current.rawPrompt,
            originalPrompt: incoming.originalPrompt ?? current.originalPrompt,
            improvedPrompt: incoming.improvedPrompt ?? current.improvedPrompt,
            lastMessagePreview: messages.last?.content
                ?? incoming.lastMessagePreview
                ?? current.lastMessagePreview,
            isMinimized: incoming.isMinimized ?? current.isMinimized,
            canSend: incoming.canSend,
            canControlFeatures: incoming.canControlFeatures ?? current.canControlFeatures,
            unsupportedReason: incoming.unsupportedReason,
            messages: messages,
            pendingSubagent: incoming.pendingSubagent ?? current.pendingSubagent,
            collaborationProjectId: incoming.collaborationProjectId ?? current.collaborationProjectId,
            collaborationProjectName: incoming.collaborationProjectName ?? current.collaborationProjectName,
            sessionName: incoming.sessionName ?? current.sessionName
        )
    }

    private static func mergeMessages(
        current: [KycodeMessage],
        incoming: [KycodeMessage]
    ) -> [KycodeMessage] {
        guard !current.isEmpty else {
            return KycodeMessageChronologyPolicy.ordered(
                KycodeMessageAliasPolicy.collapsingKnownAliases(incoming)
            )
        }
        guard !incoming.isEmpty else {
            return KycodeMessageChronologyPolicy.ordered(
                KycodeMessageAliasPolicy.collapsingKnownAliases(current)
            )
        }

        var messages = current
        var unreconciledCurrentIds = Set(current.map(\.id))
        for message in incoming {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = preferredMessage(existing: messages[index], incoming: message)
                unreconciledCurrentIds.remove(message.id)
                continue
            }

            // The live stream, optimistic UI, and authoritative detail API can
            // assign different IDs to the same logical turn. Reconcile only
            // against messages that existed before this incoming snapshot.
            // That distinction is important: two equal messages that are both
            // present in the authoritative snapshot are legitimate repeats and
            // must remain visible.
            let aliasIndices = messages.indices.filter { index in
                unreconciledCurrentIds.contains(messages[index].id)
                    && KycodeMessageAliasPolicy.areAliases(messages[index], message)
            }
            guard let insertionIndex = aliasIndices.first else {
                messages.append(message)
                continue
            }

            let aliasIds = aliasIndices.map { messages[$0].id }
            for index in aliasIndices.reversed() {
                messages.remove(at: index)
            }
            unreconciledCurrentIds.subtract(aliasIds)
            messages.insert(message, at: min(insertionIndex, messages.count))
        }
        return KycodeMessageChronologyPolicy.ordered(
            KycodeMessageAliasPolicy.collapsingKnownAliases(messages)
        )
    }

    private static func preferredMessage(
        existing: KycodeMessage,
        incoming: KycodeMessage
    ) -> KycodeMessage {
        if KycodePromptTransformStatePolicy.shouldPreserveResolvedOutput(
            existing: existing,
            incoming: incoming
        ) {
            return existing
        }
        if KycodePromptTransformStatePolicy.shouldPreserveResolvedOutput(
            existing: incoming,
            incoming: existing
        ) {
            return incoming
        }
        let existingContent = existing.content
        let incomingContent = incoming.content
        if existingContent.hasPrefix(incomingContent), existingContent != incomingContent {
            return existing
        }
        if incomingContent.hasPrefix(existingContent), incomingContent != existingContent {
            return incoming
        }
        let existingIsFinal = existing.status == nil
        let incomingIsFinal = incoming.status == nil
        if existingIsFinal != incomingIsFinal {
            return incomingIsFinal ? incoming : existing
        }
        if incomingContent.count != existingContent.count {
            return incomingContent.count > existingContent.count ? incoming : existing
        }
        return incoming.timestamp >= existing.timestamp ? incoming : existing
    }
}

enum KycodeMessageAliasPolicy {
    static let maximumTimestampDistanceMilliseconds: Double = 45_000

    static func areAliases(_ current: KycodeMessage, _ incoming: KycodeMessage) -> Bool {
        guard current.id != incoming.id,
              normalizedRole(current.role) == normalizedRole(incoming.role),
              abs(timestampMilliseconds(current.timestamp) - timestampMilliseconds(incoming.timestamp))
                <= maximumTimestampDistanceMilliseconds,
              attachmentSignature(current.imageAttachments) == attachmentSignature(incoming.imageAttachments)
        else {
            return false
        }

        let currentTexts = comparableTexts(current)
        let incomingTexts = comparableTexts(incoming)
        guard !currentTexts.isEmpty, !incomingTexts.isEmpty else { return false }
        return !currentTexts.isDisjoint(with: incomingTexts)
    }

    static func collapsingKnownAliases(_ messages: [KycodeMessage]) -> [KycodeMessage] {
        var result: [KycodeMessage] = []
        for message in messages {
            guard let aliasIndex = result.firstIndex(where: {
                shouldCollapseKnownAlias($0, message)
            }) else {
                result.append(message)
                continue
            }

            let existing = result[aliasIndex]
            result[aliasIndex] = canonicalPreference(existing, message)
        }
        return result
    }

    private static func shouldCollapseKnownAlias(
        _ existing: KycodeMessage,
        _ candidate: KycodeMessage
    ) -> Bool {
        guard areAliases(existing, candidate) else { return false }
        return isProvisionalId(existing.id) != isProvisionalId(candidate.id)
    }

    private static func canonicalPreference(
        _ existing: KycodeMessage,
        _ candidate: KycodeMessage
    ) -> KycodeMessage {
        let existingIsProvisional = isProvisionalId(existing.id)
        let candidateIsProvisional = isProvisionalId(candidate.id)
        if existingIsProvisional != candidateIsProvisional {
            return existingIsProvisional ? candidate : existing
        }

        let existingIsFinal = existing.status == nil
        let candidateIsFinal = candidate.status == nil
        if existingIsFinal != candidateIsFinal {
            return candidateIsFinal ? candidate : existing
        }
        return candidate.content.count > existing.content.count ? candidate : existing
    }

    private static func isProvisionalId(_ id: String) -> Bool {
        let normalized = id.lowercased()
        return normalized.hasPrefix("optimistic-")
            || normalized.hasPrefix("timeline-item-")
            || normalized.hasPrefix("timeline-live-")
    }

    private static func normalizedRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func timestampMilliseconds(_ timestamp: Double) -> Double {
        timestamp < 100_000_000_000 ? timestamp * 1_000 : timestamp
    }

    private static func comparableTexts(_ message: KycodeMessage) -> Set<String> {
        Set(
            [
                message.content,
                message.originalPrompt,
                message.transformedPrompt,
                message.improvedPrompt,
            ]
            .compactMap { $0 }
            .map(normalizedText)
            .filter { !$0.isEmpty }
        )
    }

    private static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func attachmentSignature(
        _ attachments: [KycodeMessageImageAttachment]?
    ) -> [String] {
        (attachments ?? []).map {
            "\($0.name)|\($0.mimeType)|\($0.size)"
        }
    }
}

enum KycodeComposerConnectivityState: Equatable {
    case online
    case reconnecting
    case retryRequired
    case offline
}

enum KycodeComposerConnectivityPolicy {
    static func state(
        isConnected: Bool,
        isStreaming: Bool,
        isShowingCachedSessions: Bool,
        isConnecting: Bool,
        isBootstrapping: Bool,
        isReconnecting: Bool,
        canRetryReconnectManually: Bool
    ) -> KycodeComposerConnectivityState {
        // A live authenticated stream is the newest authoritative signal. It
        // wins over stale reconnect/bootstrap flags left by an unrelated
        // request so the mic is never replaced by a permanent spinner.
        if isConnected && isStreaming && !isShowingCachedSessions {
            return .online
        }
        if isConnecting || isBootstrapping || isReconnecting {
            return .reconnecting
        }
        if canRetryReconnectManually {
            return .retryRequired
        }
        if isConnected && !isShowingCachedSessions {
            return .online
        }
        return .offline
    }

    static func sendBlockedReason(
        for state: KycodeComposerConnectivityState
    ) -> String? {
        switch state {
        case .online:
            return nil
        case .reconnecting:
            return "Reconectando. Tu borrador está guardado."
        case .retryRequired, .offline:
            return "Sin conexión. Tu borrador está guardado."
        }
    }
}

enum KycodeSessionActivityPolicy {
    static func isProcessing(activityStatus: String?, runtimeStatus: String?) -> Bool {
        let activity = activityStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if activity == "working" || activity == "approval" {
            return true
        }
        // A durable terminal activity state is authoritative over a stale
        // AppServer WORKING snapshot.
        if ["ready", "done", "error", "idle"].contains(activity ?? "") {
            return false
        }
        return runtimeStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == "WORKING"
    }
}

enum KycodeOptimisticSendActivityPolicy {
    static func shouldResolvePendingMessage(
        hasMatchingServerMessage: Bool,
        hasAssistantResponse: Bool,
        activityStatus: String?,
        runtimeStatus: String?
    ) -> Bool {
        // Only an authoritative user message can settle an optimistic send.
        // Assistant output, runtime activity, and errors are not proof that
        // the user bubble was durably written; using them caused the bubble to
        // disappear while the assistant kept responding.
        _ = hasAssistantResponse
        _ = activityStatus
        _ = runtimeStatus
        return hasMatchingServerMessage
    }
}

enum KycodeOptimisticMessageReconciliationPolicy {
    static func matchingAuthoritativeMessage(
        for optimistic: KycodeMessage,
        in authoritativeMessages: [KycodeMessage],
        excluding consumedIds: Set<String> = []
    ) -> KycodeMessage? {
        authoritativeMessages.last { candidate in
            guard candidate.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user",
                  !consumedIds.contains(candidate.id),
                  candidate.timestamp >= optimistic.timestamp - 45_000 else {
                return false
            }
            if candidate.id == optimistic.id {
                return true
            }
            return KycodeMessageAliasPolicy.areAliases(optimistic, candidate)
        }
    }
}

enum KycodeMobileVisualStreamPolicy {
    static let minimumAnimatedCharacterCount = 24
    static let maximumAnimatedCharacterCount = 4_000
    static let commitIntervalMilliseconds: UInt64 = 66

    private static let baseCharactersPerSecond = 240.0
    private static let maximumCharactersPerSecond = 1_400.0
    private static let fastBacklogCharacterCount = 1_600.0

    static func shouldAnimate(
        enabled: Bool,
        reduceMotion: Bool,
        voiceOverRunning: Bool,
        lowPowerMode: Bool,
        contentLength: Int
    ) -> Bool {
        enabled &&
            !reduceMotion &&
            !voiceOverRunning &&
            !lowPowerMode &&
            contentLength >= minimumAnimatedCharacterCount &&
            contentLength <= maximumAnimatedCharacterCount
    }

    static func nextVisibleCharacterCount(current: Int, target: Int) -> Int {
        guard current < target else { return max(0, target) }
        let backlog = max(0, target - current)
        let pressure = min(1, Double(backlog) / fastBacklogCharacterCount)
        let charactersPerSecond =
            baseCharactersPerSecond +
            (maximumCharactersPerSecond - baseCharactersPerSecond) * pressure
        let intervalSeconds = Double(commitIntervalMilliseconds) / 1_000
        let step = max(1, Int((charactersPerSecond * intervalSeconds).rounded(.down)))
        return min(target, current + step)
    }
}

enum KycodeMessageReconciliationPolicy {
    // SSE remains the primary path. These ten delayed detail reads are a bounded
    // safety net for a just-sent message when a live event is lost in transit.
    static let retryDelayMilliseconds: [Int64] = [
        1_000,
        2_000,
        4_000,
        6_000,
        8_000,
        10_000,
        12_000,
        15_000,
        20_000,
        25_000,
    ]

    static func shouldContinue(
        hasPendingOptimisticMessage: Bool,
        hasPendingPromptTransform: Bool = false,
        activityStatus: String?,
        runtimeStatus: String?,
        hasPendingPromptRetry: Bool = false
    ) -> Bool {
        if hasPendingOptimisticMessage || hasPendingPromptTransform || hasPendingPromptRetry {
            return true
        }
        return KycodeSessionActivityPolicy.isProcessing(
            activityStatus: activityStatus,
            runtimeStatus: runtimeStatus
        )
    }
}
