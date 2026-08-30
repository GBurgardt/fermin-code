import XCTest
@testable import KyCode

final class MobileLiveMessageTests: XCTestCase {
    func testComposerConnectivityPolicyKeepsTransientReconnectCompactAndDraftSafe() {
        let state = KycodeComposerConnectivityPolicy.state(
            isConnected: false,
            isStreaming: false,
            isShowingCachedSessions: true,
            isConnecting: false,
            isBootstrapping: false,
            isReconnecting: true,
            canRetryReconnectManually: false
        )

        XCTAssertEqual(state, .reconnecting)
        XCTAssertEqual(
            KycodeComposerConnectivityPolicy.sendBlockedReason(for: state),
            "Reconectando. Tu borrador está guardado."
        )
        XCTAssertFalse(
            KycodeComposerConnectivityPolicy.sendBlockedReason(for: state)?
                .contains("Modo de lectura") == true
        )
    }

    func testComposerConnectivityPolicyOnlyRestoresSendingForAuthoritativeOnlineState() {
        XCTAssertEqual(
            KycodeComposerConnectivityPolicy.state(
                isConnected: true,
                isStreaming: true,
                isShowingCachedSessions: false,
                isConnecting: false,
                isBootstrapping: false,
                isReconnecting: false,
                canRetryReconnectManually: false
            ),
            .online
        )
        XCTAssertEqual(
            KycodeComposerConnectivityPolicy.state(
                isConnected: true,
                isStreaming: false,
                isShowingCachedSessions: true,
                isConnecting: false,
                isBootstrapping: false,
                isReconnecting: false,
                canRetryReconnectManually: false
            ),
            .offline
        )
        XCTAssertEqual(
            KycodeComposerConnectivityPolicy.state(
                isConnected: false,
                isStreaming: false,
                isShowingCachedSessions: true,
                isConnecting: false,
                isBootstrapping: false,
                isReconnecting: false,
                canRetryReconnectManually: true
            ),
            .retryRequired
        )
    }

    func testVerifiedLiveStreamWinsOverStaleReconnectFlagsAndRestoresComposer() {
        XCTAssertEqual(
            KycodeComposerConnectivityPolicy.state(
                isConnected: true,
                isStreaming: true,
                isShowingCachedSessions: false,
                isConnecting: true,
                isBootstrapping: true,
                isReconnecting: true,
                canRetryReconnectManually: false
            ),
            .online
        )
    }

    func testInterfaceStatusCopyIsConsistentAndLocalized() {
        XCTAssertEqual(KycodeInterfaceCopyPolicy.dismissErrorAction, "Cerrar")
        XCTAssertEqual(
            KycodeInterfaceCopyPolicy.dashboardSyncStatus(isConnected: false, isStreaming: false),
            "Sin conexión"
        )
        XCTAssertEqual(
            KycodeInterfaceCopyPolicy.dashboardSyncStatus(isConnected: true, isStreaming: true),
            "En vivo"
        )
        XCTAssertEqual(
            KycodeInterfaceCopyPolicy.dashboardSyncStatus(isConnected: true, isStreaming: false),
            "Actualizando"
        )
        XCTAssertEqual(KycodeInterfaceCopyPolicy.sessionActivityStatus(" working "), "Trabajando")
        XCTAssertEqual(KycodeInterfaceCopyPolicy.sessionActivityStatus("approval"), "Esperando")
        XCTAssertEqual(KycodeInterfaceCopyPolicy.sessionActivityStatus("idle"), "En espera")
        XCTAssertEqual(KycodeInterfaceCopyPolicy.sessionActivityStatus("unknown"), "Sin conexión")
    }

    func testDecodesSidecarPatchContract() throws {
        let data = Data(
            """
            {
              "windowId":"win-1",
              "message":{
                "id":"timeline-1",
                "role":"assistant",
                "type":"codex",
                "content":"hola",
                "timestamp":100,
                "status":"streaming"
              },
              "revision":4,
              "updatedAt":110,
              "final":false
            }
            """.utf8
        )
        let patch = try JSONDecoder().decode(KycodeLiveMessagePatch.self, from: data)
        XCTAssertEqual(patch.windowId, "win-1")
        XCTAssertEqual(patch.message.content, "hola")
        XCTAssertEqual(patch.revision, 4)
        XCTAssertFalse(patch.final)
    }

    func testSessionRuntimeModelUsesDesktopStyleLabels() {
        let codex = detail(messages: [])
        XCTAssertEqual(codex.runtimeModelDisplayName, "gpt-5.6-sol")
        XCTAssertEqual(codex.runtimeReasoningEffortDisplayName, "XHIGH")
        XCTAssertEqual(codex.runtimeDisplayLabel, "CODEX · GPT-5.6-SOL · XHIGH")

        let claudeData = Data(
            """
            {
              "windowId":"win-claude",
              "sessionId":"session-claude",
              "engine":"claude",
              "model":"claude-opus-4-6",
              "reasoningEffort":"high",
              "projectKey":"project",
              "displayName":"Claude QA",
              "sidecarMode":"local",
              "activityStatus":"ready",
              "messageCount":0,
              "updatedAt":100,
              "canSend":true
            }
            """.utf8
        )
        let claude = try? JSONDecoder().decode(KycodeSessionSummary.self, from: claudeData)
        XCTAssertEqual(claude?.runtimeModelDisplayName, "Opus 4.6")
        XCTAssertEqual(claude?.runtimeDisplayLabel, "CLAUDE · OPUS 4.6 · HIGH")
    }

