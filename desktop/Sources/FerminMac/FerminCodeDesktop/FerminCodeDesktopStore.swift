import AppKit
import Combine
import Foundation
import FerminCore
import UniformTypeIdentifiers

struct FerminCodeDesktopTiming: @unchecked Sendable {
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (UInt64) async -> Void

    static let production = FerminCodeDesktopTiming(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }
    )
}

private struct FerminCodeDesktopFailedComposerDraft: Sendable {
    let text: String
    let attachments: [FerminCodeDesktopAttachmentDraft]
}

private struct FerminCodeDesktopComposerDraftState: Sendable {
    let text: String
    let attachments: [FerminCodeDesktopAttachmentDraft]
}

private struct FerminCodeDesktopSubagentDraftState: Sendable {
    let displayName: String
    let task: String
}

private struct FerminCodeDesktopSessionIdentity: Hashable, Sendable {
    let source: FerminCodeRelaySource
    let windowID: String
    let sessionID: String

    init?(route: FerminCodeRelaySessionRoute, sessionID: String) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        source = route.source
        windowID = route.windowID
        self.sessionID = normalizedSessionID
    }

    var id: String {
        "\(source.rawValue)::session::\(sessionID)::\(windowID)"
    }
}

private struct FerminCodeDesktopDetailRecoveryContext: Equatable, Sendable {
    let route: FerminCodeRelaySessionRoute?
    let identity: FerminCodeDesktopSessionIdentity?
    let requestID: UUID?
}

private struct FerminCodeDesktopCachedDetail: Sendable {
    let messages: [FerminRelayMessage]
    let reportedMessageCount: Int
    let capturedAt: TimeInterval
}

private struct FerminCodeDesktopQueuedFeatureMutation {
    let route: FerminCodeRelaySessionRoute
    let identity: FerminCodeDesktopSessionIdentity
    let token: String
    let patch: FerminRelayFeaturePatch
}

private struct FerminCodeDesktopQueuedGoalMutation {
    let route: FerminCodeRelaySessionRoute
    let token: String
    let enabled: Bool
    let mutationID: String
}

private struct FerminCodeDesktopPinnedStateOverride {
    let pinned: Bool
    let mutationID: String
    let baselineUpdatedAt: Double
    let expiresAt: Date
}

@MainActor
final class FerminCodeDesktopStore: ObservableObject {
    private static let detailCacheEntryLimit = 4
    private static let detailCacheMessageLimit = 80
    private static let detailCacheByteLimit = 1_048_576
    private static let detailCacheTTL: TimeInterval = 5 * 60
    private static let pinnedStateOverrideTTL: TimeInterval = 8

    @Published private(set) var profile: FerminCodeRelayProfile = .todo
    @Published private(set) var sourceStatuses: [FerminCodeRelaySource: FerminCodeDesktopSourceStatus]
    @Published private(set) var sourcedSessions: [FerminCodeRelaySourcedSession] = []
    @Published private(set) var unpinnedSessionIDs = Set<String>()
    @Published private var pinnedStateOverridesByRoute:
        [FerminCodeRelaySessionRoute: FerminCodeDesktopPinnedStateOverride] = [:]
    @Published private(set) var selectedRoute: FerminCodeRelaySessionRoute?
    @Published private(set) var selectedSession: FerminRelaySession?
    private var selectedSessionIdentity: FerminCodeDesktopSessionIdentity? {
        guard let selectedRoute, let selectedSession else { return nil }
        return FerminCodeDesktopSessionIdentity(
            route: selectedRoute,
            sessionID: selectedSession.sessionID
        )
    }
    var selectedSessionInstanceID: String? {
        selectedSessionIdentity?.id
    }
    @Published private(set) var models: [FerminRelayAvailableModel] = []
    @Published private(set) var projects: [FerminRelayProjectDirectory] = []
    @Published private(set) var historyItems: [FerminCodeDesktopSourcedHistoryItem] = []
    @Published private(set) var historyTotal = 0
    @Published private(set) var recoveryItems: [FerminCodeDesktopSourcedRecoveryItem] = []
    @Published private(set) var recoveryTotal = 0
    @Published private(set) var promptPreferences: [FerminCodeRelaySource: FerminRelayPromptImproverPreference] = [:]
    @Published private(set) var pendingCommands: [String: FerminCodeDesktopPendingCommand] = [:]
    @Published private(set) var credentialPresence: [FerminCodeRelaySource: Bool] = [:]
    @Published private(set) var liveMessages: [String: FerminCodeDesktopLiveMessage] = [:]
    @Published private(set) var optimisticMessages: [FerminCodeDesktopOptimisticMessage] = []
    @Published private(set) var isBootstrapping = true
    @Published private var featureOverridesBySessionIdentity:
        [FerminCodeDesktopSessionIdentity: FerminRelaySessionFeatures] = [:]
    @Published private(set) var goalModeOverridesByRoute:
        [FerminCodeRelaySessionRoute: Bool] = [:]
    @Published private(set) var goalModeDraftsByRoute:
        [FerminCodeRelaySessionRoute: Bool] = [:]
    @Published private(set) var runtimeModelOverridesByRoute:
        [FerminCodeRelaySessionRoute: FerminRelayRuntimeModelSettings] = [:]
    @Published private(set) var attachments: [FerminCodeDesktopAttachmentDraft] = []
    @Published private(set) var preview: FerminCodeDesktopPreview?
    @Published private(set) var isRefreshing = false
    @Published private(set) var detailLoadState = FerminCodeDesktopDetailLoadState.idle
    @Published private(set) var historyLoadState = FerminCodeDesktopHistoryLoadState.idle
    @Published private(set) var recoveryLoadState = FerminCodeDesktopHistoryLoadState.idle
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isLoadingProjects = false
    @Published private(set) var isCreatingSession = false
    @Published private(set) var creationPhase = FerminCodeDesktopCreationPhase.idle
    @Published private(set) var isSending = false
    @Published private var activeSendIdentity: FerminCodeDesktopSessionIdentity?
    @Published private(set) var isAddingAttachments = false
    @Published private(set) var activeMutations = Set<String>()
    @Published private(set) var notice: String? {
        didSet {
            guard oldValue != notice else { return }
            feedbackGeneration &+= 1
        }
    }
    @Published private(set) var composerSendErrorMessage: String?
    @Published var errorMessage: String? {
        didSet {
            if errorMessage != composerSendErrorMessage {
                composerSendErrorMessage = nil
                composerSendFailureMessageID = nil
            }
            if oldValue != errorMessage {
                feedbackGeneration &+= 1
            }
            guard errorMessage != nil else { return }
            notice = nil
            noticeDismissalTask?.cancel()
            noticeDismissalTask = nil
        }
    }

    var isLoadingHistory: Bool {
        historyLoadState.isLoading
    }
    var isLoadingRecovery: Bool {
        recoveryLoadState.isLoading
    }
    @Published var searchText = ""
    @Published private(set) var sessionSearchFocusRequest = 0
    @Published var includeMinimized = false
    @Published var composerText = ""
    @Published var subagentDisplayNameDraft = ""
    @Published var subagentTaskDraft = ""
    @Published var isCreatePresented = false
    @Published var isHistoryPresented = false {
        didSet {
            guard oldValue != isHistoryPresented else { return }
            historyResumeIntentID = nil
        }
    }
    @Published var isRecoveryPresented = false {
        didSet {
            guard oldValue != isRecoveryPresented else { return }
            recoveryIntentID = nil
        }
    }
    @Published var isCredentialsPresented = false
    @Published var isSubagentPresented = false
    @Published var isRenamePresented = false
    @Published var isArchiveConfirmationPresented = false
    @Published var isDeleteConfirmationPresented = false

    private let relay: any FerminCodeDesktopRelayServing
    private let credentialStore: FerminCodeCredentialStore
    private let defaults: UserDefaults
    private let timing: FerminCodeDesktopTiming
    private let createConfirmationTimeout: TimeInterval
    private let createPollNanoseconds: UInt64
    private let commandTrackers: [FerminCodeRelaySource: FerminRelayDurableCommandTracker]
    private var tokens: [FerminCodeRelaySource: String] = [:]
    private var sessionsBySource: [FerminCodeRelaySource: [FerminRelaySession]] = [:]
    private var streamTasks: [FerminCodeRelaySource: Task<Void, Never>] = [:]
    private var periodicRefreshTask: Task<Void, Never>?
    private var noticeDismissalTask: Task<Void, Never>?
    private var composerSendFailureMessageID: String?
    private var startupTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequestID: UUID?
    private var projectsRequestID: UUID?
    private var projectsLoadSource: FerminCodeRelaySource?
    private var projectLoadErrorMessage: String?
    private var historyRequestID: UUID?
    private var historyResumeIntentID: UUID?
    private var recoveryRequestID: UUID?
    private var recoveryIntentID: UUID?
    private var feedbackGeneration: UInt64 = 0
    private var stableHistoryLoadState = FerminCodeDesktopHistoryLoadState.idle
    private var stableRecoveryLoadState = FerminCodeDesktopHistoryLoadState.idle
    private var promptPreferenceRequestIDs: [FerminCodeRelaySource: UUID] = [:]
    private var sourceRefreshRequestIDs: [FerminCodeRelaySource: UUID] = [:]
    private var modelCatalogRequestID: UUID?
    private var modelCatalogErrorMessage: String?
    private var featureOverridePatchesBySessionIdentity:
        [FerminCodeDesktopSessionIdentity: FerminRelayFeaturePatch] = [:]
    private var queuedFeatureMutations:
        [FerminCodeDesktopSessionIdentity: FerminCodeDesktopQueuedFeatureMutation] = [:]
    private var queuedGoalMutations: [String: FerminCodeDesktopQueuedGoalMutation] = [:]
    private var goalModeOverrideMutationIDsByRoute:
        [FerminCodeRelaySessionRoute: String] = [:]
    private var runtimeModelOverrideMutationIDsByRoute:
        [FerminCodeRelaySessionRoute: String] = [:]
    private var failedComposerDrafts: [String: FerminCodeDesktopFailedComposerDraft] = [:]
    private var composerDraftsByRoute: [String: FerminCodeDesktopComposerDraftState] = [:]
    private var subagentDraftsByRoute: [String: FerminCodeDesktopSubagentDraftState] = [:]
    private var cachedDetailsByRoute:
        [FerminCodeDesktopSessionIdentity: FerminCodeDesktopCachedDetail] = [:]
    private var cachedDetailLRU: [FerminCodeDesktopSessionIdentity] = []
    private var hasStarted = false

    init(
        relay: any FerminCodeDesktopRelayServing,
        credentialStore: FerminCodeCredentialStore = FerminCodeCredentialStore(),
        defaults: UserDefaults = .standard,
        timing: FerminCodeDesktopTiming = .production,
        createConfirmationTimeout: TimeInterval = 150,
        createPollNanoseconds: UInt64 = 500_000_000
    ) {
        self.relay = relay
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.timing = timing
        self.createConfirmationTimeout = createConfirmationTimeout
        self.createPollNanoseconds = createPollNanoseconds
        profile = FerminCodeDesktopPreferences.profile(from: defaults)
        unpinnedSessionIDs = FerminCodeDesktopPreferences.unpinnedSessionIDs(from: defaults)
        defaults.removeObject(forKey: "fermin.code.desktop.fastMode")
        commandTrackers = Dictionary(
            uniqueKeysWithValues: FerminCodeRelaySource.allCases.map {
                ($0, FerminRelayDurableCommandTracker())
            }
        )
        sourceStatuses = Dictionary(
            uniqueKeysWithValues: FerminCodeRelaySource.allCases.map {
                (
                    $0,
                    FerminCodeDesktopSourceStatus(
                        source: $0,
                        phase: .loading,
                        sessionCount: 0,
                        detail: nil,
                        lastUpdatedAt: nil
                    )
                )
            }
        )
    }

    deinit {
        startupTask?.cancel()
        detailTask?.cancel()
        periodicRefreshTask?.cancel()
        streamTasks.values.forEach { $0.cancel() }
    }

    var visibleSessions: [FerminCodeRelaySourcedSession] {
        FerminCodeDesktopSessionListPolicy.filterAndSort(
            sourcedSessions,
            profile: profile,
            searchText: searchText,
            includeMinimized: includeMinimized
        )
    }

    var pinnedSessions: [FerminCodeRelaySourcedSession] {
        visibleSessions.filter(isSessionPinned)
    }

    var unpinnedSessions: [FerminCodeRelaySourcedSession] {
        visibleSessions.filter { !isSessionPinned($0) }
    }

    func isSessionPinned(_ item: FerminCodeRelaySourcedSession) -> Bool {
        if let route = try? FerminCodeRelaySessionRoute(
            source: item.source,
            windowID: item.session.windowID
        ), let override = pinnedStateOverridesByRoute[route],
           override.expiresAt > Date() {
            return override.pinned
        }
        return FerminCodeDesktopSessionPinningPolicy.isPinned(
            item,
            unpinnedSessionIDs: unpinnedSessionIDs
        )
    }