    func testAppendsFirstProgressiveAssistantFragment() {
        let result = KycodeLiveMessageReducer.applying(
            patch(content: "Empiezo", updatedAt: 200, final: false),
            to: detail(messages: [message(id: "user-1", role: "user", content: "hola")])
        )
        XCTAssertEqual(result.messages?.map(\.content), ["hola", "Empiezo"])
        XCTAssertEqual(result.activityStatus, "working")
        XCTAssertEqual(result.messages?.last?.status, "streaming")
    }

    func testReplacesAbsoluteContentInsteadOfDuplicatingFragments() {
        let partial = message(
            id: "timeline-1",
            role: "assistant",
            content: "Empiezo",
            status: "streaming"
        )
        let result = KycodeLiveMessageReducer.applying(
            patch(content: "Empiezo y continúo", updatedAt: 220, final: false),
            to: detail(messages: [partial])
        )
        XCTAssertEqual(result.messages?.count, 1)
        XCTAssertEqual(result.messages?.first?.content, "Empiezo y continúo")
    }

    func testFinalPatchClearsStreamingStatus() {
        let partial = message(
            id: "timeline-1",
            role: "assistant",
            content: "casi",
            status: "streaming"
        )
        let result = KycodeLiveMessageReducer.applying(
            patch(content: "listo", updatedAt: 230, final: true),
            to: detail(messages: [partial])
        )
        XCTAssertEqual(result.messages?.first?.content, "listo")
        XCTAssertNil(result.messages?.first?.status)
        XCTAssertEqual(result.activityStatus, "ready")
        XCTAssertEqual(result.runtimeStatus, "WAITING")
        XCTAssertNil(result.runtimeStatusDetail)
    }

    func testFinalUserPatchPreservesPromptMetadataAttachmentsAndWorkingState() {
        let attachment = KycodeMessageImageAttachment(
            id: "image-1",
            name: "capture.png",
            path: "/tmp/capture.png",
            size: 42,
            mimeType: "image/png",
            previewData: nil
        )
        let existing = KycodeMessage(
            id: "user-1",
            role: "user",
            type: "user",
            content: "prompt original",
            originalPrompt: "prompt original",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 100,
            status: "sent",
            imageAttachments: [attachment]
        )
        let patch = KycodeLiveMessagePatch(
            windowId: "win-1",
            message: KycodeMessage(
                id: "user-1",
                role: "user",
                type: "user",
                content: "prompt mejorado",
                originalPrompt: nil,
                transformedPrompt: "prompt transformado",
                improvedPrompt: "prompt mejorado",
                timestamp: 110,
                status: nil,
                imageAttachments: nil,
                transformStatus: "completed",
                transformErrorReason: nil,
                promptTransformNote: "Mejorado"
            ),
            revision: 2,
            updatedAt: 120,
            final: true
        )

        let result = KycodeLiveMessageReducer.applying(
            patch,
            to: detail(
                messages: [existing],
                activityStatus: "working",
                runtimeStatus: "WORKING",
                runtimeStatusDetail: "Procesando turno"
            )
        )
        let merged = result.messages?.first

        XCTAssertEqual(merged?.role, "user")
        XCTAssertEqual(merged?.originalPrompt, "prompt original")
        XCTAssertEqual(merged?.transformedPrompt, "prompt transformado")
        XCTAssertEqual(merged?.improvedPrompt, "prompt mejorado")
        XCTAssertEqual(merged?.imageAttachments, [attachment])
        XCTAssertEqual(merged?.transformStatus, "completed")
        XCTAssertEqual(merged?.promptTransformNote, "Mejorado")
        XCTAssertNil(merged?.status)
        XCTAssertEqual(result.activityStatus, "working")
        XCTAssertEqual(result.runtimeStatus, "WORKING")
        XCTAssertEqual(result.runtimeStatusDetail, "Procesando turno")
    }

    func testStalePendingPromptPatchCannotReplaceResolvedImprovement() {
        let resolved = promptTransformMessage(
            transformedPrompt: "Prompt mejorado completo",
            transformStatus: "done"
        )
        let stalePending = KycodeLiveMessagePatch(
            windowId: "win-1",
            message: promptTransformMessage(
                transformedPrompt: nil,
                transformStatus: "pending"
            ),
            revision: 2,
            updatedAt: 200,
            final: true
        )

        let result = KycodeLiveMessageReducer.applying(
            stalePending,
            to: detail(messages: [resolved])
        )

        XCTAssertEqual(result.messages?.first?.transformStatus, "done")
        XCTAssertEqual(result.messages?.first?.transformedPrompt, "Prompt mejorado completo")
        XCTAssertEqual(result.messages?.first?.improvedPrompt, "Prompt mejorado completo")
    }

    func testDetailMergeCannotRegressResolvedImprovementToPending() {
        let resolved = promptTransformMessage(
            transformedPrompt: "Prompt mejorado completo",
            transformStatus: "done"
        )
        let stalePending = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "pending"
        )

        let result = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [resolved]),
            incoming: detail(messages: [stalePending])
        )

        XCTAssertEqual(result.messages?.first?.transformStatus, "done")
        XCTAssertEqual(result.messages?.first?.transformedPrompt, "Prompt mejorado completo")
    }

    func testNewPromptRetryCanBecomePendingWhileRetainingPreviousOutput() {
        let resolved = promptTransformMessage(
            transformedPrompt: "Primer resultado",
            transformStatus: "done"
        )
        let retryPending = KycodeLiveMessagePatch(
            windowId: "win-1",
            message: promptTransformMessage(
                transformedPrompt: "Primer resultado",
                transformStatus: "pending"
            ),
            revision: 4,
            updatedAt: 300,
            final: true
        )

        let result = KycodeLiveMessageReducer.applying(
            retryPending,
            to: detail(messages: [resolved])
        )

        XCTAssertEqual(result.messages?.first?.transformStatus, "pending")
        XCTAssertEqual(result.messages?.first?.transformedPrompt, "Primer resultado")
    }

    func testResolvedOutputSuppressesStalePendingIndicatorOnceSessionIsTerminal() {
        let resolvedWithStaleStatus = promptTransformMessage(
            transformedPrompt: "Prompt mejorado completo",
            transformStatus: " PENDING "
        )

        XCTAssertFalse(
            KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                for: resolvedWithStaleStatus,
                responseIsProcessing: false
            )
        )
    }

    func testSessionFallbackOutputSuppressesStalePendingIndicatorOnceSessionIsTerminal() {
        let stalePendingMessage = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "PENDING"
        )

        XCTAssertFalse(
            KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                for: stalePendingMessage,
                responseIsProcessing: false,
                hasResolvedFallbackOutput: true
            )
        )
    }

    func testResolvedOutputStopsPendingIndicatorWhileAssistantIsStillProcessing() {
        let retry = promptTransformMessage(
            transformedPrompt: "Resultado anterior",
            transformStatus: "PENDING"
        )

        XCTAssertFalse(
            KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                for: retry,
                responseIsProcessing: true
            )
        )
    }

    func testPendingWithoutOutputRemainsVisibleUntilAResolutionArrives() {
        let pending = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: " pending "
        )

        XCTAssertTrue(
            KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                for: pending,
                responseIsProcessing: false
            )
        )
    }

    func testPromptTransformStatusVocabularyTreatsQueuedProcessingRunningAndStartedAsPending() {
        let activeStatuses = [
            "queued",
            " PROCESSING ",
            "running",
            "in_progress",
            "IN-PROGRESS",
            "started",
        ]

        for status in activeStatuses {
            let message = promptTransformMessage(
                transformedPrompt: nil,
                transformStatus: status
            )
            XCTAssertTrue(
                KycodePromptTransformStatePolicy.isPending(message),
                "\(status) debe conservar el estado activo"
            )
            XCTAssertTrue(
                KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                    for: message,
                    responseIsProcessing: false
                ),
                "\(status) debe mantener feedback visible"
            )
        }
    }

    func testPromptTransformStatusVocabularyTreatsFailedCancelledAndAbortedAsFailed() {
        let failedStatuses = [
            "failed",
            " FAILURE ",
            "cancelled",
            "CANCELED",
            "aborted",
        ]

        for status in failedStatuses {
            let message = promptTransformMessage(
                transformedPrompt: nil,
                transformStatus: status
            )
            XCTAssertTrue(
                KycodePromptTransformStatePolicy.isFailed(message),
                "\(status) debe ofrecer recuperación"
            )
            XCTAssertFalse(KycodePromptTransformStatePolicy.isPending(message))
        }
    }

    func testPromptTransformErrorReasonIsFailedEvenWhenStatusIsMissingFromVocabulary() {
        let message = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "unknown",
            transformErrorReason: "sidecar_unavailable"
        )

        XCTAssertTrue(KycodePromptTransformStatePolicy.isFailed(message))
        XCTAssertFalse(KycodePromptTransformStatePolicy.isPending(message))
    }

    func testResolvedOutputSuppressesFailureVocabularyAndStaleErrorReason() {
        let resolved = promptTransformMessage(
            transformedPrompt: "Prompt mejorado completo",
            transformStatus: "failed",
            transformErrorReason: "stale_failure"
        )

        XCTAssertFalse(KycodePromptTransformStatePolicy.isFailed(resolved))
    }

    func testProcessingPromptKeepsReconciliationWhenSessionIsReady() {
        let processing = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "processing"
        )

        XCTAssertTrue(
            KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(in: [processing])
        )
        XCTAssertTrue(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: false,
                hasPendingPromptTransform: true,
                activityStatus: "ready",
                runtimeStatus: "WAITING"
            )
        )
    }

    func testResolvedOutputSuppressesEveryActiveVocabularyStatus() {
        let activeStatuses = [
            "pending",
            "queued",
            "processing",
            "running",
            "in_progress",
            "in-progress",
            "started",
        ]

        for status in activeStatuses {
            let resolved = promptTransformMessage(
                transformedPrompt: "Prompt mejorado completo",
                transformStatus: status
            )
            XCTAssertFalse(
                KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
                    for: resolved,
                    responseIsProcessing: false
                ),
                "Una salida autoritativa debe resolver \(status)"
            )
            XCTAssertFalse(
                KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(in: [resolved])
            )
        }
    }

    func testUnknownPromptTransformStatusStaysNeutral() {
        let unknown = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "future_state"
        )

        XCTAssertFalse(KycodePromptTransformStatePolicy.isPending(unknown))
        XCTAssertFalse(KycodePromptTransformStatePolicy.isFailed(unknown))
    }

    func testPromptRetryPolicyKeepsWaitingForStaleErrorSnapshot() {
        let staleFailure = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "error",
            transformErrorReason: "sidecar_unavailable"
        )

        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: promptRetryIntent(expiresAt: 200),
                detail: detail(messages: [staleFailure], updatedAt: 100),
                now: 101
            ),
            .keepWaiting
        )
    }

    func testPromptRetryPolicyResolvesOnlyMatchingMessageOutput() {
        let otherResolvedMessage = KycodeMessage(
            id: "other-user-message",
            role: "user",
            type: "user",
            content: "Otro prompt",
            originalPrompt: "Otro prompt",
            transformedPrompt: "Otro resultado",
            improvedPrompt: "Otro resultado",
            timestamp: 90,
            status: nil,
            imageAttachments: nil,
            transformStatus: "done"
        )
        let targetStillFailed = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "error"
        )
        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: promptRetryIntent(expiresAt: 200),
                detail: detail(messages: [otherResolvedMessage, targetStillFailed]),
                now: 101
            ),
            .keepWaiting
        )

        let targetResolved = promptTransformMessage(
            transformedPrompt: "Prompt mejorado completo",
            transformStatus: "done"
        )
        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: promptRetryIntent(expiresAt: 200),
                detail: detail(messages: [targetResolved], updatedAt: 101),
                now: 102
            ),
            .resolved
        )
    }

    func testPromptRetryPolicyStopsOnNewFailureOnlyAfterObservedActivePhase() {
        let freshFailure = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "cancelled",
            transformErrorReason: "retry_cancelled"
        )
        var intent = promptRetryIntent(expiresAt: 200)

        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: intent,
                detail: detail(messages: [freshFailure], updatedAt: 101),
                now: 102
            ),
            .keepWaiting
        )

        let active = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "processing"
        )
        intent.phase = KycodePromptRetryReconciliationPolicy.phase(
            after: detail(messages: [active], updatedAt: 101),
            for: intent
        )
        XCTAssertEqual(intent.phase, .observedActive)
        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: intent,
                detail: detail(messages: [freshFailure], updatedAt: 102),
                now: 103
            ),
            .failed
        )
    }

    func testPromptRetryPolicyExpiresWithoutAuthoritativeResolution() {
        XCTAssertEqual(
            KycodePromptRetryReconciliationPolicy.decision(
                intent: promptRetryIntent(expiresAt: 200),
                detail: nil,
                now: 200
            ),
            .expired
        )
    }

    func testPromptRetryIntentKeepsReadySessionReconciliationBounded() {
        XCTAssertTrue(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: false,
                activityStatus: "ready",
                runtimeStatus: "WAITING",
                hasPendingPromptRetry: true
            )
        )
        XCTAssertEqual(
            KycodeMessageReconciliationPolicy.retryDelayMilliseconds.reduce(0, +),
            103_000
        )
    }

    func testReconciliationContinuesForUnresolvedPromptTransformAfterSessionIsReady() {
        let pending = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "pending"
        )

        XCTAssertTrue(
            KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(in: [pending])
        )
        XCTAssertTrue(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: false,
                hasPendingPromptTransform: true,
                activityStatus: "ready",
                runtimeStatus: "READY"
            )
        )
    }

    func testSessionFallbackCompletesPromptTransformReconciliation() {
        let pending = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "pending"
        )

        XCTAssertFalse(
            KycodePromptTransformStatePolicy.hasUnresolvedPendingTransform(
                in: [pending],
                sessionImprovedPrompt: "Prompt mejorado por Fermín"
            )
        )
    }

    func testUnresolvedPendingMessageIDsUsesTheSameFallbackSemanticsAsReconciliation() {
        let pending = promptTransformMessage(
            transformedPrompt: nil,
            transformStatus: "processing"
        )

        XCTAssertEqual(
            KycodePromptTransformStatePolicy.unresolvedPendingMessageIDs(in: [pending]),
            ["user-transform-1"]
        )
        XCTAssertEqual(
            KycodePromptTransformStatePolicy.unresolvedPendingMessageIDs(
                in: [pending],
                sessionImprovedPrompt: "Prompt mejorado por Fermín"
            ),
            []
        )
    }

    func testChronologyPolicyRepairsTenInversionsBeforeSelectingTheVisibleTail() {
        let firstRetriedMessageId = "mobile-user-54f78bb3-2cbe-4c38-b39c-b6e4d01f054d"
        let secondRetriedMessageId = "mobile-user-38ff4c6a-05ee-40fc-871d-1d398976fd75"
        let baseTimestamp = 1_786_000_000_000.0
        let chronological = (0..<24).map { index in
            let id: String
            switch index {
            case 5:
                id = firstRetriedMessageId
            case 15:
                id = secondRetriedMessageId
            default:
                id = "chronological-\(index)"
            }
            return message(
                id: id,
                role: index.isMultiple(of: 2) ? "assistant" : "user",
                content: "Mensaje \(index)",
                timestamp: baseTimestamp + Double(index * 1_000)
            )
        }
        let deferredIndices = Array(stride(from: 1, through: 19, by: 2))
        let deferredIndexSet = Set(deferredIndices)
        let snapshotOrder = chronological.filter { message in
            guard let index = chronological.firstIndex(where: { $0.id == message.id }) else {
                return false
            }
            return !deferredIndexSet.contains(index)
        } + deferredIndices.reversed().map { chronological[$0] }

        let adjacentInversions = zip(snapshotOrder, snapshotOrder.dropFirst()).filter {
            $0.timestamp > $1.timestamp
        }.count
        XCTAssertEqual(adjacentInversions, 10)

        let ordered = KycodeMessageChronologyPolicy.ordered(snapshotOrder)
        XCTAssertEqual(ordered.map(\.id), chronological.map(\.id))

        let visibleTailIds = Array(ordered.suffix(5)).map(\.id)
        XCTAssertEqual(visibleTailIds, chronological.suffix(5).map(\.id))
        XCTAssertFalse(visibleTailIds.contains(firstRetriedMessageId))
        XCTAssertFalse(visibleTailIds.contains(secondRetriedMessageId))
    }

    func testChronologyPolicyNormalizesTimestampUnitsAndKeepsEqualTimesStable() {
        let older = message(
            id: "older",
            role: "assistant",
            content: "Anterior",
            timestamp: 1_785_999_999_000
        )
        let secondsFirst = message(
            id: "seconds-first",
            role: "user",
            content: "Misma hora en segundos",
            timestamp: 1_786_000_000
        )
        let millisecondsSecond = message(
            id: "milliseconds-second",
            role: "assistant",
            content: "Misma hora en milisegundos",
            timestamp: 1_786_000_000_000
        )

        XCTAssertEqual(
            KycodeMessageChronologyPolicy
                .ordered([secondsFirst, millisecondsSecond, older])
                .map(\.id),
            ["older", "seconds-first", "milliseconds-second"]
        )
    }

    func testLiveRetryPatchReturnsToItsChronologicalPositionInsteadOfTheArrayTail() {
        let retryId = "mobile-user-54f78bb3-2cbe-4c38-b39c-b6e4d01f054d"
        let patch = KycodeLiveMessagePatch(
            windowId: "win-1",
            message: message(
                id: retryId,
                role: "user",
                content: "Reintento de un turno anterior",
                timestamp: 1_786_000_002_000
            ),
            revision: 1,
            updatedAt: 1_786_000_010_000,
            final: true
        )
        let result = KycodeLiveMessageReducer.applying(
            patch,
            to: detail(messages: [
                message(
                    id: "earlier",
                    role: "assistant",
                    content: "Anterior",
                    timestamp: 1_786_000_001_000
                ),
                message(
                    id: "current-tail",
                    role: "assistant",
                    content: "Último mensaje real",
                    timestamp: 1_786_000_009_000
                ),
            ])
        )

        XCTAssertEqual(result.messages?.map(\.id), ["earlier", retryId, "current-tail"])
        XCTAssertEqual(result.lastMessagePreview, "Último mensaje real")
    }

    func testSessionFallbackUsesChronologicalLatestUserWhenOldRetryWasAppended() {
        let olderRetry = KycodeMessage(
            id: "mobile-user-38ff4c6a-05ee-40fc-871d-1d398976fd75",
            role: "user",
            type: "user",
            content: "Turno anterior",
            originalPrompt: "Turno anterior",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 1_786_000_001_000,
            status: nil,
            imageAttachments: nil,
            transformStatus: "processing"
        )
        let actualLatest = KycodeMessage(
            id: "actual-latest-user",
            role: "user",
            type: "user",
            content: "Turno actual",
            originalPrompt: "Turno actual",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 1_786_000_010_000,
            status: nil,
            imageAttachments: nil,
            transformStatus: "processing"
        )

        XCTAssertEqual(
            KycodePromptTransformStatePolicy.unresolvedPendingMessageIDs(
                in: [actualLatest, olderRetry],
                sessionImprovedPrompt: "Fallback del turno actual"
            ),
            [olderRetry.id]
        )
    }

    func testLongProgressiveContentIsPreservedByteForByte() {
        let longContent = Array(repeating: "línea completa sin recorte", count: 1_000)
            .joined(separator: "\n")
        let result = KycodeLiveMessageReducer.applying(
            patch(content: longContent, updatedAt: 240, final: true),
            to: detail(messages: [])
        )
        XCTAssertEqual(result.messages?.first?.content, longContent)
        XCTAssertEqual(result.messages?.first?.content.count, longContent.count)
    }

    func testGoalModeSurvivesProgressiveMessageReduction() throws {
        let data = Data(
            """
            {
              "windowId":"win-1",
              "sessionId":"session-1",
              "engine":"codex",
              "projectKey":"project",
              "displayName":"QA",
              "sidecarMode":"local",
              "activityStatus":"working",
              "runMode":"goal",
              "goalStartedAt":1234,
              "messageCount":0,
              "updatedAt":100,
              "canSend":true
            }
            """.utf8
        )
        let goalDetail = try JSONDecoder().decode(KycodeSessionSummary.self, from: data)
        let result = KycodeLiveMessageReducer.applying(
            patch(content: "fragmento", updatedAt: 200, final: false),
            to: goalDetail
        )
        XCTAssertTrue(result.goalModeEnabled)
        XCTAssertEqual(result.goalStartedAt, 1234)
    }

    func testCollaborationProjectSurvivesProgressiveMessageReduction() {
        var assigned = detail(messages: [])
        assigned.collaborationProjectId = "collaboration-project:kycode"
        assigned.collaborationProjectName = "kycode"
        assigned.sessionName = "Project metadata QA"

        let result = KycodeLiveMessageReducer.applying(
            patch(content: "fragmento", updatedAt: 200, final: false),
            to: assigned
        )

        XCTAssertEqual(result.collaborationProjectId, "collaboration-project:kycode")
        XCTAssertEqual(result.collaborationProjectName, "kycode")
        XCTAssertEqual(result.sessionName, "Project metadata QA")
    }

    func testDetailReconciliationPreservesProjectWhenOlderSidecarOmitsIt() {
        var current = detail(messages: [])
        current.collaborationProjectId = "collaboration-project:fermin"
        current.collaborationProjectName = "fermin"
        current.sessionName = "Informe conceptual"
        let incoming = detail(messages: [
            message(id: "assistant-1", role: "assistant", content: "actualizado")
        ])

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: current,
            incoming: incoming
        )

        XCTAssertEqual(merged.collaborationProjectId, "collaboration-project:fermin")
        XCTAssertEqual(merged.collaborationProjectName, "fermin")
        XCTAssertEqual(merged.sessionName, "Informe conceptual")
        XCTAssertEqual(merged.messages?.map(\.id), ["assistant-1"])
    }

    func testPatchOrderingAcceptsGrowingRevisionWithSameTimestamp() {
        let cursor = KycodeLiveMessagePatchCursor(
            revision: 7,
            updatedAt: 200,
            final: false
        )
        XCTAssertTrue(
            KycodeLiveMessagePatchOrderingPolicy.shouldApply(
                patch(content: "Empiezo y sigo", updatedAt: 200, final: false),
                after: cursor,
                currentContent: "Empiezo"
            )
        )
    }

    func testPatchOrderingAcceptsFinalTransitionWithoutNewTimestamp() {
        let partial = patch(content: "listo", updatedAt: 230, final: false)
        let final = patch(content: "listo", updatedAt: 230, final: true)
        XCTAssertTrue(
            KycodeLiveMessagePatchOrderingPolicy.shouldApply(
                final,
                after: KycodeLiveMessagePatchOrderingPolicy.cursor(for: partial),
                currentContent: "listo"
            )
        )
    }

    func testPatchOrderingRejectsExactDuplicate() {
        let candidate = patch(content: "sin cambios", updatedAt: 240, final: false)
        XCTAssertFalse(
            KycodeLiveMessagePatchOrderingPolicy.shouldApply(
                candidate,
                after: KycodeLiveMessagePatchOrderingPolicy.cursor(for: candidate),
                currentContent: "sin cambios"
            )
        )
    }

    func testVisualStreamBypassesShortAndAccessibilitySensitiveContent() {
        XCTAssertFalse(
            KycodeMobileVisualStreamPolicy.shouldAnimate(
                enabled: true,
                reduceMotion: false,
                voiceOverRunning: false,
                lowPowerMode: false,
                contentLength: 12
            )
        )
        XCTAssertFalse(
            KycodeMobileVisualStreamPolicy.shouldAnimate(
                enabled: true,
                reduceMotion: true,
                voiceOverRunning: false,
                lowPowerMode: false,
                contentLength: 120
            )
        )
        XCTAssertFalse(
            KycodeMobileVisualStreamPolicy.shouldAnimate(
                enabled: true,
                reduceMotion: false,
                voiceOverRunning: true,
                lowPowerMode: false,
                contentLength: 120
            )
        )
    }

    func testVisualStreamAnimatesEligibleAssistantContent() {
        XCTAssertTrue(
            KycodeMobileVisualStreamPolicy.shouldAnimate(
                enabled: true,
                reduceMotion: false,
                voiceOverRunning: false,
                lowPowerMode: false,
                contentLength: 120
            )
        )
    }

    func testVisualStreamBypassesVeryLargeAssistantContent() {
        XCTAssertFalse(
            KycodeMobileVisualStreamPolicy.shouldAnimate(
                enabled: true,
                reduceMotion: false,
                voiceOverRunning: false,
                lowPowerMode: false,
                contentLength: KycodeMobileVisualStreamPolicy.maximumAnimatedCharacterCount + 1
            )
        )
    }

    func testVisualStreamProgressIsMonotonicAndBounded() {
        var current = 0
        let target = 2_000
        var iterations = 0
        while current < target {
            let next = KycodeMobileVisualStreamPolicy.nextVisibleCharacterCount(
                current: current,
                target: target
            )
            XCTAssertGreaterThan(next, current)
            XCTAssertLessThanOrEqual(next, target)
            current = next
            iterations += 1
            XCTAssertLessThan(iterations, 200)
        }
        XCTAssertEqual(current, target)
    }

    func testVisualStreamUsesAdaptiveChunkSizes() {
        let nearTargetStep =
            KycodeMobileVisualStreamPolicy.nextVisibleCharacterCount(current: 900, target: 1_000) - 900
        let backloggedStep =
            KycodeMobileVisualStreamPolicy.nextVisibleCharacterCount(current: 0, target: 4_000)
        XCTAssertGreaterThan(backloggedStep, nearTargetStep)
    }

    func testReconciliationPolicyKeepsPollingWhileOptimisticMessageIsPending() {
        XCTAssertTrue(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: true,
                activityStatus: "done",
                runtimeStatus: "WAITING"
            )
        )
    }

    func testReconciliationPolicyStopsWhenDurableStateIsReadyDespiteStaleRuntime() {
        XCTAssertFalse(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: false,
                activityStatus: "ready",
                runtimeStatus: "working"
            )
        )
    }

    func testOptimisticSendResolvesAgainstAuthoritativeUserMessageEvenWhenReady() {
        XCTAssertTrue(
            KycodeOptimisticSendActivityPolicy.shouldResolvePendingMessage(
                hasMatchingServerMessage: true,
                hasAssistantResponse: false,
                activityStatus: "ready",
                runtimeStatus: "WAITING"
            )
        )
    }

    func testOptimisticSendResolvesWhenProcessingStarts() {
        XCTAssertTrue(
            KycodeOptimisticSendActivityPolicy.shouldResolvePendingMessage(
                hasMatchingServerMessage: true,
                hasAssistantResponse: false,
                activityStatus: "working",
                runtimeStatus: "WORKING"
            )
        )
    }

    func testOptimisticSendDoesNotResolveOnAssistantResponseOrErrorAlone() {
        XCTAssertFalse(
            KycodeOptimisticSendActivityPolicy.shouldResolvePendingMessage(
                hasMatchingServerMessage: false,
                hasAssistantResponse: true,
                activityStatus: "ready",
                runtimeStatus: "WAITING"
            )
        )
        XCTAssertFalse(
            KycodeOptimisticSendActivityPolicy.shouldResolvePendingMessage(
                hasMatchingServerMessage: false,
                hasAssistantResponse: false,
                activityStatus: "error",
                runtimeStatus: "WAITING"
            )
        )
    }

    func testOptimisticMessageMatchesAuthoritativeStableIdentity() {
        let optimistic = message(
            id: "mobile-user-stable-1",
            role: "user",
            content: "mensaje estable",
            timestamp: 1_785_200_000_000
        )
        let authoritative = message(
            id: "mobile-user-stable-1",
            role: "user",
            content: "USER ORIGINAL PROMPT: mensaje estable",
            originalPrompt: "mensaje estable",
            timestamp: 1_785_200_001_000
        )

        XCTAssertEqual(
            KycodeOptimisticMessageReconciliationPolicy.matchingAuthoritativeMessage(
                for: optimistic,
                in: [authoritative]
            )?.id,
            optimistic.id
        )
    }

    func testOptimisticMessageDoesNotMatchAssistantOnlySnapshot() {
        let optimistic = message(
            id: "mobile-user-stable-2",
            role: "user",
            content: "mensaje que no debe desaparecer",
            timestamp: 1_785_210_000_000
        )
        let assistant = message(
            id: "assistant-fast",
            role: "assistant",
            content: "respuesta rápida",
            timestamp: 1_785_210_001_000
        )

        XCTAssertNil(
            KycodeOptimisticMessageReconciliationPolicy.matchingAuthoritativeMessage(
                for: optimistic,
                in: [assistant]
            )
        )
    }

    func testPatchOrderingRejectsLatePrefixRegression() {
        XCTAssertFalse(
            KycodeLiveMessagePatchOrderingPolicy.shouldApply(
                patch(content: "Voy a cerrar", updatedAt: 300, final: false),
                after: nil,
                currentContent: "Voy a cerrarlos como dos pruebas completas"
            )
        )
    }

    func testDetailReconciliationNeverDropsExistingMessages() {
        let current = detail(messages: [
            message(id: "user-1", role: "user", content: "pedido"),
            message(id: "assistant-1", role: "assistant", content: "respuesta completa"),
        ])
        let incoming = detail(messages: [
            message(id: "user-1", role: "user", content: "pedido"),
        ])

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: current,
            incoming: incoming
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(merged.messages?.last?.content, "respuesta completa")
    }

    func testLightweightSnapshotWithEmptyMessagesPreservesLoadedTranscript() {
        let current = detail(messages: [
            message(id: "user-1", role: "user", content: "pedido"),
            message(id: "assistant-1", role: "assistant", content: "respuesta completa"),
        ])

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: current,
            incoming: detail(messages: [])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(merged.messages?.last?.content, "respuesta completa")
    }

    func testDetailReconciliationRejectsShorterContentForSameMessage() {
        let current = detail(messages: [
            message(id: "assistant-1", role: "assistant", content: "Voy a cerrarlos como dos pruebas completas"),
        ])
        let incoming = detail(messages: [
            message(
                id: "assistant-1",
                role: "assistant",
                content: "Voy a cerrar",
                status: "streaming"
            ),
        ])

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: current,
            incoming: incoming
        )

        XCTAssertEqual(
            merged.messages?.first?.content,
            "Voy a cerrarlos como dos pruebas completas"
        )
        XCTAssertNil(merged.messages?.first?.status)
    }

    func testDetailReconciliationReplacesOptimisticUserAliasWithCanonicalMessage() {
        let optimistic = message(
            id: "optimistic-1",
            role: "user",
            content: "Ok, continúa como vienes. Vienes genial.",
            timestamp: 1_785_000_000_000
        )
        let canonical = message(
            id: "server-user-1",
            role: "user",
            content: "USER ORIGINAL PROMPT: Ok, continúa como vienes. Vienes genial.",
            originalPrompt: "Ok, continúa como vienes. Vienes genial.",
            timestamp: 1_785_000_004_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [optimistic]),
            incoming: detail(messages: [canonical])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["server-user-1"])
    }

    func testDetailReloadAcceptsDelayedCanonicalUserAndPreservesAssistantExactlyOnce() {
        let optimistic = message(
            id: "mobile-user-reload-1",
            role: "user",
            content: "mensaje antes de reconectar",
            timestamp: 1_785_050_000_000
        )
        let assistant = message(
            id: "assistant-before-reload",
            role: "assistant",
            content: "respuesta que llegó primero",
            timestamp: 1_785_050_004_000
        )
        let canonical = message(
            id: "mobile-user-reload-1",
            role: "user",
            content: "mensaje antes de reconectar",
            timestamp: 1_785_050_001_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [optimistic, assistant]),
            incoming: detail(messages: [canonical])
        )

        XCTAssertEqual(
            merged.messages?.map(\.id),
            ["mobile-user-reload-1", "assistant-before-reload"]
        )
    }

    func testDetailReconciliationReplacesLiveAssistantAliasWithCanonicalMessage() {
        let live = message(
            id: "timeline-live-1",
            role: "assistant",
            content: "La recuperación quedó verificada.",
            status: "streaming",
            timestamp: 1_785_100_000_000
        )
        let canonical = message(
            id: "server-assistant-1",
            role: "assistant",
            content: "La recuperación quedó verificada.",
            timestamp: 1_785_100_002_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [live]),
            incoming: detail(messages: [canonical])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["server-assistant-1"])
        XCTAssertNil(merged.messages?.first?.status)
    }

    func testDetailReconciliationPreservesLegitimateRepeatedMessagesFromServer() {
        let first = message(
            id: "server-user-1",
            role: "user",
            content: "seguí",
            timestamp: 1_785_200_000_000
        )
        let second = message(
            id: "server-user-2",
            role: "user",
            content: "seguí",
            timestamp: 1_785_200_005_000
        )
        let optimistic = message(
            id: "optimistic-user",
            role: "user",
            content: "seguí",
            timestamp: 1_785_200_004_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [optimistic]),
            incoming: detail(messages: [first, second])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["server-user-1", "server-user-2"])
    }

    func testDetailReconciliationCollapsesDurableReplayAliasFromProduction() {
        let replayAlias = message(
            id: "timeline-item-86",
            role: "assistant",
            content: "La auditoría física confirma que los controles ya no existen.",
            timestamp: 1_785_250_000_000
        )
        let canonical = message(
            id: "timeline-msg_0c41422e7fcab58b",
            role: "assistant",
            content: "La auditoría física confirma que los controles ya no existen.",
            timestamp: 1_785_250_000_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: []),
            incoming: detail(messages: [replayAlias, canonical])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["timeline-msg_0c41422e7fcab58b"])
    }

    func testDetailReconciliationCollapsesOptimisticAliasInsideDurableSnapshot() {
        let optimistic = message(
            id: "optimistic-legacy",
            role: "user",
            content: "seguí",
            timestamp: 1_785_260_000_000
        )
        let canonical = message(
            id: "server-user-legacy",
            role: "user",
            content: "seguí",
            timestamp: 1_785_260_003_000
        )

        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: []),
            incoming: detail(messages: [optimistic, canonical])
        )

        XCTAssertEqual(merged.messages?.map(\.id), ["server-user-legacy"])
    }

    func testMessageAliasPolicyDoesNotCollapseSameTextOutsideReconciliationWindow() {
        let earlier = message(
            id: "earlier",
            role: "user",
            content: "mismo texto",
            timestamp: 1_785_300_000_000
        )
        let later = message(
            id: "later",
            role: "user",
            content: "mismo texto",
            timestamp: 1_785_300_120_000
        )

        XCTAssertFalse(KycodeMessageAliasPolicy.areAliases(earlier, later))
        let merged = KycodeSessionDetailReconciliationPolicy.merging(
            current: detail(messages: [earlier]),
            incoming: detail(messages: [later])
        )
        XCTAssertEqual(merged.messages?.map(\.id), ["earlier", "later"])
    }

    func testGenuineWorkingActivityStillDrivesProcessing() {
        XCTAssertTrue(
            KycodeSessionActivityPolicy.isProcessing(
                activityStatus: "working",
                runtimeStatus: "WORKING"
            )
        )
        XCTAssertFalse(
            KycodeSessionActivityPolicy.isProcessing(
                activityStatus: "error",
                runtimeStatus: "WORKING"
            )
        )
    }

    func testReconciliationPolicyStopsAfterAuthoritativeResponseSettles() {
        XCTAssertFalse(
            KycodeMessageReconciliationPolicy.shouldContinue(
                hasPendingOptimisticMessage: false,
                activityStatus: "done",
                runtimeStatus: "WAITING"
            )
        )
        XCTAssertEqual(
            KycodeMessageReconciliationPolicy.retryDelayMilliseconds.reduce(0, +),
            103_000
        )
        XCTAssertEqual(KycodeMessageReconciliationPolicy.retryDelayMilliseconds.count, 10)
    }

    private func patch(
        content: String,
        updatedAt: Double,
        final: Bool
    ) -> KycodeLiveMessagePatch {
        KycodeLiveMessagePatch(
            windowId: "win-1",
            message: message(
                id: "timeline-1",
                role: "assistant",
                content: content,
                status: final ? nil : "streaming"
            ),
            revision: content.count,
            updatedAt: updatedAt,
            final: final
        )
    }

    private func message(
        id: String,
        role: String,
        content: String,
        status: String? = nil,
        originalPrompt: String? = nil,
        timestamp: Double = 100
    ) -> KycodeMessage {
        KycodeMessage(
            id: id,
            role: role,
            type: role == "user" ? "user" : "codex",
            content: content,
            originalPrompt: originalPrompt,
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: timestamp,
            status: status,
            imageAttachments: nil
        )
    }

    private func promptTransformMessage(
        transformedPrompt: String?,
        transformStatus: String,
        transformErrorReason: String? = nil
    ) -> KycodeMessage {
        KycodeMessage(
            id: "user-transform-1",
            role: "user",
            type: "user",
            content: "Prompt original",
            originalPrompt: "Prompt original",
            transformedPrompt: transformedPrompt,
            improvedPrompt: transformedPrompt,
            timestamp: 100,
            status: nil,
            imageAttachments: nil,
            transformStatus: transformStatus,
            transformErrorReason: transformErrorReason,
            promptTransformNote: transformedPrompt == nil ? nil : "Mejorado"
        )
    }

    private func promptRetryIntent(expiresAt: TimeInterval) -> KycodePromptRetryIntent {
        KycodePromptRetryIntent(
            attemptId: UUID(uuidString: "B80F56E9-EA80-43CF-A1DB-6AA8BDA201A5")!,
            windowId: "win-1",
            profileId: "puky",
            remoteWindowId: "win-1",
            sessionId: "session-1",
            messageId: "user-transform-1",
            generation: 7,
            baselineDetailUpdatedAt: 100,
            baselineTransformStatus: "error",
            baselineTransformErrorReason: "old_failure",
            baselineTransformedPrompt: nil,
            baselineImprovedPrompt: nil,
            baselineSessionImprovedPrompt: nil,
            expiresAt: expiresAt,
            phase: .awaitingAttempt
        )
    }

    private func detail(
        messages: [KycodeMessage],
        activityStatus: String = "ready",
        runtimeStatus: String? = "WAITING",
        runtimeStatusDetail: String? = nil,
        updatedAt: Double = 100
    ) -> KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: "win-1",
            sessionId: "session-1",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "project",
            projectPath: "/tmp/project",
            projectName: "Project",
            windowName: "QA",
            displayName: "QA",
            sidecarMode: "local",
            sidecarUrl: nil,
            activityStatus: activityStatus,
            runtimeStatus: runtimeStatus,
            runtimeStatusDetail: runtimeStatusDetail,
            features: nil,
            messageCount: messages.count,
            updatedAt: updatedAt,
            createdAt: 1,
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
    }
}