    func setSessionPinned(_ item: FerminCodeRelaySourcedSession, pinned: Bool) {
        guard isSessionPinned(item) != pinned else { return }
        guard let route = try? FerminCodeRelaySessionRoute(
            source: item.source,
            windowID: item.session.windowID
        ), let token = tokens[item.source] else {
            errorMessage = "No se pudo conectar con la Mac de origen para sincronizar la sesión."
            return
        }
        let mutationID = UUID().uuidString
        pinnedStateOverridesByRoute[route] = FerminCodeDesktopPinnedStateOverride(
            pinned: pinned,
            mutationID: mutationID,
            baselineUpdatedAt: item.session.updatedAt,
            expiresAt: Date().addingTimeInterval(Self.pinnedStateOverrideTTL)
        )
        showNotice(pinned ? "Sesión fijada." : "Sesión movida a Sin fijar.")
        Task { [weak self] in
            await self?.persistPinnedState(
                route: route,
                sessionID: item.session.sessionID,
                token: token,
                pinned: pinned,
                mutationID: mutationID
            )
        }
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.pinnedStateOverrideTTL * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.expirePinnedStateOverride(route: route, mutationID: mutationID)
        }
    }

    private func persistPinnedState(
        route: FerminCodeRelaySessionRoute,
        sessionID: String,
        token: String,
        pinned: Bool,
        mutationID: String
    ) async {
        let succeeded = await durableMutation(
            key: "pin:\(route.id):\(mutationID)",
            operation: .setPinned,
            route: route,
            targetSessionID: sessionID,
            mutationID: mutationID
        ) {
            try await relay.setPinned(
                source: route.source,
                token: token,
                windowID: route.windowID,
                pinned: pinned
            )
        }
        guard !succeeded,
              pinnedStateOverridesByRoute[route]?.mutationID == mutationID else { return }
        pinnedStateOverridesByRoute.removeValue(forKey: route)
        errorMessage = "No se pudo sincronizar el estado fijado de la sesión. Reintentá."
    }

    private func expirePinnedStateOverride(
        route: FerminCodeRelaySessionRoute,
        mutationID: String
    ) {
        guard pinnedStateOverridesByRoute[route]?.mutationID == mutationID else { return }
        pinnedStateOverridesByRoute.removeValue(forKey: route)
    }

    var displayedMessages: [FerminCodeDesktopPresentedMessage] {
        displayedMessages(limit: .max)
    }

    var isLoadingDetail: Bool {
        detailLoadState.isLoading
    }

    var detailErrorMessage: String? {
        detailLoadState.errorMessage
    }

    func displayedMessages(limit: Int) -> [FerminCodeDesktopPresentedMessage] {
        guard limit > 0 else { return [] }
        let authoritative = selectedSession?.messages ?? []
        let recentAuthoritative = Array(authoritative.suffix(limit))
        let authoritativeIDs = Set(authoritative.map(\.id))
        let recentIDs = Set(recentAuthoritative.map(\.id))
        let relevantLiveMessages = liveMessages.filter { id, _ in
            recentIDs.contains(id) || !authoritativeIDs.contains(id)
        }
        let merged = FerminCodeDesktopTranscriptPolicy.merge(
            authoritative: recentAuthoritative,
            live: relevantLiveMessages,
            optimistic: optimisticMessages
        )
        return Array(merged.suffix(limit))
    }

    var displayedMessageCount: Int {
        var identifiers = Set((selectedSession?.messages ?? []).map(\.id))
        identifiers.formUnion(liveMessages.keys)
        identifiers.formUnion(optimisticMessages.map(\.id))
        return max(selectedSession?.messageCount ?? 0, identifiers.count)
    }

    var loadedMessageCount: Int {
        var identifiers = Set((selectedSession?.messages ?? []).map(\.id))
        identifiers.formUnion(liveMessages.keys)
        identifiers.formUnion(optimisticMessages.map(\.id))
        return identifiers.count
    }

    var hasReportedMessagesMissingFromDetail: Bool {
        displayedMessageCount > loadedMessageCount
    }

    var selectedFeatures: FerminRelaySessionFeatures {
        guard let selectedSessionIdentity else {
            return selectedSession?.features ?? FerminRelaySessionFeatures()
        }
        return featureOverridesBySessionIdentity[selectedSessionIdentity]
            ?? selectedSession?.features
            ?? FerminRelaySessionFeatures()
    }

    var isUpdatingSelectedFeatures: Bool {
        guard let selectedSessionIdentity else { return false }
        return activeMutations.contains(featureMutationKey(for: selectedSessionIdentity))
    }

    var selectedGoalModeEnabled: Bool {
        guard let selectedRoute else {
            return selectedSession?.runMode?.lowercased() == "goal"
        }
        return goalModeDraftsByRoute[selectedRoute]
            ?? committedGoalModeEnabled(for: selectedRoute)
    }

    var hasPendingSelectedGoalModeDraft: Bool {
        guard let selectedRoute else { return false }
        return goalModeDraftsByRoute[selectedRoute] != nil
    }

    var isUpdatingSelectedGoalMode: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(goalMutationKey(for: selectedRoute))
    }

    func stageGoalMode(_ enabled: Bool) {
        guard let selectedRoute else { return }
        if enabled == committedGoalModeEnabled(for: selectedRoute) {
            goalModeDraftsByRoute.removeValue(forKey: selectedRoute)
        } else {
            goalModeDraftsByRoute[selectedRoute] = enabled
        }
        errorMessage = nil
    }

    var isRenamingSelectedSession: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(renameMutationKey(for: selectedRoute))
    }

    var isCreatingSubagentForSelectedSession: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(subagentMutationKey(for: selectedRoute))
    }

    var isUpdatingSelectedSessionVisibility: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(visibilityMutationKey(for: selectedRoute))
    }

    var isArchivingSelectedSession: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(archiveMutationKey(for: selectedRoute))
            || pendingCommands.values.contains {
                $0.source == selectedRoute.source
                    && $0.windowID == selectedRoute.windowID
                    && $0.operation == .archive
            }
    }

    var isDeletingSelectedSession: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(deleteMutationKey(for: selectedRoute))
            || pendingCommands.values.contains {
                $0.source == selectedRoute.source
                    && $0.windowID == selectedRoute.windowID
                    && $0.operation == .delete
            }
    }

    func isRetryingPromptTransform(messageID: String) -> Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(
            promptRetryMutationKey(messageID: messageID, route: selectedRoute)
        )
    }

    var selectedRuntimeModel: String? {
        guard let selectedRoute else { return selectedSession?.model }
        return runtimeModelOverridesByRoute[selectedRoute]?.model ?? selectedSession?.model
    }

    var selectedReasoningEffort: String? {
        guard let selectedRoute else { return selectedSession?.reasoningEffort }
        return runtimeModelOverridesByRoute[selectedRoute]?.effort
            ?? selectedSession?.reasoningEffort
    }

    var isApplyingSelectedRuntimeModel: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(modelMutationKey(for: selectedRoute))
    }

    var availableCreateSources: [FerminCodeRelaySource] {
        profile.sources.filter { credentialPresence[$0] == true }
    }

    var preferredCreateSource: FerminCodeRelaySource? {
        let availableSources = availableCreateSources
        if let selectedSource = selectedRoute?.source,
           availableSources.contains(selectedSource) {
            return selectedSource
        }
        if let onlineSource = availableSources.first(where: {
            sourceStatuses[$0]?.phase == .online
        }) {
            return onlineSource
        }
        return availableSources.first
    }

    var canCreateSession: Bool {
        !isBootstrapping && preferredCreateSource != nil && !isCreatingSession
    }

    var hasPresentedModal: Bool {
        isCreatePresented
            || isHistoryPresented
            || isRecoveryPresented
            || isCredentialsPresented
            || isSubagentPresented
            || isRenamePresented
            || isArchiveConfirmationPresented
            || isDeleteConfirmationPresented
            || preview != nil
    }

    var canInvokeCreateShortcut: Bool {
        canCreateSession && !hasPresentedModal
    }

    var canChangeProfile: Bool {
        !isSending && !isAddingAttachments && !isCreatingSession
    }

    var canSend: Bool {
        guard selectedSession?.canSend == true,
              !isSending,
              !isAddingAttachments,
              composerValidationMessage == nil else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    func effectiveActivityStatus(
        for session: FerminRelaySession,
        route: FerminCodeRelaySessionRoute
    ) -> String {
        guard activeSendIdentity == FerminCodeDesktopSessionIdentity(
            route: route,
            sessionID: session.sessionID
        ) else {
            return session.activityStatus
        }
        return "processing"
    }

    func effectiveActivityStatus(for item: FerminCodeRelaySourcedSession) -> String {
        guard activeSendIdentity?.source == item.source,
              activeSendIdentity?.windowID == item.session.windowID,
              activeSendIdentity?.sessionID == item.session.sessionID else {
            return item.session.activityStatus
        }
        return "processing"
    }

    var composerValidationMessage: String? {
        FerminCodeDesktopComposerTextPresentation.validationMessage(for: composerText)
    }

    var composerBlockingMessage: String? {
        FerminCodeDesktopComposerAvailability.blockingMessage(for: selectedSession)
    }

    var canInvokeComposerShortcut: Bool {
        canSend
            && !hasPresentedModal
            && !isRenamingSelectedSession
            && !isUpdatingSelectedSessionVisibility
            && !isArchivingSelectedSession
            && !isDeletingSelectedSession
    }

    var canInvokeInterruptShortcut: Bool {
        canInterruptSelectedSession && !hasPresentedModal
    }

    var canInterruptSelectedSession: Bool {
        guard let selectedRoute, let selectedSession else { return false }
        return FerminCodeDesktopActivityPresentation.state(
            for: selectedSession.activityStatus
        ) == .busy && !activeMutations.contains(interruptMutationKey(for: selectedRoute))
    }

    var isInterruptingSelectedSession: Bool {
        guard let selectedRoute else { return false }
        return activeMutations.contains(interruptMutationKey(for: selectedRoute))
    }

    var selectedSourceStatus: FerminCodeDesktopSourceStatus? {
        guard let source = selectedRoute?.source else { return nil }
        return sourceStatuses[source]
    }

    var promptPreferenceLabel: String {
        let values = profile.sources.compactMap { promptPreferences[$0]?.variant }
        guard let first = values.first else { return "Sin cargar" }
        return values.allSatisfy { $0 == first } ? label(for: first) : "Mixto"
    }

    var selectedPromptPreferenceLabel: String? {
        guard let source = selectedRoute?.source,
              let variant = promptPreferences[source]?.variant else { return nil }
        return label(for: variant)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startupTask = Task { [weak self] in
            await self?.bootstrap()
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        detailTask?.cancel()
        detailTask = nil
        detailRequestID = UUID()
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        streamTasks.values.forEach { $0.cancel() }
        streamTasks.removeAll()
        historyResumeIntentID = nil
        invalidateHistoryRequestForLifecycle()
        recoveryIntentID = nil
        invalidateRecoveryRequestForLifecycle()
        purgeCachedDetails()
    }

    func invalidateHistoryRequestForLifecycle() {
        historyRequestID = nil
        guard historyLoadState.isLoading else {
            stableHistoryLoadState = historyLoadState
            return
        }
        historyLoadState = stableHistoryLoadState
    }

    func invalidateRecoveryRequestForLifecycle() {
        recoveryRequestID = nil
        guard recoveryLoadState.isLoading else {
            stableRecoveryLoadState = recoveryLoadState
            return
        }
        recoveryLoadState = stableRecoveryLoadState
    }

    func setAppActive(_ active: Bool) {
        if active {
            start()
            Task { await refreshAll() }
        }
    }

    func selectProfile(_ nextProfile: FerminCodeRelayProfile) {
        guard profile != nextProfile else { return }
        guard canChangeProfile else { return }
        historyResumeIntentID = nil
        recoveryIntentID = nil
        purgeCachedDetails()
        profile = nextProfile
        FerminCodeDesktopPreferences.saveProfile(nextProfile, to: defaults)
        projectsRequestID = nil
        projectsLoadSource = nil
        isLoadingProjects = false
        projects = []
        historyRequestID = nil
        historyLoadState = .idle
        stableHistoryLoadState = .idle
        historyItems = []
        historyTotal = 0
        recoveryRequestID = nil
        recoveryLoadState = .idle
        stableRecoveryLoadState = .idle
        recoveryItems = []
        recoveryTotal = 0
        if let selectedRoute, !nextProfile.accepts(selectedRoute.source) {
            clearSelection()
        }
        Task {
            await loadPromptPreferences()
        }
    }

    func requestSessionSearchFocus() {
        sessionSearchFocusRequest &+= 1
    }

    func discardSubagentDraft() {
        guard !isCreatingSubagentForSelectedSession else { return }
        if let selectedRoute,
           let key = sessionScopedDraftKey(
               for: selectedRoute,
               sessionID: selectedSession?.sessionID
           ) {
            subagentDraftsByRoute.removeValue(forKey: key)
        }
        subagentDisplayNameDraft = ""
        subagentTaskDraft = ""
    }

    func selectSession(_ item: FerminCodeRelaySourcedSession) {
        guard profile.accepts(item.source),
              let route = try? FerminCodeRelaySessionRoute(
                  source: item.source,
                  windowID: item.session.windowID
              ),
              let nextIdentity = FerminCodeDesktopSessionIdentity(
                  route: route,
                  sessionID: item.session.sessionID
              ) else { return }
        guard !isSending, !isAddingAttachments else {
            errorMessage = isSending
                ? "Esperá a que termine el envío antes de cambiar de sesión."
                : "Esperá a que terminen de prepararse las imágenes."
            return
        }
        if selectedSessionInstanceID != nextIdentity.id {
            historyResumeIntentID = nil
        }
        clearModelCatalogErrorIfCurrent()
        composerSendErrorMessage = nil
        composerSendFailureMessageID = nil
        stashSelectedComposerDraft()
        stashSelectedSubagentDraft()
        selectedRoute = route
        let cached = cachedSession(for: route, summary: item.session)
        selectedSession = cached ?? item.session
        isRenamePresented = false
        isArchiveConfirmationPresented = false
        isDeleteConfirmationPresented = false
        detailRequestID = UUID()
        detailLoadState = cached == nil ? .loading : .revalidating
        modelCatalogRequestID = UUID()
        models = []
        isLoadingModels = true
        liveMessages.removeAll(keepingCapacity: true)
        optimisticMessages.removeAll(keepingCapacity: true)
        failedComposerDrafts.removeAll(keepingCapacity: true)
        restoreComposerDraft(for: route)
        restoreSubagentDraft(for: route)
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            await self?.refreshDetail(route: route, userInitiated: true)
            await self?.loadModelCatalog(route: route)
        }
    }

    func clearSelection() {
        if selectedRoute != nil || selectedSession != nil {
            historyResumeIntentID = nil
        }
        clearModelCatalogErrorIfCurrent()
        composerSendErrorMessage = nil
        composerSendFailureMessageID = nil
        stashSelectedComposerDraft()
        stashSelectedSubagentDraft()
        detailTask?.cancel()
        isRenamePresented = false
        isArchiveConfirmationPresented = false
        isDeleteConfirmationPresented = false
        selectedRoute = nil
        selectedSession = nil
        detailRequestID = UUID()
        detailLoadState = .idle
        modelCatalogRequestID = UUID()
        isLoadingModels = false
        liveMessages.removeAll(keepingCapacity: false)
        optimisticMessages.removeAll(keepingCapacity: false)
        failedComposerDrafts.removeAll(keepingCapacity: false)
        composerText = ""
        attachments = []
        subagentDisplayNameDraft = ""
        subagentTaskDraft = ""
        models = []
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: SourceRefreshResult.self) { group in
            for source in FerminCodeRelaySource.allCases {
                let requestID = beginSourceRefresh(for: source)
                guard let token = tokens[source] else {
                    setMissingCredential(source)
                    continue
                }
                group.addTask { [relay] in
                    do {
                        async let health = relay.fetchHealth(source: source, token: token)
                        async let sessions = relay.fetchSessions(source: source, token: token)
                        return try await SourceRefreshResult(
                            requestID: requestID,
                            source: source,
                            health: health,
                            sessions: sessions,
                            error: nil
                        )
                    } catch {
                        return SourceRefreshResult(
                            requestID: requestID,
                            source: source,
                            health: nil,
                            sessions: nil,
                            error: error
                        )
                    }
                }
            }
            for await result in group {
                apply(result)
            }
        }
        if let route = selectedRoute {
            await refreshDetail(route: route, userInitiated: false)
        }
    }

    func refreshDetail() async {
        guard let route = selectedRoute else { return }
        await refreshDetail(route: route, userInitiated: true)
    }

    @discardableResult
    func reloadModelCatalog() async -> Bool {
        guard let route = selectedRoute else { return false }
        await loadModelCatalog(route: route, userInitiated: true)
        return selectedRoute == route && !models.isEmpty
    }

    @discardableResult
    func saveCredential(_ rawToken: String, for source: FerminCodeRelaySource) async -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Pegá un token antes de guardar."
            return false
        }
        let mutationKey = credentialMutationKey(action: "save", for: source)
        guard !activeMutations.contains(mutationKey) else { return false }
        activeMutations.insert(mutationKey)
        defer { activeMutations.remove(mutationKey) }
        do {
            try await credentialStore.save(token, for: source)
            purgeCachedDetails(for: source)
            tokens[source] = token
            credentialPresence[source] = true
            showNotice("Token de \(source.displayName) guardado en Keychain.")
            errorMessage = nil
            restartStream(for: source)
            await refresh(source: source)
            return true
        } catch {
            errorMessage = "No se pudo guardar el token en Keychain."
            return false
        }
    }

    @discardableResult
    func clearCredential(for source: FerminCodeRelaySource) async -> Bool {
        let mutationKey = credentialMutationKey(action: "delete", for: source)
        guard !activeMutations.contains(mutationKey) else { return false }
        activeMutations.insert(mutationKey)
        defer { activeMutations.remove(mutationKey) }
        do {
            try await credentialStore.delete(for: source)
            purgeCachedDetails(for: source)
            tokens.removeValue(forKey: source)
            sourceRefreshRequestIDs[source] = UUID()
            promptPreferenceRequestIDs.removeValue(forKey: source)
            credentialPresence[source] = false
            streamTasks[source]?.cancel()
            streamTasks.removeValue(forKey: source)
            sessionsBySource[source] = []
            rebuildSessions()
            setMissingCredential(source)
            if selectedRoute?.source == source { clearSelection() }
            showNotice("Token de \(source.displayName) eliminado.")
            errorMessage = nil
            return true
        } catch {
            errorMessage = "No se pudo eliminar el token de Keychain."
            return false
        }
    }

    func loadProjects(source requestedSource: FerminCodeRelaySource? = nil) async {
        guard let source = requestedSource ?? profile.singleSource ?? preferredCreateSource,
              profile.accepts(source),
              let token = tokens[source] else {
            projects = []
            errorMessage = "Elegí Personal o Puky y configurá su token."
            return
        }
        guard !isLoadingProjects || projectsLoadSource != source else { return }
        let requestID = UUID()
        projectsRequestID = requestID
        projectsLoadSource = source
        isLoadingProjects = true
        projects = []
        defer {
            if projectsRequestID == requestID {
                projectsRequestID = nil
                projectsLoadSource = nil
                isLoadingProjects = false
            }
        }
        do {
            let envelope = try await relay.fetchProjects(source: source, token: token)
            guard projectsRequestID == requestID,
                  projectsLoadSource == source else { return }
            projects = projectsWithRoot(envelope)
            let previousProjectError = projectLoadErrorMessage
            projectLoadErrorMessage = nil
            if errorMessage == previousProjectError {
                errorMessage = nil
            }
        } catch {
            guard projectsRequestID == requestID,
                  projectsLoadSource == source else { return }
            projects = []
            let message = presentable(error, action: "cargar los proyectos")
            projectLoadErrorMessage = message
            errorMessage = message
        }
    }

    @discardableResult
    func createSession(
        projectPath: String,
        name: String,
        source requestedSource: FerminCodeRelaySource? = nil,
        model: String? = FerminCodeDesktopNewSessionRuntimePolicy.model,
        reasoningEffort: String? = FerminCodeDesktopNewSessionRuntimePolicy.reasoningEffort
    ) async -> Bool {
        guard !isCreatingSession else { return false }
        guard let source = requestedSource ?? profile.singleSource ?? preferredCreateSource,
              profile.accepts(source),
              let token = tokens[source] else {
            errorMessage = "Elegí Personal o Puky y configurá su token."
            return false
        }
        let normalizedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = FerminCodeDesktopSessionNamePolicy.normalized(name)
        guard !normalizedPath.isEmpty else {
            errorMessage = "Elegí un proyecto."
            return false
        }
        guard FerminCodeDesktopSessionNamePolicy.isValid(normalizedName) else {
            errorMessage = "El nombre debe tener entre 1 y \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres."
            return false
        }
        let selectedRouteAtStart = selectedRoute
        isCreatingSession = true
        creationPhase = .submitting
        defer {
            isCreatingSession = false
            creationPhase = .idle
        }
        let sessionID = "sess_\(Int(Date().timeIntervalSince1970 * 1_000))_\(UUID().uuidString.prefix(6))"
        do {
            let acknowledgement = try await relay.createSession(
                source: source,
                token: token,
                request: FerminRelayCreateSessionRequest(
                    projectPath: normalizedPath,
                    sessionID: sessionID,
                    sessionName: normalizedName,
                    model: normalized(model),
                    reasoningEffort: normalized(reasoningEffort),
                    idempotencyKey: UUID().uuidString
                )
            )
            creationPhase = .waitingForConfirmation
            try await register(
                acknowledgement,
                operation: .createSession,
                source: source,
                sessionID: acknowledgement.sessionID ?? sessionID
            )
            let confirmedSessionID = acknowledgement.sessionID ?? sessionID
            guard let item = await waitForSession(
                source: source,
                token: token,
                sessionID: confirmedSessionID,
                expectedName: normalizedName
            ) else {
                throw FerminCodeDesktopUserError(
                    "La creación quedó aceptada, pero no apareció antes de 150 segundos."
                )
            }
            clearObservedCreateCommand(
                source: source,
                commandID: acknowledgement.commandID
            )
            if selectedRoute == selectedRouteAtStart {
                selectSession(item)
            } else {
                showNotice("Sesión \(normalizedName) creada en \(source.displayName).")
            }
            isCreatePresented = false
            return true
        } catch {
            errorMessage = presentable(error, action: "crear la sesión")
            return false
        }
    }

    @discardableResult
    func sendComposer() async -> Bool {
        guard !isSending else { return false }
        guard !isAddingAttachments else {
            errorMessage = "Esperá a que terminen de prepararse las imágenes."
            return false
        }
        guard let route = selectedRoute,
              let token = tokens[route.source],
              let selectedSession,
              selectedSession.canSend == true,
              let sessionIdentity = FerminCodeDesktopSessionIdentity(
                  route: route,
                  sessionID: selectedSession.sessionID
              ) else {
            errorMessage = "La sesión no está lista para recibir mensajes."
            return false
        }
        let composerDraft = composerText
        let text = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let drafts = attachments
        guard !text.isEmpty || !drafts.isEmpty else { return false }
        if let validationMessage = FerminCodeDesktopComposerTextPresentation.validationMessage(
            for: composerDraft
        ) {
            errorMessage = validationMessage
            return false
        }
        do {
            try FerminCodeDesktopAttachmentPolicy.validate(drafts)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        composerSendErrorMessage = nil
        composerSendFailureMessageID = nil
        errorMessage = nil
        activeSendIdentity = sessionIdentity
        isSending = true
        defer {
            isSending = false
            if activeSendIdentity == sessionIdentity {
                activeSendIdentity = nil
            }
        }
        if let desiredGoalMode = goalModeDraftsByRoute[route] {
            guard !isUpdatingSelectedGoalMode else {
                errorMessage = "Esperá a que GOAL termine de sincronizarse."
                return false
            }
            if committedGoalModeEnabled(for: route) != desiredGoalMode {
                await setGoalMode(desiredGoalMode)
                guard selectedRoute == route,
                      !isUpdatingSelectedGoalMode,
                      committedGoalModeEnabled(for: route) == desiredGoalMode else {
                    if errorMessage == nil {
                        errorMessage = "No se pudo preparar GOAL. El mensaje no fue enviado."
                    }
                    return false
                }
            }
            goalModeDraftsByRoute.removeValue(forKey: route)
        }

        let clientMessageID = "desktop-user-\(UUID().uuidString.lowercased())"
        let optimistic = FerminCodeDesktopOptimisticMessage(
            message: FerminRelayMessage(
                id: clientMessageID,
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970 * 1_000,
                status: "sending",
                imageAttachments: drafts.map { draft in
                    FerminRelayMessageImageAttachment(
                        id: draft.id,
                        name: draft.name,
                        size: draft.data.count,
                        mimeType: draft.mimeType
                    )
                }
            ),
            delivery: .sending
        )
        failedComposerDrafts[clientMessageID] = FerminCodeDesktopFailedComposerDraft(
            text: composerDraft,
            attachments: drafts
        )
        optimisticMessages.append(optimistic)
        composerText = ""
        attachments = []
        if let draftKey = sessionScopedDraftKey(
            for: route,
            sessionID: sessionIdentity.sessionID
        ) {
            composerDraftsByRoute.removeValue(forKey: draftKey)
        }
        do {
            var uploaded: [FerminRelayMessageAttachment] = []
            for draft in drafts {
                let result = try await relay.uploadAttachment(
                    source: route.source,
                    token: token,
                    windowID: route.windowID,
                    attachment: FerminRelayAttachmentUpload(
                        fileName: draft.name,
                        mimeType: draft.mimeType,
                        data: draft.data
                    )
                )
                uploaded.append(FerminRelayMessageAttachment(
                    path: result.path,
                    name: draft.name,
                    size: result.bytes,
                    mimeType: result.mimeType
                ))
            }
            let request = FerminRelaySendMessageRequest(
                message: text,
                clientMessageID: clientMessageID,
                attachments: uploaded,
                fastModeEnabled: false,
                // The user-message identity is also the durable command identity.
                // Retrying an ambiguous HTTP result can therefore never create a
                // second Codex turn for the same tap on Send.
                idempotencyKey: clientMessageID
            )
            let acknowledgement: FerminRelayDurableCommandAcknowledgement
            do {
                acknowledgement = try await relay.sendMessage(
                    source: route.source,
                    token: token,
                    windowID: route.windowID,
                    request: request
                )
            } catch {
                guard isAmbiguousSendResult(error) else { throw error }
                if await reconcileAuthoritativeSend(
                    route: route,
                    token: token,
                    identity: sessionIdentity,
                    messageID: clientMessageID
                ) {
                    return true
                }
                do {
                    acknowledgement = try await relay.sendMessage(
                        source: route.source,
                        token: token,
                        windowID: route.windowID,
                        request: request
                    )
                } catch {
                    guard isAmbiguousSendResult(error),
                          await reconcileAuthoritativeSend(
                            route: route,
                            token: token,
                            identity: sessionIdentity,
                            messageID: clientMessageID
                          ) else {
                        throw error
                    }
                    return true
                }
            }
            try await register(
                acknowledgement,
                operation: .sendMessage,
                route: route,
                messageID: clientMessageID,
                sessionID: sessionIdentity.sessionID
            )
            if acknowledgement.commandState?.isFailure == true {
                let message = "El relay no pudo completar el envío."
                preserveComposerDraftAfterSelectionChange(
                    composerDraft,
                    attachments: drafts,
                    route: route,
                    identity: sessionIdentity
                )
                setOptimisticDelivery(id: clientMessageID, delivery: .failed(message))
                composerSendFailureMessageID = clientMessageID
                composerSendErrorMessage = message
                errorMessage = message
                return false
            }
            setOptimisticDelivery(id: clientMessageID, delivery: .accepted)
            errorMessage = nil
            return true
        } catch {
            let message = presentable(error, action: "enviar el mensaje")
            let resultWasAmbiguous = isAmbiguousSendResult(error)
            if selectedSessionMatches(
                route: route,
                sessionID: sessionIdentity.sessionID
            ) {
                let recovered = mergedComposerDraft(
                    failedText: composerDraft,
                    failedAttachments: drafts,
                    existingText: composerText,
                    existingAttachments: attachments
                )
                composerText = recovered.text
                attachments = recovered.attachments
                if resultWasAmbiguous {
                    setOptimisticDelivery(
                        id: clientMessageID,
                        delivery: .failed("El relay todavía no confirmó si recibió el mensaje.")
                    )
                    composerSendFailureMessageID = clientMessageID
                } else {
                    optimisticMessages.removeAll { $0.id == clientMessageID }
                    failedComposerDrafts.removeValue(forKey: clientMessageID)
                }
            } else {
                preserveComposerDraftAfterSelectionChange(
                    composerDraft,
                    attachments: drafts,
                    route: route,
                    identity: sessionIdentity
                )
                setOptimisticDelivery(id: clientMessageID, delivery: .failed(message))
                composerSendFailureMessageID = clientMessageID
            }
            composerSendErrorMessage = message
            errorMessage = message
            return false
        }
    }

    @discardableResult
    func retryComposerSend() async -> Bool {
        guard !isSending else { return false }
        if let messageID = composerSendFailureMessageID {
            if let route = selectedRoute,
               let token = tokens[route.source],
               let selectedSession,
               let identity = FerminCodeDesktopSessionIdentity(
                route: route,
                sessionID: selectedSession.sessionID
               ),
               await reconcileAuthoritativeSend(
                route: route,
                token: token,
                identity: identity,
                messageID: messageID
               ) {
                return true
            }
            guard recoverFailedComposer(messageID: messageID) else {
                let message = "No se pudo recuperar el borrador para reintentar."
                composerSendErrorMessage = message
                errorMessage = message
                return false
            }
        }
        return await sendComposer()
    }

    @discardableResult
    func recoverFailedComposer(messageID: String) -> Bool {
        guard let failedDraft = failedComposerDrafts[messageID],
              optimisticMessages.contains(where: {
                  guard $0.id == messageID else { return false }
                  if case .failed = $0.delivery { return true }
                  return false
              }) else {
            return false
        }

        let combinedAttachments = failedDraft.attachments + attachments
        do {
            try FerminCodeDesktopAttachmentPolicy.validate(combinedAttachments)
        } catch {
            errorMessage = "No se pudo recuperar el mensaje: \(error.localizedDescription)"
            return false
        }

        if composerText.isEmpty {
            composerText = failedDraft.text
        } else if !failedDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText = failedDraft.text + "\n\n" + composerText
        }
        attachments = combinedAttachments
        optimisticMessages.removeAll { $0.id == messageID }
        failedComposerDrafts.removeValue(forKey: messageID)
        errorMessage = nil
        showNotice("El mensaje no enviado volvió al editor.")
        return true
    }

    func addAttachments(from urls: [URL]) async {
        guard !urls.isEmpty, !isAddingAttachments else { return }
        do {
            try FerminCodeDesktopAttachmentPolicy.validateAdditionCount(
                existingCount: attachments.count,
                incomingCount: urls.count
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let route = selectedRoute
        isAddingAttachments = true
        defer { isAddingAttachments = false }
        do {
            let additions = try await Task.detached(priority: .userInitiated) {
                var loaded: [FerminCodeDesktopAttachmentDraft] = []
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values: URLResourceValues
                    do {
                        values = try url.resourceValues(
                            forKeys: [.fileSizeKey, .isRegularFileKey]
                        )
                    } catch {
                        throw FerminCodeDesktopUserError(
                            "No pudimos leer \(url.lastPathComponent). Revisá sus permisos e intentá de nuevo."
                        )
                    }
                    guard values.isRegularFile == true else {
                        throw FerminCodeDesktopUserError(
                            "\(url.lastPathComponent) no es un archivo regular."
                        )
                    }
                    guard (values.fileSize ?? 0)
                        <= FerminCodeDesktopAttachmentPolicy.maximumBytes else {
                        throw FerminCodeDesktopUserError(
                            "\(url.lastPathComponent) supera 20 MiB."
                        )
                    }
                    let data: Data
                    do {
                        data = try Data(contentsOf: url, options: .mappedIfSafe)
                    } catch {
                        throw FerminCodeDesktopUserError(
                            "No pudimos leer \(url.lastPathComponent). Revisá sus permisos e intentá de nuevo."
                        )
                    }
                    guard let mimeType = FerminCodeDesktopAttachmentPolicy.detectedMIMEType(
                        for: data
                    ) else {
                        throw FerminCodeDesktopUserError(
                            "\(url.lastPathComponent) no es PNG, JPEG, GIF o WebP válido."
                        )
                    }
                    loaded.append(FerminCodeDesktopAttachmentDraft(
                        name: url.lastPathComponent,
                        mimeType: mimeType,
                        data: data
                    ))
                }
                return loaded
            }.value
            guard selectedRoute == route else { return }
            try FerminCodeDesktopAttachmentPolicy.validate(attachments + additions)
            attachments.append(contentsOf: additions)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAttachments(from itemProviders: [NSItemProvider]) async {
        let imageProviders = itemProviders.filter { provider in
            provider.registeredTypeIdentifiers.contains { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            }
        }
        guard !imageProviders.isEmpty, !isAddingAttachments else { return }
        do {
            try FerminCodeDesktopAttachmentPolicy.validateAdditionCount(
                existingCount: attachments.count,
                incomingCount: imageProviders.count
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let route = selectedRoute
        isAddingAttachments = true
        defer { isAddingAttachments = false }
        do {
            var additions: [FerminCodeDesktopAttachmentDraft] = []
            for (index, provider) in imageProviders.enumerated() {
                let typeIdentifier = try Self.preferredClipboardImageType(for: provider)
                let sourceData = try await Self.loadClipboardData(
                    from: provider,
                    typeIdentifier: typeIdentifier
                )
                additions.append(
                    try Self.clipboardAttachment(
                        from: sourceData,
                        index: index + 1
                    )
                )
            }
            guard selectedRoute == route else { return }
            try FerminCodeDesktopAttachmentPolicy.validate(attachments + additions)
            attachments.append(contentsOf: additions)
            errorMessage = nil
            showNotice(
                additions.count == 1
                    ? "Imagen pegada desde el portapapeles."
                    : "\(additions.count) imágenes pegadas desde el portapapeles."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAttachment(id: String) {
        attachments.removeAll { $0.id == id }
    }

    private static func preferredClipboardImageType(for provider: NSItemProvider) throws -> String {
        let preferredTypes: [UTType] = [.png, .jpeg, .gif, .webP, .tiff]
        if let match = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            return match.identifier
        }
        if let match = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            return match
        }
        throw FerminCodeDesktopUserError("El portapapeles no contiene una imagen compatible.")
    }

    private static func loadClipboardData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: FerminCodeDesktopUserError(
                            "No pudimos leer la imagen del portapapeles."
                        )
                    )
                }
            }
        }
    }

    private static func clipboardAttachment(
        from sourceData: Data,
        index: Int
    ) throws -> FerminCodeDesktopAttachmentDraft {
        if let mimeType = FerminCodeDesktopAttachmentPolicy.detectedMIMEType(for: sourceData) {
            return FerminCodeDesktopAttachmentDraft(
                name: "Imagen pegada \(index).\(fileExtension(for: mimeType))",
                mimeType: mimeType,
                data: sourceData
            )
        }

        guard let image = NSImage(data: sourceData),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            throw FerminCodeDesktopUserError(
                "La imagen del portapapeles no pudo convertirse a PNG."
            )
        }
        return FerminCodeDesktopAttachmentDraft(
            name: "Imagen pegada \(index).png",
            mimeType: "image/png",
            data: pngData
        )
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }

    func interruptSelectedSession() async {
        guard canInterruptSelectedSession,
              let route = selectedRoute,
              let token = tokens[route.source] else { return }
        _ = await durableMutation(
            key: interruptMutationKey(for: route),
            operation: .interrupt,
            route: route
        ) {
            try await relay.interrupt(
                source: route.source,
                token: token,
                windowID: route.windowID
            )
        }
    }

    @discardableResult
    func renameSelectedSession(_ name: String) async -> Bool {
        guard let route = selectedRoute, let token = tokens[route.source] else { return false }
        let normalizedName = FerminCodeDesktopSessionNamePolicy.normalized(name)
        guard FerminCodeDesktopSessionNamePolicy.isValid(name) else {
            errorMessage = "El nombre debe tener entre 1 y 64 caracteres."
            return false
        }
        guard normalizedName != FerminCodeDesktopSessionNamePolicy.normalized(
            selectedSession?.displayName ?? ""
        ) else {
            errorMessage = "Escribí un nombre distinto al actual."
            return false
        }
        return await durableMutation(
            key: renameMutationKey(for: route),
            operation: .rename,
            route: route
        ) {
            try await relay.rename(
                source: route.source,
                token: token,
                windowID: route.windowID,
                name: normalizedName
            )
        }
    }

    func setSelectedSessionMinimized(_ minimized: Bool) async {
        guard let route = selectedRoute, let token = tokens[route.source] else { return }
        _ = await durableMutation(
            key: visibilityMutationKey(for: route),
            operation: .minimize,
            route: route
        ) {
            try await relay.setMinimized(
                source: route.source,
                token: token,
                windowID: route.windowID,
                minimized: minimized
            )
        }
    }

    func archiveSelectedSession() async {
        guard let route = selectedRoute, let token = tokens[route.source] else { return }
        let sessionID = selectedSession?.sessionID
        _ = await durableMutation(
            key: archiveMutationKey(for: route),
            operation: .archive,
            route: route,
            targetSessionID: sessionID
        ) {
            try await relay.archive(
                source: route.source,
                token: token,
                windowID: route.windowID
            )
        }
    }

    func deleteSelectedSessionPermanently() async {
        guard let route = selectedRoute, let token = tokens[route.source] else { return }
        let sessionID = selectedSession?.sessionID
        _ = await durableMutation(
            key: deleteMutationKey(for: route),
            operation: .delete,
            route: route,
            targetSessionID: sessionID
        ) {
            try await relay.deletePermanently(
                source: route.source,
                token: token,
                windowID: route.windowID
            )
        }
    }

    func setFeatures(
        promptImprover: Bool? = nil,
        explainer: Bool? = nil,
        codeContext: Bool? = nil
    ) async {
        guard let route = selectedRoute,
              let identity = selectedSessionIdentity,
              let token = tokens[route.source] else { return }
        let mutationKey = featureMutationKey(for: identity)
        let current = selectedFeatures
        let hasRequestedChange = (promptImprover.map {
            $0 != current.promptImproverEnabled
        } ?? false)
            || (explainer.map { $0 != current.explainerEnabled } ?? false)
            || (codeContext.map { $0 != current.codeContextEnabled } ?? false)
        guard hasRequestedChange else { return }
        let next = FerminRelaySessionFeatures(
            promptImproverEnabled: promptImprover ?? current.promptImproverEnabled,
            explainerEnabled: explainer ?? current.explainerEnabled,
            codeContextEnabled: codeContext ?? current.codeContextEnabled
        )
        let patch = FerminRelayFeaturePatch(
            promptImproverEnabled: promptImprover,
            explainerEnabled: explainer,
            codeContextEnabled: codeContext,
            idempotencyKey: UUID().uuidString
        )
        featureOverridesBySessionIdentity[identity] = next
        if activeMutations.contains(mutationKey) {
            let latestPatch = FerminRelayFeaturePatch(
                promptImproverEnabled: next.promptImproverEnabled,
                explainerEnabled: next.explainerEnabled,
                codeContextEnabled: next.codeContextEnabled,
                idempotencyKey: UUID().uuidString
            )
            featureOverridePatchesBySessionIdentity[identity] = latestPatch
            queuedFeatureMutations[identity] = FerminCodeDesktopQueuedFeatureMutation(
                route: route,
                identity: identity,
                token: token,
                patch: latestPatch
            )
            return
        }
        featureOverridePatchesBySessionIdentity[identity] = patch
        await performFeatureMutation(
            route: route,
            identity: identity,
            token: token,
            patch: patch
        )
    }

    private func performFeatureMutation(
        route: FerminCodeRelaySessionRoute,
        identity: FerminCodeDesktopSessionIdentity,
        token: String,
        patch: FerminRelayFeaturePatch
    ) async {
        let succeeded = await durableMutation(
            key: featureMutationKey(for: identity),
            operation: .setFeatures,
            route: route,
            targetSessionID: identity.sessionID,
            mutationID: patch.idempotencyKey,
            shouldPresentFailure: {
                self.featureOverridePatchesBySessionIdentity[identity]?.idempotencyKey
                    == patch.idempotencyKey
            }
        ) {
            try await relay.setFeatures(
                source: route.source,
                token: token,
                windowID: route.windowID,
                patch: patch
            )
        }
        if !succeeded,
           featureOverridePatchesBySessionIdentity[identity]?.idempotencyKey
               == patch.idempotencyKey {
            featureOverridesBySessionIdentity.removeValue(forKey: identity)
            featureOverridePatchesBySessionIdentity.removeValue(forKey: identity)
        }
        if selectedRoute == route,
           let currentIdentity = selectedSessionIdentity,
           currentIdentity != identity {
            featureOverridesBySessionIdentity.removeValue(forKey: identity)
            featureOverridePatchesBySessionIdentity.removeValue(forKey: identity)
            queuedFeatureMutations.removeValue(forKey: identity)
            return
        }
        if let queued = queuedFeatureMutations.removeValue(forKey: identity) {
            await performFeatureMutation(
                route: queued.route,
                identity: queued.identity,
                token: queued.token,
                patch: queued.patch
            )
        }
    }

    private func committedGoalModeEnabled(
        for route: FerminCodeRelaySessionRoute
    ) -> Bool {
        goalModeOverridesByRoute[route]
            ?? (selectedRoute == route && selectedSession?.runMode?.lowercased() == "goal")
    }

    func setGoalMode(_ enabled: Bool) async {
        guard let route = selectedRoute, let token = tokens[route.source] else { return }
        let mutationKey = goalMutationKey(for: route)
        let mutationID = UUID().uuidString
        goalModeOverridesByRoute[route] = enabled
        goalModeOverrideMutationIDsByRoute[route] = mutationID
        if activeMutations.contains(mutationKey) {
            queuedGoalMutations[route.id] = FerminCodeDesktopQueuedGoalMutation(
                route: route,
                token: token,
                enabled: enabled,
                mutationID: mutationID
            )
            return
        }
        await performGoalMutation(
            route: route,
            token: token,
            enabled: enabled,
            mutationID: mutationID
        )
    }

    private func performGoalMutation(
        route: FerminCodeRelaySessionRoute,
        token: String,
        enabled: Bool,
        mutationID: String
    ) async {
        let mutationKey = goalMutationKey(for: route)
        let succeeded = await durableMutation(
            key: mutationKey,
            operation: .setRunMode,
            route: route,
            mutationID: mutationID,
            shouldPresentFailure: {
                self.goalModeOverrideMutationIDsByRoute[route] == mutationID
            }
        ) {
            try await relay.setRunMode(
                source: route.source,
                token: token,
                windowID: route.windowID,
                enabled: enabled,
                idempotencyKey: mutationID
            )
        }
        if !succeeded,
           goalModeOverrideMutationIDsByRoute[route] == mutationID {
            goalModeOverridesByRoute.removeValue(forKey: route)
            goalModeOverrideMutationIDsByRoute.removeValue(forKey: route)
        }
        if let queued = queuedGoalMutations.removeValue(forKey: route.id) {
            await performGoalMutation(
                route: queued.route,
                token: queued.token,
                enabled: queued.enabled,
                mutationID: queued.mutationID
            )
        }
    }

    @discardableResult
    func setRuntimeModel(model: String, effort: String) async -> Bool {
        guard let route = selectedRoute, let token = tokens[route.source] else { return false }
        let mutationKey = modelMutationKey(for: route)
        guard !activeMutations.contains(mutationKey) else { return false }
        let mutationID = UUID().uuidString
        let sessionID = selectedSession?.sessionID
        do {
            try FerminRelayRuntimePolicy.validate(model: model)
            errorMessage = nil
            activeMutations.insert(mutationKey)
            defer { activeMutations.remove(mutationKey) }
            runtimeModelOverridesByRoute[route] = FerminRelayRuntimeModelSettings(
                model: model,
                effort: effort
            )
            runtimeModelOverrideMutationIDsByRoute[route] = mutationID
            let envelope = try await relay.setModelSettings(
                source: route.source,
                token: token,
                windowID: route.windowID,
                request: FerminRelayModelSettingsRequest(
                    model: model,
                    reasoningEffort: effort,
                    idempotencyKey: mutationID
                )
            )
            runtimeModelOverridesByRoute[route] = envelope.modelSettings
            try await register(
                envelope.command,
                operation: .setModel,
                route: route,
                sessionID: sessionID,
                mutationID: mutationID
            )
            await refresh(source: route.source)
            if selectedRoute == route {
                await refreshDetail(route: route, userInitiated: false)
            }
            return true
        } catch {
            if runtimeModelOverrideMutationIDsByRoute[route] == mutationID {
                runtimeModelOverridesByRoute.removeValue(forKey: route)
                runtimeModelOverrideMutationIDsByRoute.removeValue(forKey: route)
            }
            if selectedRoute == route {
                errorMessage = presentable(error, action: "cambiar el modelo")
            }
            return false
        }
    }

    @discardableResult
    func createSubagent(message: String, displayName: String?) async -> Bool {
        guard let route = selectedRoute, let token = tokens[route.source] else { return false }
        let mutationKey = subagentMutationKey(for: route)
        guard !activeMutations.contains(mutationKey) else { return false }
        let parentSessionID = selectedSession?.sessionID
        let parentDisplayName = selectedSession?.displayName ?? "la sesión original"
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Escribí una tarea para el subagente."
            return false
        }
        if let validationMessage = FerminCodeDesktopSubagentFormPolicy.taskValidationMessage(
            text
        ) {
            errorMessage = validationMessage
            return false
        }
        let normalizedDisplayName = normalized(displayName)
        guard normalizedDisplayName?.count ?? 0
                <= FerminCodeDesktopSessionNamePolicy.maximumLength else {
            errorMessage = "Usá hasta \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres para el nombre opcional."
            return false
        }
        let sessionID = "sess_\(Int(Date().timeIntervalSince1970 * 1_000))_\(UUID().uuidString.prefix(6))"
        do {
            activeMutations.insert(mutationKey)
            defer { activeMutations.remove(mutationKey) }
            let acknowledgement = try await relay.createSubagent(
                source: route.source,
                token: token,
                windowID: route.windowID,
                request: FerminRelayCreateSubagentRequest(
                    message: text,
                    sessionID: sessionID,
                    displayName: normalizedDisplayName,
                    engine: "codex",
                    idempotencyKey: UUID().uuidString
                )
            )
            try await register(
                acknowledgement,
                operation: .createSubagent,
                route: route,
                sessionID: acknowledgement.sessionID ?? sessionID
            )
            let childSessionID = acknowledgement.sessionID ?? sessionID
            guard let child = await waitForSession(
                source: route.source,
                token: token,
                sessionID: childSessionID,
                expectedName: nil,
                requireStartedSubagent: true
            ) else {
                throw FerminCodeDesktopUserError(
                    "El subagente quedó aceptado, pero no inició antes de 150 segundos."
                )
            }
            if let draftKey = sessionScopedDraftKey(
                for: route,
                sessionID: parentSessionID
            ) {
                subagentDraftsByRoute.removeValue(forKey: draftKey)
            }
            if selectedRoute == route {
                subagentDisplayNameDraft = ""
                subagentTaskDraft = ""
                selectSession(child)
                isSubagentPresented = false
            } else {
                showNotice("Subagente creado en \(parentDisplayName).")
            }
            return true
        } catch {
            let message = presentable(error, action: "crear el subagente")
            errorMessage = selectedRoute == route
                ? message
                : "\(parentDisplayName): \(message)"
            return false
        }
    }

    @discardableResult
    func retryPromptTransform(messageID: String) async -> Bool {
        guard let route = selectedRoute, let token = tokens[route.source] else { return false }
        return await durableMutation(
            key: promptRetryMutationKey(messageID: messageID, route: route),
            operation: .retryPromptTransform,
            route: route,
            messageID: messageID
        ) {
            try await relay.retryPromptTransform(
                source: route.source,
                token: token,
                windowID: route.windowID,
                messageID: messageID
            )
        }
    }

    func loadHistory(
        text: String = "",
        state: FerminRelayHistoryState = .all,
        sort: FerminRelayHistorySort = .recent,
        refresh: Bool = false
    ) async {
        let requestID = UUID()
        let requestedProfile = profile
        if !historyLoadState.isLoading {
            stableHistoryLoadState = historyLoadState
        }
        historyRequestID = requestID
        historyLoadState = historyItems.isEmpty ? .loading : .revalidating
        defer {
            if historyRequestID == requestID {
                historyRequestID = nil
            }
        }
        let query = FerminRelaySessionHistoryQuery(
            text: text,
            state: state,
            sort: sort,
            limit: 100,
            refresh: refresh
        )
        var fetched: [FerminCodeDesktopSourcedHistoryItem] = []
        var total = 0
        var failedSources: [FerminCodeRelaySource] = []
        await withTaskGroup(of: HistoryResult.self) { group in
            for source in requestedProfile.sources {
                guard let token = tokens[source] else {
                    failedSources.append(source)
                    continue
                }
                group.addTask { [relay] in
                    do {
                        return HistoryResult(
                            source: source,
                            envelope: try await relay.fetchHistory(
                                source: source,
                                token: token,
                                query: query
                            ),
                            error: nil
                        )
                    } catch {
                        return HistoryResult(source: source, envelope: nil, error: error)
                    }
                }
            }
            for await result in group {
                if let envelope = result.envelope {
                    total += envelope.total
                    fetched += envelope.items.map {
                        FerminCodeDesktopSourcedHistoryItem(source: result.source, item: $0)
                    }
                } else {
                    failedSources.append(result.source)
                }
            }
        }
        guard !Task.isCancelled else {
            if historyRequestID == requestID {
                invalidateHistoryRequestForLifecycle()
            }
            return
        }
        guard historyRequestID == requestID, profile == requestedProfile else { return }
        historyItems = fetched.sorted { $0.item.updatedAt > $1.item.updatedAt }
        historyTotal = total
        if !failedSources.isEmpty, !fetched.isEmpty {
            historyLoadState = .partial(
                "Historial parcial: no respondió \(failedSources.map(\.displayName).joined(separator: ", "))."
            )
        } else if fetched.isEmpty, !failedSources.isEmpty {
            historyLoadState = .failed("No se pudo cargar el historial.")
        } else {
            historyLoadState = .loaded
        }
        stableHistoryLoadState = historyLoadState
    }

    @discardableResult
    func resumeHistoryItem(_ sourcedItem: FerminCodeDesktopSourcedHistoryItem) async -> Bool {
        guard let token = tokens[sourcedItem.source] else { return false }
        guard isHistoryPresented else { return false }
        let rowMutationKey = FerminCodeDesktopHistoryPresentation.resumeMutationKey(
            source: sourcedItem.source,
            itemID: sourcedItem.item.id
        )
        guard !activeMutations.contains("resume") else { return false }
        let intentID = UUID()
        let originatingProfile = profile
        let originatingSessionInstanceID = selectedSessionInstanceID
        let originatingFeedbackGeneration = feedbackGeneration
        historyResumeIntentID = intentID
        do {
            activeMutations.insert("resume")
            activeMutations.insert(rowMutationKey)
            defer {
                activeMutations.remove("resume")
                activeMutations.remove(rowMutationKey)
                if historyResumeIntentID == intentID {
                    historyResumeIntentID = nil
                }
            }
            let envelope = try await relay.resumeHistory(
                source: sourcedItem.source,
                token: token,
                id: sourcedItem.item.id
            )
            let acknowledgement = FerminRelayDurableCommandAcknowledgement(
                ok: envelope.ok,
                commandID: envelope.commandID,
                commandState: envelope.state,
                inserted: envelope.queued,
                durable: true,
                queuedAt: envelope.queuedAt,
                windowID: envelope.windowID,
                sessionID: envelope.sessionID,
                projectPath: envelope.projectPath
            )
            try await register(
                acknowledgement,
                operation: .resumeHistory,
                source: sourcedItem.source,
                sessionID: envelope.sessionID
            )
            guard let item = await waitForSession(
                source: sourcedItem.source,
                token: token,
                sessionID: envelope.sessionID,
                expectedName: nil
            ) else {
                throw FerminCodeDesktopUserError(
                    "La sesión quedó aceptada, pero no apareció antes de 150 segundos."
                )
            }
            guard applyHistoryResumeHandoffIfCurrent(
                intentID,
                profile: originatingProfile,
                sessionInstanceID: originatingSessionInstanceID,
                item: item,
                sourceProfile: sourcedItem.source.profile
            ) else {
                return true
            }
            if feedbackGeneration == originatingFeedbackGeneration {
                errorMessage = nil
            }
            return true
        } catch {
            guard historyResumeIntentIsCurrent(
                intentID,
                profile: originatingProfile,
                sessionInstanceID: originatingSessionInstanceID
            ), feedbackGeneration == originatingFeedbackGeneration else {
                return false
            }
            errorMessage = presentable(error, action: "reanudar la sesión")
            return false
        }
    }

    func loadRecoverableSessions(text: String = "") async {
        let requestID = UUID()
        let requestedProfile = profile
        if !recoveryLoadState.isLoading {
            stableRecoveryLoadState = recoveryLoadState
        }
        recoveryRequestID = requestID
        recoveryLoadState = recoveryItems.isEmpty ? .loading : .revalidating
        defer {
            if recoveryRequestID == requestID {
                recoveryRequestID = nil
            }
        }
        let query = FerminRelaySessionRecoveryQuery(text: text, limit: 100)
        var fetched: [FerminCodeDesktopSourcedRecoveryItem] = []
        var total = 0
        var failedSources: [FerminCodeRelaySource] = []
        await withTaskGroup(of: RecoveryResult.self) { group in
            for source in requestedProfile.sources {
                guard let token = tokens[source] else {
                    failedSources.append(source)
                    continue
                }
                group.addTask { [relay] in
                    do {
                        return RecoveryResult(
                            source: source,
                            envelope: try await relay.fetchRecoverableSessions(
                                source: source,
                                token: token,
                                query: query
                            ),
                            error: nil
                        )
                    } catch {
                        return RecoveryResult(source: source, envelope: nil, error: error)
                    }
                }
            }
            for await result in group {
                if let envelope = result.envelope {
                    total += envelope.total
                    fetched += envelope.items.map {
                        FerminCodeDesktopSourcedRecoveryItem(source: result.source, item: $0)
                    }
                } else {
                    failedSources.append(result.source)
                }
            }
        }
        guard !Task.isCancelled else {
            if recoveryRequestID == requestID {
                invalidateRecoveryRequestForLifecycle()
            }
            return
        }
        guard recoveryRequestID == requestID, profile == requestedProfile else { return }
        recoveryItems = fetched.sorted {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               $0.item.score != $1.item.score {
                return $0.item.score > $1.item.score
            }
            return $0.item.updatedAt > $1.item.updatedAt
        }
        recoveryTotal = total
        if !failedSources.isEmpty, !fetched.isEmpty {
            recoveryLoadState = .partial(
                "Recuperación parcial: no respondió \(failedSources.map(\.displayName).joined(separator: ", "))."
            )
        } else if fetched.isEmpty, !failedSources.isEmpty {
            recoveryLoadState = .failed("No se pudieron buscar sesiones para recuperar.")
        } else {
            recoveryLoadState = .loaded
        }
        stableRecoveryLoadState = recoveryLoadState
    }

    @discardableResult
    func recoverSession(_ sourcedItem: FerminCodeDesktopSourcedRecoveryItem) async -> Bool {
        guard let token = tokens[sourcedItem.source], isRecoveryPresented else { return false }
        guard !activeMutations.contains("recover") else { return false }
        let intentID = UUID()
        let originatingProfile = profile
        let originatingSessionInstanceID = selectedSessionInstanceID
        let originatingFeedbackGeneration = feedbackGeneration
        recoveryIntentID = intentID
        do {
            activeMutations.insert("recover")
            let rowMutationKey = "recover:\(sourcedItem.id)"
            activeMutations.insert(rowMutationKey)
            defer {
                activeMutations.remove("recover")
                activeMutations.remove(rowMutationKey)
                if recoveryIntentID == intentID {
                    recoveryIntentID = nil
                }
            }
            let envelope = try await relay.recoverSession(
                source: sourcedItem.source,
                token: token,
                id: sourcedItem.item.id
            )
            try await register(
                FerminRelayDurableCommandAcknowledgement(
                    ok: envelope.ok,
                    commandID: envelope.commandID,
                    commandState: envelope.state,
                    inserted: envelope.queued,
                    durable: true,
                    queuedAt: envelope.queuedAt,
                    windowID: envelope.windowID,
                    sessionID: envelope.sessionID,
                    projectPath: envelope.projectPath
                ),
                operation: .recoverSession,
                source: sourcedItem.source,
                sessionID: envelope.sessionID
            )
            guard let item = await waitForSession(
                source: sourcedItem.source,
                token: token,
                sessionID: envelope.sessionID,
                expectedName: nil
            ) else {
                throw FerminCodeDesktopUserError(
                    "La recuperación fue aceptada, pero la sesión no apareció antes de 150 segundos."
                )
            }
            guard !Task.isCancelled,
                  recoveryIntentID == intentID,
                  isRecoveryPresented,
                  profile == originatingProfile,
                  selectedSessionInstanceID == originatingSessionInstanceID else {
                return true
            }
            recoveryIntentID = nil
            selectProfile(sourcedItem.source.profile)
            selectSession(item)
            isRecoveryPresented = false
            if feedbackGeneration == originatingFeedbackGeneration {
                errorMessage = nil
            }
            return true
        } catch {
            guard !Task.isCancelled,
                  recoveryIntentID == intentID,
                  isRecoveryPresented,
                  profile == originatingProfile,
                  selectedSessionInstanceID == originatingSessionInstanceID,
                  feedbackGeneration == originatingFeedbackGeneration else {
                return false
            }
            errorMessage = presentable(error, action: "recuperar la sesión")
            return false
        }
    }

    private func historyResumeIntentIsCurrent(
        _ intentID: UUID,
        profile originatingProfile: FerminCodeRelayProfile,
        sessionInstanceID originatingSessionInstanceID: String?
    ) -> Bool {
        !Task.isCancelled
            && historyResumeIntentID == intentID
            && isHistoryPresented
            && profile == originatingProfile
            && selectedSessionInstanceID == originatingSessionInstanceID
    }

    private func applyHistoryResumeHandoffIfCurrent(
        _ intentID: UUID,
        profile originatingProfile: FerminCodeRelayProfile,
        sessionInstanceID originatingSessionInstanceID: String?,
        item: FerminCodeRelaySourcedSession,
        sourceProfile: FerminCodeRelayProfile
    ) -> Bool {
        guard historyResumeIntentIsCurrent(
            intentID,
            profile: originatingProfile,
            sessionInstanceID: originatingSessionInstanceID
        ) else { return false }
        historyResumeIntentID = nil
        selectProfile(sourceProfile)
        selectSession(item)
        isHistoryPresented = false
        return true
    }

    func loadPromptPreferences() async {
        var requestIDs: [FerminCodeRelaySource: UUID] = [:]
        await withTaskGroup(of: PromptPreferenceResult.self) { group in
            for source in profile.sources {
                guard let token = tokens[source] else { continue }
                let requestID = UUID()
                requestIDs[source] = requestID
                promptPreferenceRequestIDs[source] = requestID
                group.addTask { [relay] in
                    do {
                        return PromptPreferenceResult(
                            source: source,
                            preference: try await relay.fetchPromptImproverPreference(
                                source: source,
                                token: token
                            ).preference,
                            failed: false
                        )
                    } catch {
                        return PromptPreferenceResult(
                            source: source,
                            preference: nil,
                            failed: true
                        )
                    }
                }
            }
            for await result in group {
                guard promptPreferenceRequestIDs[result.source] == requestIDs[result.source]
                else { continue }
                promptPreferenceRequestIDs.removeValue(forKey: result.source)
                if let preference = result.preference {
                    promptPreferences[result.source] = preference
                }
            }
        }
    }

    @discardableResult
    func setPromptPreference(_ variant: FerminRelayPromptImproverVariant) async -> Bool {
        let mutationKey = "prompt-preference"
        guard !activeMutations.contains(mutationKey) else { return false }
        activeMutations.insert(mutationKey)
        defer { activeMutations.remove(mutationKey) }
        var succeeded: [FerminCodeRelaySource] = []
        var failed: [FerminCodeRelaySource] = []
        await withTaskGroup(of: PromptPreferenceResult.self) { group in
            for source in profile.sources {
                guard let token = tokens[source] else {
                    failed.append(source)
                    continue
                }
                promptPreferenceRequestIDs.removeValue(forKey: source)
                group.addTask { [relay] in
                    do {
                        return PromptPreferenceResult(
                            source: source,
                            preference: try await relay.setPromptImproverPreference(
                                source: source,
                                token: token,
                                variant: variant
                            ).preference,
                            failed: false
                        )
                    } catch {
                        return PromptPreferenceResult(
                            source: source,
                            preference: nil,
                            failed: true
                        )
                    }
                }
            }
            for await result in group {
                if let preference = result.preference {
                    promptPreferences[result.source] = preference
                    succeeded.append(result.source)
                } else {
                    failed.append(result.source)
                }
            }
        }
        if failed.isEmpty {
            showNotice(
                "Preferencia aplicada en \(succeeded.map(\.displayName).joined(separator: " y "))."
            )
            errorMessage = nil
            return true
        } else if !succeeded.isEmpty {
            errorMessage = "Preferencia parcial: falló \(failed.map(\.displayName).joined(separator: ", "))."
        } else {
            errorMessage = "No se pudo guardar la preferencia."
        }
        return false
    }

    func openRemotePath(path: String, name: String, mimeType: String?) async {
        guard let route = selectedRoute,
              let expectedSessionInstanceID = selectedSessionInstanceID,
              let token = tokens[route.source] else { return }
        do {
            if let mimeType, mimeType.hasPrefix("image/") {
                let content = try await relay.fetchAttachmentContent(
                    source: route.source,
                    token: token,
                    path: path
                )
                guard selectedRoute == route,
                      selectedSessionInstanceID == expectedSessionInstanceID else { return }
                preview = FerminCodeDesktopPreview(
                    id: "\(route.source.rawValue)::\(path)",
                    name: name,
                    path: path,
                    content: .image(content.data, mimeType: content.mimeType ?? mimeType)
                )
            } else {
                let file = try await relay.filePreview(
                    source: route.source,
                    token: token,
                    path: path
                )
                guard selectedRoute == route,
                      selectedSessionInstanceID == expectedSessionInstanceID else { return }
                preview = FerminCodeDesktopPreview(
                    id: "\(route.source.rawValue)::\(path)",
                    name: file.name,
                    path: file.path,
                    content: .text(file.content, language: file.language)
                )
            }
        } catch {
            guard selectedRoute == route,
                  selectedSessionInstanceID == expectedSessionInstanceID else { return }
            errorMessage = presentable(error, action: "abrir el archivo")
        }
    }

    func closePreview() {
        preview = nil
    }

    func dismissMessages() {
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        notice = nil
        errorMessage = nil
    }

    private func showNotice(_ message: String) {
        errorMessage = nil
        notice = message
        noticeDismissalTask?.cancel()
        noticeDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, self?.notice == message else { return }
            self?.notice = nil
            self?.noticeDismissalTask = nil
        }
    }

    private func bootstrap() async {
        defer { isBootstrapping = false }
        if ProcessInfo.processInfo.arguments.contains("--fermin-ui-empty-credentials") {
            tokens.removeAll()
            sessionsBySource.removeAll()
            rebuildSessions()
            for source in FerminCodeRelaySource.allCases {
                credentialPresence[source] = false
                setMissingCredential(source)
            }
            return
        }
        let snapshot: FerminCodeCredentialSnapshot
        do {
            snapshot = try await credentialStore.load(importBootstrap: true)
        } catch {
            errorMessage = error.localizedDescription
            do {
                snapshot = try await credentialStore.load(importBootstrap: false)
            } catch {
                errorMessage = "No se pudieron leer las credenciales de Keychain."
                return
            }
        }
        for source in FerminCodeRelaySource.allCases {
            if let token = snapshot.token(for: source) { tokens[source] = token }
            credentialPresence[source] = snapshot.hasToken(for: source)
            if !snapshot.hasToken(for: source) { setMissingCredential(source) }
        }
        if !snapshot.importedSources.isEmpty {
            showNotice("Token bootstrap importado a Keychain y eliminado del contenedor.")
        }
        await refreshAll()
        await loadPromptPreferences()
        startStreams()
        startPeriodicRefresh()
    }

    private func refresh(source: FerminCodeRelaySource) async {
        let requestID = beginSourceRefresh(for: source)
        guard let token = tokens[source] else {
            setMissingCredential(source)
            return
        }
        do {
            async let health = relay.fetchHealth(source: source, token: token)
            async let sessions = relay.fetchSessions(source: source, token: token)
            let result = try await SourceRefreshResult(
                requestID: requestID,
                source: source,
                health: health,
                sessions: sessions,
                error: nil
            )
            apply(result)
        } catch {
            apply(SourceRefreshResult(
                requestID: requestID,
                source: source,
                health: nil,
                sessions: nil,
                error: error
            ))
        }
    }

    private func apply(_ result: SourceRefreshResult) {
        guard sourceRefreshRequestIDs[result.source] == result.requestID else { return }
        if let sessions = result.sessions, let health = result.health {
            guard applySnapshot(
                sessions,
                source: result.source,
                enforceSelectedIdentity: true
            ) else { return }
            sourceStatuses[result.source] = FerminCodeDesktopSourceStatus(
                source: result.source,
                phase: health.ok && health.ready ? .online : .stale,
                sessionCount: sessions.items.count,
                detail: health.ready ? health.version : "El relay respondió, pero no está listo.",
                lastUpdatedAt: FerminCodeDesktopTimestamp.date(
                    millisecondsOrSeconds: sessions.now ?? sessions.exportedAt ?? 0
                )
            )
        } else {
            sourceStatuses[result.source] = FerminCodeDesktopSourceStatus(
                source: result.source,
                phase: .offline,
                sessionCount: sessionsBySource[result.source]?.count ?? 0,
                detail: "No respondió el relay de producción.",
                lastUpdatedAt: sourceStatuses[result.source]?.lastUpdatedAt
            )
        }
    }

    private func beginSourceRefresh(for source: FerminCodeRelaySource) -> UUID {
        let requestID = UUID()
        sourceRefreshRequestIDs[source] = requestID
        return requestID
    }

    @discardableResult
    private func applySnapshot(
        _ envelope: FerminRelaySessionsEnvelope,
        source: FerminCodeRelaySource,
        reconcilePersistedCursor: Bool = true,
        enforceSelectedIdentity: Bool = false
    ) -> Bool {
        guard !snapshotContainsDuplicateRoutes(envelope.items) else {
            sourceStatuses[source] = FerminCodeDesktopSourceStatus(
                source: source,
                phase: .stale,
                sessionCount: sessionsBySource[source]?.count ?? 0,
                detail: "El snapshot repitió una ventana; se conservó el estado previo.",
                lastUpdatedAt: sourceStatuses[source]?.lastUpdatedAt
            )
            return false
        }
        if enforceSelectedIdentity,
           let selectedIdentity = selectedSessionIdentity,
           selectedIdentity.source == source,
           selectedSession?.messages.isEmpty == false {
            let containsSelectedIdentity = envelope.items.contains { summary in
                guard let route = try? FerminCodeRelaySessionRoute(
                    source: source,
                    windowID: summary.windowID
                ),
                let summaryIdentity = FerminCodeDesktopSessionIdentity(
                    route: route,
                    sessionID: summary.sessionID
                ) else { return false }
                return summaryIdentity == selectedIdentity
            }
            if !containsSelectedIdentity {
                clearSelection()
            }
        }
        reconcilePinnedStateOverrides(in: envelope.items, source: source)
        sessionsBySource[source] = envelope.items
        rebuildSessions()
        if reconcilePersistedCursor,
           let authoritativeCursor = envelope.cursor,
           let storedCursor = loadCursor(for: source),
           authoritativeCursor < storedCursor {
            persistCursor(authoritativeCursor, for: source)
            restartStream(for: source)
        }
        if let route = selectedRoute,
           route.source == source,
           selectedSession?.messages.isEmpty != false {
            let selectedIdentity = selectedSession.flatMap {
                FerminCodeDesktopSessionIdentity(route: route, sessionID: $0.sessionID)
            }
            let summary = envelope.items.first { item in
                guard item.windowID == route.windowID else { return false }
                guard selectedSession != nil else { return true }
                guard let selectedIdentity,
                      let summaryIdentity = FerminCodeDesktopSessionIdentity(
                          route: route,
                          sessionID: item.sessionID
                      ) else { return false }
                return summaryIdentity == selectedIdentity
            }
            if let summary {
                selectedSession = summary
            }
        }
        return true
    }

    private func snapshotContainsDuplicateRoutes(
        _ items: [FerminRelaySession]
    ) -> Bool {
        var windowIDs = Set<String>()
        for item in items {
            guard let windowID = normalized(item.windowID) else { continue }
            if !windowIDs.insert(windowID).inserted {
                return true
            }
        }
        return false
    }

    private func rebuildSessions() {
        sourcedSessions = FerminCodeRelayAggregation.sessions(
            personal: sessionsBySource[.personal] ?? [],
            puky: sessionsBySource[.puky] ?? []
        )
    }

    private func reconcilePinnedStateOverrides(
        in sessions: [FerminRelaySession],
        source: FerminCodeRelaySource
    ) {
        for session in sessions {
            reconcilePinnedStateOverride(for: session, source: source)
        }
    }

    private func reconcilePinnedStateOverride(
        for session: FerminRelaySession,
        source: FerminCodeRelaySource
    ) {
        guard let authoritative = session.isPinned,
              let route = try? FerminCodeRelaySessionRoute(
                  source: source,
                  windowID: session.windowID
              ), let pending = pinnedStateOverridesByRoute[route] else { return }
        let confirmsLocalChange = pending.pinned == authoritative
        let supersedesLocalChange = session.updatedAt > pending.baselineUpdatedAt
        guard confirmsLocalChange || supersedesLocalChange || pending.expiresAt <= Date() else {
            return
        }
        pinnedStateOverridesByRoute.removeValue(forKey: route)
    }

    private func clearModelCatalogErrorIfCurrent() {
        let previousCatalogError = modelCatalogErrorMessage
        modelCatalogErrorMessage = nil
        if errorMessage == previousCatalogError {
            errorMessage = nil
        }
    }

    private func refreshDetail(
        route: FerminCodeRelaySessionRoute,
        userInitiated: Bool
    ) async {
        guard selectedRoute == route else { return }
        guard let token = tokens[route.source] else {
            detailLoadState = .failed(
                "Configurá el token de \(route.source.displayName) para cargar la conversación."
            )
            return
        }
        let requestID = UUID()
        let expectedSessionID = selectedSession?.sessionID
        detailRequestID = requestID
        if userInitiated || detailLoadState == .idle || detailLoadState.errorMessage != nil {
            detailLoadState = selectedSession?.messages.isEmpty == false
                ? .revalidating
                : .loading
        }
        do {
            let detail = try await relay.fetchSession(
                source: route.source,
                token: token,
                windowID: route.windowID
            ).item
            guard selectedRoute == route,
                  detailRequestID == requestID else { return }
            applySessionDetail(
                detail,
                route: route,
                expectedSessionID: expectedSessionID,
                presentMismatch: true
            )
        } catch {
            guard selectedRoute == route,
                  detailRequestID == requestID else { return }
            detailLoadState = .failed(
                presentable(error, action: "cargar la conversación")
            )
        }
    }

    private func detailRecoveryContext(
        for source: FerminCodeRelaySource
    ) -> FerminCodeDesktopDetailRecoveryContext {
        guard selectedRoute?.source == source else {
            return FerminCodeDesktopDetailRecoveryContext(
                route: nil,
                identity: nil,
                requestID: nil
            )
        }
        return FerminCodeDesktopDetailRecoveryContext(
            route: selectedRoute,
            identity: selectedSessionIdentity,
            requestID: detailRequestID
        )
    }

    private func ownsDetailRecoveryContext(
        _ context: FerminCodeDesktopDetailRecoveryContext,
        source: FerminCodeRelaySource
    ) -> Bool {
        detailRecoveryContext(for: source) == context
    }

    private func validateRecoverySelection(
        _ context: FerminCodeDesktopDetailRecoveryContext,
        source: FerminCodeRelaySource
    ) throws {
        guard let currentRoute = selectedRoute,
              currentRoute.source == source else { return }
        guard currentRoute == context.route,
              selectedSessionIdentity == context.identity else {
            throw FerminCodeDesktopUserError(
                "La sesión seleccionada cambió durante la revalidación."
            )
        }
    }

    private func loadModelCatalog(
        route: FerminCodeRelaySessionRoute,
        userInitiated: Bool = false
    ) async {
        guard selectedRoute == route,
              let token = tokens[route.source] else { return }
        let requestID = UUID()
        modelCatalogRequestID = requestID
        isLoadingModels = true
        defer {
            if modelCatalogRequestID == requestID {
                isLoadingModels = false
            }
        }
        do {
            let fetched = try await relay.fetchModels(
                source: route.source,
                token: token,
                windowID: route.windowID
            ).data
            guard selectedRoute == route,
                  modelCatalogRequestID == requestID else { return }
            models = FerminRelayRuntimePolicy.supportedModels(from: fetched)
            let previousCatalogError = modelCatalogErrorMessage
            modelCatalogErrorMessage = nil
            if errorMessage == previousCatalogError {
                errorMessage = nil
            }
        } catch {
            guard selectedRoute == route,
                  modelCatalogRequestID == requestID else { return }
            models = []
            if userInitiated {
                let message = presentable(error, action: "cargar los modelos")
                modelCatalogErrorMessage = message
                errorMessage = message
            }
        }
    }

    private func waitForSession(
        source: FerminCodeRelaySource,
        token: String,
        sessionID: String,
        expectedName: String?,
        requireStartedSubagent: Bool = false
    ) async -> FerminCodeRelaySourcedSession? {
        let startedAt = timing.now()
        while !Task.isCancelled, timing.now() - startedAt < createConfirmationTimeout {
            if let existing = sessionsBySource[source]?.first(where: {
                matches(
                    $0,
                    sessionID: sessionID,
                    expectedName: expectedName,
                    requireStartedSubagent: requireStartedSubagent
                )
            }) {
                return FerminCodeRelaySourcedSession(source: source, session: existing)
            }
            do {
                let snapshot = try await relay.fetchSessions(source: source, token: token)
                if applySnapshot(snapshot, source: source),
                   let created = snapshot.items.first(where: {
                    matches(
                        $0,
                        sessionID: sessionID,
                        expectedName: expectedName,
                        requireStartedSubagent: requireStartedSubagent
                    )
                }) {
                    return FerminCodeRelaySourcedSession(source: source, session: created)
                }
            } catch {
                // A transient read failure must not discard the accepted durable create.
            }
            await timing.sleep(createPollNanoseconds)
        }
        return nil
    }

    private func matches(
        _ session: FerminRelaySession,
        sessionID: String,
        expectedName: String?,
        requireStartedSubagent: Bool = false
    ) -> Bool {
        guard session.sessionID == sessionID else { return false }
        if let expectedName {
            let actual = (session.sessionName ?? session.windowName ?? session.displayName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard actual == expectedName else { return false }
        }
        guard requireStartedSubagent else { return true }
        return session.messageCount > 0
            && session.pendingSubagent?.childMessageSentAt != nil
    }

    private func projectsWithRoot(
        _ envelope: FerminRelayProjectDirectoryEnvelope
    ) -> [FerminRelayProjectDirectory] {
        guard let root = envelope.rootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else { return envelope.items }
        let rootItem = FerminRelayProjectDirectory(name: "~/projects", path: root, kind: "root")
        return [rootItem] + envelope.items.filter { $0.path != root }
    }

    private func durableMutation(
        key: String,
        operation: FerminRelayTrackedCommandOperation,
        route: FerminCodeRelaySessionRoute,
        messageID: String? = nil,
        targetSessionID: String? = nil,
        mutationID: String? = nil,
        shouldPresentFailure: () -> Bool = { true },
        action: () async throws -> FerminRelayDurableCommandAcknowledgement
    ) async -> Bool {
        guard !activeMutations.contains(key) else { return false }
        activeMutations.insert(key)
        defer { activeMutations.remove(key) }
        do {
            let acknowledgement = try await action()
            try await register(
                acknowledgement,
                operation: operation,
                route: route,
                messageID: messageID,
                sessionID: targetSessionID ?? selectedSession?.sessionID,
                mutationID: mutationID
            )
            await refresh(source: route.source)
            if selectedSessionMatches(route: route, sessionID: targetSessionID) {
                await refreshDetail(route: route, userInitiated: false)
            }
            return true
        } catch {
            if selectedSessionMatches(route: route, sessionID: targetSessionID),
               shouldPresentFailure() {
                errorMessage = presentable(error, action: label(for: operation))
            }
            return false
        }
    }

    private func mutate(
        key: String,
        action: () async throws -> Void
    ) async {
        activeMutations.insert(key)
        defer { activeMutations.remove(key) }
        do {
            try await action()
        } catch {
            errorMessage = presentable(error, action: key)
        }
    }

    private func register(
        _ acknowledgement: FerminRelayDurableCommandAcknowledgement,
        operation: FerminRelayTrackedCommandOperation,
        route: FerminCodeRelaySessionRoute? = nil,
        source: FerminCodeRelaySource? = nil,
        messageID: String? = nil,
        sessionID: String? = nil,
        mutationID: String? = nil
    ) async throws {
        let resolvedSource = route?.source ?? source
        guard let resolvedSource, let tracker = commandTrackers[resolvedSource] else {
            throw FerminCodeDesktopUserError("No se pudo determinar el origen del comando.")
        }
        let context = FerminRelayTrackedCommandContext(
            operation: operation,
            source: resolvedSource,
            windowID: route?.windowID,
            messageID: messageID,
            sessionID: sessionID,
            mutationID: mutationID
        )
        let transition = try await tracker.register(acknowledgement, context: context)
        let state = acknowledgement.commandState ?? .unknown
        let key = commandKey(source: resolvedSource, commandID: acknowledgement.commandID)
        if !state.isTerminal {
            pendingCommands[key] = FerminCodeDesktopPendingCommand(
                id: key,
                source: resolvedSource,
                operation: operation,
                windowID: route?.windowID,
                messageID: messageID,
                state: state,
                error: nil
            )
        }
        await applyCommandTransition(
            transition,
            source: resolvedSource,
            commandID: acknowledgement.commandID
        )
    }

    private func applyCommandEvent(
        _ event: FerminRelayCommandStateChangedEvent,
        source: FerminCodeRelaySource
    ) async {
        let key = commandKey(source: source, commandID: event.commandID)
        if var command = pendingCommands[key] {
            command.state = event.state
            command.error = event.error
            pendingCommands[key] = command
        }
        guard let tracker = commandTrackers[source] else { return }
        let transition = await tracker.apply(event)
        await applyCommandTransition(
            transition,
            source: source,
            commandID: event.commandID
        )
    }

    private func applyCommandTransition(
        _ transition: FerminRelayCommandTransition,
        source: FerminCodeRelaySource,
        commandID: String
    ) async {
        let key = commandKey(source: source, commandID: commandID)
        switch transition {
        case .ignored, .pending:
            break
        case .completed(let context):
            pendingCommands.removeValue(forKey: key)
            await reconcile(context)
        case .failed(let context, _, _):
            pendingCommands.removeValue(forKey: key)
            if context?.operation == .sendMessage, let messageID = context?.messageID {
                setOptimisticDelivery(
                    id: messageID,
                    delivery: .failed("El relay no pudo completar el envío.")
                )
            }
            if context?.operation == .setFeatures,
               context?.source == source,
               let windowID = context?.windowID,
               let sessionID = context?.sessionID,
               let route = try? FerminCodeRelaySessionRoute(
                   source: source,
                   windowID: windowID
               ),
               let identity = FerminCodeDesktopSessionIdentity(
                   route: route,
                   sessionID: sessionID
               ),
               featureOverridePatchesBySessionIdentity[identity]?.idempotencyKey
                   == context?.mutationID {
                featureOverridesBySessionIdentity.removeValue(forKey: identity)
                featureOverridePatchesBySessionIdentity.removeValue(forKey: identity)
            }
            if context?.operation == .setRunMode,
               context?.source == source,
               let windowID = context?.windowID,
               let route = try? FerminCodeRelaySessionRoute(
                   source: source,
                   windowID: windowID
               ),
               goalModeOverrideMutationIDsByRoute[route] == context?.mutationID {
                goalModeOverridesByRoute.removeValue(forKey: route)
                goalModeOverrideMutationIDsByRoute.removeValue(forKey: route)
            }
            if context?.operation == .setModel,
               context?.source == source,
               let windowID = context?.windowID,
               let route = try? FerminCodeRelaySessionRoute(
                   source: source,
                   windowID: windowID
               ),
               runtimeModelOverrideMutationIDsByRoute[route] == context?.mutationID {
                runtimeModelOverridesByRoute.removeValue(forKey: route)
                runtimeModelOverrideMutationIDsByRoute.removeValue(forKey: route)
            }
            if context?.operation == .setPinned,
               context?.source == source,
               let windowID = context?.windowID,
               let route = try? FerminCodeRelaySessionRoute(
                   source: source,
                   windowID: windowID
               ), pinnedStateOverridesByRoute[route]?.mutationID == context?.mutationID {
                pinnedStateOverridesByRoute.removeValue(forKey: route)
                errorMessage = "No se pudo sincronizar el estado fijado de la sesión. Reintentá."
            }
            if selectedSessionMatches(
                source: context?.source,
                windowID: context?.windowID,
                sessionID: context?.sessionID
            ), FerminCodeDesktopCommandTargetPolicy.shouldPresentFailure(
                context: context,
                eventSource: source,
                selectedRoute: selectedRoute
            ) {
                if let operation = context?.operation {
                    errorMessage = "No se pudo \(label(for: operation)) en \(source.displayName)."
                } else {
                    errorMessage = "Un comando en \(source.displayName) terminó con error."
                }
            }
        }
    }

    private func reconcile(_ context: FerminRelayTrackedCommandContext?) async {
        guard let context else { return }
        await refresh(source: context.source)
        if context.operation == .archive || context.operation == .delete,
           let windowID = context.windowID,
           let route = try? FerminCodeRelaySessionRoute(
               source: context.source,
               windowID: windowID
           ) {
            sessionsBySource[context.source]?.removeAll { $0.windowID == windowID }
            rebuildSessions()
            purgeCachedDetails(for: route)
            if selectedSessionMatches(
                source: context.source,
                windowID: windowID,
                sessionID: context.sessionID
            ) {
                clearSelection()
            }
            showNotice(
                context.operation == .delete
                    ? "Sesión eliminada definitivamente."
                    : "Sesión archivada."
            )
            return
        }
        if let windowID = context.windowID,
           selectedSessionMatches(
               source: context.source,
               windowID: windowID,
               sessionID: context.sessionID
           ),
           let route = selectedRoute {
            await refreshDetail(route: route, userInitiated: false)
        }
    }

    private func setOptimisticDelivery(
        id: String,
        delivery: FerminCodeDesktopOptimisticMessage.Delivery
    ) {
        guard let index = optimisticMessages.firstIndex(where: { $0.id == id }) else { return }
        optimisticMessages[index].delivery = delivery
    }

    private func selectedSessionMatches(
        route: FerminCodeRelaySessionRoute,
        sessionID: String?
    ) -> Bool {
        guard selectedRoute == route else { return false }
        guard let sessionID = normalized(sessionID) else { return true }
        return normalized(selectedSession?.sessionID) == sessionID
    }

    private func reconcileAuthoritativeSend(
        route: FerminCodeRelaySessionRoute,
        token: String,
        identity: FerminCodeDesktopSessionIdentity,
        messageID: String
    ) async -> Bool {
        guard let detail = try? await relay.fetchSession(
            source: route.source,
            token: token,
            windowID: route.windowID
        ).item,
        normalized(detail.sessionID) == identity.sessionID,
        detail.messages.contains(where: { $0.id == messageID }) else {
            return false
        }
        if selectedSessionMatches(route: route, sessionID: identity.sessionID) {
            applySessionDetail(
                detail,
                route: route,
                expectedSessionID: identity.sessionID,
                presentMismatch: false
            )
        } else {
            optimisticMessages.removeAll { $0.id == messageID }
            failedComposerDrafts.removeValue(forKey: messageID)
        }
        clearConfirmedComposerFailure(messageID: messageID)
        return true
    }

    private func isAmbiguousSendResult(_ error: Error) -> Bool {
        if let relayError = error as? FerminRelayHTTPError {
            switch relayError {
            case .transport, .invalidResponse, .decoding:
                return true
            default:
                return false
            }
        }
        return error is URLError
    }

    private func selectedSessionMatches(
        source: FerminCodeRelaySource?,
        windowID: String?,
        sessionID: String?
    ) -> Bool {
        guard let source,
              let windowID,
              let route = try? FerminCodeRelaySessionRoute(
                  source: source,
                  windowID: windowID
              ) else { return false }
        return selectedSessionMatches(route: route, sessionID: sessionID)
    }

    private func preserveComposerDraftAfterSelectionChange(
        _ text: String,
        attachments: [FerminCodeDesktopAttachmentDraft],
        route: FerminCodeRelaySessionRoute,
        identity: FerminCodeDesktopSessionIdentity
    ) {
        guard !selectedSessionMatches(route: route, sessionID: identity.sessionID),
              let draftKey = sessionScopedDraftKey(
                  for: route,
                  sessionID: identity.sessionID
              ) else { return }
        let existing = composerDraftsByRoute[draftKey]
        let recovered = mergedComposerDraft(
            failedText: text,
            failedAttachments: attachments,
            existingText: existing?.text ?? "",
            existingAttachments: existing?.attachments ?? []
        )
        composerDraftsByRoute[draftKey] = recovered
    }

    private func mergedComposerDraft(
        failedText: String,
        failedAttachments: [FerminCodeDesktopAttachmentDraft],
        existingText: String,
        existingAttachments: [FerminCodeDesktopAttachmentDraft]
    ) -> FerminCodeDesktopComposerDraftState {
        let combinedText: String
        if failedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedText = existingText
        } else if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedText = failedText
        } else {
            combinedText = failedText + "\n\n" + existingText
        }
        var attachmentIDs = Set<String>()
        let combinedAttachments = (failedAttachments + existingAttachments).filter {
            attachmentIDs.insert($0.id).inserted
        }
        return FerminCodeDesktopComposerDraftState(
            text: combinedText,
            attachments: combinedAttachments
        )
    }

    private func stashSelectedComposerDraft() {
        guard let route = selectedRoute,
              let key = sessionScopedDraftKey(
                  for: route,
                  sessionID: selectedSession?.sessionID
              ) else { return }
        if composerText.isEmpty, attachments.isEmpty {
            composerDraftsByRoute.removeValue(forKey: key)
        } else {
            composerDraftsByRoute[key] = FerminCodeDesktopComposerDraftState(
                text: composerText,
                attachments: attachments
            )
        }
    }

    private func restoreComposerDraft(for route: FerminCodeRelaySessionRoute) {
        let key = sessionScopedDraftKey(
            for: route,
            sessionID: selectedSession?.sessionID
        )
        let draft = key.flatMap { composerDraftsByRoute[$0] }
        composerText = draft?.text ?? ""
        attachments = draft?.attachments ?? []
    }

    private func stashSelectedSubagentDraft() {
        guard let route = selectedRoute,
              let key = sessionScopedDraftKey(
                  for: route,
                  sessionID: selectedSession?.sessionID
              ) else { return }
        if subagentDisplayNameDraft.isEmpty, subagentTaskDraft.isEmpty {
            subagentDraftsByRoute.removeValue(forKey: key)
        } else {
            subagentDraftsByRoute[key] = FerminCodeDesktopSubagentDraftState(
                displayName: subagentDisplayNameDraft,
                task: subagentTaskDraft
            )
        }
    }

    private func restoreSubagentDraft(for route: FerminCodeRelaySessionRoute) {
        let key = sessionScopedDraftKey(
            for: route,
            sessionID: selectedSession?.sessionID
        )
        let draft = key.flatMap { subagentDraftsByRoute[$0] }
        subagentDisplayNameDraft = draft?.displayName ?? ""
        subagentTaskDraft = draft?.task ?? ""
    }

    private func sessionScopedDraftKey(
        for route: FerminCodeRelaySessionRoute,
        sessionID: String?
    ) -> String? {
        let normalizedSessionID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedSessionID.isEmpty else { return nil }
        return "\(route.id)::instance::\(normalizedSessionID)"
    }

    private func clearObservedCreateCommand(
        source: FerminCodeRelaySource,
        commandID: String
    ) {
        pendingCommands.removeValue(forKey: commandKey(source: source, commandID: commandID))
    }

    private func reconcileOptimistic(with authoritative: [FerminRelayMessage]) {
        let authoritativeIDs = Set(authoritative.map(\.id))
        if let failureID = composerSendFailureMessageID,
           authoritativeIDs.contains(failureID) {
            clearConfirmedComposerFailure(messageID: failureID)
        }
        if let route = selectedRoute {
            let observedCommandKeys: [String] = pendingCommands.compactMap { element in
                let (key, command) = element
                guard command.source == route.source,
                      command.windowID == route.windowID,
                      command.operation == .sendMessage,
                      let messageID = command.messageID,
                      authoritativeIDs.contains(messageID) else {
                    return nil
                }
                return key
            }
            for key in observedCommandKeys {
                pendingCommands.removeValue(forKey: key)
            }
        }
        optimisticMessages.removeAll { authoritativeIDs.contains($0.id) }
        for messageID in authoritativeIDs {
            failedComposerDrafts.removeValue(forKey: messageID)
        }
        liveMessages = liveMessages.filter { id, live in
            !authoritativeIDs.contains(id) || !live.isFinal
        }
    }

    private func clearConfirmedComposerFailure(messageID: String) {
        guard composerSendFailureMessageID == messageID else { return }
        if let failedDraft = failedComposerDrafts[messageID] {
            if composerText == failedDraft.text {
                composerText = ""
            } else {
                let restoredPrefix = failedDraft.text + "\n\n"
                if composerText.hasPrefix(restoredPrefix) {
                    composerText.removeFirst(restoredPrefix.count)
                }
            }
            let restoredAttachmentIDs = Set(failedDraft.attachments.map(\.id))
            attachments.removeAll { restoredAttachmentIDs.contains($0.id) }
        }
        failedComposerDrafts.removeValue(forKey: messageID)
        composerSendFailureMessageID = nil
        if errorMessage == composerSendErrorMessage {
            errorMessage = nil
        } else {
            composerSendErrorMessage = nil
        }
    }

    private func reconcileFeatureOverride(
        for identity: FerminCodeDesktopSessionIdentity,
        with authoritative: FerminRelaySessionFeatures?
    ) {
        guard queuedFeatureMutations[identity] == nil,
              let featureOverride = featureOverridesBySessionIdentity[identity] else { return }
        let isConfirmed: Bool
        if let featureOverridePatch = featureOverridePatchesBySessionIdentity[identity] {
            isConfirmed = FerminCodeDesktopFeatureConfirmationPolicy.confirms(
                patch: featureOverridePatch,
                authoritative: authoritative
            )
        } else {
            isConfirmed = authoritative == featureOverride
        }
        guard isConfirmed else { return }
        featureOverridesBySessionIdentity.removeValue(forKey: identity)
        featureOverridePatchesBySessionIdentity.removeValue(forKey: identity)
    }

    private func reconcileGoalModeOverride(
        for route: FerminCodeRelaySessionRoute,
        with authoritativeRunMode: String?
    ) {
        guard queuedGoalMutations[route.id] == nil,
              let goalModeOverride = goalModeOverridesByRoute[route] else { return }
        let authoritativeEnabled = authoritativeRunMode?.lowercased() == "goal"
        guard authoritativeEnabled == goalModeOverride else { return }
        goalModeOverridesByRoute.removeValue(forKey: route)
        goalModeOverrideMutationIDsByRoute.removeValue(forKey: route)
    }

    private func reconcileRuntimeModelOverride(
        for route: FerminCodeRelaySessionRoute,
        with authoritative: FerminRelaySession
    ) {
        guard let runtimeModelOverride = runtimeModelOverridesByRoute[route] else { return }
        guard authoritative.model == runtimeModelOverride.model,
              authoritative.reasoningEffort?.caseInsensitiveCompare(
                  runtimeModelOverride.effort
              ) == .orderedSame else { return }
        runtimeModelOverridesByRoute.removeValue(forKey: route)
        runtimeModelOverrideMutationIDsByRoute.removeValue(forKey: route)
    }

    private func startStreams() {
        for source in FerminCodeRelaySource.allCases where tokens[source] != nil {
            restartStream(for: source)
        }
    }

    private func restartStream(for source: FerminCodeRelaySource) {
        streamTasks[source]?.cancel()
        guard tokens[source] != nil else {
            streamTasks.removeValue(forKey: source)
            return
        }
        streamTasks[source] = Task { [weak self] in
            await self?.runStream(source: source)
        }
    }

    private func runStream(source: FerminCodeRelaySource) async {
        var backoffSeconds: UInt64 = 1
        while !Task.isCancelled, let token = tokens[source] {
            do {
                var cursor = FerminRelaySSECursor(lastEventID: loadCursor(for: source))
                let stream = try await relay.stream(
                    source: source,
                    token: token,
                    lastEventID: cursor.lastEventID
                )
                backoffSeconds = 1
                deliveryLoop: for try await envelope in stream {
                    try Task.checkCancellation()
                    try await applyStreamEnvelope(envelope, source: source)
                    try cursor.apply(envelope.cursorAction)
                    persistCursor(cursor.lastEventID, for: source)
                    if case .reset = envelope.cursorAction {
                        break deliveryLoop
                    }
                }
            } catch is CancellationError {
                return
            } catch let relayError as FerminRelayHTTPError where relayError.requiresFullRefetch {
                sourceStatuses[source]?.phase = .stale
                sourceStatuses[source]?.detail = "Revalidando eventos perdidos…"
                do {
                    try await authoritativeRefetchAfterStreamLoss(source: source)
                } catch {
                    sourceStatuses[source]?.phase = .offline
                    sourceStatuses[source]?.detail = "No se pudo revalidar después de perder eventos."
                }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(30, backoffSeconds * 2)
            } catch {
                if sourceStatuses[source]?.phase != .missingCredential {
                    sourceStatuses[source]?.phase = .stale
                    sourceStatuses[source]?.detail = "Reconectando el stream…"
                }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(30, backoffSeconds * 2)
            }
        }
    }

    private func applyStreamEnvelope(
        _ envelope: FerminRelayStreamDelivery,
        source: FerminCodeRelaySource
    ) async throws {
        switch envelope.event {
        case .snapshot(let snapshot):
            guard applySnapshot(
                snapshot,
                source: source,
                reconcilePersistedCursor: false,
                enforceSelectedIdentity: true
            ) else {
                throw FerminCodeDesktopUserError(
                    "El snapshot del stream contiene rutas de sesión ambiguas."
                )
            }
        case .messagePatch(let patch):
            guard selectedRoute?.source == source,
                  selectedRoute?.windowID == patch.windowID else { return }
            if var existing = liveMessages[patch.message.id] {
                _ = existing.apply(patch)
                liveMessages[patch.message.id] = existing
            } else {
                liveMessages[patch.message.id] = FerminCodeDesktopLiveMessage(
                    message: patch.message,
                    revision: patch.revision,
                    updatedAt: patch.updatedAt,
                    isFinal: patch.isFinal
                )
            }
            if patch.isFinal, let route = selectedRoute {
                await refreshDetail(route: route, userInitiated: false)
            }
        case .commandStateChanged(let event):
            await applyCommandEvent(event, source: source)
        case .sessionUpserted(let session):
            guard let incomingWindowID = normalized(session.windowID),
                  let incomingSessionID = normalized(session.sessionID) else {
                sourceStatuses[source]?.phase = .stale
                sourceStatuses[source]?.detail = "Revalidando una sesión sin identidad…"
                await refresh(source: source)
                return
            }
            let replacesSelectedIdentity = selectedRoute?.source == source
                && selectedRoute?.windowID == incomingWindowID
                && normalized(selectedSession?.sessionID) != incomingSessionID
            if replacesSelectedIdentity {
                sourceStatuses[source]?.phase = .stale
                sourceStatuses[source]?.detail = "Revalidando la identidad de la sesión…"
                clearSelection()
            }
            var items = sessionsBySource[source] ?? []
            items.removeAll { normalized($0.windowID) == incomingWindowID }
            items.append(session)
            sessionsBySource[source] = items
            reconcilePinnedStateOverride(for: session, source: source)
            rebuildSessions()
            if replacesSelectedIdentity {
                await refresh(source: source)
            }
        case .sessionRemoved(let event):
            let removedWindowID = normalized(event.windowID)
            let removedSessionID = normalized(event.sessionID)
            guard removedWindowID != nil || removedSessionID != nil else {
                sourceStatuses[source]?.phase = .stale
                sourceStatuses[source]?.detail = "Revalidando una baja sin identidad…"
                await refresh(source: source)
                return
            }
            sessionsBySource[source]?.removeAll {
                sessionRemovalMatches(
                    eventWindowID: removedWindowID,
                    eventSessionID: removedSessionID,
                    candidateWindowID: $0.windowID,
                    candidateSessionID: $0.sessionID
                )
            }
            rebuildSessions()
            purgeCachedDetails(
                for: source,
                windowID: removedWindowID,
                sessionID: removedSessionID
            )
            if let selectedRoute,
               selectedRoute.source == source,
               sessionRemovalMatches(
                   eventWindowID: removedWindowID,
                   eventSessionID: removedSessionID,
                   candidateWindowID: selectedRoute.windowID,
                   candidateSessionID: selectedSession?.sessionID
               ) {
                clearSelection()
            }
        case .refreshTarget(let name, let target):
            if name == "model_catalog_updated", let route = selectedRoute,
               route.source == source {
                await loadModelCatalog(route: route)
            }
            if let windowID = target.windowID,
               let route = selectedRoute,
               route.source == source,
               route.windowID == windowID {
                await refreshDetail(route: route, userInitiated: false)
            } else {
                await refresh(source: source)
            }
        case .serverError:
            sourceStatuses[source]?.phase = .stale
            sourceStatuses[source]?.detail = "El stream informó un error; revalidando…"
            await refresh(source: source)
        case .eventOmitted(let omitted):
            guard omitted.refetchRequired, let token = tokens[source] else { return }
            try await refetchAfterOmittedEvent(source: source, token: token)
        case .unknown(let name, _):
            if name == "event_omitted" {
                guard let token = tokens[source] else { return }
                try await refetchAfterOmittedEvent(source: source, token: token)
            }
        }
    }

    private func refetchAfterOmittedEvent(
        source: FerminCodeRelaySource,
        token: String
    ) async throws {
        let detailContext = detailRecoveryContext(for: source)
        let snapshot = try await relay.fetchSessions(source: source, token: token)
        try validateRecoverySelection(detailContext, source: source)
        guard applySnapshot(
            snapshot,
            source: source,
            enforceSelectedIdentity: true
        ) else {
            throw FerminCodeDesktopUserError(
                "El snapshot autoritativo contiene rutas de sesión ambiguas."
            )
        }
        guard ownsDetailRecoveryContext(detailContext, source: source),
              let route = detailContext.route else { return }
        let detail: FerminRelaySession
        do {
            detail = try await relay.fetchSession(
                source: source,
                token: token,
                windowID: route.windowID
            ).item
        } catch {
            guard ownsDetailRecoveryContext(detailContext, source: source) else { return }
            throw error
        }
        guard ownsDetailRecoveryContext(detailContext, source: source) else { return }
        applySessionDetail(
            detail,
            route: route,
            expectedSessionID: detailContext.identity?.sessionID,
            presentMismatch: false
        )
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    private func authoritativeRefetchAfterStreamLoss(
        source: FerminCodeRelaySource
    ) async throws {
        guard let token = tokens[source] else {
            throw FerminCodeDesktopUserError("Falta la credencial para revalidar el stream.")
        }
        let detailContext = detailRecoveryContext(for: source)
        let route = detailContext.route
        let snapshot = try await relay.fetchSessions(source: source, token: token)
        guard let authoritativeCursor = snapshot.cursor else {
            throw FerminCodeDesktopUserError("El snapshot no incluyó un cursor autoritativo.")
        }
        let detail: FerminRelaySession?
        if let route, ownsDetailRecoveryContext(detailContext, source: source) {
            do {
                detail = try await relay.fetchSession(
                    source: source,
                    token: token,
                    windowID: route.windowID
                ).item
            } catch {
                guard !ownsDetailRecoveryContext(detailContext, source: source) else {
                    throw error
                }
                detail = nil
            }
        } else {
            detail = nil
        }
        // The snapshot and cursor belong to the source even when the selected
        // detail changes mid-recovery. Ownership below still rejects stale detail.
        guard applySnapshot(
            snapshot,
            source: source,
            reconcilePersistedCursor: false,
            enforceSelectedIdentity: true
        ) else {
            throw FerminCodeDesktopUserError(
                "El snapshot autoritativo contiene rutas de sesión ambiguas."
            )
        }
        if let route, let detail,
           ownsDetailRecoveryContext(detailContext, source: source),
           !applySessionDetail(
               detail,
               route: route,
               expectedSessionID: detailContext.identity?.sessionID,
               presentMismatch: false
           ) {
            throw FerminCodeDesktopUserError("El detalle autoritativo no coincidió con la sesión.")
        }
        persistCursor(authoritativeCursor, for: source)
        sourceStatuses[source] = FerminCodeDesktopSourceStatus(
            source: source,
            phase: .online,
            sessionCount: snapshot.items.count,
            detail: "Stream sincronizado.",
            lastUpdatedAt: FerminCodeDesktopTimestamp.date(
                millisecondsOrSeconds: snapshot.now ?? snapshot.exportedAt ?? 0
            )
        )
    }

    @discardableResult
    private func applySessionDetail(
        _ detail: FerminRelaySession,
        route: FerminCodeRelaySessionRoute,
        expectedSessionID: String? = nil,
        presentMismatch: Bool
    ) -> Bool {
        guard selectedRoute == route else { return false }
        guard FerminCodeDesktopSessionDetailPolicy.matches(
            detail,
            route: route,
            expectedSessionID: expectedSessionID ?? selectedSession?.sessionID
        ) else {
            sourceStatuses[route.source]?.phase = .stale
            sourceStatuses[route.source]?.detail =
                "El detalle recibido no coincide con la sesión solicitada."
            if presentMismatch {
                detailLoadState = .failed(
                    "La conversación recibida no coincide con la seleccionada. Volvé a intentar."
                )
            }
            return false
        }
        selectedSession = detail
        detailLoadState = .loaded
        cacheDetail(detail, for: route)
        if let identity = FerminCodeDesktopSessionIdentity(
            route: route,
            sessionID: detail.sessionID
        ) {
            reconcileFeatureOverride(for: identity, with: detail.features)
        }
        reconcileGoalModeOverride(for: route, with: detail.runMode)
        reconcileRuntimeModelOverride(for: route, with: detail)
        reconcilePinnedStateOverride(for: detail, source: route.source)
        reconcileOptimistic(with: detail.messages)
        return true
    }

    private func cachedSession(
        for route: FerminCodeRelaySessionRoute,
        summary: FerminRelaySession
    ) -> FerminRelaySession? {
        guard let identity = FerminCodeDesktopSessionIdentity(
            route: route,
            sessionID: summary.sessionID
        ), let cached = cachedDetailsByRoute[identity] else { return nil }
        let age = max(0, timing.now() - cached.capturedAt)
        guard age <= Self.detailCacheTTL,
              !cached.messages.isEmpty else {
            removeCachedDetail(for: identity)
            return nil
        }
        touchCachedDetail(identity)
        return session(
            summary,
            replacingMessages: cached.messages,
            reportedMessageCount: cached.reportedMessageCount
        )
    }

    private func cacheDetail(
        _ detail: FerminRelaySession,
        for route: FerminCodeRelaySessionRoute
    ) {
        guard let identity = FerminCodeDesktopSessionIdentity(
            route: route,
            sessionID: detail.sessionID
        ) else {
            purgeCachedDetails(for: route)
            return
        }
        let messages = cacheableTail(from: detail.messages)
        guard !messages.isEmpty else {
            removeCachedDetail(for: identity)
            return
        }
        cachedDetailsByRoute[identity] = FerminCodeDesktopCachedDetail(
            messages: messages,
            reportedMessageCount: max(detail.messageCount, detail.messages.count),
            capturedAt: timing.now()
        )
        touchCachedDetail(identity)
        while cachedDetailLRU.count > Self.detailCacheEntryLimit,
              let oldest = cachedDetailLRU.first {
            removeCachedDetail(for: oldest)
        }
    }

    private func cacheableTail(
        from messages: [FerminRelayMessage]
    ) -> [FerminRelayMessage] {
        var retained: [FerminRelayMessage] = []
        var retainedBytes = 0
        for message in messages.reversed().prefix(Self.detailCacheMessageLimit) {
            let sanitized = cacheableMessage(message)
            let messageBytes = estimatedCacheBytes(for: sanitized)
            if messageBytes > Self.detailCacheByteLimit {
                if retained.isEmpty { return [] }
                break
            }
            guard retainedBytes + messageBytes <= Self.detailCacheByteLimit else { break }
            retained.append(sanitized)
            retainedBytes += messageBytes
        }
        return Array(retained.reversed())
    }

    private func cacheableMessage(_ message: FerminRelayMessage) -> FerminRelayMessage {
        FerminRelayMessage(
            id: message.id,
            role: message.role,
            type: message.type,
            content: message.content,
            originalPrompt: message.originalPrompt,
            transformedPrompt: message.transformedPrompt,
            improvedPrompt: message.improvedPrompt,
            timestamp: message.timestamp,
            status: message.status,
            imageAttachments: message.imageAttachments.map { attachment in
                FerminRelayMessageImageAttachment(
                    id: attachment.id,
                    name: attachment.name,
                    path: attachment.path,
                    size: attachment.size,
                    mimeType: attachment.mimeType,
                    previewData: nil
                )
            },
            transformStatus: message.transformStatus,
            transformErrorReason: message.transformErrorReason,
            promptTransformNote: message.promptTransformNote
        )
    }

    private func estimatedCacheBytes(for message: FerminRelayMessage) -> Int {
        var byteCount = [
            message.id,
            message.role,
            message.type,
            message.content,
            message.originalPrompt,
            message.transformedPrompt,
            message.improvedPrompt,
            message.status,
            message.transformStatus,
            message.transformErrorReason,
            message.promptTransformNote,
        ].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
        for attachment in message.imageAttachments {
            byteCount += attachment.id.utf8.count
                + attachment.name.utf8.count
                + (attachment.path?.utf8.count ?? 0)
                + attachment.mimeType.utf8.count
        }
        return byteCount
    }

    private func session(
        _ summary: FerminRelaySession,
        replacingMessages messages: [FerminRelayMessage],
        reportedMessageCount: Int
    ) -> FerminRelaySession {
        FerminRelaySession(
            windowID: summary.windowID,
            sessionID: summary.sessionID,
            engine: summary.engine,
            model: summary.model,
            reasoningEffort: summary.reasoningEffort,
            providerSessionID: summary.providerSessionID,
            providerSessionPath: summary.providerSessionPath,
            projectKey: summary.projectKey,
            projectPath: summary.projectPath,
            projectName: summary.projectName,
            windowName: summary.windowName,
            displayName: summary.displayName,
            sidecarMode: summary.sidecarMode,
            sidecarURL: summary.sidecarURL,
            activityStatus: summary.activityStatus,
            runtimeStatus: summary.runtimeStatus,
            runtimeStatusDetail: summary.runtimeStatusDetail,
            features: summary.features,
            runMode: summary.runMode,
            goalStartedAt: summary.goalStartedAt,
            messageCount: max(max(reportedMessageCount, summary.messageCount), messages.count),
            updatedAt: summary.updatedAt,
            createdAt: summary.createdAt,
            rawPrompt: summary.rawPrompt,
            originalPrompt: summary.originalPrompt,
            improvedPrompt: summary.improvedPrompt,
            lastMessagePreview: summary.lastMessagePreview,
            isMinimized: summary.isMinimized,
            isPinned: summary.isPinned,
            canSend: summary.canSend,
            canControlFeatures: summary.canControlFeatures,
            unsupportedReason: summary.unsupportedReason,
            messages: messages,
            pendingSubagent: summary.pendingSubagent,
            collaborationProjectID: summary.collaborationProjectID,
            collaborationProjectName: summary.collaborationProjectName,
            sessionName: summary.sessionName
        )
    }

    private func touchCachedDetail(_ identity: FerminCodeDesktopSessionIdentity) {
        cachedDetailLRU.removeAll { $0 == identity }
        cachedDetailLRU.append(identity)
    }

    private func removeCachedDetail(for identity: FerminCodeDesktopSessionIdentity) {
        cachedDetailsByRoute.removeValue(forKey: identity)
        cachedDetailLRU.removeAll { $0 == identity }
    }

    private func purgeCachedDetails() {
        cachedDetailsByRoute.removeAll(keepingCapacity: false)
        cachedDetailLRU.removeAll(keepingCapacity: false)
    }

    private func purgeCachedDetails(for source: FerminCodeRelaySource) {
        let identities = cachedDetailsByRoute.keys.filter { $0.source == source }
        identities.forEach { removeCachedDetail(for: $0) }
    }

    private func purgeCachedDetails(for route: FerminCodeRelaySessionRoute) {
        let identities = cachedDetailsByRoute.keys.filter {
            $0.source == route.source && $0.windowID == route.windowID
        }
        identities.forEach { removeCachedDetail(for: $0) }
    }

    private func purgeCachedDetails(
        for source: FerminCodeRelaySource,
        windowID: String?,
        sessionID: String?
    ) {
        let identities = cachedDetailsByRoute.keys.compactMap { identity -> FerminCodeDesktopSessionIdentity? in
            guard identity.source == source else { return nil }
            return sessionRemovalMatches(
                eventWindowID: windowID,
                eventSessionID: sessionID,
                candidateWindowID: identity.windowID,
                candidateSessionID: identity.sessionID
            ) ? identity : nil
        }
        identities.forEach { removeCachedDetail(for: $0) }
    }

    private func sessionRemovalMatches(
        eventWindowID: String?,
        eventSessionID: String?,
        candidateWindowID: String,
        candidateSessionID: String?
    ) -> Bool {
        guard eventWindowID != nil || eventSessionID != nil else { return false }
        if let eventWindowID,
           normalized(candidateWindowID) != eventWindowID {
            return false
        }
        if let eventSessionID,
           normalized(candidateSessionID) != eventSessionID {
            return false
        }
        return true
    }

    private func setMissingCredential(_ source: FerminCodeRelaySource) {
        sourceStatuses[source] = FerminCodeDesktopSourceStatus(
            source: source,
            phase: .missingCredential,
            sessionCount: 0,
            detail: "Configurá el token en Ajustes.",
            lastUpdatedAt: nil
        )
    }

    private func commandKey(source: FerminCodeRelaySource, commandID: String) -> String {
        "\(source.rawValue)::command::\(commandID)"
    }

    private func credentialMutationKey(
        action: String,
        for source: FerminCodeRelaySource
    ) -> String {
        "credential-\(action)-\(source.rawValue)"
    }

    private func cursorKey(for source: FerminCodeRelaySource) -> String {
        "fermin.code.desktop.sse.\(source.rawValue).\(source.productionBaseURL.absoluteString).cursor"
    }

    private func loadCursor(for source: FerminCodeRelaySource) -> UInt64? {
        guard let raw = defaults.string(forKey: cursorKey(for: source)) else { return nil }
        return UInt64(raw)
    }

    private func persistCursor(_ cursor: UInt64?, for source: FerminCodeRelaySource) {
        if let cursor {
            defaults.set(String(cursor), forKey: cursorKey(for: source))
        } else {
            defaults.removeObject(forKey: cursorKey(for: source))
        }
    }

    private func presentable(_ error: Error, action: String) -> String {
        FerminCodeDesktopErrorPresentation.message(for: error, action: action)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func label(for operation: FerminRelayTrackedCommandOperation) -> String {
        switch operation {
        case .createSession: return "crear la sesión"
        case .sendMessage: return "enviar el mensaje"
        case .interrupt: return "interrumpir la ejecución"
        case .retryPromptTransform: return "reintentar la mejora"
        case .minimize: return "cambiar el estado de la sesión"
        case .setPinned: return "sincronizar el estado fijado de la sesión"
        case .rename: return "renombrar la sesión"
        case .archive: return "archivar la sesión"
        case .delete: return "eliminar definitivamente la sesión"
        case .setFeatures: return "actualizar las funciones"
        case .setRunMode: return "cambiar el modo GOAL"
        case .setModel: return "cambiar el modelo"
        case .createSubagent: return "crear el subagente"
        case .resumeHistory: return "reanudar la sesión"
        case .recoverSession: return "recuperar la sesión"
        }
    }

    private func label(for variant: FerminRelayPromptImproverVariant) -> String {
        switch variant {
        case .standard: return "Estándar"
        case .motivational: return "Motivacional"
        case .unknown: return "Desconocida"
        }
    }

    private func featureMutationKey(
        for identity: FerminCodeDesktopSessionIdentity
    ) -> String {
        "features:\(identity.id)"
    }

    private func modelMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "model:\(route.id)"
    }

    private func goalMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "goal:\(route.id)"
    }

    private func renameMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "rename:\(route.id)"
    }

    private func interruptMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "interrupt:\(route.id)"
    }

    private func subagentMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "subagent:\(route.id)"
    }

    private func visibilityMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "visibility:\(route.id)"
    }

    private func archiveMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "archive:\(route.id)"
    }

    private func deleteMutationKey(for route: FerminCodeRelaySessionRoute) -> String {
        "delete:\(route.id)"
    }

    private func promptRetryMutationKey(
        messageID: String,
        route: FerminCodeRelaySessionRoute
    ) -> String {
        "prompt-retry:\(route.id):\(messageID)"
    }
}

private struct SourceRefreshResult: @unchecked Sendable {
    let requestID: UUID
    let source: FerminCodeRelaySource
    let health: FerminRelayHealth?
    let sessions: FerminRelaySessionsEnvelope?
    let error: Error?
}

private struct HistoryResult: @unchecked Sendable {
    let source: FerminCodeRelaySource
    let envelope: FerminRelaySessionHistoryEnvelope?
    let error: Error?
}

private struct RecoveryResult: @unchecked Sendable {
    let source: FerminCodeRelaySource
    let envelope: FerminRelaySessionRecoveryEnvelope?
    let error: Error?
}

private struct PromptPreferenceResult: Sendable {
    let source: FerminCodeRelaySource
    let preference: FerminRelayPromptImproverPreference?
    let failed: Bool
}
