import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum KycodeImageAttachmentOptimizer {
    static let maximumPixelDimension = 2_560
    static let optimizationThresholdBytes = 1_024 * 1_024

    static func optimized(
        data: Data,
        mimeType: String,
        force: Bool = false
    ) -> (data: Data, mimeType: String) {
        guard (force || data.count >= optimizationThresholdBytes),
              mimeType == "image/jpeg" || mimeType == "image/png",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maximumPixelDimension else {
            return (data, mimeType)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return (data, mimeType)
        }

        let image = UIImage(cgImage: thumbnail)
        if mimeType == "image/png", let optimizedPNG = image.pngData(), optimizedPNG.count < data.count {
            return (optimizedPNG, mimeType)
        }
        if let optimizedJPEG = image.jpegData(compressionQuality: 0.86), optimizedJPEG.count < data.count {
            return (optimizedJPEG, "image/jpeg")
        }
        return (data, mimeType)
    }
}

enum KycodeInterfaceCopyPolicy {
    static let dismissErrorAction = "Cerrar"

    static func dashboardSyncStatus(isConnected: Bool, isStreaming: Bool) -> String {
        guard isConnected else { return "Sin conexión" }
        return isStreaming ? "En vivo" : "Actualizando"
    }

    static func sessionActivityStatus(_ rawStatus: String) -> String {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "working": return "Trabajando"
        case "approval": return "Esperando"
        case "error": return "Error"
        case "ready", "done": return "Lista"
        case "idle": return "En espera"
        default: return "Sin conexión"
        }
    }
}

enum KycodeRuntimeFailurePresentationPolicy {
    static func message(activityStatus: String, detail: String?) -> String? {
        guard activityStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "error"
        else { return nil }
        let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }
}

private enum DashboardLayout {
    static let outerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 8
    static let gridSpacing: CGFloat = 8
    static let panelRadius: CGFloat = 3
    static let cardRadius: CGFloat = 3
}

private struct DashboardMetrics {
    let width: CGFloat
    let height: CGFloat
    let columnsCount: Int
    let visibleRows: Int
    let outerPadding: CGFloat
    let verticalPadding: CGFloat
    let sectionSpacing: CGFloat
    let gridSpacing: CGFloat
    let cardHeight: CGFloat
    let cardRadius: CGFloat
    let isTablet: Bool
    let isTabletLandscape: Bool
    let previewLineLimit: Int

    var fixedCardHeight: Bool { isTablet }
    var dashboardTitleSize: CGFloat { isTablet ? 24 : 28 }
    var cardTitleSize: CGFloat { isTablet ? 15 : 16.5 }
    var cardPreviewSize: CGFloat { isTablet ? 13.5 : 14 }
    var cardMetaSize: CGFloat { isTablet ? 10.5 : 10 }
    var cardPadding: CGFloat { isTablet ? 10 : 13 }
    var headerHeightEstimate: CGFloat { 0 }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: gridSpacing),
            count: columnsCount
        )
    }

    static func resolve(for size: CGSize) -> DashboardMetrics {
        let width = size.width
        let height = size.height
        let isTablet = width >= 768
        let isTabletLandscape = width >= 1024 && width > height
        // Filas de ancho completo. En teléfono siempre 1 columna (lista, no
        // grilla); en iPad como mucho 2, priorizando filas anchas.
        let columnsCount: Int
        if width >= 768 {
            columnsCount = 2
        } else {
            columnsCount = 1
        }

        let visibleRows = isTablet ? 2 : 0
        let outerPadding: CGFloat = isTablet ? 8 : DashboardLayout.outerPadding
        let verticalPadding: CGFloat = isTablet ? 8 : 10
        let sectionSpacing: CGFloat = isTablet ? 8 : DashboardLayout.sectionSpacing
        let gridSpacing: CGFloat = isTablet ? 10 : DashboardLayout.gridSpacing
        let headerEstimate: CGFloat = 0
        let bottomReserve: CGFloat = isTablet ? 52 : 34
        let availableGridHeight = max(0, height - headerEstimate - bottomReserve - (CGFloat(max(visibleRows - 1, 0)) * gridSpacing))
        let tabletCardHeight = floor(availableGridHeight / CGFloat(max(visibleRows, 1)))
        let cardHeight: CGFloat
        if isTabletLandscape {
            cardHeight = min(max(tabletCardHeight, 246), 316)
        } else if isTablet {
            cardHeight = min(max(tabletCardHeight, 274), 380)
        } else {
            // Teléfono: las filas se ajustan a su contenido (sin alto fijo).
            cardHeight = 0
        }

        return DashboardMetrics(
            width: width,
            height: height,
            columnsCount: columnsCount,
            visibleRows: visibleRows,
            outerPadding: outerPadding,
            verticalPadding: verticalPadding,
            sectionSpacing: sectionSpacing,
            gridSpacing: gridSpacing,
            cardHeight: cardHeight,
            cardRadius: DashboardLayout.cardRadius,
            isTablet: isTablet,
            isTabletLandscape: isTabletLandscape,
            previewLineLimit: isTablet ? (isTabletLandscape ? 11 : 14) : 2
        )
    }
}

private extension String {
    func leftPadded(to width: Int, with character: Character = "0") -> String {
        guard count < width else { return self }
        return String(repeating: String(character), count: width - count) + self
    }
}

private func kycodeSearchNormalize(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_AR")
        )
}

struct DashboardSearchIndexRevision: Equatable, Sendable {
    let windowId: String
    let collaborationSessionName: String
    let collaborationProjectDisplayName: String
    let projectName: String
    let projectPath: String
    let lastMessagePreview: String
    let rawPrompt: String

    init(session: KycodeSessionSummary) {
        windowId = session.windowId
        collaborationSessionName = kycodeSearchNormalize(session.collaborationSessionName)
        collaborationProjectDisplayName = kycodeSearchNormalize(
            session.collaborationProjectDisplayName ?? ""
        )
        projectName = kycodeSearchNormalize(session.projectName ?? "")
        projectPath = kycodeSearchNormalize(session.projectPath ?? "")
        lastMessagePreview = kycodeSearchNormalize(session.lastMessagePreview ?? "")
        rawPrompt = kycodeSearchNormalize(session.rawPrompt ?? "")
    }

    static func snapshot(
        for sessions: [KycodeSessionSummary]
    ) -> [DashboardSearchIndexRevision] {
        sessions
            .map(DashboardSearchIndexRevision.init(session:))
            .sorted { $0.windowId < $1.windowId }
    }

    var searchableFields: [(label: String, value: String)] {
        [
            ("nombre", collaborationSessionName),
            ("proyecto", collaborationProjectDisplayName),
            ("carpeta", projectName),
            ("ruta", projectPath),
            ("mensaje", lastMessagePreview),
            ("prompt", rawPrompt),
        ]
    }
}

struct DashboardSearchDocument: Sendable {
    let fields: [(label: String, value: String)]

    init(session: KycodeSessionSummary) {
        self.init(revision: DashboardSearchIndexRevision(session: session))
    }

    init(revision: DashboardSearchIndexRevision) {
        fields = revision.searchableFields
    }

    func contains(_ query: String) -> Bool {
        fields.contains { $0.value.contains(query) }
    }

    func matchingField(_ query: String) -> String? {
        fields.first { $0.value.contains(query) }?.label
    }
}

/// Uses the button's native pressed state so contact feedback happens on
/// touch-down instead of waiting for SwiftUI's action on touch-up.
private struct ImmediateVoiceButtonStyle: ButtonStyle {
    let onTouchDown: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ImmediateVoiceButtonStyleBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            reduceMotion: reduceMotion,
            onTouchDown: onTouchDown
        )
    }
}

private struct ImmediateVoiceButtonStyleBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let reduceMotion: Bool
    let onTouchDown: () -> Void

    var body: some View {
        label
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isPressed ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 1),
                value: isPressed
            )
            .onChange(of: isPressed) { _, pressed in
                guard pressed else { return }
                onTouchDown()
            }
    }
}

@MainActor
private final class RenameSessionHaptics {
    static let shared = RenameSessionHaptics()

    private let longPressGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let savedGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        longPressGenerator.prepare()
        savedGenerator.prepare()
        notificationGenerator.prepare()
    }

    func longPressDetected() {
        guard AppHaptics.shared.isEnabled else { return }
        longPressGenerator.impactOccurred(intensity: 0.86)
        longPressGenerator.prepare()
    }

    func nameSaved() {
        guard AppHaptics.shared.isEnabled else { return }
        savedGenerator.impactOccurred(intensity: 0.72)
        savedGenerator.prepare()
    }

    func nameError() {
        guard AppHaptics.shared.isEnabled else { return }
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}

private struct SessionRenameTarget: Identifiable, Equatable {
    let windowId: String
    let currentName: String
    let draftName: String?

    init(windowId: String, currentName: String, draftName: String? = nil) {
        self.windowId = windowId
        self.currentName = currentName
        self.draftName = draftName
    }

    var id: String { windowId }
}

private struct SessionDeleteTarget: Identifiable, Equatable {
    let windowId: String
    let displayName: String

    var id: String { windowId }
}

private struct SessionProjectSelectionTarget: Identifiable, Equatable {
    let session: KycodeSessionSummary

    var id: String { session.windowId }
}

private enum DashboardSessionFilter: String, CaseIterable {
    case all
    case attention

    var label: String {
        switch self {
        case .all: return "Todas"
        case .attention: return "Atención"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "rectangle.stack"
        case .attention: return "exclamationmark.bubble"
        }
    }
}

enum KycodeSessionPinningPolicy {
    static func identifiers(from storage: String) -> Set<String> {
        Set(storage.split(separator: "\n").map(String.init))
    }

    static func storageValue(for identifiers: Set<String>) -> String {
        identifiers.sorted().joined(separator: "\n")
    }

    static func isPinned(windowId: String, unpinnedWindowIds: Set<String>) -> Bool {
        !unpinnedWindowIds.contains(windowId)
    }

    static func pinnedSessions(
        in sessions: [KycodeSessionSummary],
        unpinnedWindowIds: Set<String>
    ) -> [KycodeSessionSummary] {
        sessions.filter { isPinned(windowId: $0.windowId, unpinnedWindowIds: unpinnedWindowIds) }
    }

    static func unpinnedSessions(
        in sessions: [KycodeSessionSummary],
        unpinnedWindowIds: Set<String>
    ) -> [KycodeSessionSummary] {
        sessions.filter { !isPinned(windowId: $0.windowId, unpinnedWindowIds: unpinnedWindowIds) }
    }
}

private enum DashboardFilterMenuSurface {
    case dock
    case search

    func profileIdentifier(_ profileId: String) -> String {
        switch self {
        case .dock: return "dashboard-target-\(profileId)"
        case .search: return "dashboard-search-target-\(profileId)"
        }
    }

    func filterIdentifier(_ filter: DashboardSessionFilter) -> String {
        switch self {
        case .dock: return "dashboard-menu-filter-\(filter.rawValue)"
        case .search: return "dashboard-search-menu-filter-\(filter.rawValue)"
        }
    }

    var resetIdentifier: String {
        switch self {
        case .dock: return "dashboard-reset-filters"
        case .search: return "dashboard-search-reset-filters"
        }
    }
}

enum KycodeDashboardEmptyCopyPolicy {
    static func title(minimizedCount: Int, showMinimizedSessions: Bool) -> String {
        minimizedCount > 0 && !showMinimizedSessions
            ? "Sesiones minimizadas"
            : "Sin sesiones"
    }
}

private enum SessionRenameRules {
    static let maxLength = 64

    static func retryMessage(serverMessage: String?) -> String {
        let trimmedMessage = serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedMessage.isEmpty else {
            return "El nombre sigue en el editor, listo para reintentar."
        }
        let separator = trimmedMessage.hasSuffix(".") ? " " : ". "
        return "\(trimmedMessage)\(separator)El nombre sigue en el editor, listo para reintentar."
    }
}

enum KycodeConnectionFormPolicy {
    static let manualBaseURLGuidance =
        "Ingresá una URL completa que empiece con http:// o https://."

    static func canSubmitRemoteHub(token: String, isConnecting: Bool) -> Bool {
        !isConnecting && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func manualBaseURLValidationMessage(_ baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return manualBaseURLGuidance
        }
        return nil
    }

    static func canSubmitManual(baseURL: String, token: String, isConnecting: Bool) -> Bool {
        !isConnecting
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && manualBaseURLValidationMessage(baseURL) == nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum KycodeComposerSubmissionPolicy {
    static func canBegin(
        isSending: Bool,
        isCreatingSubagent: Bool,
        isPreparingAttachments: Bool,
        hasPayload: Bool
    ) -> Bool {
        hasPayload && !isSending && !isCreatingSubagent && !isPreparingAttachments
    }
}

enum KycodeDetailNavigationPolicy {
    static func shouldDismissPresentedDetail(
        previousProfileId: String,
        currentProfileId: String,
        hasPresentedDetail: Bool
    ) -> Bool {
        hasPresentedDetail && previousProfileId != currentProfileId
    }
}

private enum ConnectionInputField: Hashable {
    case baseURL
    case token
}

struct KycodeRootView: View {
    @StateObject private var store = KycodeConnectionStore()
    @EnvironmentObject private var backgroundRecording: BackgroundRecordingState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigationPath: [String] = []
    @State private var showConnectionSheet = false
    @State private var showForgetRemoteTokenConfirmation = false
    @State private var isConnectionTokenVisible = false
    @State private var showAdvancedRuntimeControls = false
    @State private var showCreateSessionSheet = false
    @State private var showCreateSessionTargetChooser = false
    @State private var isPreparingCreateSessionTarget = false
    @State private var showSessionHistory = false
    @State private var renameTarget: SessionRenameTarget?
    @State private var renameErrorMessage: String?
    @State private var deleteTarget: SessionDeleteTarget?
    @State private var deleteErrorMessage: String?
    @State private var projectSelectionTarget: SessionProjectSelectionTarget?
    @State private var dashboardNoticeText: String?
    @State private var showsDashboardSearch = false
    @State private var debouncedDashboardSearchText = ""
    @State private var dashboardSearchDocuments: [String: DashboardSearchDocument] = [:]
    @State private var dashboardSearchTask: Task<Void, Never>?
    @State private var dashboardSearchFocusTask: Task<Void, Never>?
    @State private var dashboardIndexTask: Task<Void, Never>?
    @State private var dashboardProfileSwitchTargetId: String?
    @State private var isUnpinnedSessionsExpanded = false
    @State private var isReorderingSessions = false
    @State private var draggedSessionWindowId: String?
    @State private var isHandlingRecoveredRecording = false
    @State private var dismissedVoiceDraftRecoveryId: String?
    @FocusState private var focusedConnectionInput: ConnectionInputField?
    @State private var isHandlingRecoveredVoiceDraft = false
    @State private var recoveredVoiceDraftPlayer: AVAudioPlayer?
    @State private var dashboardSearchText = ""
    @AppStorage("kycode.mobile.dashboardFilter") private var dashboardFilterRaw = DashboardSessionFilter.all.rawValue
    @AppStorage("kycode.mobile.lastOpenedWindowId") private var lastOpenedWindowId = ""
    @FocusState private var isDashboardSearchFocused: Bool
    @AppStorage("kycode.mobile.showMinimizedSessions") private var showMinimizedSessions = false
    @AppStorage("kycode.mobile.unpinnedWindowIds.v1") private var unpinnedWindowIdsStorage = ""
    @AppStorage(AppHaptics.enabledDefaultsKey) private var hapticsEnabled = true

    private var visibleSessions: [KycodeSessionSummary] {
        let query = kycodeSearchNormalize(debouncedDashboardSearchText)
        return store.sessions
            .filter { session in
                switch dashboardFilter {
                case .all:
                    return true
                case .attention:
                    return sessionNeedsAttention(session)
                }
            }
            .filter { session in
                guard !query.isEmpty else { return true }
                return dashboardSearchDocuments[session.windowId]?.contains(query) ?? false
            }
    }

    private var dashboardFilter: DashboardSessionFilter {
        DashboardSessionFilter(rawValue: dashboardFilterRaw) ?? .all
    }

    private var dashboardSessions: [KycodeSessionSummary] {
        store.sessions
    }

    private var attentionSessionCount: Int {
        dashboardSessions.filter(sessionNeedsAttention).count + visibleRecentCreatedSessions.count
    }

    private func sessionNeedsAttention(_ session: KycodeSessionSummary) -> Bool {
        switch session.visualActivityStatus {
        case "approval", "error":
            return true
        default:
            return false
        }
    }

    private var lastOpenedSession: KycodeSessionSummary? {
        guard !lastOpenedWindowId.isEmpty else { return nil }
        return dashboardSessions.first { $0.windowId == lastOpenedWindowId }
    }

    private var minimizedSessions: [KycodeSessionSummary] {
        store.sessions.filter(\.minimized)
    }

    private var unpinnedWindowIds: Set<String> {
        KycodeSessionPinningPolicy.identifiers(from: unpinnedWindowIdsStorage)
    }

    private var pinnedSessions: [KycodeSessionSummary] {
        KycodeSessionPinningPolicy.pinnedSessions(
            in: visibleSessions,
            unpinnedWindowIds: unpinnedWindowIds
        )
    }

    private var unpinnedSessions: [KycodeSessionSummary] {
        KycodeSessionPinningPolicy.unpinnedSessions(
            in: visibleSessions,
            unpinnedWindowIds: unpinnedWindowIds
        )
    }

    private var showsUnpinnedSessions: Bool {
        isUnpinnedSessionsExpanded || !kycodeSearchNormalize(debouncedDashboardSearchText).isEmpty
    }

    private func isSessionPinned(_ windowId: String) -> Bool {
        KycodeSessionPinningPolicy.isPinned(
            windowId: windowId,
            unpinnedWindowIds: unpinnedWindowIds
        )
    }

    private var dashboardSearchRevision: [DashboardSearchIndexRevision] {
        DashboardSearchIndexRevision.snapshot(for: store.sessions)
    }

    private var profileSelectionBinding: Binding<String> {
        Binding(
            get: { store.selectedProfileId },
            set: { newValue in
                selectConnectionProfile(newValue)
            }
        )
    }

    private func selectConnectionProfile(_ profileId: String, announcesResult: Bool = false) {
        guard profileId != store.selectedProfileId else { return }
        guard dashboardProfileSwitchTargetId == nil else { return }

        backgroundRecording.ensureCaptureContinuity()
        AppHaptics.shared.play(.profileSelection)
        store.prepareForManualConnectionInteraction()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
            dashboardProfileSwitchTargetId = profileId
        }

        Task { @MainActor in
            await store.selectProfile(id: profileId)
            backgroundRecording.ensureCaptureContinuity()
            guard dashboardProfileSwitchTargetId == profileId else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                dashboardProfileSwitchTargetId = nil
            }
            guard announcesResult else { return }
            if store.isConnected {
                showDashboardNotice("Conectado a \(store.selectedProfileName)")
            } else if store.isReconnecting || store.isBootstrapping {
                showDashboardNotice("Reconectando con \(store.selectedProfileName)…")
            } else {
                showDashboardNotice("\(store.selectedProfileName) seleccionado")
            }
        }
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { store.baseURLInput },
            set: { newValue in
                store.prepareForManualConnectionInteraction()
                store.baseURLInput = newValue
            }
        )
    }

    private var authTokenBinding: Binding<String> {
        Binding(
            get: { store.authTokenInput },
            set: { newValue in
                store.prepareForManualConnectionInteraction()
                store.authTokenInput = newValue
            }
        )
    }

    private var canSubmitRemoteHubConnection: Bool {
        KycodeConnectionFormPolicy.canSubmitRemoteHub(
            token: store.authTokenInput,
            isConnecting: store.isConnecting
        )
    }

    private var canSubmitManualConnection: Bool {
        KycodeConnectionFormPolicy.canSubmitManual(
            baseURL: store.baseURLInput,
            token: store.authTokenInput,
            isConnecting: store.isConnecting
        )
    }

    private var manualBaseURLValidationMessage: String? {
        KycodeConnectionFormPolicy.manualBaseURLValidationMessage(store.baseURLInput)
    }

    private func submitRemoteHubConnection() {
        guard canSubmitRemoteHubConnection else { return }
        isConnectionTokenVisible = false
        focusedConnectionInput = nil
        store.prepareForManualConnectionInteraction()
        Task {
            await store.selectRemoteHubProfile(token: store.authTokenInput)
        }
    }

    private func submitManualConnection() {
        guard canSubmitManualConnection else { return }
        isConnectionTokenVisible = false
        focusedConnectionInput = nil
        store.prepareForManualConnectionInteraction()
        Task {
            await store.connect()
        }
    }

    private func connectionTokenField(
        placeholder: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        identifier: String,
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Group {
                if isConnectionTokenVisible {
                    TextField(placeholder, text: authTokenBinding)
                } else {
                    SecureField(placeholder, text: authTokenBinding)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($focusedConnectionInput, equals: .token)
            .onSubmit(onSubmit)
            .privacySensitive()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier(identifier)

            Button {
                isConnectionTokenVisible.toggle()
                focusedConnectionInput = .token
            } label: {
                Image(systemName: isConnectionTokenVisible ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.inkMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isConnectionTokenVisible ? "Ocultar token" : "Mostrar token")
            .accessibilityHint("Cambia sólo la visibilidad; no modifica el token")
            .accessibilityIdentifier("\(identifier)-visibility")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 48)
        .background(
            AppTheme.cardSurfaceRaised,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
        )
    }

    private var connectionNoticeText: String? {
        if let notice = store.reconnectStatusText, !notice.isEmpty {
            return notice
        }
        if store.isBootstrapping {
            return store.bootstrapStatusText
        }
        return nil
    }

    private var connectionNoticeActionTitle: String? {
        if store.isBootstrapping || store.isReconnecting {
            return "Cancelar"
        }
        if store.canRetryReconnectManually {
            return "Reconectar"
        }
        return nil
    }

    private func handleConnectionNoticeAction() {
        if store.isBootstrapping || store.isReconnecting {
            store.cancelReconnect()
            return
        }
        if store.canRetryReconnectManually {
            AppHaptics.shared.play(.reconnectRequest)
            Task {
                await store.retryAutoConnect()
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            dashboardView
                .toolbar(.hidden, for: .navigationBar)
            .background(BreathingBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { windowId in
                KycodeSessionDetailView(
                    windowId: windowId,
                    composerDraftStorageKey: store.composerDraftStorageKey(for: windowId),
                    onNavigateToWindow: { nextWindowId in
                        navigationPath = [nextWindowId]
                    },
                    onCreateSession: {
                        presentCreateSession()
                    }
                )
                .environmentObject(store)
            }
        }
        // Compact NavigationStack can briefly reuse the detail toolbar while
        // an interactive back gesture settles. Keep the phone dashboard
        // explicitly chrome-free, matching the iPad dashboard, without
        // changing the detail toolbar or the iPad navigation policy.
        .toolbar(
            UIDevice.current.userInterfaceIdiom == .phone && navigationPath.isEmpty
                ? .hidden
                : .automatic,
            for: .navigationBar
        )
        .onChange(of: store.selectedProfileId) { previousProfileId, currentProfileId in
            guard KycodeDetailNavigationPolicy.shouldDismissPresentedDetail(
                previousProfileId: previousProfileId,
                currentProfileId: currentProfileId,
                hasPresentedDetail: !navigationPath.isEmpty
            ) else { return }
            // Drafts, feature queues and inline errors belong to one Mac route.
            // Recreate the detail after a handoff instead of reusing local
            // state for a same-named window from the other Mac.
            navigationPath.removeAll()
        }
        .sheet(isPresented: $showConnectionSheet, onDismiss: {
            AppHaptics.shared.play(.connectionPanelClose)
            showAdvancedRuntimeControls = false
            isConnectionTokenVisible = false
        }) {
            NavigationStack {
                connectionSheet
                    .navigationTitle("Preferencias")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Listo") {
                                showConnectionSheet = false
                            }
                            .accessibilityIdentifier("connection-sheet-done")
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCreateSessionSheet) {
            KycodeCreateSessionSheet()
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "¿Dónde querés crearla?",
            isPresented: $showCreateSessionTargetChooser,
            titleVisibility: .visible
        ) {
            Button("Mac personal") {
                prepareCreateSessionTarget("personal")
            }
            .accessibilityIdentifier("create-session-target-personal")

            Button("Puky") {
                prepareCreateSessionTarget("puky")
            }
            .accessibilityIdentifier("create-session-target-puky")

            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todo reúne las dos Macs. Elegí el origen de esta nueva sesión.")
        }
        .sheet(isPresented: $showSessionHistory) {
            KycodeSessionHistoryView { windowId in
                recordSessionOpened(windowId)
                navigationPath = [windowId]
            }
            .environmentObject(store)
        }
        .sheet(item: $projectSelectionTarget) { target in
            CollaborationProjectSelectionSheet(
                store: store,
                session: target.session,
                onAssigned: { project in
                    showDashboardNotice("Proyecto cambiado a \(project.name)")
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: recoverableRecordingBinding) { recording in
            VoiceRecordingRecoverySheet(
                recording: recording,
                sessionName: store.sessions.first(where: { $0.windowId == recording.windowId })?.displayName,
                isPlaying: backgroundRecording.isPlayingRecovery,
                isWorking: isHandlingRecoveredRecording,
                canUseRecording: !(store.currentVoiceDraft?.isRecoverable ?? false),
                errorMessage: backgroundRecording.errorMessage,
                onListen: {
                    Task { await backgroundRecording.toggleRecoveryPlayback() }
                },
                onContinue: {
                    continueRecoveredVoiceRecording(recording)
                },
                onUse: {
                    useRecoveredVoiceRecording(recording)
                },
                onDiscard: {
                    backgroundRecording.cancelRecording()
                }
            )
            .interactiveDismissDisabled()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: recoverableVoiceDraftBinding) { draft in
            VoiceDraftRecoverySheet(
                draft: draft,
                sessionName: store.sessions.first(where: { $0.windowId == draft.windowId })?.displayName,
                isPlaying: recoveredVoiceDraftPlayer?.isPlaying == true,
                isWorking: isHandlingRecoveredVoiceDraft,
                onListen: {
                    toggleRecoveredVoiceDraftPlayback(draft)
                },
                onOpen: {
                    openRecoveredVoiceDraft(draft)
                },
                onRetry: {
                    retryRecoveredVoiceDraft(draft)
                },
                onDiscard: {
                    stopRecoveredVoiceDraftPlayback()
                    store.deleteVoiceDraft(draft)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .task {
            debouncedDashboardSearchText = dashboardSearchText
            rebuildDashboardSearchDocuments()
            store.bootstrapIfNeeded()
        }
        .onChange(of: dashboardSearchText) { _, value in
            scheduleDashboardSearch(value)
        }
        .onChange(of: dashboardSearchRevision) { _, _ in
            rebuildDashboardSearchDocuments()
        }
        .onDisappear {
            dashboardSearchTask?.cancel()
            dashboardSearchFocusTask?.cancel()
            dashboardSearchFocusTask = nil
            dashboardIndexTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            backgroundRecording.handleScenePhase(isBackground: phase == .background)
            guard phase == .active else { return }
            Task {
                if store.isConnected, !store.isReconnecting {
                    await store.recoverForegroundState()
                } else if !store.isBootstrapping, !store.isReconnecting {
                    await store.retryAutoConnect()
                }
            }
        }
        .overlay(alignment: .bottom) {
            rootRenameEditorOverlay
        }
        .alert("No se pudo renombrar", isPresented: renameErrorBinding) {
            Button(KycodeInterfaceCopyPolicy.dismissErrorAction, role: .cancel) {
                renameErrorMessage = nil
            }
        } message: {
            Text(renameErrorMessage ?? "Intentá de nuevo.")
        }
        .alert(
            "¿Borrar sesión?",
            isPresented: deleteConfirmationBinding,
            presenting: deleteTarget
        ) { target in
            Button("Borrar", role: .destructive) {
                commitDelete(target)
            }
            .accessibilityIdentifier("delete-session-confirm")
            Button("Cancelar", role: .cancel) {}
        } message: { target in
            Text("“\(target.displayName)” y su historial local se eliminarán. Esta acción no se puede deshacer.")
        }
        .alert("No se pudo borrar", isPresented: deleteErrorBinding) {
            Button(KycodeInterfaceCopyPolicy.dismissErrorAction, role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "La sesión volvió a aparecer. Intentá de nuevo.")
        }
        .environmentObject(store)
    }

    private var recoverableRecordingBinding: Binding<RecoverableVoiceRecording?> {
        Binding(
            get: { backgroundRecording.recoverableRecording },
            set: { _ in }
        )
    }

    private var recoverableVoiceDraftBinding: Binding<VoiceDraft?> {
        Binding(
            get: {
                guard backgroundRecording.isRecoveryScanComplete,
                      backgroundRecording.recoverableRecording == nil,
                      let draft = store.currentVoiceDraft,
                      draft.isRecoverable,
                      store.recoveredVoiceDraftIdAtLaunch == draft.id,
                      dismissedVoiceDraftRecoveryId != draft.id else { return nil }
                return draft
            },
            set: { _ in }
        )
    }

    private func toggleRecoveredVoiceDraftPlayback(_ draft: VoiceDraft) {
        if recoveredVoiceDraftPlayer?.isPlaying == true {
            stopRecoveredVoiceDraftPlayback()
            return
        }
        guard draft.hasAudioFile else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: draft.fileURL)
            player.prepareToPlay()
            recoveredVoiceDraftPlayer = player
            _ = player.play()
        } catch {
            recoveredVoiceDraftPlayer = nil
        }
    }

    private func stopRecoveredVoiceDraftPlayback() {
        recoveredVoiceDraftPlayer?.stop()
        recoveredVoiceDraftPlayer = nil
    }

    private func openRecoveredVoiceDraft(_ draft: VoiceDraft) {
        stopRecoveredVoiceDraftPlayback()
        dismissedVoiceDraftRecoveryId = draft.id
        recordSessionOpened(draft.windowId)
        navigationPath = [draft.windowId]
    }

    private func retryRecoveredVoiceDraft(_ draft: VoiceDraft) {
        guard !isHandlingRecoveredVoiceDraft, draft.hasAudioFile else { return }
        isHandlingRecoveredVoiceDraft = true
        stopRecoveredVoiceDraftPlayback()
        Task { @MainActor in
            let transcript = await store.transcribeAudioFile(filePath: draft.filePath)
            isHandlingRecoveredVoiceDraft = false
            if transcript != nil {
                dismissedVoiceDraftRecoveryId = draft.id
                recordSessionOpened(draft.windowId)
                navigationPath = [draft.windowId]
                AppHaptics.shared.play(.voiceStateTransition)
            } else {
                AppHaptics.shared.play(.messageSendError)
            }
        }
    }

    private func continueRecoveredVoiceRecording(_ recording: RecoverableVoiceRecording) {
        guard !isHandlingRecoveredRecording else { return }
        isHandlingRecoveredRecording = true
        backgroundRecording.stopRecoveryPlayback()
        Task { @MainActor in
            let resumed = await backgroundRecording.continueRecoveredRecording()
            isHandlingRecoveredRecording = false
            if resumed {
                // Mutating the navigation path while the recovery sheet is
                // still presented can leave SwiftUI displaying the previous
                // conversation even though the app-global recorder resumed
                // in the recovered one. Start capture first, then route once
                // the sheet is dismissed by the published recovery state.
                navigationPath = [recording.windowId]
            } else {
                AppHaptics.shared.play(.messageSendError)
            }
        }
    }

    private func useRecoveredVoiceRecording(_ recording: RecoverableVoiceRecording) {
        guard !isHandlingRecoveredRecording,
              !(store.currentVoiceDraft?.isRecoverable ?? false) else { return }
        isHandlingRecoveredRecording = true
        backgroundRecording.stopRecoveryPlayback()
        Task { @MainActor in
            guard let result = await backgroundRecording.finalizeRecoveredRecording() else {
                isHandlingRecoveredRecording = false
                AppHaptics.shared.play(.messageSendError)
                return
            }
            let job = store.beginVoiceTranscription(
                windowId: result.windowId,
                duration: result.duration
            )
            store.attachRecordingAndStartVoiceTranscription(
                jobId: job.id,
                fileURL: result.fileURL,
                duration: result.duration
            )
            navigationPath = [result.windowId]
            isHandlingRecoveredRecording = false
            AppHaptics.shared.play(.voiceStateTransition)
        }
    }

    private var renameErrorBinding: Binding<Bool> {
        Binding(
            get: { renameErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    renameErrorMessage = nil
                }
            }
        )
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTarget = nil
                }
            }
        )
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deleteErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var rootRenameEditorOverlay: some View {
        if let renameTarget {
            SessionNameEditorOverlay(
                target: renameTarget,
                onCancel: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.renameTarget = nil
                    }
                },
                onCommit: { name in
                    commitRename(renameTarget, name: name)
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(10)
        }
    }

    private var bootstrapView: some View {
        GeometryReader { geometry in
            let layout = DashboardMetrics.resolve(for: geometry.size)
            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: layout.gridSpacing) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonDashboardCard(layout: layout)
                    }
                }
                .padding(.horizontal, layout.outerPadding)
                .padding(.vertical, layout.verticalPadding)
            }
        }
    }

    private var connectionSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionProfileCard(showConnectedVia: true)

                connectionForm

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Sensación")
                    Toggle(isOn: $hapticsEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hápticos")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                                .foregroundStyle(AppTheme.ink)
                            Text("Respuesta táctil.")
                                .font(.system(size: 13, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(AppTheme.accent)
                    .accessibilityHint("Podés usar toda la app aunque esté desactivado")
                }
                .premiumCard(padding: 16)

                NavigationLink {
                    VoiceProfileSettingsView()
                        .environmentObject(store)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: store.hasEnrolledVoiceProfile ? "waveform.badge.checkmark" : "waveform.and.person.filled")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mi voz")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                                .foregroundStyle(AppTheme.ink)
                            Text(store.hasEnrolledVoiceProfile ? "Perfil local listo · \(store.voiceIsolationMode.title)" : "Aislamiento, perfil y confianza")
                                .font(.system(size: 13, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.inkMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .premiumCard(padding: 16)
                .accessibilityHint("Configura qué voces se conservan al transcribir")

                if showAdvancedRuntimeControls {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Runtime avanzado")
                        Toggle(
                            isOn: Binding(
                                get: { store.fastModeEnabled },
                                set: { store.setFastModeEnabled($0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Fast mode de Codex")
                                    .font(.system(size: 15, weight: .semibold, design: .default))
                                    .foregroundStyle(AppTheme.ink)
                                Text("Solicita el service tier Fast para cada turno compatible. Puede usar más créditos.")
                                    .font(.system(size: 13, weight: .medium, design: .default))
                                    .foregroundStyle(AppTheme.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(AppTheme.accent)
                        .accessibilityHint("Se aplica al próximo mensaje sin reiniciar la app")

                        Label(
                            store.fastModeEnabled ? "FAST activo" : "Velocidad estándar",
                            systemImage: store.fastModeEnabled ? "bolt.fill" : "bolt.slash"
                        )
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(store.fastModeEnabled ? AppTheme.accent : AppTheme.inkSoft)

                        Divider()
                            .overlay(AppTheme.ink.opacity(0.1))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mejorador de prompt")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                                .foregroundStyle(AppTheme.ink)

                            Picker(
                                "Tipo de mejorador de prompt",
                                selection: Binding<KycodePromptImproverVariant?>(
                                    get: { store.promptImproverVariantSelection },
                                    set: { variant in
                                        guard let variant else { return }
                                        Task { await store.setPromptImproverVariant(variant) }
                                    }
                                )
                            ) {
                                ForEach(KycodePromptImproverVariant.allCases, id: \.self) { variant in
                                    Text(variant.title).tag(Optional(variant))
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("prompt-improver-variant-picker")
                            .accessibilityHint("Se aplica a todos los chats del runtime seleccionado")
                            .accessibilityValue(store.promptImproverVariantAccessibilityValue)

                            Text(store.promptImproverVariantSummary)
                                .font(.system(size: 13, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 7) {
                                if store.isPromptImproverVariantSynchronizing {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(AppTheme.accent)
                                }
                                Text(store.promptImproverVariantStatusText)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.inkMuted)
                                Spacer(minLength: 4)
                                if store.promptImproverVariantSyncState == .unavailable
                                    || store.promptImproverVariantSyncState == .partial,
                                   !store.isPromptImproverVariantSynchronizing {
                                    Button("Reintentar") {
                                        Task { await store.refreshPromptImproverVariant() }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.accent)
                                    .accessibilityHint("Vuelve a consultar el runtime seleccionado")
                                }
                            }
                            .accessibilityIdentifier("prompt-improver-variant-status")
                        }
                    }
                    .premiumCard(padding: 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if store.isConnected {
                    Button {
                        store.disconnect()
                        showConnectionSheet = false
                    } label: {
                        Text("Desconectar")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .foregroundStyle(AppTheme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                AppTheme.ink.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(16)
        }
        .confirmationDialog(
            "¿Olvidar el token de \(store.selectedProfileName)?",
            isPresented: $showForgetRemoteTokenConfirmation,
            titleVisibility: .visible
        ) {
            Button("Olvidar y desconectar", role: .destructive) {
                focusedConnectionInput = nil
                store.clearRemoteHubToken()
                store.disconnect()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(
                "Se elimina de este iPhone y se cierra la conexión actual. " +
                "Necesitarás pegarlo otra vez para volver a conectar."
            )
        }
        .onChange(of: store.selectedProfileId) { _, _ in
            isConnectionTokenVisible = false
        }
    }

    private func connectionProfileCard(showConnectedVia: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Mac activa")
            Picker("Mac activa", selection: profileSelectionBinding) {
                ForEach(store.userSelectableProfiles) { profile in
                    Text(kycodeCompactProfileLabel(for: profile)).tag(profile.id)
                }
            }
            .pickerStyle(.segmented)

            Text(store.selectedProfileSummary)
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.inkSoft)

            if showConnectedVia, let source = store.lastConnectionSource, !source.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Conectado mediante")
                    Text(source)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                }
                .padding(.top, 4)
            }
        }
        .premiumCard(padding: 16)
        .onLongPressGesture(minimumDuration: 1.2) {
            AppHaptics.shared.play(.connectionPanelOpen)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                showAdvancedRuntimeControls = true
            }
            Task { await store.refreshPromptImproverVariant() }
        }
        .accessibilityAction(named: "Mostrar runtime avanzado") {
            showAdvancedRuntimeControls = true
            Task { await store.refreshPromptImproverVariant() }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: connectionFormSectionTitle)

            if store.selectedProfileUsesAll {
                Text("Puky y tu Mac personal se conectan de forma independiente. Si una falla, la otra sigue disponible.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.prepareForManualConnectionInteraction()
                    Task { await store.retryAutoConnect() }
                } label: {
                    HStack(spacing: 10) {
                        if store.isConnecting || store.isBootstrapping {
                            ProgressView().tint(.white)
                        }
                        Text("Reconectar ambas")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            } else if store.selectedProfileUsesRemoteHub {
                Text("La app se conecta a Fermín Code por internet para controlar \(store.selectedProfileName).")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fermín Code por internet")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)

                    Text(store.baseURLInput.isEmpty ? KycodeRelayConfiguration.primaryBaseURL : store.baseURLInput)
                        .font(.system(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(AppTheme.inkSoft)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            AppTheme.cardSurfaceRaised,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Token de Fermín Code")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)

                    connectionTokenField(
                        placeholder: "Pegá el token de Fermín Code",
                        accessibilityLabel: "Token de Fermín Code",
                        accessibilityHint: "Pegá el token y usá Conectar en el teclado o el botón",
                        identifier: "remote-hub-token-field",
                        onSubmit: submitRemoteHubConnection
                    )
                }

                HStack(spacing: 10) {
                    Button(action: submitRemoteHubConnection) {
                        HStack(spacing: 10) {
                            if store.isConnecting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                            Text(store.isConnected ? "Guardar y reconectar" : "Guardar y conectar")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            canSubmitRemoteHubConnection
                                ? AppTheme.accent
                                : AppTheme.cardSurfaceRaised,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canSubmitRemoteHubConnection)
                    .accessibilityIdentifier("remote-hub-connect")

                    if store.getRemoteHubToken() != nil {
                        Button {
                            focusedConnectionInput = nil
                            showForgetRemoteTokenConfirmation = true
                        } label: {
                            Text("Olvidar token")
                                .font(.system(size: 14, weight: .semibold, design: .default))
                                .foregroundStyle(Color.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .background(
                                    AppTheme.ink.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                                )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityHint("Pide confirmación antes de eliminarlo y desconectar")
                        .accessibilityIdentifier("forget-remote-token")
                    }
                }
            } else if store.selectedProfileSupportsManualFields {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base URL")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                    TextField("https://desktop.example.com", text: baseURLBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.next)
                        .focused($focusedConnectionInput, equals: .baseURL)
                        .onSubmit {
                            focusedConnectionInput = .token
                        }
                        .padding(14)
                        .frame(minHeight: 48)
                        .background(
                            AppTheme.cardSurfaceRaised,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                        )
                        .accessibilityLabel("URL base")
                        .accessibilityHint(
                            manualBaseURLValidationMessage
                                ?? "Usá Siguiente para pasar al token"
                        )
                        .accessibilityIdentifier("manual-base-url-field")

                    if let manualBaseURLValidationMessage {
                        Label(
                            manualBaseURLValidationMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("manual-base-url-error")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bearer token")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                    connectionTokenField(
                        placeholder: "Sidecar token",
                        accessibilityLabel: "Bearer token",
                        accessibilityHint: "Usá Conectar en el teclado o el botón",
                        identifier: "manual-bearer-token-field",
                        onSubmit: submitManualConnection
                    )
                }

                Button(action: submitManualConnection) {
                    HStack(spacing: 10) {
                        if store.isConnecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                        Text(store.isConnected ? "Reconectar" : "Conectar")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        canSubmitManualConnection
                            ? AppTheme.accent
                            : AppTheme.cardSurfaceRaised,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canSubmitManualConnection)
                .accessibilityIdentifier("manual-connect")
            } else {
                Text("Detección LAN automática.")
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.inkSoft)

                Button {
                    store.prepareForManualConnectionInteraction()
                    Task {
                        await store.retryAutoConnect()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if store.isConnecting || store.isBootstrapping {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                        Text("Buscar en LAN")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        AppTheme.accent,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .premiumCard(padding: 18)
    }

    private var connectionFormSectionTitle: String {
        if store.selectedProfileUsesAll {
            return "Puky + Mac personal"
        }
        if store.selectedProfileUsesRemoteHub {
            return "\(store.selectedProfileName) · automática"
        }
        return store.selectedProfileSupportsManualFields ? "Manual fallback" : "Auto-connect"
    }

    private var dashboardConnectivityTitle: String {
        if store.isReconnecting {
            return "Reconectando"
        }
        if !store.isConnected {
            return store.isShowingCachedSessions ? "Sin conexión · copia local" : "Sin conexión"
        }
        return store.isStreaming ? "En vivo" : "Sincronizando"
    }

    private var dashboardConnectivityTint: Color {
        if store.isReconnecting || store.isBootstrapping {
            return AppTheme.statusBusy
        }
        if !store.isConnected || store.isShowingCachedSessions {
            return AppTheme.cloudWarning
        }
        return store.isStreaming ? AppTheme.statusReady : AppTheme.statusBusy
    }

    private var dashboardConnectivitySymbol: String {
        if store.isReconnecting || store.isBootstrapping {
            return "arrow.triangle.2.circlepath"
        }
        if !store.isConnected || store.isShowingCachedSessions {
            return "wifi.slash"
        }
        return store.isStreaming ? "bolt.horizontal.circle.fill" : "arrow.clockwise.circle"
    }

    private func handleDashboardConnectivityAction() {
        if store.isReconnecting || store.isBootstrapping {
            store.cancelReconnect()
            showDashboardNotice("Reconexión pausada")
            return
        }

        Task {
            if store.isConnected {
                await store.refreshSessionsNow()
                showDashboardNotice("Sesiones actualizadas")
            } else {
                AppHaptics.shared.play(.reconnectRequest)
                await store.retryAutoConnect()
            }
        }
    }

    private func shortRelativeAge(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "ahora" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    private func spokenRelativeAge(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "unos segundos" }
        if seconds < 60 { return "\(seconds) segundos" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            return "\(minutes) \(minutes == 1 ? "minuto" : "minutos")"
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return "\(hours) \(hours == 1 ? "hora" : "horas")"
        }
        let days = seconds / 86_400
        return "\(days) \(days == 1 ? "día" : "días")"
    }

    private func copyConnectionDiagnostics() {
        let refreshedAt = store.lastSessionsRefreshAt.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "never"
        UIPasteboard.general.string = [
            "KyCode Mobile diagnostics",
            "profile=\(store.selectedProfileName)",
            "connected=\(store.isConnected)",
            "streaming=\(store.isStreaming)",
            "reconnecting=\(store.isReconnecting)",
            "cached=\(store.isShowingCachedSessions)",
            "sessions=\(store.sessions.count)",
            "lastRefresh=\(refreshedAt)",
            "error=\(store.errorMessage ?? "none")",
            "backgroundSyncError=\(store.lastBackgroundSyncErrorMessage ?? "none")",
        ].joined(separator: "\n")
        showDashboardNotice("Diagnóstico copiado")
    }

    private var dashboardCanShowFilteredEmpty: Bool {
        switch store.dashboardSnapshotState {
        case .loading, .failedNoData:
            return false
        case .showingCache, .content, .partialSourceFailure, .authoritativeEmpty:
            return true
        }
    }

    private var dashboardFailedSourcesLabel: String {
        let names = store.dashboardFailedSourceNames
        if names.count == 1 {
            return names[0]
        }
        if names.count > 1 {
            return names.joined(separator: " y ")
        }
        return store.selectedProfileName
    }

    @ViewBuilder
    private var dashboardSnapshotNotice: some View {
        switch store.dashboardSnapshotState {
        case .showingCache:
            if store.sessions.isEmpty {
                DashboardSnapshotNotice(
                    symbol: "internaldrive",
                    title: "Copia local",
                    message: store.lastSessionsRefreshAt.map {
                        "Actualizada hace \(shortRelativeAge(since: $0, now: Date())). Podés seguir leyendo mientras recuperamos la conexión."
                    } ?? "Podés seguir leyendo mientras recuperamos la conexión.",
                    identifier: "dashboard-cache-notice",
                    onRetry: retryDashboardConnection
                )
            }
        case .partialSourceFailure:
            if store.sessions.isEmpty {
                DashboardSnapshotNotice(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    title: "Falta \(dashboardFailedSourcesLabel)",
                    message: "Conservamos la última lista completa para no ocultarte sesiones.",
                    identifier: "dashboard-partial-notice",
                    onRetry: retryDashboardConnection
                )
            }
        case .loading, .content, .failedNoData, .authoritativeEmpty:
            EmptyView()
        }
    }

    private func retryDashboardConnection() {
        AppHaptics.shared.play(.reconnectRequest)
        Task {
            await store.retryAutoConnect()
        }
    }

    private var dashboardView: some View {
        GeometryReader { geometry in
            let layout = DashboardMetrics.resolve(for: geometry.size)
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                        // Background and cross-screen failures remain available
                        // through the overflow menu's connection diagnostics,
                        // never as a prominent red card at the dashboard top.

                        if showsDashboardSearch || !dashboardSearchText.isEmpty {
                            dashboardSearchPanel(layout: layout)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        dashboardSnapshotNotice

                        if !visibleRecentCreatedSessions.isEmpty {
                            PendingCreatedSessionsView(entries: visibleRecentCreatedSessions, layout: layout)
                        }

                        if visibleSessions.isEmpty && visibleRecentCreatedSessions.isEmpty {
                            if dashboardCanShowFilteredEmpty && (
                                !dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    dashboardFilter != .all
                            ) {
                                dashboardNoResultsState
                            } else {
                                switch store.dashboardSnapshotState {
                                case .loading:
                                    DashboardLoadingState(layout: layout)
                                case .failedNoData:
                                    DashboardUnavailableState(
                                        sourceName: dashboardFailedSourcesLabel,
                                        onRetry: retryDashboardConnection
                                    )
                                case .showingCache, .content, .partialSourceFailure, .authoritativeEmpty:
                                    EmptyDashboardState(
                                        minimizedCount: minimizedSessions.count,
                                        showMinimizedSessions: showMinimizedSessions,
                                        selectedProfileName: store.selectedProfileName,
                                        accessibilityIdentifier: store.dashboardSnapshotState == .authoritativeEmpty
                                            ? "dashboard-empty-authoritative"
                                            : "dashboard-empty",
                                        onCreateSession: presentCreateSession,
                                        onShowMinimized: {
                                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                                showMinimizedSessions = true
                                            }
                                        }
                                    )
                                }
                            }
                        } else {
                            LazyVGrid(columns: layout.columns, spacing: layout.gridSpacing) {
                                ForEach(Array(pinnedSessions.enumerated()), id: \.element.windowId) { index, session in
                                    let presentationSession = store.detail(for: session.windowId) ?? session
                                    let cardActionSize: CGFloat = layout.isTablet ? 52 : 44
                                    let cardActionIconSize: CGFloat = layout.isTablet ? 15 : 11
                                    ZStack(alignment: .bottomTrailing) {
                                        NavigationLink(value: session.windowId) {
                                            SessionConsoleCard(
                                                session: presentationSession,
                                                presentation: session.minimized ? .minimized : .normal,
                                                layout: layout,
                                                displayIndex: index,
                                                totalCount: pinnedSessions.count,
                                                isPinned: true,
                                                hasDraft: hasComposerDraft(for: session.windowId),
                                                isLastOpened: session.windowId == lastOpenedWindowId,
                                                isReordering: isReorderingSessions,
                                                searchMatchHint: searchMatchHint(for: session),
                                                sourceLabel: store.sessionSourceLabel(for: session.windowId)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isReorderingSessions)
                                        .accessibilityIdentifier(
                                            session.supportsMobileBridgeMessaging
                                                ? "session-card-messaging-\(session.windowId)"
                                                : "session-card-\(session.windowId)"
                                        )
                                        .simultaneousGesture(
                                            TapGesture().onEnded {
                                                guard !isReorderingSessions else { return }
                                                AppHaptics.shared.play(.conversationSelection)
                                                recordSessionOpened(session.windowId)
                                            }
                                        )
                                        .accessibilityLabel(cardAccessibilityLabel(for: session))
                                        .accessibilityHint(
                                            isReorderingSessions
                                                ? "Arrastrá la sesión a la posición deseada."
                                                : "Abre la conversación. Mantené presionado para reordenar."
                                        )

                                        if isReorderingSessions {
                                            VStack {
                                                Spacer()
                                                HStack {
                                                    Spacer()
                                                    Image(systemName: "line.3.horizontal")
                                                        .font(.system(size: 18, weight: .semibold))
                                                        .foregroundStyle(AppTheme.accent)
                                                        .frame(width: 44, height: 44)
                                                        .accessibilityLabel("Arrastrar sesión")
                                                }
                                            }
                                            .padding(.trailing, 4)
                                        }

                                        if !isReorderingSessions {
                                            Menu {
                                                if store.supportsCollaborationProjects(
                                                    windowId: presentationSession.windowId
                                                ) {
                                                    Button {
                                                        beginProjectSelection(presentationSession)
                                                    } label: {
                                                        Label(
                                                            presentationSession.dashboardProjectActionLabel,
                                                            systemImage: "square.stack.3d.up.fill"
                                                        )
                                                    }
                                                    .accessibilityIdentifier(
                                                        "select-project-\(presentationSession.windowId)"
                                                    )
                                                }

                                                Button {
                                                    togglePinned(session.windowId)
                                                } label: {
                                                    Label(
                                                        isSessionPinned(session.windowId) ? "Desfijar" : "Fijar",
                                                        systemImage: isSessionPinned(session.windowId) ? "pin.slash" : "pin.fill"
                                                    )
                                                }
                                                .accessibilityIdentifier("pin-session-\(session.windowId)")

                                                Button {
                                                    beginRename(session)
                                                } label: {
                                                    Label("Renombrar", systemImage: "pencil")
                                                }
                                                .accessibilityIdentifier("rename-session-\(session.windowId)")

                                                Button(role: .destructive) {
                                                    beginDelete(session)
                                                } label: {
                                                    Label("Borrar", systemImage: "trash")
                                                }
                                                .accessibilityIdentifier("delete-session-\(session.windowId)")
                                            } label: {
                                                Image(systemName: "ellipsis")
                                                    .font(.system(size: cardActionIconSize + 2, weight: .bold))
                                                    .foregroundStyle(AppTheme.inkMuted.opacity(0.78))
                                                    .frame(width: cardActionSize, height: cardActionSize)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.76))
                                            .accessibilityLabel("Más acciones para \(session.displayName)")
                                            .accessibilityHint("Permite cambiar proyecto, fijar, renombrar o borrar")
                                            .accessibilityIdentifier("session-actions-\(session.windowId)")
                                            .padding(.trailing, 4)
                                            .padding(.bottom, 1)
                                        }
                                    }
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.38).onEnded { _ in
                                            guard !isReorderingSessions else { return }
                                            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                                                isReorderingSessions = true
                                            }
                                            AppHaptics.shared.play(.conversationSelection)
                                        }
                                    )
                                    .onDrag {
                                        if !isReorderingSessions {
                                            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                                                isReorderingSessions = true
                                            }
                                            AppHaptics.shared.play(.conversationSelection)
                                        }
                                        draggedSessionWindowId = session.windowId
                                        return NSItemProvider(object: session.windowId as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: SessionReorderDropDelegate(
                                            targetWindowId: session.windowId,
                                            draggedWindowId: $draggedSessionWindowId,
                                            onMove: { draggedWindowId, targetWindowId in
                                                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86)) {
                                                    store.moveSession(
                                                        windowId: draggedWindowId,
                                                        over: targetWindowId
                                                    )
                                                }
                                                AppHaptics.shared.play(.profileSelection)
                                            },
                                            onDrop: {
                                                AppHaptics.shared.play(.conversationSelection)
                                            }
                                        )
                                    )
                                }
                            }

                            if !unpinnedSessions.isEmpty {
                                unpinnedSessionsSection(
                                    layout: layout,
                                    scrollProxy: scrollProxy
                                )
                                    .padding(.top, layout.sectionSpacing)
                            }
                        }
                    }
                    .padding(.horizontal, layout.outerPadding)
                    .padding(.top, layout.verticalPadding)
                    .padding(.bottom, layout.isTablet ? 166 : 158)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await store.refreshSessionsNow()
                        showDashboardNotice("Sesiones actualizadas")
                    }
                }

                if layout.isTablet {
                    HStack(alignment: .bottom, spacing: 10) {
                        dashboardSearchButton(layout: layout)
                            .frame(maxWidth: 220)
                        dashboardFloatingMenu(layout: layout)
                        VStack(spacing: 10) {
                            if !showsInlineEmptyAction {
                                dashboardCreateSessionButton(layout: layout)
                            }
                            dashboardFilterMenu(layout: layout)
                        }
                    }
                        .padding(.trailing, 22)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .ignoresSafeArea(.container, edges: .bottom)

                    if let recordingWindowId = activeRecordingWindowId {
                        dashboardRecordingButton(windowId: recordingWindowId)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomLeading
                        )
                        .padding(.leading, 22)
                        .padding(.bottom, 18)
                        .ignoresSafeArea(.container, edges: .bottom)
                    }
                } else {
                    PhoneDashboardBottomDock {
                        if let recordingWindowId = activeRecordingWindowId {
                            dashboardRecordingButton(windowId: recordingWindowId)
                            .frame(
                                maxWidth: max(0, layout.width - 188),
                                alignment: .leading
                            )
                            .layoutPriority(1)
                        } else {
                            dashboardSearchButton(layout: layout)
                                .frame(maxWidth: max(0, layout.width - 188), alignment: .leading)
                                .layoutPriority(1)
                        }
                    } actions: {
                        HStack(spacing: 8) {
                            dashboardFloatingMenu(layout: layout)
                            dashboardFilterMenu(layout: layout)
                            if !showsInlineEmptyAction {
                                dashboardCreateSessionButton(layout: layout)
                            }
                        }
                    }
                }

                if let dashboardNoticeText {
                    DashboardActionNotice(text: dashboardNoticeText)
                        .padding(.horizontal, layout.outerPadding)
                        .padding(.bottom, layout.isTablet ? 164 : 142)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.isStaticText)
                }

                if isReorderingSessions {
                    SessionReorderModeBar {
                        draggedSessionWindowId = nil
                        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86)) {
                            isReorderingSessions = false
                        }
                        AppHaptics.shared.play(.conversationSelection)
                    }
                    .padding(.horizontal, layout.outerPadding)
                    .padding(.bottom, layout.isTablet ? 160 : 138)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func unpinnedSessionsSection(
        layout: DashboardMetrics,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(AppTheme.divider.opacity(0.72))
                .frame(height: 1)

            Button {
                let isExpanding = !isUnpinnedSessionsExpanded
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.17)) {
                    isUnpinnedSessionsExpanded.toggle()
                }
                if isExpanding {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                            scrollProxy.scrollTo("dashboard-unpinned-end", anchor: .bottom)
                        }
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(showsUnpinnedSessions ? 90 : 0))
                        .accessibilityHidden(true)

                    Text("Sin fijar")
                        .font(.system(size: layout.isTablet ? 14 : 13, weight: .semibold))

                    Spacer(minLength: 8)

                    Text("\(unpinnedSessions.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.inkMuted)
                }
                .foregroundStyle(AppTheme.inkSoft)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.99, opacity: 0.88))
            .accessibilityLabel("Sesiones sin fijar")
            .accessibilityValue(
                showsUnpinnedSessions
                    ? "Expandida, \(unpinnedSessions.count) sesiones"
                    : "Contraída, \(unpinnedSessions.count) sesiones"
            )
            .accessibilityHint(
                showsUnpinnedSessions
                    ? "Oculta las sesiones sin fijar"
                    : "Muestra las sesiones sin fijar"
            )
            .accessibilityIdentifier("dashboard-unpinned-disclosure")

            if showsUnpinnedSessions {
                LazyVStack(spacing: 8) {
                    ForEach(unpinnedSessions, id: \.windowId) { session in
                        unpinnedSessionRow(session, layout: layout)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("dashboard-unpinned-end")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func unpinnedSessionRow(
        _ session: KycodeSessionSummary,
        layout: DashboardMetrics
    ) -> some View {
        HStack(spacing: 4) {
            NavigationLink(value: session.windowId) {
                HStack(spacing: 11) {
                    Circle()
                        .fill(unpinnedSessionStatusColor(session))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.collaborationSessionName)
                            .font(.system(size: layout.isTablet ? 15 : 14, weight: .semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(KycodeInterfaceCopyPolicy.sessionActivityStatus(session.visualActivityStatus))
                            if let source = store.sessionSourceLabel(for: session.windowId) {
                                Text("·")
                                Text(source == "Mac personal" ? "Personal" : source)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.inkMuted)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.inkMuted)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 13)
                .frame(maxWidth: .infinity, minHeight: layout.isTablet ? 58 : 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                AppHaptics.shared.play(.conversationSelection)
                recordSessionOpened(session.windowId)
            })
            .accessibilityLabel(cardAccessibilityLabel(for: session))
            .accessibilityHint("Abre la conversación")
            .accessibilityIdentifier("unpinned-session-row-\(session.windowId)")

            Button {
                togglePinned(session.windowId)
            } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.92, opacity: 0.76))
            .accessibilityLabel("Fijar \(session.collaborationSessionName)")
            .accessibilityHint("Mueve la sesión a la lista principal")
            .accessibilityIdentifier("pin-unpinned-session-\(session.windowId)")
        }
        .padding(.trailing, 4)
        .v2RaisedSurface(fill: AppTheme.cardSurface.opacity(0.86))
    }

    private func unpinnedSessionStatusColor(_ session: KycodeSessionSummary) -> Color {
        switch session.visualActivityStatus {
        case "working", "approval": return AppTheme.statusBusy
        case "error": return AppTheme.statusError
        case "ready", "done": return AppTheme.statusReady
        default: return AppTheme.inkMuted
        }
    }

    private var activeRecordingWindowId: String? {
        guard backgroundRecording.hasInFlightRecording else { return nil }
        return backgroundRecording.activeWindowId
    }

    private var showsInlineEmptyAction: Bool {
        visibleSessions.isEmpty &&
            visibleRecentCreatedSessions.isEmpty &&
            dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            dashboardFilter == .all
    }

    private var visibleRecentCreatedSessions: [KycodeRecentCreatedSession] {
        let entries = KycodeRecentCreatedSessionScopePolicy.visibleEntries(
            store.recentCreatedSessions,
            selectedProfileId: store.selectedProfileId
        )
        let query = kycodeSearchNormalize(debouncedDashboardSearchText)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            kycodeSearchNormalize(
                [entry.sessionName, entry.projectName, entry.projectPath, entry.profileId]
                    .compactMap { $0 }
                    .joined(separator: " ")
            ).contains(query)
        }
    }

    private func dashboardRecordingButton(windowId: String) -> some View {
        Button {
            guard backgroundRecording.phase != .recovered else { return }
            recordSessionOpened(windowId)
            navigationPath = [windowId]
        } label: {
            BackgroundRecordingIndicator(
                phase: backgroundRecording.phase,
                duration: backgroundRecording.duration,
                sessionName: store.sessions.first(where: { $0.windowId == windowId })?.displayName
            )
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97, opacity: 0.92))
        .accessibilityIdentifier("background-recording-indicator")
        .accessibilityHint(
            backgroundRecording.phase == .recovered
                ? "Usá el panel de recuperación para continuar o guardar el audio"
                : "Vuelve a la conversación que está grabando"
        )
    }

    private func dashboardSearchPanel(layout: DashboardMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.isTablet ? 8 : 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.inkMuted)
                TextField("Buscar nombre, proyecto o mensaje", text: $dashboardSearchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isDashboardSearchFocused)
                    .onSubmit {
                        isDashboardSearchFocused = false
                    }
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityIdentifier("dashboard-search")
                Button {
                    if dashboardSearchText.isEmpty {
                        cancelPendingDashboardSearchFocus()
                        showsDashboardSearch = false
                        isDashboardSearchFocused = false
                    } else {
                        dashboardSearchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.inkMuted)
                        .frame(width: layout.isTablet ? 52 : 44, height: layout.isTablet ? 52 : 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dashboardSearchText.isEmpty ? "Cerrar búsqueda" : "Limpiar búsqueda")
            }
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .frame(minHeight: layout.isTablet ? 56 : 48)
            .v2InsetSurface()

            HStack(spacing: 8) {
                dashboardSearchScopeMenu(layout: layout)

                if !kycodeSearchNormalize(debouncedDashboardSearchText).isEmpty {
                    Spacer(minLength: 0)
                    Text(
                        visibleSessions.count == 1
                            ? "1 sesión coincide"
                            : "\(visibleSessions.count) sesiones coinciden"
                    )
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityIdentifier("dashboard-search-result-count")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dashboardSearchScopeLabel: String {
        let profileLabel = store.selectedProfile.map(kycodeCompactProfileLabel(for:))
            ?? store.selectedProfileName
        return "\(profileLabel) · \(dashboardFilter.label)"
    }

    private func dashboardSearchScopeMenu(layout: DashboardMetrics) -> some View {
        let hasActiveFilters = activeDashboardFilterCount > 0

        return Menu {
            dashboardFilterMenuContent(surface: .search)
        } label: {
            HStack(spacing: 6) {
                Image(
                    systemName: hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease"
                )
                Text(dashboardSearchScopeLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: layout.isTablet ? 13 : 11, weight: .semibold))
            .foregroundStyle(hasActiveFilters ? AppTheme.accent : AppTheme.inkSoft)
            .padding(.horizontal, 11)
            .frame(minHeight: layout.isTablet ? 52 : 44)
            .v2RaisedSurface(
                fill: hasActiveFilters ? AppTheme.accent.opacity(0.16) : AppTheme.cardSurfaceRaised
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.s, style: .continuous)
                    .stroke(hasActiveFilters ? AppTheme.accent.opacity(0.58) : AppTheme.lineSoft, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97, opacity: 0.9))
        .disabled(dashboardProfileSwitchTargetId != nil)
        .accessibilityLabel("Filtros de búsqueda")
        .accessibilityValue(
            "\(store.selectedProfileName), \(dashboardFilter.label), \(visibleSessions.count) sesiones"
        )
        .accessibilityHint("Cambia la computadora o muestra sólo sesiones que necesitan atención")
        .accessibilityIdentifier("dashboard-search-scope")
    }

    private var dashboardNoResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: dashboardFilter == .attention ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppTheme.inkMuted)
            Text(dashboardFilter == .attention ? "Nada requiere atención" : "Sin resultados")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text(
                dashboardFilter == .attention
                    ? "Tus otras sesiones siguen disponibles."
                    : "Probá otro nombre, proyecto o mensaje."
            )
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.inkMuted)
            .multilineTextAlignment(.center)
            Button("Mostrar todas") {
                resetDashboardFilters()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 184)
    }

    private func togglePinned(_ windowId: String) {
        var next = unpinnedWindowIds
        let wasPinned = isSessionPinned(windowId)
        if wasPinned {
            next.insert(windowId)
        } else {
            next.remove(windowId)
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            unpinnedWindowIdsStorage = KycodeSessionPinningPolicy.storageValue(for: next)
        }
        AppHaptics.shared.play(.conversationSelection)
        showDashboardNotice(wasPinned ? "Sesión movida a Sin fijar" : "Sesión fijada")
    }

    private func sessionCount(for filter: DashboardSessionFilter) -> Int {
        switch filter {
        case .all:
            return dashboardSessions.count
        case .attention:
            return attentionSessionCount
        }
    }

    private func lastRefreshLabel(at now: Date) -> String {
        guard let date = store.lastSessionsRefreshAt else { return "Sin sincronizar" }
        return "Sync \(shortRelativeAge(since: date, now: now))"
    }

    private func lastRefreshAccessibilityLabel(at now: Date) -> String {
        guard let date = store.lastSessionsRefreshAt else { return "Todavía no se sincronizaron las sesiones" }
        return "Última sincronización hace \(spokenRelativeAge(since: date, now: now))"
    }

    private func continueLastSessionButton(_ session: KycodeSessionSummary) -> some View {
        NavigationLink(value: session.windowId) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                Text(session.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.inkMuted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(AppTheme.cardSurfaceRaised, in: Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .simultaneousGesture(TapGesture().onEnded {
            recordSessionOpened(session.windowId)
        })
        .accessibilityIdentifier("continue-last-session")
    }

    private func recordSessionOpened(_ windowId: String) {
        lastOpenedWindowId = windowId
    }

    private func hasComposerDraft(for windowId: String) -> Bool {
        let defaults = UserDefaults.standard
        let scopedKey = store.composerDraftStorageKey(for: windowId)
        let scopedValue = defaults.string(forKey: scopedKey) ?? ""
        return !scopedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func searchMatchHint(for session: KycodeSessionSummary) -> String? {
        let query = kycodeSearchNormalize(debouncedDashboardSearchText)
        guard !query.isEmpty else { return nil }
        return dashboardSearchDocuments[session.windowId]?.matchingField(query)
    }

    private func scheduleDashboardSearch(_ value: String) {
        dashboardSearchTask?.cancel()
        dashboardSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            debouncedDashboardSearchText = value
        }
    }

    private func rebuildDashboardSearchDocuments() {
        let snapshot = DashboardSearchIndexRevision.snapshot(for: store.sessions)
        dashboardIndexTask?.cancel()
        dashboardIndexTask = Task {
            let documents = await Task.detached(priority: .utility) {
                Dictionary(
                    uniqueKeysWithValues: snapshot.map {
                        ($0.windowId, DashboardSearchDocument(revision: $0))
                    }
                )
            }.value
            guard !Task.isCancelled else { return }
            dashboardSearchDocuments = documents
        }
    }

    private func cardAccessibilityLabel(for session: KycodeSessionSummary) -> String {
        var parts = [
            session.dashboardCollaborationTitle,
            session.dashboardAccessibilityStatus,
        ]
        if let runtimeLabel = session.runtimeDisplayLabel { parts.append(runtimeLabel) }
        if let sourceLabel = store.sessionSourceLabel(for: session.windowId) {
            parts.append(sourceLabel == "Mac personal" ? "Personal" : sourceLabel)
        }
        if isSessionPinned(session.windowId) { parts.append("fijada") }
        if hasComposerDraft(for: session.windowId) { parts.append("con borrador") }
        if session.windowId == lastOpenedWindowId { parts.append("última conversación usada") }
        return parts.joined(separator: ", ")
    }

    private func showDashboardNotice(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            dashboardNoticeText = text
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, dashboardNoticeText == text else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                dashboardNoticeText = nil
            }
        }
    }

    private func revealDashboardSearch() {
        cancelPendingDashboardSearchFocus()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            showsDashboardSearch = true
        }
        let focusDelayMilliseconds = dashboardSearchFocusDelayMilliseconds
        dashboardSearchFocusTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(focusDelayMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled, showsDashboardSearch else { return }
            isDashboardSearchFocused = true
            dashboardSearchFocusTask = nil
        }
    }

    private func resetDashboardFilters() {
        cancelPendingDashboardSearchFocus()
        dashboardSearchText = ""
        dashboardFilterRaw = DashboardSessionFilter.all.rawValue
        showsDashboardSearch = false
        isDashboardSearchFocused = false
        if store.selectedProfileId != "all" {
            selectConnectionProfile("all", announcesResult: true)
        }
    }

    private func cancelPendingDashboardSearchFocus() {
        dashboardSearchFocusTask?.cancel()
        dashboardSearchFocusTask = nil
    }

    private var dashboardSearchFocusDelayMilliseconds: Int {
#if DEBUG
        if let rawValue = ProcessInfo.processInfo.environment[
            "KYCODE_UI_TEST_DASHBOARD_SEARCH_FOCUS_DELAY_MS"
        ], let value = Int(rawValue) {
            return min(max(value, 0), 5_000)
        }
#endif
        return 180
    }

    private var activeDashboardFilterCount: Int {
        (store.selectedProfileId == "all" ? 0 : 1) + (dashboardFilter == .all ? 0 : 1)
    }

    private func dashboardSearchButton(layout: DashboardMetrics) -> some View {
        Button(action: revealDashboardSearch) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: layout.isTablet ? 17 : 15, weight: .semibold))
                Text("Buscar sesiones")
                    .font(.system(size: layout.isTablet ? 15 : 14, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.inkSoft)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: layout.isTablet ? 64 : 48)
            .v2InsetSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
        .opacity(showsDashboardSearch || isDashboardSearchFocused ? 0 : 1)
        .allowsHitTesting(!showsDashboardSearch && !isDashboardSearchFocused)
        .accessibilityHidden(showsDashboardSearch || isDashboardSearchFocused)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: showsDashboardSearch || isDashboardSearchFocused
        )
        .accessibilityLabel("Buscar sesiones")
        .accessibilityHint("Busca por nombre, proyecto o mensaje")
        .accessibilityIdentifier("dashboard-search-action")
    }

    private func dashboardFloatingMenu(layout: DashboardMetrics) -> some View {
        let size: CGFloat = layout.isTablet ? 64 : 48

        return Menu {
            Section("KyCode") {
                Button(action: handleDashboardConnectivityAction) {
                    Label(
                        "\(dashboardConnectivityTitle) · \(store.lastSessionsRefreshAt.map { shortRelativeAge(since: $0, now: .now) } ?? "sin sync")",
                        systemImage: dashboardConnectivitySymbol
                    )
                }
                .accessibilityHint(store.isConnected ? "Actualiza las sesiones" : "Reintenta la conexión")

                Button(action: copyConnectionDiagnostics) {
                    Label("Copiar diagnóstico", systemImage: "doc.on.doc")
                }

                Button {
                    showSessionHistory = true
                } label: {
                    Label("Historial de sesiones", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("session-history-open")

                Button {
                    presentConnectionPanel()
                } label: {
                    Label("Desktop y preferencias", systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: layout.isTablet ? 22 : 20, weight: .bold))
                .foregroundStyle(AppTheme.inkSoft)
            .frame(width: size, height: size)
                .v2RaisedSurface(fill: AppTheme.cardSurfaceRaised)
                .contentShape(Rectangle())
        }
        .opacity(isDashboardSearchFocused ? 0 : 1)
        .allowsHitTesting(!isDashboardSearchFocused)
        .buttonStyle(PressableButtonStyle(scale: 0.95, opacity: 0.9))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDashboardSearchFocused)
        .accessibilityLabel("Más")
        .accessibilityHint("Abre historial, conexión y preferencias")
        .accessibilityIdentifier("dashboard-floating-menu")
    }

    private func dashboardFilterMenu(layout: DashboardMetrics) -> some View {
        let size: CGFloat = layout.isTablet ? 64 : 48
        let hasActiveFilters = activeDashboardFilterCount > 0

        return Menu {
            dashboardFilterMenuContent(surface: .dock)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: layout.isTablet ? 22 : 20, weight: .semibold))
                    .foregroundStyle(hasActiveFilters ? Color.white : AppTheme.inkSoft)
                    .frame(width: size, height: size)
                    .v2RaisedSurface(
                        fill: hasActiveFilters ? AppTheme.accent : AppTheme.cardSurfaceRaised,
                        topLight: hasActiveFilters ? AppTheme.surfaceTopLightStrong : AppTheme.surfaceTopLight
                    )
                    .contentShape(Rectangle())

                if activeDashboardFilterCount > 0 {
                    Text("\(activeDashboardFilterCount)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 18, height: 18)
                        .background(Color.white, in: Circle())
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
        }
        .opacity(showsDashboardSearch || isDashboardSearchFocused ? 0 : 1)
        .allowsHitTesting(
            !showsDashboardSearch && !isDashboardSearchFocused && dashboardProfileSwitchTargetId == nil
        )
        .accessibilityHidden(showsDashboardSearch || isDashboardSearchFocused)
        .buttonStyle(PressableButtonStyle(scale: 0.95, opacity: 0.9))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsDashboardSearch)
        .accessibilityLabel("Filtros")
        .accessibilityValue(
            "\(store.selectedProfileName), \(dashboardFilter.label), \(visibleSessions.count) sesiones, "
                + (store.isConnected ? "Conectado" : "Sin conexión")
        )
        .accessibilityHint("Filtra por computadora o por sesiones que necesitan atención")
        .accessibilityIdentifier("dashboard-filter-menu")
    }

    @ViewBuilder
    private func dashboardFilterMenuContent(surface: DashboardFilterMenuSurface) -> some View {
        Section("Computadora") {
            ForEach(store.userSelectableProfiles) { profile in
                Button {
                    selectConnectionProfile(profile.id, announcesResult: true)
                    isDashboardSearchFocused = false
                } label: {
                    Label(
                        kycodeCompactProfileLabel(for: profile),
                        systemImage: store.selectedProfileId == profile.id
                            ? "checkmark.circle.fill"
                            : dashboardProfileSymbol(profile.id)
                    )
                }
                .accessibilityValue(
                    store.selectedProfileId == profile.id
                        ? (dashboardProfileSwitchTargetId == profile.id ? "Seleccionado, cambiando" : "Seleccionado")
                        : "No seleccionado"
                )
                .accessibilityIdentifier(surface.profileIdentifier(profile.id))
            }
        }

        Section("Estado") {
            ForEach(DashboardSessionFilter.allCases, id: \.rawValue) { filter in
                Button {
                    dashboardFilterRaw = filter.rawValue
                    isDashboardSearchFocused = false
                } label: {
                    Label(
                        "\(filter.label) · \(sessionCount(for: filter))",
                        systemImage: dashboardFilter == filter ? "checkmark.circle.fill" : filter.symbol
                    )
                }
                .accessibilityValue(dashboardFilter == filter ? "Seleccionado" : "")
                .accessibilityIdentifier(surface.filterIdentifier(filter))
            }
        }

        if activeDashboardFilterCount > 0 || !dashboardSearchText.isEmpty {
            Section {
                Button(action: resetDashboardFilters) {
                    Label("Restablecer filtros", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier(surface.resetIdentifier)
            }
        }
    }

    private func dashboardProfileSymbol(_ profileId: String) -> String {
        switch profileId {
        case "puky": return "server.rack"
        case "all": return "square.grid.2x2.fill"
        default: return "laptopcomputer"
        }
    }

    private func dashboardCreateSessionButton(layout: DashboardMetrics) -> some View {
        let size: CGFloat = layout.isTablet ? 64 : 56

        return Button(action: presentCreateSession) {
            Group {
                if isPreparingCreateSessionTarget {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: layout.isTablet ? 24 : 22, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .v2RaisedSurface(fill: AppTheme.accent, topLight: AppTheme.surfaceTopLightStrong)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95, opacity: 0.9))
        .opacity(isDashboardSearchFocused ? 0 : 1)
        .allowsHitTesting(!isDashboardSearchFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDashboardSearchFocused)
        .accessibilityLabel("Nueva sesión")
        .accessibilityHint("Crea una sesión en un toque")
        .accessibilityIdentifier("dashboard-new-session")
    }

    private func dashboardServerSwitcher(layout: DashboardMetrics) -> some View {
        DashboardServerSwitcher(
            profiles: store.userSelectableProfiles,
            selectedProfileId: store.selectedProfileId,
            switchingProfileId: dashboardProfileSwitchTargetId,
            isConnected: store.isConnected,
            reduceMotion: reduceMotion,
            onSelectProfile: { profileId in
                selectConnectionProfile(profileId, announcesResult: true)
            }
        )
        .opacity(isDashboardSearchFocused ? 0 : 1)
        .allowsHitTesting(!isDashboardSearchFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDashboardSearchFocused)
    }

    private func presentCreateSession() {
        guard !showCreateSessionSheet, !showCreateSessionTargetChooser else { return }

        switch store.createSessionAccess {
        case .available:
            AppHaptics.shared.play(.newSession)
            showCreateSessionSheet = true
            if !store.isConnected, !store.isBootstrapping {
                Task { await store.retryAutoConnect() }
            }
        case .profileSelectionRequired:
            AppHaptics.shared.play(.conversationSelection)
            showCreateSessionTargetChooser = true
        case .credentialsRequired:
            AppHaptics.shared.play(.messageSendError)
            showDashboardNotice("Falta conectar \(store.selectedProfileName) para crear la sesión")
            presentConnectionPanel()
        }
    }

    private func prepareCreateSessionTarget(_ profileId: String) {
        guard !isPreparingCreateSessionTarget else { return }
        isPreparingCreateSessionTarget = true
        showDashboardNotice("Preparando la nueva sesión…")

        Task { @MainActor in
            await store.selectProfile(id: profileId)
            isPreparingCreateSessionTarget = false
            switch store.createSessionAccess {
            case .available:
                AppHaptics.shared.play(.newSession)
                showCreateSessionSheet = true
            case .credentialsRequired:
                showDashboardNotice("Falta conectar \(store.selectedProfileName) para crear la sesión")
                presentConnectionPanel()
            case .profileSelectionRequired:
                showDashboardNotice("Elegí Puky o Mac personal para crear la sesión")
            }
        }
    }

    private func presentConnectionPanel() {
        guard !showConnectionSheet else { return }
        AppHaptics.shared.play(.connectionPanelOpen)
        showConnectionSheet = true
    }

    private func restoreMinimizedSession(_ session: KycodeSessionSummary) async {
        let restored = await store.setSessionMinimized(windowId: session.windowId, minimized: false)
        guard restored else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            showMinimizedSessions = false
        }
        navigationPath = [session.windowId]
    }

    private func beginRename(_ session: KycodeSessionSummary) {
        RenameSessionHaptics.shared.longPressDetected()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            renameTarget = SessionRenameTarget(
                windowId: session.windowId,
                currentName: session.collaborationSessionName
            )
        }
    }

    private func beginProjectSelection(_ session: KycodeSessionSummary) {
        guard session.agentEngine != .claude else {
            showDashboardNotice("Los proyectos compartidos son para sesiones Codex")
            return
        }
        guard !session.minimized else {
            showDashboardNotice("Restaurá la sesión antes de cambiar su proyecto")
            return
        }
        AppHaptics.shared.play(.conversationSelection)
        projectSelectionTarget = SessionProjectSelectionTarget(session: session)
    }

    private func beginDelete(_ session: KycodeSessionSummary) {
        deleteTarget = SessionDeleteTarget(
            windowId: session.windowId,
            displayName: session.dashboardCollaborationTitle
        )
    }

    private func commitDelete(_ target: SessionDeleteTarget) {
        deleteTarget = nil
        AppHaptics.shared.play(.sessionDeleteRequest)

        Task {
            let deleted = await store.deleteSession(windowId: target.windowId)
            await MainActor.run {
                if deleted {
                    var nextUnpinned = unpinnedWindowIds
                    nextUnpinned.remove(target.windowId)
                    unpinnedWindowIdsStorage = KycodeSessionPinningPolicy.storageValue(for: nextUnpinned)
                    if lastOpenedWindowId == target.windowId {
                        lastOpenedWindowId = ""
                    }
                    AppHaptics.shared.play(.sessionDeleteSuccess)
                    showDashboardNotice("Sesión borrada")
                } else {
                    AppHaptics.shared.play(.sessionDeleteError)
                    deleteErrorMessage = store.errorMessage ?? "Intentá de nuevo."
                }
            }
        }
    }

    private func commitRename(_ target: SessionRenameTarget, name: String) {
        let trimmedName = String(name.prefix(SessionRenameRules.maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            RenameSessionHaptics.shared.nameError()
            renameErrorMessage = "El nombre no puede estar vacío."
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            renameTarget = nil
        }

        Task {
            let updated = await store.renameSession(windowId: target.windowId, newName: trimmedName)
            if !updated {
                await MainActor.run {
                    RenameSessionHaptics.shared.nameError()
                    renameTarget = SessionRenameTarget(
                        windowId: target.windowId,
                        currentName: target.currentName,
                        draftName: trimmedName
                    )
                    renameErrorMessage = SessionRenameRules.retryMessage(serverMessage: store.errorMessage)
                }
            } else {
                await MainActor.run {
                    RenameSessionHaptics.shared.nameSaved()
                    showDashboardNotice("Sesión renombrada")
                }
            }
        }
    }

}

@MainActor
private struct CollaborationProjectSelectionSheet: View {
    @ObservedObject var store: KycodeConnectionStore
    let session: KycodeSessionSummary
    let onAssigned: (KycodeCollaborationProject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projects: [KycodeCollaborationProject] = []
    @State private var isLoading = true
    @State private var assigningProjectId: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Cargando proyectos…")
                                .foregroundStyle(.secondary)
                        }
                    } else if projects.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No hay proyectos configurados")
                                .font(.headline)
                            Text("Los proyectos aparecen a partir de tus etiquetas existentes y de la configuración del desktop.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(projects) { project in
                            Button {
                                assign(project)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(project.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                        if let count = project.activeSessionCount {
                                            Text("\(count) \(count == 1 ? "sesión activa" : "sesiones activas")")
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.inkMuted)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if assigningProjectId == project.id {
                                        ProgressView()
                                    } else if session.collaborationProjectId == project.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppTheme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(assigningProjectId != nil)
                            .accessibilityIdentifier("collaboration-project-\(project.id)")
                        }
                    }
                } header: {
                    Text("Proyecto conceptual")
                } footer: {
                    Text("No cambia la carpeta de trabajo. Al elegirlo, KyCode avisa a todas y solo las sesiones Codex activas de ese proyecto para que colaboren sin pisar cambios.")
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(AppTheme.statusError)
                    }
                }
            }
            .navigationTitle(session.collaborationSessionName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .task(id: session.windowId) {
            await loadProjects()
        }
    }

    private func loadProjects() async {
        isLoading = true
        errorMessage = nil
        let loaded = await store.fetchCollaborationProjects(windowId: session.windowId)
        guard !Task.isCancelled else { return }
        if let loaded {
            projects = loaded
        } else {
            errorMessage = store.errorMessage ?? "No se pudieron cargar los proyectos."
        }
        isLoading = false
    }

    private func assign(_ project: KycodeCollaborationProject) {
        guard assigningProjectId == nil else { return }
        if session.collaborationProjectId == project.id {
            dismiss()
            return
        }
        assigningProjectId = project.id
        errorMessage = nil
        Task {
            let assigned = await store.assignCollaborationProject(
                windowId: session.windowId,
                project: project
            )
            guard !Task.isCancelled else { return }
            assigningProjectId = nil
            if assigned {
                onAssigned(project)
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "No se pudo cambiar el proyecto."
            }
        }
    }
}

@MainActor
private struct VoiceProfileSettingsView: View {
    @EnvironmentObject private var store: KycodeConnectionStore
    @EnvironmentObject private var backgroundRecording: BackgroundRecordingState
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AudioRecordingService?
    @State private var tickerTask: Task<Void, Never>?
    @State private var isRecordingSample = false
    @State private var isEnrolling = false
    @State private var enrollmentProgress: Float = 0
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingLevel: Float = 0
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var canRecordSample: Bool {
        store.isVoiceProfileEngineConfigured
            && backgroundRecording.isRecoveryScanComplete
            && !backgroundRecording.isRecording
            && !isEnrolling
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modeCard
                profileCard
                safetyCard
                if let report = store.latestVoiceIsolationReport {
                    latestResultCard(report)
                }
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("voice-isolation-settings")
        .navigationTitle("Mi voz")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if recorder == nil {
                recorder = AudioRecordingService()
            }
        }
        .onDisappear {
            tickerTask?.cancel()
            tickerTask = nil
            if isRecordingSample {
                recorder?.cancelRecording(prepareNext: false)
            }
        }
        .alert("Borrar perfil de voz", isPresented: $showDeleteConfirmation) {
            Button("Borrar", role: .destructive) {
                Task {
                    await store.deleteVoiceProfile()
                    statusMessage = "Perfil local eliminado."
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("La app dejará de identificar tu voz hasta que grabes una muestra nueva.")
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Modo")
            Picker(
                "Aislamiento",
                selection: Binding(
                    get: { store.voiceIsolationMode },
                    set: { store.setVoiceIsolationMode($0) }
                )
            ) {
                ForEach(VoiceIsolationMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("voice-isolation-mode-picker")

            Text(store.voiceIsolationMode.explanation)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if store.voiceIsolationMode == .personalized {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Confianza mínima")
                        Spacer()
                        Text("\(Int(store.voiceIsolationThreshold * 100))%")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.inkSoft)

                    Slider(
                        value: Binding(
                            get: { Double(store.voiceIsolationThreshold) },
                            set: { store.setVoiceIsolationThreshold(Float($0)) }
                        ),
                        in: 0.35...0.85,
                        step: 0.05
                    )
                    .tint(AppTheme.accent)
                }
            }
        }
        .premiumCard(padding: 16)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Perfil local")
                Spacer()
                Label(
                    store.hasEnrolledVoiceProfile ? "Listo" : "Sin crear",
                    systemImage: store.hasEnrolledVoiceProfile ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(store.hasEnrolledVoiceProfile ? AppTheme.statusReady : AppTheme.inkMuted)
            }

            Text("Grabá entre 8 y 15 segundos hablando con naturalidad. El perfil queda en Keychain y una referencia corta queda protegida en este dispositivo.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isVoiceProfileEngineConfigured {
                Label("Falta PICOVOICE_ACCESS_KEY. El modo personalizado hará fallback al texto completo.", systemImage: "key.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.statusBusy)
                    .fixedSize(horizontal: false, vertical: true)
            } else if backgroundRecording.isRecording {
                Label("Terminá la grabación activa antes de crear el perfil.", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.statusBusy)
            }

            if isRecordingSample {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                        Text("Muestra \(formattedDuration(recordingDuration))")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        Text(recordingDuration >= VoiceEnrollmentPolicy.minimumDuration ? "Suficiente" : "Mínimo 8 s")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(recordingDuration >= VoiceEnrollmentPolicy.minimumDuration ? AppTheme.statusReady : AppTheme.inkMuted)
                    }

                    GeometryReader { proxy in
                        Capsule()
                            .fill(AppTheme.ink.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(AppTheme.accent)
                                    .frame(width: max(4, proxy.size.width * CGFloat(min(1, max(0.03, recordingLevel)))))
                            }
                    }
                    .frame(height: 8)
                }
            }

            if isEnrolling {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: enrollmentProgress)
                        .tint(AppTheme.accent)
                    Text("Construyendo el perfil en el dispositivo… \(Int(enrollmentProgress * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.inkSoft)
                }
            }

            Button {
                if isRecordingSample {
                    finishAndEnroll()
                } else {
                    startSampleRecording()
                }
            } label: {
                Label(
                    isRecordingSample ? "Terminar y crear perfil" : (store.hasEnrolledVoiceProfile ? "Grabar perfil nuevo" : "Grabar mi voz"),
                    systemImage: isRecordingSample ? "checkmark.circle.fill" : "mic.fill"
                )
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isRecordingSample ? AppTheme.statusReady : AppTheme.accent,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                )
                .foregroundStyle(Color.white)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isRecordingSample && !canRecordSample)
            .opacity((!isRecordingSample && !canRecordSample) ? 0.45 : 1)

            if store.hasEnrolledVoiceProfile, !isRecordingSample, !isEnrolling {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text("Borrar perfil local")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.statusReady)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.statusBusy)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .premiumCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-profile-card")
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Regla de seguridad")
            Label("El WAV completo siempre se conserva hasta terminar el envío.", systemImage: "externaldrive.fill.badge.checkmark")
            Label("Si la evidencia no alcanza, se usa el texto completo.", systemImage: "arrow.uturn.backward.circle.fill")
            Label("El perfil no se envía a Mistral.", systemImage: "lock.shield.fill")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppTheme.inkSoft)
        .premiumCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-isolation-safety-card")
    }

    private func latestResultCard(_ report: VoiceIsolationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Último resultado")
            Label(
                report.applied ? "Se conservó solo tu voz" : "Se conservó el texto completo",
                systemImage: report.applied ? "person.wave.2.fill" : "text.badge.checkmark"
            )
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(report.applied ? AppTheme.statusReady : AppTheme.inkSoft)

            if let confidence = report.aggregateConfidence {
                Text("Confianza agregada: \(Int(confidence * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.inkMuted)
            }
            if let fallback = report.fallbackReason {
                Text(fallback.userMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .premiumCard(padding: 16)
    }

    private func startSampleRecording() {
        guard canRecordSample else { return }
        errorMessage = nil
        statusMessage = nil
        enrollmentProgress = 0
        recordingDuration = 0
        recordingLevel = 0
        Task { @MainActor in
            let service: AudioRecordingService
            if let recorder {
                service = recorder
            } else {
                let created = AudioRecordingService()
                recorder = created
                service = created
            }
            guard await service.requestPermissionIfNeeded() else {
                errorMessage = service.lastError?.localizedDescription ?? "No hay permiso de micrófono."
                return
            }
            let started = await service.startRecording()
            guard started else {
                errorMessage = service.lastError?.localizedDescription ?? "No pude iniciar la muestra."
                return
            }
            isRecordingSample = true
            tickerTask?.cancel()
            tickerTask = Task { @MainActor in
                while !Task.isCancelled, service.isRecording {
                    recordingDuration = service.currentTime
                    recordingLevel = service.currentLevel
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }

    private func finishAndEnroll() {
        guard let recorder, isRecordingSample, !isEnrolling else { return }
        tickerTask?.cancel()
        tickerTask = nil
        isRecordingSample = false
        isEnrolling = true
        errorMessage = nil
        statusMessage = nil

        Task { @MainActor in
            guard let fileURL = await recorder.stopRecording(prepareNext: false) else {
                isEnrolling = false
                errorMessage = recorder.lastError?.localizedDescription ?? "La muestra no quedó guardada."
                return
            }
            defer { recorder.deleteTemporaryFile(at: fileURL) }
            do {
                let result = try await store.enrollVoiceProfile(from: fileURL) { progress in
                    await MainActor.run {
                        enrollmentProgress = progress
                    }
                }
                enrollmentProgress = 1
                statusMessage = "Perfil listo con \(Int(result.processedDuration.rounded())) segundos de voz."
                AppHaptics.shared.play(.voiceStateTransition)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppHaptics.shared.play(.messageSendError)
            }
            isEnrolling = false
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
struct VoiceIsolationUITestHarness: View {
    @StateObject private var store = KycodeConnectionStore()
    @StateObject private var backgroundRecording = BackgroundRecordingState()

    var body: some View {
        NavigationStack {
            VoiceProfileSettingsView()
                .environmentObject(store)
                .environmentObject(backgroundRecording)
        }
    }
}

/// Phone-only bottom dock. Unlike the legacy pair of full-screen overlays,
/// this stays above the Home indicator safe area and gives hit testing only to
/// the visible recording chip and actions menu.
private struct PhoneDashboardBottomDock<Recording: View, Actions: View>: View {
    private let recording: () -> Recording
    private let actions: () -> Actions

    init(
        @ViewBuilder recording: @escaping () -> Recording,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.recording = recording
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            recording()

            Spacer(minLength: 0)

            actions()
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// Product-level target selector. LAN and relay remain internal transports for
/// Mac personal; the user chooses only a machine or the combined view.
private struct DashboardServerSwitcher: View {
    let profiles: [KycodeConnectionProfile]
    let selectedProfileId: String
    let switchingProfileId: String?
    let isConnected: Bool
    let reduceMotion: Bool
    let onSelectProfile: (String) -> Void

    private var orderedProfiles: [KycodeConnectionProfile] {
        ["puky", "personal", "all"].compactMap { profileId in
            profiles.first(where: { $0.id == profileId })
        }
    }

    private var isSwitching: Bool {
        switchingProfileId != nil
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(orderedProfiles) { profile in
                targetButton(profile)
            }
        }
        .padding(3)
        .frame(height: 48)
        .background(AppTheme.cardSurfaceRaised.opacity(0.97), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.divider.opacity(0.66), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.36), radius: 8, x: 0, y: 4)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
            value: selectedProfileId
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSwitching)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destino de KyCode")
        .accessibilityIdentifier("dashboard-server-switcher")
    }

    private func targetButton(_ profile: KycodeConnectionProfile) -> some View {
        let selected = profile.id == selectedProfileId
        let switching = profile.id == switchingProfileId
        let tint = switching
            ? AppTheme.statusBusy
            : (selected && isConnected ? AppTheme.statusReady : AppTheme.inkMuted)

        return Button {
            onSelectProfile(profile.id)
        } label: {
            HStack(spacing: 5) {
                if switching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(selected ? Color.white : tint)
                } else {
                    Image(systemName: profileSymbol(profile))
                        .font(.system(size: 11, weight: .bold))
                }
                Text(kycodeCompactProfileLabel(for: profile))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : AppTheme.inkSoft)
            .padding(.horizontal, 8)
            .frame(minWidth: profile.id == "personal" ? 78 : 54, minHeight: 42)
            .background(
                selected
                    ? AnyShapeStyle(AppTheme.accent)
                    : AnyShapeStyle(Color.clear),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.9))
        .modifier(DashboardTargetKeyboardShortcut(profileId: profile.id))
        .disabled(isSwitching)
        .accessibilityLabel(kycodeCompactProfileLabel(for: profile))
        .accessibilityValue(
            selected
                ? (switching ? "Seleccionado, cambiando" : isConnected ? "Seleccionado, conectado" : "Seleccionado, sin conexión")
                : "No seleccionado"
        )
        .accessibilityHint("Cambia el destino de las sesiones")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("dashboard-target-\(profile.id)")
    }

    private func profileSymbol(_ profile: KycodeConnectionProfile) -> String {
        switch profile.id {
        case "puky":
            return "server.rack"
        case "all":
            return "square.grid.2x2.fill"
        default:
            return "laptopcomputer"
        }
    }
}

private struct DashboardTargetKeyboardShortcut: ViewModifier {
    let profileId: String

    @ViewBuilder
    func body(content: Content) -> some View {
        switch profileId {
        case "puky":
            content.keyboardShortcut("1", modifiers: .command)
        case "personal":
            content.keyboardShortcut("2", modifiers: .command)
        case "all":
            content.keyboardShortcut("3", modifiers: .command)
        default:
            content
        }
    }
}

private struct BackgroundRecordingIndicator: View {
    let phase: BackgroundRecordingState.Phase
    let duration: TimeInterval
    let sessionName: String?

    private var phaseLabel: String {
        switch phase {
        case .starting: return "PREPARANDO"
        case .recording: return "REC"
        case .interrupted: return "INTERRUMPIDA"
        case .finalizing: return "GUARDANDO"
        case .recovered: return "RECUPERADA"
        case .idle: return "AUDIO"
        }
    }

    private var formattedDuration: String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(phase == .recording ? Color.red : AppTheme.statusBusy)
                    .frame(width: 10, height: 10)
                if phase == .recording {
                    Circle()
                        .stroke(Color.red.opacity(0.34), lineWidth: 5)
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(phaseLabel)
                        .font(.system(size: 11, weight: .black, design: .default))
                        .tracking(0.55)
                    Text(formattedDuration)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)

                if let sessionName, !sessionName.isEmpty {
                    Text(sessionName)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Image(systemName: phase == .recovered ? "waveform.badge.exclamationmark" : "arrow.up.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(Color.black.opacity(0.88), in: Rectangle())
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(phase == .recording ? Color.red : AppTheme.statusBusy)
                .frame(width: 3)
        }
        .shadow(color: Color.black.opacity(0.52), radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phaseLabel), \(formattedDuration)\(sessionName.map { ", \($0)" } ?? "")")
    }
}

private struct VoiceRecordingRecoverySheet: View {
    let recording: RecoverableVoiceRecording
    let sessionName: String?
    let isPlaying: Bool
    let isWorking: Bool
    let canUseRecording: Bool
    let errorMessage: String?
    let onListen: () -> Void
    let onContinue: () -> Void
    let onUse: () -> Void
    let onDiscard: () -> Void
    @State private var isConfirmingDiscard = false

    private var formattedDuration: String {
        let seconds = max(0, Int(recording.duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(AppTheme.statusBusy)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.statusBusy.opacity(0.12), in: Rectangle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio recuperado")
                        .font(.system(size: 23, weight: .bold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                    Text(recoveryExplanation)
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(AppTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.statusError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.statusError.opacity(0.10), in: Rectangle())
            }

            HStack(spacing: 10) {
                recoveryButton(
                    title: isPlaying ? "Detener" : "Escuchar",
                    systemImage: isPlaying ? "stop.fill" : "play.fill",
                    isEnabled: recording.hasPlayableAudio,
                    action: onListen
                )
                recoveryButton(
                    title: "Continuar",
                    systemImage: "mic.fill",
                    action: onContinue
                )
            }

            Button(action: onUse) {
                Label("Usar y transcribir audio", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(canUseRecording ? AppTheme.accent : AppTheme.inkMuted, in: Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
            .disabled(isWorking || !canUseRecording || !recording.hasPlayableAudio)
            .accessibilityIdentifier("recovery-use-recording")

            if !canUseRecording {
                Text("Primero usá o descartá el otro audio pendiente; éste seguirá guardado.")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
            }

            Button("Descartar definitivamente", role: .destructive) {
                isConfirmingDiscard = true
            }
                .font(.system(size: 14, weight: .semibold, design: .default))
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isWorking)
                .accessibilityIdentifier("recovery-discard-recording")
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled(true)
        .alert("¿Borrar este audio definitivamente?", isPresented: $isConfirmingDiscard) {
            Button("Conservar audio", role: .cancel) {}
            Button("Sí, borrar definitivamente", role: .destructive, action: onDiscard)
        } message: {
            Text("Es la única acción que elimina los archivos recuperados. No se puede deshacer.")
        }
        .accessibilityIdentifier("voice-recording-recovery-sheet")
    }

    private var recoveryExplanation: String {
        let conversation = sessionName ?? "esta conversación"
        if recording.hasPlayableAudio {
            return "Encontramos \(formattedDuration) de audio de \(conversation) después del cierre. Podés escucharlo, continuar o pasarlo a texto."
        }
        return "Encontramos el registro de \(formattedDuration) de \(conversation) y conservamos todos sus archivos. Todavía no pudimos abrir el audio y no lo borraremos automáticamente."
    }

    private func recoveryButton(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                .overlay(Rectangle().stroke(AppTheme.divider.opacity(0.62), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
        .disabled(isWorking || !isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct VoiceDraftRecoverySheet: View {
    let draft: VoiceDraft
    let sessionName: String?
    let isPlaying: Bool
    let isWorking: Bool
    let onListen: () -> Void
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    @State private var isConfirmingDiscard = false

    private var formattedDuration: String {
        let seconds = max(0, Int(draft.duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform.badge.checkmark")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.gold.opacity(0.12), in: Rectangle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Tu audio sigue guardado")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Encontramos \(formattedDuration) de \(sessionName ?? "una conversación") al volver a abrir KyCode.")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message = draft.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.statusError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.statusError.opacity(0.10), in: Rectangle())
            }

            HStack(spacing: 10) {
                recoveryButton(
                    isPlaying ? "Detener" : "Escuchar",
                    systemImage: isPlaying ? "stop.fill" : "play.fill",
                    isEnabled: draft.hasAudioFile,
                    action: onListen
                )
                recoveryButton(
                    "Abrir conversación",
                    systemImage: "arrow.right.circle.fill",
                    action: onOpen
                )
            }

            Button(action: onRetry) {
                Label("Reintentar transcripción", systemImage: "text.badge.checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(draft.hasAudioFile ? AppTheme.accent : AppTheme.inkMuted, in: Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
            .disabled(isWorking || !draft.hasAudioFile)

            Text("El archivo permanece guardado hasta que el envío se confirme o decidas borrarlo explícitamente.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Descartar definitivamente", role: .destructive) {
                isConfirmingDiscard = true
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isWorking)
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled(true)
        .alert("¿Borrar este audio definitivamente?", isPresented: $isConfirmingDiscard) {
            Button("Conservar audio", role: .cancel) {}
            Button("Sí, borrar definitivamente", role: .destructive, action: onDiscard)
        } message: {
            Text("Se eliminarán el WAV y su registro de recuperación. No se puede deshacer.")
        }
        .accessibilityIdentifier("voice-draft-recovery-sheet")
    }

    private func recoveryButton(
        _ title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                .overlay(Rectangle().stroke(AppTheme.divider.opacity(0.62), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
        .disabled(isWorking || !isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct DashboardHeader: View {
    let layout: DashboardMetrics
    let isConnected: Bool
    let isStreaming: Bool
    let profiles: [KycodeConnectionProfile]
    let selectedProfileId: String
    let visibleCount: Int
    let minimizedCount: Int
    @Binding var showMinimizedSessions: Bool
    let onSelectProfile: (String) async -> Void
    let onOpenDesktop: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: layout.isTablet ? 0 : 12) {
            HStack(alignment: layout.isTablet ? .center : .top, spacing: layout.isTablet ? 10 : 12) {
                brandBlock

                Spacer(minLength: 8)

                headerActions
            }

            if !layout.isTablet {
                profileStrip
            }
        }
        .padding(.horizontal, layout.isTablet ? 10 : 0)
        .padding(.vertical, layout.isTablet ? 7 : 4)
        .background(
            layout.isTablet
                ? AppTheme.cardSurface.opacity(0.82)
                : Color.clear,
            in: Rectangle()
        )
        .overlay(
            Rectangle()
                .stroke(Color.clear, lineWidth: 1)
        )
    }

    private var brandBlock: some View {
        Group {
            if layout.isTablet {
                HStack(spacing: 7) {
                    Text("KyCode")
                        .font(.system(size: 17, weight: .bold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                        .layoutPriority(1)

                    compactStatusPill
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("KyCode")
                            .font(.system(size: layout.dashboardTitleSize, weight: .bold, design: .default))
                            .foregroundStyle(AppTheme.ink)
                            .layoutPriority(1)

                        compactStatusPill
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(syncStatusColor)
                                .frame(width: 8, height: 8)

                            Text(syncStatusLabel)
                                .font(.system(size: 13, weight: .bold, design: .default))
                                .foregroundStyle(AppTheme.ink)
                        }

                        if minimizedCount > 0 {
                            minimizedToggle
                        }
                    }
                }
            }
        }
    }

    private var compactStatusPill: some View {
        Text("\(visibleCount) visibles")
            .font(.system(size: layout.isTablet ? 10.5 : 12, weight: .bold, design: .default))
            .foregroundStyle(AppTheme.inkSoft)
            .lineLimit(1)
            .padding(.horizontal, layout.isTablet ? 8 : 9)
            .padding(.vertical, layout.isTablet ? 4 : 5)
            .background(AppTheme.cardSurfaceRaised, in: Rectangle())
            .overlay(
                Rectangle()
                    .stroke(Color.clear, lineWidth: 1)
            )
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if layout.isTablet, minimizedCount > 0 {
                minimizedToggle
            }

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(width: layout.isTablet ? 32 : 30, height: layout.isTablet ? 32 : 30)
                    .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                    .overlay(
                        Rectangle()
                            .stroke(Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")

            Menu {
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if minimizedCount > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showMinimizedSessions.toggle()
                        }
                    } label: {
                        Label(
                            showMinimizedSessions ? "Ocultar minimizadas" : "Ver minimizadas",
                            systemImage: showMinimizedSessions ? "eye.slash" : "eye"
                        )
                    }
                }

                Button {
                    onOpenDesktop()
                } label: {
                    Label("Desktop", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(width: layout.isTablet ? 32 : 30, height: layout.isTablet ? 32 : 30)
                    .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                    .overlay(
                        Rectangle()
                            .stroke(Color.clear, lineWidth: 1)
                    )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private var minimizedToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                showMinimizedSessions.toggle()
            }
        } label: {
            Label("\(minimizedCount)", systemImage: showMinimizedSessions ? "tray.full.fill" : "tray.full")
                .font(.system(size: layout.isTablet ? 12.5 : 12, weight: .bold, design: .default))
                .foregroundStyle(showMinimizedSessions ? AppTheme.ink : AppTheme.inkSoft)
                .padding(.horizontal, layout.isTablet ? 10 : 9)
                .padding(.vertical, layout.isTablet ? 6 : 5)
                .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                .overlay(
                    Rectangle()
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showMinimizedSessions ? "Ocultar minimizadas" : "Ver minimizadas")
    }

    private var profileStrip: some View {
        Group {
            if layout.isTablet {
                HStack(spacing: 8) {
                    ForEach(profiles) { profile in
                        profileButton(profile)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profiles) { profile in
                            profileButton(profile)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private func profileButton(_ profile: KycodeConnectionProfile) -> some View {
        Button {
            Task {
                await onSelectProfile(profile.id)
            }
        } label: {
            Text(kycodeCompactProfileLabel(for: profile))
                .font(.system(size: layout.isTablet ? 12.5 : 13, weight: .semibold, design: .default))
                .foregroundStyle(selectedProfileId == profile.id ? AppTheme.ink : AppTheme.inkSoft)
                .padding(.horizontal, layout.isTablet ? 12 : 12)
                .padding(.vertical, layout.isTablet ? 7 : 8)
                .background(
                    selectedProfileId == profile.id
                        ? AppTheme.cardSurfaceRaised
                        : AppTheme.cardSurface.opacity(0.72),
                    in: Rectangle()
                )
                .overlay(
                    Rectangle()
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var syncStatusLabel: String {
        KycodeInterfaceCopyPolicy.dashboardSyncStatus(
            isConnected: isConnected,
            isStreaming: isStreaming
        )
    }

    private var syncStatusColor: Color {
        if !isConnected {
            return AppTheme.inkMuted
        }
        return isStreaming ? AppTheme.statusReady : AppTheme.statusBusy
    }
}

private func kycodeCompactProfileLabel(for profile: KycodeConnectionProfile) -> String {
    switch profile.id {
    case "puky":
        return "Puky"
    case "personal", "this-mac", "remote-hub":
        return "Personal"
    case "all":
        return "Todo"
    default:
        return profile.name
    }
}

private struct KycodeCreateSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KycodeConnectionStore

    @State private var sessionName = ""
    @State private var defaultProject: KycodeProjectDirectory?
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorText: String?
    @State private var didAttemptSubmit = false
    @FocusState private var isNameFocused: Bool

    private var validationMessage: String? {
        guard didAttemptSubmit || !sessionName.isEmpty else { return nil }
        return KycodeSessionNameRules.validationMessage(for: sessionName)
    }

    private var canCreate: Bool {
        defaultProject != nil &&
            KycodeSessionNameRules.validationMessage(for: sessionName) == nil &&
            !isLoading &&
            !isCreating
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BreathingBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nombre de la sesión")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                                .foregroundStyle(AppTheme.ink)

                            TextField("Ej. Revisar el nuevo onboarding", text: $sessionName)
                                .textInputAutocapitalization(.sentences)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($isNameFocused)
                                .disabled(isCreating)
                                .font(.system(size: 17, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(
                                    AppTheme.cardSurfaceRaised,
                                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                                        .stroke(validationMessage == nil ? Color.clear : Color.red.opacity(0.65), lineWidth: 1)
                                )
                                .onSubmit {
                                    Task { await createNamedSession() }
                                }
                                .accessibilityLabel("Nombre de la sesión")
                                .accessibilityHint("Máximo \(KycodeSessionNameRules.maxLength) caracteres")
                                .accessibilityIdentifier("create-session-name")

                            HStack(alignment: .firstTextBaseline) {
                                if let validationMessage {
                                    Text(validationMessage)
                                        .foregroundStyle(Color.red.opacity(0.9))
                                } else {
                                    Text("Así aparecerá en tu lista de sesiones.")
                                        .foregroundStyle(AppTheme.inkMuted)
                                }

                                Spacer(minLength: 8)

                                Text("\(sessionName.count)/\(KycodeSessionNameRules.maxLength)")
                                    .foregroundStyle(
                                        sessionName.count > KycodeSessionNameRules.maxLength
                                            ? Color.red.opacity(0.9)
                                            : AppTheme.inkMuted
                                    )
                                    .accessibilityHidden(true)
                            }
                            .font(.system(size: 12, weight: .medium, design: .default))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Carpeta")
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(AppTheme.inkSoft)

                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 34, height: 34)
                                    .background(AppTheme.cloudAccentSoft, in: RoundedRectangle(cornerRadius: 9))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Carpeta predeterminada")
                                        .font(.system(size: 16, weight: .semibold, design: .default))
                                        .foregroundStyle(AppTheme.ink)

                                    if isLoading {
                                        Text("Resolviendo la carpeta predeterminada…")
                                            .foregroundStyle(AppTheme.inkMuted)
                                    } else if let defaultProject {
                                        Text(defaultProject.path)
                                            .foregroundStyle(AppTheme.inkMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else {
                                        Text("No se pudo resolver la carpeta.")
                                            .foregroundStyle(Color.red.opacity(0.9))
                                    }
                                }
                                .font(.system(size: 12, weight: .medium, design: .default))

                                Spacer(minLength: 8)

                                if isLoading {
                                    ProgressView()
                                        .tint(AppTheme.accent)
                                } else if defaultProject != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(AppTheme.accent)
                                } else {
                                    Button("Reintentar") {
                                        Task { await loadDefaultProject() }
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(minHeight: 44)
                                    .disabled(isCreating)
                                    .accessibilityHint("Vuelve a consultar la carpeta en la Mac")
                                }
                            }
                            .padding(16)
                            .background(
                                AppTheme.cardSurface,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                            )
                            .accessibilityIdentifier("create-session-default-project")
                        }

                        if let errorText, !errorText.isEmpty {
                            InlineErrorCard(text: errorText)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                }

                if isCreating {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()

                    VStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AppTheme.accent)
                            .scaleEffect(1.08)

                        VStack(spacing: 4) {
                            Text("Creando sesión...")
                                .font(.system(size: 17, weight: .bold, design: .default))
                                .foregroundStyle(AppTheme.ink)

                            Text(KycodeSessionNameRules.normalized(sessionName))
                                .font(.system(size: 13, weight: .medium, design: .default))
                                .foregroundStyle(AppTheme.inkSoft)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 300)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                            .stroke(Color.clear, lineWidth: 1)
                    )
                    .shadow(color: AppTheme.shadowCard, radius: 18, x: 0, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
                }
            }
            .navigationTitle("Nueva sesión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        dismiss()
                    }
                    .disabled(isCreating)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Button {
                        Task { await createNamedSession() }
                    } label: {
                        HStack(spacing: 8) {
                            if isCreating {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.85)
                            }
                            Text(isCreating ? "Creando..." : "Crear sesión")
                                .font(.system(size: 15, weight: .semibold, design: .default))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            canCreate ? AppTheme.accent : AppTheme.inkMuted,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canCreate)
                    .accessibilityIdentifier("create-session-confirm")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
                }
            }
            .task {
                isNameFocused = true
                await loadDefaultProject()
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private func loadDefaultProject() async {
        if isLoading { return }
        isLoading = true
        errorText = nil
        do {
            defaultProject = try await store.fetchDefaultProject()
        } catch {
            defaultProject = nil
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func createNamedSession() async {
        guard !isCreating else { return }
        didAttemptSubmit = true
        if KycodeSessionNameRules.validationMessage(for: sessionName) != nil {
            errorText = nil
            isNameFocused = true
            return
        }
        guard !isLoading else { return }
        guard let defaultProject else {
            errorText = "No pude resolver la carpeta predeterminada. Reintentá."
            return
        }

        isNameFocused = false
        isCreating = true
        errorText = nil
        do {
            _ = try await store.createSession(
                projectPath: defaultProject.path,
                sessionName: sessionName
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isNameFocused = true
        }
        isCreating = false
    }
}

private extension KycodeSessionSummary {
    var dashboardProjectActionLabel: String {
        collaborationProjectDisplayName ?? "Proyecto"
    }

    var dashboardCollaborationTitle: String {
        "\(dashboardProjectActionLabel): \(collaborationSessionName)"
    }

    var supportsMobileBridgeMessaging: Bool {
        if canSend { return true }
        return unsupportedReason == "missing_provider_session"
    }

    var usesPristineReadyVisualState: Bool {
        let preview = lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = runtimeStatusDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return messageCount == 0 && preview.isEmpty && detail.isEmpty
    }

    var visualActivityStatus: String {
        if usesPristineReadyVisualState && (activityStatus == "working" || activityStatus == "idle") {
            return "ready"
        }
        return activityStatus
    }

    var dashboardAccessibilityStatus: String {
        switch visualActivityStatus {
        case "working": return "trabajando"
        case "approval": return "esperando aprobación"
        case "error": return "con error"
        case "ready", "done": return "lista"
        case "idle": return "inactiva"
        default: return "sin conexión"
        }
    }
}

private struct PendingCreatedSessionsView: View {
    let entries: [KycodeRecentCreatedSession]
    let layout: DashboardMetrics

    var body: some View {
        VStack(spacing: layout.isTablet ? 6 : 8) {
            ForEach(entries) { entry in
                PendingCreatedSessionCard(entry: entry, layout: layout)
            }
        }
    }
}

private struct PendingCreatedSessionCard: View {
    let entry: KycodeRecentCreatedSession
    let layout: DashboardMetrics

    private var isDelayed: Bool {
        entry.status.lowercased() == "delayed"
    }

    private var targetName: String {
        switch entry.profileId?.lowercased() {
        case "puky": return "Puky"
        case "personal": return "Mac personal"
        default: return "La Mac"
        }
    }

    private var sessionTitle: String {
        let normalizedName = entry.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedName.isEmpty ? "Nueva sesión" : normalizedName
    }

    private var statusText: String {
        isDelayed ? "\(targetName) está tardando más de lo habitual" : "Creando \(sessionTitle)…"
    }

    private var detailText: String {
        isDelayed
            ? "Seguimos comprobando; podés continuar usando Fermín."
            : "\(targetName) aceptó el pedido · \(entry.projectName)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isDelayed {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(AppTheme.accent)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.system(size: 14, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.ink)

                Text(detailText)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, layout.isTablet ? 12 : 14)
        .padding(.vertical, layout.isTablet ? 10 : 12)
        .background(
            AppTheme.cloudAccentSoft,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
        .accessibilityValue(detailText)
        .accessibilityHint("La sesión aparecerá automáticamente cuando esté lista.")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("pending-created-session-\(entry.sessionId)")
    }
}

#if DEBUG
struct PendingCreatedSessionUITestHarness: View {
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            PendingCreatedSessionCard(
                entry: KycodeRecentCreatedSession(
                    sessionId: "ui-pending",
                    windowId: nil,
                    projectPath: "/Users/example/projects",
                    projectName: "projects",
                    sessionName: "Auditar onboarding",
                    profileId: "puky",
                    createdAt: Date(),
                    status: "pending"
                ),
                layout: DashboardMetrics.resolve(for: CGSize(width: 390, height: 844))
            )
            .padding(20)
        }
    }
}
#endif

private struct SessionNameEditorOverlay: View {
    let target: SessionRenameTarget
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var draftName: String
    @State private var isConfirmingImplicitDiscard = false
    @FocusState private var isFocused: Bool

    init(
        target: SessionRenameTarget,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onCommit = onCommit
        _draftName = State(
            initialValue: String((target.draftName ?? target.currentName).prefix(SessionRenameRules.maxLength))
        )
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var originalName: String {
        String(target.currentName.prefix(SessionRenameRules.maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingChange: Bool {
        trimmedName != originalName
    }

    private var canCommit: Bool {
        !trimmedName.isEmpty
            && trimmedName.count <= SessionRenameRules.maxLength
            && hasPendingChange
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    requestImplicitDismissal()
                }

            editorCard
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onEnded { value in
                            if value.translation.height > 58 {
                                requestImplicitDismissal()
                            }
                        }
                )
        }
        .animation(.easeInOut(duration: 0.18), value: canCommit)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            isFocused = true
        }
        .alert("¿Descartar el nuevo nombre?", isPresented: $isConfirmingImplicitDiscard) {
            Button("Seguir editando", role: .cancel) {
                isFocused = true
            }
            Button("Descartar", role: .destructive) {
                onCancel()
            }
        } message: {
            Text("El cambio todavía no se guardó.")
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancelar") {
                    onCancel()
                }
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.inkMuted)
                .compactTouchTarget()
                .accessibilityIdentifier("rename-session-cancel")

                Spacer()

                Button(hasPendingChange ? "Guardar" : "Sin cambios") {
                    commit()
                }
                .font(.system(size: 15, weight: .bold, design: .default))
                .foregroundStyle(canCommit ? AppTheme.accent : AppTheme.inkMuted)
                .compactTouchTarget()
                .disabled(!canCommit)
                .accessibilityHint(
                    hasPendingChange ? "Guarda el nuevo nombre" : "Editá el nombre para guardar"
                )
                .accessibilityIdentifier("rename-session-save")
            }

            TextField("Nombre de sesión", text: $draftName)
                .font(.system(size: 20, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit {
                    commit()
                }
                .onChange(of: draftName) { _, value in
                    if value.count > SessionRenameRules.maxLength {
                        draftName = String(value.prefix(SessionRenameRules.maxLength))
                    }
                }
                .accessibilityIdentifier("rename-session-field")
                .padding(.leading, 12)
                .padding(.trailing, draftName.isEmpty ? 12 : 52)
                .padding(.vertical, 11)
                .background(
                    AppTheme.cardSurfaceRaised,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
                .overlay(alignment: .trailing) {
                    if !draftName.isEmpty {
                        Button {
                            draftName = ""
                            isFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppTheme.inkMuted)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Borrar nombre")
                        .accessibilityHint("Vacía el campo para escribir un nombre nuevo")
                        .accessibilityIdentifier("rename-session-clear")
                        .padding(.trailing, 4)
                    }
                }

            HStack {
                Text("\(draftName.count)/\(SessionRenameRules.maxLength)")
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)

                Spacer()

                if trimmedName.isEmpty {
                    Text("Nombre requerido")
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.statusError)
                }
            }
        }
        .padding(14)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadowCard, radius: 18, x: 0, y: 10)
    }

    private func commit() {
        guard !trimmedName.isEmpty else {
            RenameSessionHaptics.shared.nameError()
            return
        }
        guard canCommit else { return }
        onCommit(trimmedName)
    }

    private func requestImplicitDismissal() {
        guard hasPendingChange else {
            onCancel()
            return
        }
        isConfirmingImplicitDiscard = true
    }
}

#if DEBUG
struct SessionNameEditorUITestHarness: View {
    @State private var target: SessionRenameTarget? = SessionRenameTarget(
        windowId: "rename-ui-test",
        currentName: "Plan semanal"
    )
    @State private var savedName: String?
    @State private var saveAttemptCount = 0
    @State private var errorMessage: String?

    private let failsFirstSave = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RENAME_FAIL_ONCE"] == "1"

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let savedName {
                Text("Guardado: \(savedName)")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityIdentifier("rename-session-saved")
            }

            if let target {
                SessionNameEditorOverlay(
                    target: target,
                    onCancel: { self.target = nil },
                    onCommit: { name in
                        self.target = nil
                        saveAttemptCount += 1
                        if failsFirstSave && saveAttemptCount == 1 {
                            self.target = SessionRenameTarget(
                                windowId: target.windowId,
                                currentName: target.currentName,
                                draftName: name
                            )
                            errorMessage = SessionRenameRules.retryMessage(
                                serverMessage: "Conexión interrumpida"
                            )
                        } else {
                            savedName = name
                        }
                    }
                )
            }
        }
        .alert("No se pudo renombrar", isPresented: errorBinding) {
            Button(KycodeInterfaceCopyPolicy.dismissErrorAction, role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "El nombre sigue en el editor, listo para reintentar.")
        }
    }
}
#endif

// Punto de estado: respira cuando la sesión está "trabajando"
// (scale 1→1.12, opacity 0.55→1, 2.4s easeInOut). Al asentarse, queda fijo.
private struct BreathingStatusDot: View {
    let color: Color
    let isBusy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(isBusy && animate && !reduceMotion ? 1.12 : 1.0)
            .opacity(isBusy && !reduceMotion ? (animate ? 1.0 : 0.55) : 1.0)
            .animation(
                isBusy && !reduceMotion
                    ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.3),
                value: animate
            )
            .onAppear { animate = isBusy && !reduceMotion }
            .onChange(of: isBusy) { _, busy in animate = busy && !reduceMotion }
            .onChange(of: reduceMotion) { _, shouldReduce in
                animate = isBusy && !shouldReduce
            }
    }
}

private struct SessionConsoleCard: View {
    enum Presentation {
        case normal
        case minimized
    }

    let session: KycodeSessionSummary
    var presentation: Presentation = .normal
    let layout: DashboardMetrics
    var displayIndex: Int? = nil
    var totalCount: Int? = nil
    var isPinned = false
    var hasDraft = false
    var isLastOpened = false
    var isReordering = false
    var searchMatchHint: String? = nil
    var sourceLabel: String? = nil

    private var statusColor: Color {
        if presentation == .minimized {
            return AppTheme.inkMuted
        }
        switch session.visualActivityStatus {
        case "working", "approval":
            return AppTheme.statusBusy
        case "error":
            return AppTheme.statusError
        case "ready", "done":
            return AppTheme.statusReady
        case "idle":
            return AppTheme.inkMuted
        default:
            return AppTheme.inkMuted
        }
    }

    private var isBusyStatus: Bool {
        guard presentation == .normal else { return false }
        return session.visualActivityStatus == "working" || session.visualActivityStatus == "approval"
    }

    private var statusLabel: String {
        if presentation == .minimized {
            return "Minimizada"
        }
        return KycodeInterfaceCopyPolicy.sessionActivityStatus(session.visualActivityStatus)
    }

    private var compactModelLabel: String? {
        guard let raw = session.runtimeModelDisplayName ?? session.agentEngine?.displayName else {
            return nil
        }
        let normalized = raw
            .uppercased()
            .replacingOccurrences(of: "GPT-5.6-", with: "")
            .replacingOccurrences(of: "GPT‑5.6‑", with: "")
        return normalized
    }

    private var compactEffortLabel: String? {
        let value = session.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return value.isEmpty ? nil : value
    }

    private var compactSourceLabel: String? {
        guard let sourceLabel else { return nil }
        return sourceLabel == "Mac personal" ? "Personal" : sourceLabel
    }

    private var headerMetadataLabel: String? {
        let values = [compactModelLabel, compactEffortLabel, compactSourceLabel?.uppercased()]
            .compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var cachedConversationMessages: [KycodeMessage] {
        guard let messages = session.messages else { return [] }
        return Array(
            messages
                .reversed()
                .filter { message in
                    let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return (role == "user" || role == "assistant")
                        && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .prefix(6)
        )
    }

    private var initialPromptContext: String? {
        for candidate in [session.originalPrompt, session.rawPrompt] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private var secondaryText: String {
        let cachedMessages = cachedConversationMessages
        if !cachedMessages.isEmpty {
            var sections = cachedMessages.enumerated().map { index, message in
                let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let speaker = role == "user" ? "Vos" : "KyCode"
                let moment = index == 0 ? "ahora" : "antes"
                return "**\(speaker) · \(moment)**\n\(message.content)"
            }

            if sections.count < 3,
               let initialPromptContext,
               !cachedMessages.contains(where: {
                   comparablePreviewText($0.content) == comparablePreviewText(initialPromptContext)
               }) {
                sections.append("**Tu pedido inicial**\n\(initialPromptContext)")
            }
            return sections.joined(separator: "\n\n")
        }
        let preview = session.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview, !preview.isEmpty {
            var sections = ["**Último mensaje**\n\(preview)"]
            if let initialPromptContext,
               comparablePreviewText(preview) != comparablePreviewText(initialPromptContext) {
                sections.append("**Tu pedido inicial**\n\(initialPromptContext)")
            }
            return sections.joined(separator: "\n\n")
        }
        if let initialPromptContext {
            return "**Tu pedido inicial**\n\(initialPromptContext)"
        }
        let project = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let project, !project.isEmpty {
            return "**Proyecto**\n\(project)"
        }
        return "Sin mensajes todavía"
    }

    private func comparablePreviewText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private var resolvedCardHeight: CGFloat? {
        guard layout.fixedCardHeight else { return nil }
        let hasRichCachedContext = cachedConversationMessages.count >= 2
            || secondaryText.count >= 280
        guard !hasRichCachedContext else { return layout.cardHeight }
        return min(layout.cardHeight, layout.isTabletLandscape ? 210 : 240)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.collaborationSessionName)
                    .font(.system(size: layout.isTablet ? 18 : 17, weight: .semibold, design: .default))
                    .tracking(-0.1)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let searchMatchHint {
                    Text(searchMatchHint)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.12), in: Rectangle())
                        .accessibilityLabel("Coincide en \(searchMatchHint)")
                }

                Text(relativeTime(from: session.updatedAt))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.inkMuted)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.inkMuted)
                    .accessibilityHidden(true)
            }

            MarkdownInlineText(
                attributed: MarkdownMessageRenderer.previewText(for: secondaryText),
                isUser: false,
                font: .system(size: layout.isTablet ? 16 : 14, weight: .regular, design: .default)
            )
            .foregroundColor(AppTheme.inkSoft)
            .lineLimit(layout.previewLineLimit)
            .lineSpacing(layout.isTablet ? 5 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: layout.isTablet ? 8 : 2)

            rowFooter
                .padding(.top, layout.isTablet ? 4 : 2)
                .padding(.trailing, layout.isTablet ? 58 : 48)
        }
        .padding(.vertical, layout.isTablet ? 14 : 9)
        .padding(.horizontal, layout.isTablet ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: resolvedCardHeight, alignment: .top)
        .v2RaisedSurface(fill: AppTheme.cardSurface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(statusColor)
                .frame(width: presentation == .minimized ? 2 : 3)
        }
        .opacity(presentation == .minimized ? 0.7 : 1)
        .scaleEffect(isReordering ? 0.985 : 1)
        .overlay {
            if isReordering {
                Rectangle()
                    .stroke(AppTheme.accent.opacity(0.42), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var rowFooter: some View {
        HStack(spacing: 6) {
            BreathingStatusDot(color: statusColor, isBusy: isBusyStatus)

            Text(statusLabel)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(statusColor)
                .lineLimit(1)

            if let headerMetadataLabel {
                Text("·  \(headerMetadataLabel)")
                    .font(.system(size: layout.cardMetaSize, weight: .semibold, design: .monospaced))
                    .tracking(0.25)
                    .foregroundStyle(AppTheme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityLabel("Modelo, razonamiento y origen \(headerMetadataLabel)")
                    .accessibilityIdentifier("session-metadata-\(session.windowId)")
            }

            if hasDraft {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("Borrador")
            } else if isLastOpened {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.inkSoft)
                    .accessibilityLabel("Reciente")
            } else if isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("Fijada")
            }

            if !session.supportsMobileBridgeMessaging {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
                    .accessibilityLabel("Solo lectura")
            }

            Spacer(minLength: 0)
        }
    }

    private func relativeTime(from timestamp: Double) -> String {
        guard timestamp > 0 else { return "ahora" }
        let delta = max(0, Date().timeIntervalSince1970 - timestamp / 1000)
        if delta < 60 { return "ahora" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        return "\(Int(delta / 86_400))d"
    }
}

#if DEBUG
struct DashboardSessionMetadataUITestHarness: View {
    private let session = KycodeSessionSummary(
        windowId: "metadata-harness",
        sessionId: "metadata-harness-session",
        engine: "codex",
        model: "gpt-5.6-sol",
        reasoningEffort: "max",
        providerSessionId: nil,
        providerSessionPath: nil,
        projectKey: "fermin-code",
        projectPath: "/tmp/fermin-code",
        projectName: "Fermín Code",
        windowName: "Continuar Fermín Code",
        displayName: "Continuar Fermín Code",
        sidecarMode: "mobile",
        sidecarUrl: nil,
        activityStatus: "ready",
        runtimeStatus: "READY",
        runtimeStatusDetail: nil,
        features: nil,
        messageCount: 2,
        updatedAt: 1_786_000_000_000,
        createdAt: 1_786_000_000_000,
        rawPrompt: nil,
        originalPrompt: nil,
        improvedPrompt: nil,
        lastMessagePreview: "El estado actual quedó preservado y listo para continuar.",
        isMinimized: false,
        canSend: true,
        canControlFeatures: true,
        unsupportedReason: nil,
        messages: nil
    )

    var body: some View {
        GeometryReader { geometry in
            let layout = DashboardMetrics.resolve(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Sesiones")
                        .font(.title.bold())
                        .foregroundStyle(AppTheme.ink)

                    SessionConsoleCard(
                        session: session,
                        layout: layout,
                        displayIndex: 0,
                        totalCount: 1,
                        sourceLabel: "Mac personal"
                    )
                }
                .padding(20)
            }
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }
}
#endif

private struct DashboardStatusBadge: View {
    let label: String
    let color: Color
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
            Text(label)
                .font(.system(size: compact ? 10 : 10, weight: .bold, design: .default))
                .lineLimit(1)
        }
        .foregroundStyle(AppTheme.ink)
        .padding(.horizontal, compact ? 6 : 0)
        .padding(.vertical, compact ? 3 : 0)
        .background(compact ? color.opacity(0.12) : Color.clear, in: Rectangle())
    }
}

private struct DashboardActionNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(AppTheme.cardSurfaceRaised, in: Rectangle())
    }
}

private struct SessionReorderModeBar: View {
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ordenar sesiones")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text("Arrastrá cada sesión a su lugar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.inkMuted)
            }
            Spacer(minLength: 8)
            Button("Listo", action: onDone)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 52, minHeight: 44)
                .buttonStyle(PressableButtonStyle(scale: 0.95, opacity: 0.74))
                .accessibilityIdentifier("finish-session-reorder")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 52)
        .background(AppTheme.cardSurfaceRaised, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.55))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SessionReorderDropDelegate: DropDelegate {
    let targetWindowId: String
    @Binding var draggedWindowId: String?
    let onMove: (String, String) -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedWindowId, draggedWindowId != targetWindowId else { return }
        onMove(draggedWindowId, targetWindowId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedWindowId = nil
        onDrop()
        return true
    }
}

// Estado como etiqueta de color (punto + palabra), no pill.
private struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(color)
        }
    }
}

private extension View {
    func compactTouchTarget(minWidth: CGFloat = 44) -> some View {
        frame(minWidth: minWidth, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private struct InlineErrorCard: View {
    let text: String
    var onDismiss: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if onDismiss != nil || onCopy != nil {
                HStack(spacing: 8) {
                    if let onCopy {
                        Button("Copiar diagnóstico", action: onCopy)
                            .compactTouchTarget()
                            .accessibilityLabel("Copiar diagnóstico de conexión")
                            .accessibilityIdentifier("connection-error-copy")
                    }
                    Spacer()
                    if let onDismiss {
                        Button("Cerrar", action: onDismiss)
                            .compactTouchTarget()
                            .accessibilityLabel("Cerrar error")
                            .accessibilityIdentifier("connection-error-dismiss")
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cloudDangerBackground, in: Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-error-card")
    }
}

private struct ConnectionNoticeCard: View {
    let text: String
    let isBusy: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if isBusy {
                ProgressView()
                    .tint(AppTheme.ink)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.cloudWarning)
            }

            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.accent)
                    .compactTouchTarget()
                    .accessibilityIdentifier("connection-notice-action")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurfaceRaised, in: Rectangle())
    }
}

struct ComposerUndoBanner: View {
    let message: String
    let accessibilityHint: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Deshacer", action: onUndo)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint(accessibilityHint)
                .accessibilityIdentifier("composer-undo")
        }
        .padding(.horizontal, 12)
        .background(AppTheme.cardSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.m))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-undo-notice")
    }
}

private struct EmptyDashboardState: View {
    let minimizedCount: Int
    let showMinimizedSessions: Bool
    let selectedProfileName: String
    let accessibilityIdentifier: String
    let onCreateSession: () -> Void
    let onShowMinimized: () -> Void

    private var hasHiddenMinimizedSessions: Bool {
        minimizedCount > 0 && !showMinimizedSessions
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.ink)

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.inkMuted)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Button(action: hasHiddenMinimizedSessions ? onShowMinimized : onCreateSession) {
                Label(
                    hasHiddenMinimizedSessions ? "Mostrar minimizadas" : "Nueva sesión",
                    systemImage: hasHiddenMinimizedSessions ? "rectangle.stack" : "plus"
                )
                .font(.system(size: 14, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .v2RaisedSurface(
                    fill: AppTheme.accent,
                    topLight: AppTheme.surfaceTopLightStrong
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.97, opacity: 0.9))
            .padding(.top, 6)
            .accessibilityLabel(hasHiddenMinimizedSessions ? "Mostrar minimizadas" : "Nueva sesión")
            .accessibilityHint(
                hasHiddenMinimizedSessions
                    ? "Muestra las sesiones ocultas en el tablero"
                    : "Abre el formulario para crear una sesión"
            )
            .accessibilityIdentifier(
                hasHiddenMinimizedSessions ? "dashboard-show-minimized" : "dashboard-new-session"
            )
        }
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
        .padding(.horizontal, 24)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var title: String {
        KycodeDashboardEmptyCopyPolicy.title(
            minimizedCount: minimizedCount,
            showMinimizedSessions: showMinimizedSessions
        )
    }

    private var message: String {
        if minimizedCount > 0, !showMinimizedSessions {
            return "Tenés \(minimizedCount) sesión\(minimizedCount == 1 ? "" : "es") minimizada\(minimizedCount == 1 ? "" : "s")."
        }
        if selectedProfileName == "Todo" {
            return "Elegí una Mac y creá tu primera sesión."
        }
        return "Creá una sesión en \(selectedProfileName) para empezar."
    }
}

private struct DashboardLoadingState: View {
    let layout: DashboardMetrics

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 9) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(AppTheme.accent)
                Text("Cargando sesiones…")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: layout.columns, spacing: layout.gridSpacing) {
                ForEach(0..<(layout.isTablet ? 4 : 2), id: \.self) { _ in
                    SkeletonDashboardCard(layout: layout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cargando sesiones")
        .accessibilityIdentifier("dashboard-loading")
    }
}

private struct DashboardUnavailableState: View {
    let sourceName: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppTheme.cloudWarning)
            Text("No pudimos cargar tus sesiones")
                .font(.system(size: 18, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.ink)
            Text("No pudimos consultar \(sourceName). Reintentá cuando quieras.")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button("Reintentar", action: onRetry)
                .font(.system(size: 14, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .v2RaisedSurface(
                    fill: AppTheme.accent,
                    topLight: AppTheme.surfaceTopLightStrong
                )
                .buttonStyle(PressableButtonStyle(scale: 0.97, opacity: 0.9))
                .accessibilityHint("Vuelve a buscar sesiones en la Mac seleccionada")
                .accessibilityIdentifier("dashboard-state-retry")
        }
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-state-error")
    }
}

private struct DashboardSnapshotNotice: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.cloudWarning)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.ink)
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Reintentar", action: onRetry)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint("Actualiza las sesiones de todas las fuentes")
                .accessibilityIdentifier("dashboard-state-retry")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.cardSurfaceRaised,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct SkeletonDashboardCard: View {
    let layout: DashboardMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var shouldAnimate: Bool {
        !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: width, height: height)
            // Barrido de luz tenue que cruza (no opacidad parpadeante).
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color.clear, Color.white.opacity(0.10), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: shouldAnimate && sweep ? geo.size.width : -geo.size.width * 0.08)
                }
            )
            .clipShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar(width: 168, height: 15)
            bar(width: nil, height: 13)
            bar(width: 132, height: 12)
        }
        .padding(.vertical, 15)
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: layout.fixedCardHeight ? layout.cardHeight : nil, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.inkMuted.opacity(0.4))
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.lineSoft)
                .frame(height: 1)
                .padding(.leading, 16)
        }
        .animation(
            shouldAnimate ? .easeInOut(duration: 1.4).repeatForever(autoreverses: false) : nil,
            value: sweep
        )
        .onAppear { sweep = shouldAnimate }
        .onChange(of: reduceMotion) { _, _ in sweep = shouldAnimate }
    }
}

enum RuntimeModelSwitcherPresentation {
    static func compactModelLabel(_ model: String?) -> String {
        let normalized = model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return "MODELO" }
        if normalized == "gpt-5.6" { return "SOL" }
        if normalized.hasPrefix("gpt-5.6-") {
            return String(normalized.dropFirst("gpt-5.6-".count)).uppercased()
        }
        return normalized.split(separator: "-").last.map(String.init)?.uppercased() ?? "MODELO"
    }

    static func compactEffortLabel(_ effort: String?) -> String {
        let normalized = effort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return normalized.isEmpty ? "AUTO" : normalized
    }

    static func accessibilityValue(model: String?, effort: String?) -> String {
        "\(compactModelLabel(model)), \(compactEffortLabel(effort))"
    }
}

enum RuntimeModelControlPolicy {
    /// `canControlFeatures` and `unsupportedReason` are intentionally not gates:
    /// older snapshots and remote relays may advertise those generic fields
    /// incorrectly. A Codex session gets the control and the dedicated live
    /// catalog endpoint remains authoritative for support and transport errors.
    static func isAvailable(
        engine: KycodeAgentEngine?,
        advertisedFeatureControl: Bool?,
        unsupportedReason: String?
    ) -> Bool {
        _ = advertisedFeatureControl
        _ = unsupportedReason
        return engine == .codex
    }
}

struct RuntimeModelSwitcherButton: View {
    let model: String?
    let reasoningEffort: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(RuntimeModelSwitcherPresentation.compactModelLabel(model))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                Text("·")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkMuted)
                Text(RuntimeModelSwitcherPresentation.compactEffortLabel(reasoningEffort))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkMuted)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(AppTheme.inkSoft)
            .frame(width: 72, height: 28)
            .v2RaisedSurface(fill: AppTheme.cardSurfaceRaised)
            .frame(width: 72, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.9))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("Modelo y razonamiento")
        .accessibilityValue(
            RuntimeModelSwitcherPresentation.accessibilityValue(
                model: model,
                effort: reasoningEffort
            )
        )
        .accessibilityHint("Abre el selector de modelo y nivel de razonamiento")
        .accessibilityIdentifier("detail-runtime-model-switcher")
    }
}

private struct KycodeRuntimeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let currentModel: String?
    let currentReasoningEffort: String?
    let loadModels: () async throws -> [KycodeAvailableModel]
    /// Returns nil on success or a user-presentable transport/runtime error.
    let applySettings: (String, String) async -> String?

    @State private var models: [KycodeAvailableModel] = []
    @State private var selectedModel = ""
    @State private var selectedEffort = ""
    @State private var baselineModel = ""
    @State private var baselineEffort = ""
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var errorText: String?

    private var selectedModelEntry: KycodeAvailableModel? {
        models.first {
            $0.id.caseInsensitiveCompare(selectedModel) == .orderedSame ||
                $0.model.caseInsensitiveCompare(selectedModel) == .orderedSame
        }
    }

    private var effortOptions: [KycodeReasoningEffortOption] {
        selectedModelEntry?.supportedReasoningEfforts ?? []
    }

    private var hasPendingChange: Bool {
        selectedModel.caseInsensitiveCompare(baselineModel) != .orderedSame ||
            selectedEffort.caseInsensitiveCompare(baselineEffort) != .orderedSame
    }

    private var canApply: Bool {
        !isLoading &&
            !isApplying &&
            !selectedModel.isEmpty &&
            !selectedEffort.isEmpty &&
            hasPendingChange
    }

    private var applyButtonTitle: String {
        if isApplying {
            return "Aplicando…"
        }
        if !hasPendingChange {
            return "Sin cambios"
        }
        return errorText == nil ? "Aplicar a la sesión" : "Reintentar cambio"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                if isLoading {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView("Consultando la sesión Codex…")
                            .tint(AppTheme.accent)
                        Spacer()
                    }
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 2) {
                                runtimeSelectionLabel("Modelo")
                                    .accessibilityIdentifier("runtime-model-label")
                                runtimeModelPicker
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 52,
                                        alignment: .leading
                                    )
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        } else {
                            HStack(spacing: 12) {
                                runtimeSelectionLabel("Modelo")
                                    .accessibilityIdentifier("runtime-model-label")
                                Spacer(minLength: 12)
                                runtimeModelPicker
                                    .frame(minWidth: 132, minHeight: 52, alignment: .trailing)
                            }
                            .padding(.leading, 16)
                        }

                        Divider().overlay(AppTheme.divider)

                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 2) {
                                runtimeSelectionLabel("Razonamiento")
                                    .accessibilityIdentifier("runtime-reasoning-label")
                                runtimeEffortPicker
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 52,
                                        alignment: .leading
                                    )
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        } else {
                            HStack(spacing: 12) {
                                runtimeSelectionLabel("Razonamiento")
                                    .accessibilityIdentifier("runtime-reasoning-label")
                                Spacer(minLength: 12)
                                runtimeEffortPicker
                                    .frame(minWidth: 132, minHeight: 52, alignment: .trailing)
                            }
                            .padding(.leading, 16)
                        }

                        if let description = effortOptions.first(where: {
                            $0.reasoningEffort.caseInsensitiveCompare(selectedEffort) == .orderedSame
                        })?.description,
                           !description.isEmpty {
                            Text(description)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(AppTheme.inkMuted)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                    .accessibilityElement(children: .contain)

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.red)
                            .accessibilityIdentifier("runtime-settings-error")

                        if models.isEmpty {
                            Button("Reintentar catálogo") {
                                Task { await loadCatalog(force: true) }
                            }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                            .compactTouchTarget()
                            .accessibilityIdentifier("runtime-catalog-retry")
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        applySelection()
                    } label: {
                        HStack(spacing: 8) {
                            if isApplying {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(applyButtonTitle)
                                .font(.headline.weight(.bold))
                        }
                        .foregroundStyle(hasPendingChange ? Color.white : AppTheme.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            hasPendingChange ? AppTheme.accent : AppTheme.cardSurfaceRaised,
                            in: Rectangle()
                        )
                        .overlay {
                            Rectangle()
                                .stroke(
                                    hasPendingChange ? Color.clear : AppTheme.divider,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.92))
                    .disabled(!canApply)
                    .accessibilityIdentifier("runtime-settings-apply")
                }
            }
            .padding(20)
            .background(AppTheme.backgroundSolid.ignoresSafeArea())
            .navigationTitle("Modelo y razonamiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasPendingChange ? "Cancelar" : "Cerrar") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.inkSoft)
                    .disabled(isApplying)
                    .accessibilityHint(
                        hasPendingChange
                            ? "Descarta la selección sin aplicarla"
                            : "Vuelve a la sesión"
                    )
                }
            }
            .task {
                await loadCatalog()
            }
            .onChange(of: selectedModel) { _, _ in
                reconcileEffortSelection()
            }
        }
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize
                ? [.medium, .large]
                : [.height(390), .large]
        )
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isApplying)
    }

    private func runtimeSelectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(AppTheme.inkMuted)
    }

    private var runtimeModelPicker: some View {
        Picker("Modelo", selection: $selectedModel) {
            ForEach(models) { model in
                Text(model.displayName).tag(model.model)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(AppTheme.ink)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityLabel("Modelo")
        .accessibilityIdentifier("runtime-model-picker")
    }

    private var runtimeEffortPicker: some View {
        Picker("Razonamiento", selection: $selectedEffort) {
            ForEach(effortOptions, id: \.reasoningEffort) { option in
                Text(option.reasoningEffort.uppercased())
                    .tag(option.reasoningEffort)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(AppTheme.ink)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityLabel("Razonamiento")
        .accessibilityIdentifier("runtime-reasoning-picker")
    }

    @MainActor
    private func loadCatalog(force: Bool = false) async {
        guard force || models.isEmpty else { return }
        isLoading = true
        errorText = nil
        do {
            let loaded = try await loadModels()
            models = KycodeRuntimeModelPolicy.supportedModels(from: loaded)
                .filter { $0.hidden != true }
            guard !models.isEmpty else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Codex no informó modelos disponibles."]
                )
            }
            let normalizedCurrent = currentModel?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let initialModel = models.first {
                $0.id.caseInsensitiveCompare(normalizedCurrent) == .orderedSame ||
                    $0.model.caseInsensitiveCompare(normalizedCurrent) == .orderedSame
            } ?? models.first(where: { $0.isDefault == true }) ?? models[0]
            selectedModel = initialModel.model

            let normalizedEffort = currentReasoningEffort?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            selectedEffort = initialModel.supportedReasoningEfforts.contains {
                $0.reasoningEffort.caseInsensitiveCompare(normalizedEffort) == .orderedSame
            } ? normalizedEffort : initialModel.defaultReasoningEffort
            reconcileEffortSelection()
            baselineModel = selectedModel
            baselineEffort = selectedEffort
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func reconcileEffortSelection() {
        guard let model = selectedModelEntry else { return }
        let supportsSelection = model.supportedReasoningEfforts.contains {
            $0.reasoningEffort.caseInsensitiveCompare(selectedEffort) == .orderedSame
        }
        if !supportsSelection {
            selectedEffort = model.defaultReasoningEffort
        }
    }

    private func applySelection() {
        guard canApply else { return }
        isApplying = true
        errorText = nil
        Task {
            let failureMessage = await applySettings(selectedModel, selectedEffort)
            await MainActor.run {
                isApplying = false
                if failureMessage == nil {
                    AppHaptics.shared.play(.goalModeToggle)
                    dismiss()
                } else {
                    AppHaptics.shared.play(.messageSendError)
                    errorText = failureMessage
                }
            }
        }
    }
}

#if DEBUG
@MainActor
struct RuntimeModelSwitcherUITestHarness: View {
    @State private var currentModel = "gpt-5.6-sol"
    @State private var currentEffort = "high"
    @State private var isPresented = false
    @State private var applyAttempt = 0
    @State private var catalogAttempt = 0

    private let failFirstApply =
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RUNTIME_SWITCHER_FAIL_FIRST"] == "1"
    private let failFirstCatalog =
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RUNTIME_CATALOG_FAIL_FIRST"] == "1"
    private let usesAccessibilityText =
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RUNTIME_ACCESSIBILITY_TEXT"] == "1"

    private let models = [
        KycodeAvailableModel(
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            displayName: "GPT-5.6-SOL",
            defaultReasoningEffort: "high",
            supportedReasoningEfforts: [
                KycodeReasoningEffortOption(reasoningEffort: "medium", description: "Equilibrado"),
                KycodeReasoningEffortOption(reasoningEffort: "high", description: "Profundo"),
                KycodeReasoningEffortOption(reasoningEffort: "xhigh", description: "Muy profundo"),
                KycodeReasoningEffortOption(reasoningEffort: "max", description: "Máximo"),
            ],
            hidden: false,
            isDefault: true
        ),
        KycodeAvailableModel(
            id: "gpt-5.6-terra",
            model: "gpt-5.6-terra",
            displayName: "GPT-5.6-TERRA",
            defaultReasoningEffort: "medium",
            supportedReasoningEfforts: [
                KycodeReasoningEffortOption(reasoningEffort: "low", description: "Rápido"),
                KycodeReasoningEffortOption(reasoningEffort: "medium", description: "Equilibrado"),
                KycodeReasoningEffortOption(reasoningEffort: "high", description: "Profundo"),
            ],
            hidden: false,
            isDefault: false
        ),
        KycodeAvailableModel(
            id: "gpt-5.6-luna",
            model: "gpt-5.6-luna",
            displayName: "GPT-5.6-LUNA",
            defaultReasoningEffort: "low",
            supportedReasoningEfforts: [
                KycodeReasoningEffortOption(reasoningEffort: "none", description: "Sin razonamiento"),
                KycodeReasoningEffortOption(reasoningEffort: "low", description: "Rápido"),
                KycodeReasoningEffortOption(reasoningEffort: "max", description: "Máximo"),
            ],
            hidden: false,
            isDefault: false
        ),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Selector de sesión")
                    .font(.system(size: 28, weight: .bold))
                Text("\(currentModel) · \(currentEffort)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkMuted)
                    .accessibilityIdentifier("runtime-harness-selection")
                Spacer()
            }
            .foregroundStyle(AppTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(AppTheme.backgroundSolid.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        RuntimeModelSwitcherButton(
                            model: currentModel,
                            reasoningEffort: currentEffort,
                            isEnabled: true
                        ) {
                            isPresented = true
                        }

                        GoalModeToggleButton(
                            isEnabled: false,
                            isSupported: true,
                            action: {}
                        )
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                KycodeRuntimeSettingsSheet(
                    currentModel: currentModel,
                    currentReasoningEffort: currentEffort,
                    loadModels: loadHarnessModels,
                    applySettings: applyHarnessSettings
                )
                .dynamicTypeSize(usesAccessibilityText ? .accessibility3 : .large)
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(usesAccessibilityText ? .accessibility3 : .large)
    }

    private func loadHarnessModels() async throws -> [KycodeAvailableModel] {
        catalogAttempt += 1
        if failFirstCatalog, catalogAttempt == 1 {
            throw NSError(
                domain: "KycodeUITest",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "El catálogo de prueba no respondió."]
            )
        }
        return models
    }

    private func applyHarnessSettings(model: String, effort: String) async -> String? {
        let previousModel = currentModel
        let previousEffort = currentEffort
        currentModel = model
        currentEffort = effort
        applyAttempt += 1
        try? await Task.sleep(for: .milliseconds(250))
        if failFirstApply, applyAttempt == 1 {
            currentModel = previousModel
            currentEffort = previousEffort
            return "El runtime de prueba rechazó el cambio. Se restauró la configuración anterior."
        }
        return nil
    }
}
#endif

struct GoalModeToggleButton: View {
    let isEnabled: Bool
    let isSupported: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .opacity(isEnabled ? 1 : 0)
                    .accessibilityHidden(true)
                Text("GOAL")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.4)
            }
            .foregroundStyle(isEnabled ? Color.white : AppTheme.inkSoft)
            .frame(width: 52, height: 28)
            .v2RaisedSurface(
                fill: isEnabled ? AppTheme.accent : AppTheme.cardSurfaceRaised,
                topLight: isEnabled ? AppTheme.surfaceTopLightStrong : AppTheme.surfaceTopLight
            )
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.9))
        .disabled(!isSupported)
        .animation(.easeInOut(duration: 0.16), value: isEnabled)
        .accessibilityLabel("Goal Mode")
        .accessibilityValue(isEnabled ? "Activado" : "Desactivado")
        .accessibilityHint("Se aplica al próximo mensaje cuando toques Enviar")
        .accessibilityIdentifier("detail-goal-mode-toggle")
    }
}

#if DEBUG
@MainActor
struct GoalModeUITestHarness: View {
    @State private var isGoalModeEnabled = false
    @State private var composer = ""
    @State private var goalCommandCount = 0
    @State private var messageCommandCount = 0
    @State private var acknowledgement = "Esperando un envío explícito"

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Sesión de prueba")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)

                    Text("GOAL sólo prepara el borrador. Ningún comando sale hasta tocar Enviar.")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(AppTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Mensaje", text: $composer)
                        .textFieldStyle(.plain)
                        .padding(14)
                        .background(AppTheme.cardSurfaceRaised)
                        .foregroundStyle(AppTheme.ink)
                        .accessibilityIdentifier("goal-mode-harness-composer")

                    HStack(spacing: 10) {
                        Circle()
                            .fill(isGoalModeEnabled ? AppTheme.accent : AppTheme.inkMuted)
                            .frame(width: 9, height: 9)
                        Text(isGoalModeEnabled ? "GOAL activo" : "GOAL inactivo")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.ink)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("goal-mode-harness-state")

                    Text(acknowledgement)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.inkMuted)
                        .accessibilityIdentifier("goal-mode-harness-acknowledgement")

                    Text("goal=\(goalCommandCount), message=\(messageCommandCount)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.inkMuted)
                        .accessibilityIdentifier("goal-mode-harness-counts")

                    Button("Enviar") {
                        submitExplicitly()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("goal-mode-harness-send")

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.top, 48)
            }
            .navigationTitle("KyCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GoalModeToggleButton(
                        isEnabled: isGoalModeEnabled,
                        isSupported: true,
                        action: toggleGoalMode
                    )
                }
            }
        }
    }

    private func toggleGoalMode() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isGoalModeEnabled.toggle()
            acknowledgement = "GOAL preparado; todavía no se envió nada"
        }
    }

    private func submitExplicitly() {
        guard !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isGoalModeEnabled {
            goalCommandCount += 1
        }
        messageCommandCount += 1
        acknowledgement = "Procesando después del envío explícito"
        composer = ""
    }
}
#endif

#if DEBUG
@MainActor
struct FeatureToggleMutationUITestHarness: View {
    private enum Control {
        case promptImprover
        case explainer
    }

    private struct Intent {
        let promptImproverEnabled: Bool
        let explainerEnabled: Bool
        let source: Control
    }

    @State private var promptImproverEnabled = false
    @State private var explainerEnabled = false
    @State private var serverPromptImproverEnabled = false
    @State private var serverExplainerEnabled = false
    @State private var busyControl: Control?
    @State private var sentCount = 0
    @State private var queue = KycodeLatestIntentMutationQueue<Intent>()
    @State private var failedIntent: Intent?
    @State private var featureErrorText: String?
    @State private var hasSimulatedFailure = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Controles de sesión")
                    .font(.system(size: 28, weight: .bold))
                Text("Cada toque cambia la intención al instante; la red procesa sólo el primer estado y el último.")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.inkSoft)

                HStack(spacing: 12) {
                    featureButton(
                        title: "Improver",
                        symbol: "wand.and.stars",
                        control: .promptImprover,
                        isActive: promptImproverEnabled
                    )
                    featureButton(
                        title: "Explainer",
                        symbol: "text.viewfinder",
                        control: .explainer,
                        isActive: explainerEnabled
                    )
                }

                if let featureErrorText, let failedIntent {
                    InlineActionErrorCard(text: featureErrorText, buttonTitle: "Reintentar cambio") {
                        submit(failedIntent)
                    }
                    .accessibilityIdentifier("feature-harness-retry-error")
                }

                Text(
                    "Servidor: Improver \(serverPromptImproverEnabled ? "activado" : "desactivado") · " +
                        "Explainer \(serverExplainerEnabled ? "activado" : "desactivado") · " +
                        "\(sentCount) envíos"
                )
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.inkMuted)
                .accessibilityIdentifier("feature-harness-server-state")

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            .background(AppTheme.backgroundSolid.ignoresSafeArea())
            .foregroundStyle(AppTheme.ink)
            .navigationTitle("Fermín Code")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func featureButton(
        title: String,
        symbol: String,
        control: Control,
        isActive: Bool
    ) -> some View {
        let isBusy = busyControl == control
        return Button {
            requestToggle(control)
        } label: {
            ZStack(alignment: .bottom) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AppTheme.accent)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                }
                if isActive {
                    Rectangle()
                        .fill(AppTheme.accent)
                        .frame(width: 16, height: 3)
                        .padding(.bottom, 4)
                }
            }
            .frame(width: 36, height: 36)
            .background(isActive ? AppTheme.accent.opacity(0.14) : Color.clear, in: Rectangle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.9))
        .accessibilityLabel(title)
        .accessibilityValue(
            (isActive ? "Activado" : "Desactivado") +
                (isBusy ? ", sincronizando" : "")
        )
        .accessibilityHint(
            isBusy
                ? "El cambio está en curso; podés tocar de nuevo para elegir el estado final"
                : "Cambia esta función para los próximos mensajes"
        )
        .accessibilityIdentifier(
            control == .promptImprover
                ? "feature-harness-improver"
                : "feature-harness-explainer"
        )
    }

    private func requestToggle(_ control: Control) {
        switch control {
        case .promptImprover:
            promptImproverEnabled.toggle()
        case .explainer:
            explainerEnabled.toggle()
        }
        let intent = Intent(
            promptImproverEnabled: promptImproverEnabled,
            explainerEnabled: explainerEnabled,
            source: control
        )

        submit(intent)
    }

    private func submit(_ intent: Intent) {
        promptImproverEnabled = intent.promptImproverEnabled
        explainerEnabled = intent.explainerEnabled
        busyControl = intent.source
        failedIntent = nil
        featureErrorText = nil

        Task {
            let result = await queue.submit(intent) { intent in
                sentCount += 1
                try? await Task.sleep(for: .milliseconds(1_200))
                if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FEATURE_TOGGLES_FAIL_ONCE"] == "1",
                   !hasSimulatedFailure {
                    hasSimulatedFailure = true
                    return false
                }
                serverPromptImproverEnabled = intent.promptImproverEnabled
                serverExplainerEnabled = intent.explainerEnabled
                return true
            }
            guard case let .completed(finalIntent, succeeded) = result else { return }
            busyControl = nil
            if !succeeded {
                promptImproverEnabled = serverPromptImproverEnabled
                explainerEnabled = serverExplainerEnabled
                failedIntent = finalIntent
                featureErrorText = "No se pudo actualizar la función. Revisá la conexión y reintentá."
            }
        }
    }
}
#endif

struct KycodeSessionDetailView: View {
    private static let initialVisibleMessages = 10
    private static let messagePageSize = 20
    private static let maximumSavedMessageCount = 200

    private enum VoiceComposerPhase {
        case idle
        case recording
        case transcribing
        case draftReady
        case sending
        case error
    }

    private enum ComposerUndoAction {
        case text(String)
        case attachments([KycodeImageAttachmentDraft])
    }

    private enum FeatureToolbarControl: Hashable {
        case explainer
        case promptImprover
    }

    private struct FeatureUpdateRequest {
        let promptImproverEnabled: Bool
        let explainerEnabled: Bool
        let source: FeatureToolbarControl
    }

    private struct MessageSourceRevision: Equatable {
        let updatedAt: Double
        let declaredCount: Int
        let loadedCount: Int
        let tailId: String?
        let tailTimestamp: Double?
        let tailStatus: String?
    }

    private struct DetailControlMetrics {
        let isTablet = UIDevice.current.userInterfaceIdiom == .pad

        var composerButtonSize: CGFloat { 36 }
        var composerUtilityButtonSize: CGFloat { 36 }
        var composerAuxiliaryButtonSize: CGFloat { 36 }
        var composerIconSize: CGFloat { isTablet ? 18 : 14 }
        var composerUtilityIconSize: CGFloat { isTablet ? 18 : 14 }
        var composerProgressScale: CGFloat { isTablet ? 0.72 : 0.58 }
        var composerHorizontalSpacing: CGFloat { isTablet ? 10 : 6 }
        var composerVerticalSpacing: CGFloat { 4 }
        var composerPadding: CGFloat { 6 }
        var composerDockPadding: CGFloat { 6 }
        var composerDockCornerRadius: CGFloat { 0 }
        var composerInputMinHeight: CGFloat { isTablet ? 128 : 112 }
        var composerInputCornerRadius: CGFloat { 0 }
        var composerTextSurfaceHeight: CGFloat { isTablet ? 164 : 148 }
        var composerRecordingSurfaceHeight: CGFloat { isTablet ? 138 : 122 }
        var composerSurfaceHorizontalInset: CGFloat { isTablet ? 16 : 14 }
        var composerTextSurfaceVerticalInset: CGFloat { isTablet ? 14 : 12 }
        var composerRecordingSurfaceVerticalInset: CGFloat { isTablet ? 12 : 10 }
        var composerFloatingControlSize: CGFloat { isTablet ? 56 : 48 }
        var composerCancelVoiceSize: CGFloat { isTablet ? 52 : 36 }
        var composerFloatingPrimarySize: CGFloat { isTablet ? 56 : 36 }
        var composerTopControlSize: CGFloat { isTablet ? 44 : 27 }
        var composerRecordingControlSpacing: CGFloat { isTablet ? 14 : 12 }
        var featureToolbarSpacing: CGFloat { isTablet ? 9 : 6 }
        var featureToolbarClusterPadding: CGFloat { isTablet ? 0 : 0 }
        var featureToolbarButtonWidth: CGFloat { isTablet ? 52 : 36 }
        var featureToolbarButtonHeight: CGFloat { isTablet ? 52 : 36 }
        var featureToolbarIconFrame: CGFloat { isTablet ? 36 : 24 }
        var featureToolbarIconSize: CGFloat { isTablet ? 18 : 11.5 }
        var featureToolbarCornerRadius: CGFloat { 0 }
        var featureToolbarClusterCornerRadius: CGFloat { 0 }
        var featureToolbarProgressScale: CGFloat { isTablet ? 0.72 : 0.58 }
        var featureToolbarIndicatorWidth: CGFloat { isTablet ? 22 : 16 }
        var featureToolbarBusyIndicatorWidth: CGFloat { isTablet ? 14 : 10 }
        var featureToolbarIndicatorHeight: CGFloat { isTablet ? 4 : 3 }
        var featureToolbarIndicatorBottomPadding: CGFloat { isTablet ? 7 : 5 }
    }

    @EnvironmentObject private var store: KycodeConnectionStore
    @EnvironmentObject private var backgroundRecording: BackgroundRecordingState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let windowId: String
    var onNavigateToWindow: ((String) -> Void)? = nil
    var onCreateSession: (() -> Void)? = nil

    @State private var composer = ""
    @State private var composerDraftStorageKey: String
    @State private var legacyComposerDraftText: String?
    @State private var showLegacyComposerDraftRecovery = false
    @State private var isSending = false
    @State private var isCreatingSubagent = false
    @State private var isUpdatingMinimized = false
    @State private var isUpdatingFeatures = false
    @State private var goalModeErrorMessage: String?
    @State private var updatingFeature: FeatureToolbarControl?
    @State private var promptImproverEnabled = false
    @State private var explainerEnabled = false
    @State private var featureMutationQueue =
        KycodeLatestIntentMutationQueue<FeatureUpdateRequest>()
    @State private var failedFeatureUpdateRequest: FeatureUpdateRequest?
    @State private var featureUpdateErrorText: String?
    @State private var sendErrorText: String?
    @State private var subagentStatusText: String?
    @State private var retrySubagentOnError = false
    @State private var isChoosingSubagentEngine = false
    @State private var selectedSubagentEngine: KycodeAgentEngine?
    @State private var isReviewingSubagentParentNote = false
    @State private var subagentParentNoteDraft = ""
    @State private var subagentParentNoteWasEdited = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingLevel: Float = 0
    @State private var lastRecordedVoiceDuration: TimeInterval = 0
    @State private var isRecordingVoice = false
    @State private var isTranscribingVoice = false
    @State private var isFinalizingVoiceRecording = false
    @State private var isRequestingVoicePermission = false
    @State private var voiceErrorText: String?
    @State private var voiceDurationTimer: Timer?
    @State private var voiceStartTask: Task<Void, Never>?
    @State private var voiceWarmupTask: Task<Void, Never>?
    @State private var voicePermissionTask: Task<Void, Never>?
    @State private var lastVoiceTouchDownUptime: TimeInterval?
    @State private var voicePulseActive = false
    @State private var showMicrophoneSettingsAlert = false
    @State private var showDiscardVoiceDraftAlert = false
    @State private var renameTarget: SessionRenameTarget?
    @State private var renameErrorMessage: String?
    @State private var narrationPlayerAsset: ExplainerNarrationAsset?
    @State private var isNarrationPlayerPresented = false
    @State private var narrationGeneratingMessageId: String?
    @State private var narrationErrorText: String?
    @State private var messageTimeline: [KycodeMessage] = []
    @State private var messageTimelineRevision: UInt64 = 0
    @State private var visibleMessageLimit = Self.initialVisibleMessages
    @State private var transcriptFollowRequest = 0
    @State private var composerOcclusionHeight: CGFloat = 60
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageAttachments: [KycodeImageAttachmentDraft] = []
    @State private var imageAttachmentError: String?
    @State private var isImportingImages = {
#if DEBUG
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_IMPORT_IN_FLIGHT"] == "1"
#else
        false
#endif
    }()
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var previewedAttachment: KycodeImageAttachmentDraft?
    @State private var presentedFileReference: KycodeFileReference?
    @StateObject private var explanationViewerModel = ExplanationViewerViewModel()
    @State private var isRuntimeSettingsPresented = false
    @State private var composerUndoAction: ComposerUndoAction?
    @State private var composerUndoText: String?
    @State private var composerUndoToken = UUID()
    @State private var isTranscriptSearchPresented = false
    @State private var transcriptSearchText = ""
    @State private var debouncedTranscriptSearchText = ""
    @State private var transcriptSearchMatchIndex = 0
    @State private var transcriptSearchDocuments: [String: String] = [:]
    @State private var transcriptSearchTask: Task<Void, Never>?
    @State private var transcriptIndexTask: Task<Void, Never>?
    @State private var composerDraftPersistenceTask: Task<Void, Never>?
    @State private var savedMessageIds: Set<String> = []
    @State private var isFullScreenComposerPresented = false
    @FocusState private var isComposerFocused: Bool

    private let narrationService = ExplainerNarrationService()

    init(
        windowId: String,
        composerDraftStorageKey: String,
        onNavigateToWindow: ((String) -> Void)? = nil,
        onCreateSession: (() -> Void)? = nil
    ) {
        self.windowId = windowId
        self.onNavigateToWindow = onNavigateToWindow
        self.onCreateSession = onCreateSession
        _composerDraftStorageKey = State(initialValue: composerDraftStorageKey)
    }

    private var audioRecorder: AudioRecordingService {
        backgroundRecording.audioRecorder
    }

    private var controlMetrics: DetailControlMetrics {
        DetailControlMetrics()
    }

    private var session: KycodeSessionSummary? {
        store.detail(for: windowId)
    }

    private var pendingSubagentDraft: KycodePendingSubagentDraft? {
        session?.pendingSubagent ?? store.sessions.first(where: { $0.windowId == windowId })?.pendingSubagent
    }

    private var pendingSubagentParentNoteSource: String? {
        guard let prompt = pendingSubagentDraft?.parentNotificationPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return nil
        }
        return prompt
    }

    private var voiceDraft: VoiceDraft? {
        guard let draft = store.currentVoiceDraft,
              draft.isRecoverable,
              store.voiceDraftBelongsToCurrentTarget(draft, windowId: windowId) else {
            return nil
        }
        return draft
    }

    private var activeVoiceJob: VoiceTranscriptionJob? {
        store.voiceTranscriptionJobs.values.first(where: {
            store.voiceJobBelongsToCurrentTarget($0, windowId: windowId)
        })
    }

    private var foreignVoiceDraft: VoiceDraft? {
        guard let draft = store.currentVoiceDraft,
              draft.isRecoverable,
              !store.voiceDraftBelongsToCurrentTarget(draft, windowId: windowId) else {
            return nil
        }
        return draft
    }

    private var allMessages: [KycodeMessage] {
        messageTimeline
    }

    private var visibleMessages: [KycodeMessage] {
        Array(allMessages.suffix(visibleMessageLimit))
    }

    private var transcriptSearchMatches: [KycodeMessage] {
        let query = kycodeSearchNormalize(debouncedTranscriptSearchText)
        guard !query.isEmpty else { return [] }
        return allMessages.filter {
            transcriptSearchDocuments[$0.id]?.contains(query) == true
        }
    }

    private var messageSourceRevision: MessageSourceRevision {
        let currentSession = session
        let tail = currentSession?.messages?.last
        return MessageSourceRevision(
            updatedAt: store.transcriptUpdatedAt(for: windowId),
            declaredCount: currentSession?.messageCount ?? 0,
            loadedCount: currentSession?.messages?.count ?? 0,
            tailId: tail?.id,
            tailTimestamp: tail?.timestamp,
            tailStatus: tail?.status
        )
    }

    private var selectedTranscriptSearchMessageId: String? {
        guard transcriptSearchMatches.indices.contains(transcriptSearchMatchIndex) else {
            return nil
        }
        return transcriptSearchMatches[transcriptSearchMatchIndex].id
    }

    private var hasOlderMessages: Bool {
        allMessages.count > visibleMessageLimit
    }

    private var latestNarratableMessage: KycodeMessage? {
        allMessages.last { isNarratableAssistantMessage($0) }
    }

    private var canStartLatestNarration: Bool {
        latestNarratableMessage != nil && narrationGeneratingMessageId == nil
    }

    private var isProcessing: Bool {
        guard let session else { return false }
        if session.usesPristineReadyVisualState {
            return false
        }
        return KycodeSessionActivityPolicy.isProcessing(
            activityStatus: session.visualActivityStatus,
            runtimeStatus: session.runtimeStatus
        )
    }

    private var processingLabel: String {
        guard let session else { return "Procesando..." }
        if session.visualActivityStatus == "approval" {
            return "Esperando aprobación..."
        }
        return "Procesando..."
    }

    private var isVoiceBusy: Bool {
        isRecordingVoice || isRequestingVoicePermission || isFinalizingVoiceRecording
    }

    private var imageAttachmentComposerPhase: KycodeImageAttachmentComposerPhase {
        if isTranscribingVoice { return .transcribing }
        if isRecordingVoice { return .recording }
        return .idle
    }

    private var canControlFeatures: Bool {
        session?.canControlFeatures ?? false
    }

    private var featureControlsDisabled: Bool {
        !canControlFeatures || composerConnectivityState != .online
    }

    private var composerTextTrimmed: String {
        composer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composerSubmissionText: String {
        let draftText = activeVoiceJob == nil
            ? voiceDraft?.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return composerTextTrimmed.isEmpty ? (draftText ?? "") : composerTextTrimmed
    }

    private var canSubmitComposer: Bool {
        !composerSubmissionText.isEmpty || !imageAttachments.isEmpty
    }

    private var composerConnectivityState: KycodeComposerConnectivityState {
        KycodeComposerConnectivityPolicy.state(
            isConnected: store.isConnected,
            isStreaming: store.isStreaming,
            isShowingCachedSessions: store.isShowingCachedSessions,
            isConnecting: store.isConnecting,
            isBootstrapping: store.isBootstrapping,
            isReconnecting: store.isReconnecting,
            canRetryReconnectManually: store.canRetryReconnectManually
        )
    }

    private var composerSessionBlockedReason: String? {
        if !(session?.supportsMobileBridgeMessaging ?? false) {
            return session?.unsupportedReason ?? "Esta sesión no acepta mensajes desde Mobile."
        }
        return nil
    }

    private var composerConnectionBlockedReason: String? {
        KycodeComposerConnectivityPolicy.sendBlockedReason(
            for: composerConnectivityState
        ) ?? composerSessionBlockedReason
    }

    private var attachmentSlotsRemaining: Int {
        max(0, KycodeImageAttachmentPolicy.maximumCount - imageAttachments.count)
    }

    private var attachmentBytesTotal: Int {
        imageAttachments.reduce(0) { $0 + $1.data.count }
    }

    private var attachmentSizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(attachmentBytesTotal),
            countStyle: .file
        )
    }

    private var canCreateSubagentComposer: Bool {
        store.isConnected &&
        !store.isShowingCachedSessions &&
        (session?.supportsMobileBridgeMessaging ?? false) &&
        !isSending &&
        !isCreatingSubagent &&
        !isVoiceBusy &&
        !store.isReconnecting &&
        !store.canRetryReconnectManually &&
        pendingSubagentDraft == nil &&
        !composerSubmissionText.isEmpty
    }

    private var canUseVoiceCapture: Bool {
        store.isConnected &&
        !store.isShowingCachedSessions &&
        (session?.supportsMobileBridgeMessaging ?? false) &&
        !isSending &&
        !isCreatingSubagent &&
        !store.isReconnecting &&
        !store.canRetryReconnectManually &&
        (!backgroundRecording.hasInFlightRecording || backgroundRecording.belongs(to: windowId)) &&
        voiceDraft == nil &&
        foreignVoiceDraft == nil
    }

    private var voiceCaptureBlockedReason: String? {
        if let composerConnectionBlockedReason {
            return composerConnectionBlockedReason
        }
        if backgroundRecording.hasInFlightRecording,
           !backgroundRecording.belongs(to: windowId) {
            return "Ya hay una grabación activa en otra conversación."
        }
        if !(session?.supportsMobileBridgeMessaging ?? false) {
            return "Esta ventana no acepta mensajes ahora."
        }
        if foreignVoiceDraft != nil {
            return "Ya hay un audio pendiente en otra ventana."
        }
        if voiceDraft != nil {
            return "Terminá o descartá el audio pendiente antes de grabar otro."
        }
        if store.isReconnecting || store.canRetryReconnectManually {
            return "Esperá a que la conexión vuelva antes de grabar."
        }
        if isCreatingSubagent {
            return "Esperá a que termine la creación de sub-agente actual."
        }
        if isSending {
            return "Esperá a que termine el envío actual."
        }
        return nil
    }

    private var voicePhase: VoiceComposerPhase {
        if isTranscribingVoice {
            return .transcribing
        }
        if isRecordingVoice {
            return .recording
        }
        if let draft = voiceDraft {
            if draft.sendStatus == .sending || isSending {
                return .sending
            }
            if draft.transcriptStatus == .failed || draft.sendStatus == .failed {
                return .error
            }
            if draft.transcriptStatus == .success {
                return .draftReady
            }
            return .idle
        }
        if let voiceErrorText, !voiceErrorText.isEmpty {
            return .error
        }
        return .idle
    }

    private var voiceDraftSyncToken: String {
        guard let draft = voiceDraft else { return "none" }
        return [
            draft.id,
            draft.transcriptStatus.rawValue,
            draft.sendStatus.rawValue,
            draft.transcriptText ?? "",
            draft.errorMessage ?? ""
        ].joined(separator: "|")
    }

    private var shouldShowVoiceDraftStatusCard: Bool {
        guard activeVoiceJob == nil,
              let draft = voiceDraft,
              !isTranscribingVoice else {
            return false
        }
        if draft.transcriptStatus == .success, draft.sendStatus == .idle, !composerTextTrimmed.isEmpty {
            return false
        }
        return true
    }

    private func formattedVoiceDraftDuration(_ duration: TimeInterval) -> String {
        let totalTenths = max(0, Int((duration * 10).rounded(.down)))
        let wholeSeconds = totalTenths / 10
        return String(
            format: "%01d:%02d.%01d",
            wholeSeconds / 60,
            wholeSeconds % 60,
            totalTenths % 10
        )
    }

    private func appendTranscriptToComposer(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        guard composerTextTrimmed != trimmedTranscript,
              !composerTextTrimmed.hasSuffix(trimmedTranscript) else {
            return
        }

        guard !composerTextTrimmed.isEmpty else {
            composer = trimmedTranscript
            return
        }

        if composer.last?.isWhitespace == true {
            composer += trimmedTranscript
        } else {
            composer += " \(trimmedTranscript)"
        }
    }

    private var voiceButtonIconName: String {
        if isTranscribingVoice {
            return "waveform.badge.magnifyingglass"
        }
        return isRecordingVoice ? "stop.fill" : "mic.fill"
    }

    private var voiceButtonBackground: Color {
        if isRecordingVoice {
            return Color.red.opacity(0.86)
        }
        if isTranscribingVoice {
            return AppTheme.highlightBackground
        }
        return AppTheme.accentSend
    }

    private var voiceButtonForeground: Color {
        if isRecordingVoice {
            return .white
        }
        if isTranscribingVoice {
            return AppTheme.accent
        }
        return .white
    }

    var body: some View {
        detailScreen
    }

    private var detailScreen: AnyView {
        let titled = detailStack
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { detailHeaderToolbar }
            .toolbarBackground(AppTheme.backgroundSolid, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(AppTheme.inkSoft)
            .accentColor(AppTheme.inkSoft)
        let tasked = titled.task {
            syncMessageTimeline()
            if composer.isEmpty {
                let savedDraft = KycodeComposerDraftStoragePolicy.loadDraft(
                    defaults: .standard,
                    storageKey: composerDraftStorageKey
                )
                let stagedTask = pendingSubagentDraft?.isWaitingForExplicitSend == true
                    ? pendingSubagentDraft?.displayMessage
                    : nil
                composer = savedDraft ?? stagedTask ?? ""
                if savedDraft == nil, let stagedTask, !stagedTask.isEmpty {
                    UserDefaults.standard.set(stagedTask, forKey: composerDraftStorageKey)
                }
                if savedDraft == nil,
                   stagedTask == nil,
                   let legacyDraft = KycodeComposerDraftStoragePolicy.legacyDraft(
                       defaults: .standard,
                       windowId: windowId
                   ),
                   !legacyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    legacyComposerDraftText = legacyDraft
                    showLegacyComposerDraftRecovery = true
                }
            }
            savedMessageIds = Set(
                (UserDefaults.standard.string(forKey: savedMessagesStorageKey) ?? "")
                    .split(separator: "\n")
                    .map(String.init)
                    .prefix(Self.maximumSavedMessageCount)
            )
            await store.refreshDetail(windowId: windowId)
            syncMessageTimeline()
            syncPendingSubagentParentNote()
            debouncedTranscriptSearchText = transcriptSearchText
            if isTranscriptSearchPresented {
                rebuildTranscriptSearchDocuments()
            }
            if explanationViewerModel.isPresented {
                explanationViewerModel.sync(messages: allMessages)
            }
            syncFeatureState()
            syncVoiceDraftFromStore()
            syncVoiceRecordingFromGlobalState()
        }
        let refreshed = tasked.onChange(of: store.sessions.first(where: { $0.windowId == windowId })?.updatedAt ?? 0) { _, _ in
            Task {
                await store.refreshDetail(windowId: windowId)
                syncMessageTimeline()
            }
        }
        let timelineSynced = refreshed.onChange(of: messageSourceRevision) { _, _ in
            syncMessageTimeline()
        }
        let indexed = timelineSynced.onChange(of: messageTimelineRevision) { _, _ in
            if isTranscriptSearchPresented {
                rebuildTranscriptSearchDocuments()
            }
            if explanationViewerModel.isPresented {
                explanationViewerModel.sync(messages: allMessages)
            }
            if !savedMessageIds.isEmpty {
                pruneSavedMessages()
            }
        }
        let searchIndexed = indexed.onChange(of: isTranscriptSearchPresented) { _, isPresented in
            if isPresented {
                rebuildTranscriptSearchDocuments()
            }
        }
        let promptSynced = searchIndexed.onChange(of: session?.features?.promptImproverEnabled ?? false) { _, value in
            if !isUpdatingFeatures {
                promptImproverEnabled = value
            }
        }
        let explainerSynced = promptSynced.onChange(of: session?.features?.explainerEnabled ?? false) { _, value in
            if !isUpdatingFeatures {
                explainerEnabled = value
            }
        }
        let statusLogged = explainerSynced.onChange(of: session?.activityStatus ?? "") { oldValue, newValue in
            if oldValue != newValue {
                NSLog("%@", "[Connection] Estado de detalle \(windowId) cambio: \(oldValue) -> \(newValue)")
            }
        }
        let subagentDraftSynced = statusLogged.onChange(of: pendingSubagentDraft?.displayMessage ?? "") { _, stagedTask in
            guard composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pendingSubagentDraft?.isWaitingForExplicitSend == true,
                  !stagedTask.isEmpty else { return }
            composer = stagedTask
            UserDefaults.standard.set(stagedTask, forKey: composerDraftStorageKey)
        }
        let subagentParentNoteSynced = subagentDraftSynced.onChange(
            of: pendingSubagentDraft?.parentNotificationPrompt ?? ""
        ) { _, _ in
            syncPendingSubagentParentNote()
        }
        let draftSynced = subagentParentNoteSynced.onChange(of: voiceDraftSyncToken) { _, _ in
            syncVoiceDraftFromStore()
        }
        let photosSynced = draftSynced.onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await importSelectedPhotos(items)
                selectedPhotoItems = []
            }
        }
        let composerSynced = photosSynced.onChange(of: composer) { _, value in
            scheduleComposerDraftPersistence(value)
        }
        let voiceSceneSynced = composerSynced.onChange(of: scenePhase) { _, phase in
            handleVoiceScenePhase(phase)
        }
        let globalVoiceSynced = voiceSceneSynced.onChange(of: backgroundRecording.phase) { _, _ in
            syncVoiceRecordingFromGlobalState()
        }
        let cleanedUp = globalVoiceSynced.onDisappear {
            composerDraftPersistenceTask?.cancel()
            persistComposerDraft(composer)
            transcriptSearchTask?.cancel()
            transcriptIndexTask?.cancel()
            voicePermissionTask?.cancel()
            voiceWarmupTask?.cancel()
            stopVoiceDurationTimer()
            let isStartingOrCapturingHere = isRecordingVoice
                || voiceStartTask != nil
                || backgroundRecording.belongs(to: windowId)
            if !isStartingOrCapturingHere {
                voiceStartTask?.cancel()
                audioRecorder.invalidatePreparation(reason: "detalle cerrado sin captura activa")
            } else {
                // On a compact NavigationStack the back gesture can finish in
                // the same run-loop turn as recorder activation. Let the
                // app-global owner complete that start instead of cancelling
                // the microphone between detail and Home.
                logVoice("Detalle cerrado; inicio/grabación global continúa")
            }
        }
        let alerted = cleanedUp.alert("Micrófono deshabilitado", isPresented: $showMicrophoneSettingsAlert) {
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Permití el micrófono.")
        }
        let discardAlerted = alerted.alert("Descartar grabación", isPresented: $showDiscardVoiceDraftAlert) {
            Button("Descartar", role: .destructive) {
                discardCurrentVoiceDraft()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Borrar audio y texto.")
        }
        let legacyDraftAlerted = discardAlerted.alert(
            "Recuperar borrador anterior",
            isPresented: $showLegacyComposerDraftRecovery
        ) {
            Button("Recuperar acá") {
                guard legacyComposerDraftText != nil,
                      let recovered = KycodeComposerDraftStoragePolicy.recoverLegacyDraft(
                    defaults: .standard,
                    storageKey: composerDraftStorageKey,
                    legacyWindowId: windowId
                ) else { return }
                composer = recovered
                legacyComposerDraftText = nil
                isComposerFocused = true
            }
            Button("Ahora no", role: .cancel) {
                legacyComposerDraftText = nil
            }
        } message: {
            Text(
                "La versión anterior no guardaba si este texto era de Personal o Puky. "
                    + "Recuperalo acá sólo si corresponde a esta conversación."
            )
        }
        let enginePrompted = legacyDraftAlerted.confirmationDialog(
            "Elegí el motor del sub-agente",
            isPresented: $isChoosingSubagentEngine,
            titleVisibility: .visible
        ) {
            if store.supportsClaudeSubagents(windowId: windowId) {
                Button("Claude") {
                    requestCreateSubagent(engine: .claude)
                }
            }
            Button("Codex") {
                requestCreateSubagent(engine: .codex)
            }
            if store.supportsClaudeSubagents(windowId: windowId) {
                Button(inheritedSubagentEngineLabel) {
                    requestCreateSubagent(engine: nil)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se abrirá un borrador editable. Todavía no se envía nada: en el hijo podés cambiar la tarea, Prompt Improver o GOAL y después tocar Enviar.")
        }
        let narrationOverlaid = enginePrompted.overlay {
            narrationPlayerOverlay
        }
        let renameOverlaid = narrationOverlaid.overlay(alignment: .bottom) {
            detailRenameEditorOverlay
        }
        let renameAlerted = renameOverlaid.alert("No se pudo renombrar", isPresented: detailRenameErrorBinding) {
            Button(KycodeInterfaceCopyPolicy.dismissErrorAction, role: .cancel) {
                renameErrorMessage = nil
            }
        } message: {
            Text(renameErrorMessage ?? "Intentá de nuevo.")
        }
        let goalModeAlerted = renameAlerted.alert(
            "No se pudo cambiar GOAL",
            isPresented: detailGoalModeErrorBinding
        ) {
            Button(KycodeInterfaceCopyPolicy.dismissErrorAction, role: .cancel) {
                goalModeErrorMessage = nil
            }
        } message: {
            Text(goalModeErrorMessage ?? "El estado anterior fue restaurado. Intentá de nuevo.")
        }
        let cameraPresented = goalModeAlerted.sheet(isPresented: $isCameraPresented) {
            CameraImagePicker { image in
                appendImageAttachment(image, sourceName: "camera")
            }
            .ignoresSafeArea()
        }
        let libraryPresented = cameraPresented.photosPicker(
            isPresented: $isPhotoLibraryPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, attachmentSlotsRemaining),
            matching: .images
        )
        let previewPresented = libraryPresented.fullScreenCover(item: $previewedAttachment) { attachment in
            ImageAttachmentPreview(attachment: attachment) {
                previewedAttachment = nil
            }
        }
        let filePresented = previewPresented.sheet(item: $presentedFileReference) { reference in
            FileViewerSheet(reference: reference) { path in
                try await store.fetchFilePreview(path: path, windowId: windowId)
            }
        }
        let explanationPresented = filePresented.fullScreenCover(
            isPresented: Binding(
                get: { explanationViewerModel.isPresented },
                set: { isPresented in
                    if !isPresented {
                        explanationViewerModel.dismiss()
                    }
                }
            )
        ) {
            ExplanationViewerSheet(viewModel: explanationViewerModel)
        }
        let runtimeSettingsPresented = explanationPresented.sheet(
            isPresented: $isRuntimeSettingsPresented
        ) {
            if let session {
                KycodeRuntimeSettingsSheet(
                    currentModel: session.model,
                    currentReasoningEffort: session.reasoningEffort,
                    loadModels: {
                        try await store.modelCatalog(windowId: windowId)
                    },
                    applySettings: { model, effort in
                        let succeeded = await store.setRuntimeModelSettings(
                            windowId: windowId,
                            model: model,
                            reasoningEffort: effort
                        )
                        return succeeded
                            ? nil
                            : (store.errorMessage ?? "Codex rechazó el cambio. Se restauró la configuración anterior.")
                    }
                )
            }
        }
        let parentNotePresented = runtimeSettingsPresented.sheet(
            isPresented: $isReviewingSubagentParentNote
        ) {
            SubagentParentNoteEditorSheet(text: subagentParentNoteDraft) { updatedText in
                let normalized = updatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                subagentParentNoteDraft = normalized
                subagentParentNoteWasEdited = normalized != pendingSubagentParentNoteSource
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        let composerEditorPresented = parentNotePresented.fullScreenCover(
            isPresented: $isFullScreenComposerPresented
        ) {
            FullScreenTextEditorSheet(
                text: composer,
                recoveryIdentifier: fullScreenComposerRecoveryIdentifier
            ) { updatedText in
                composer = updatedText
                persistComposerDraft(updatedText)
            }
        }
        return AnyView(composerEditorPresented)
    }

    private var detailRenameErrorBinding: Binding<Bool> {
        Binding(
            get: { renameErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    renameErrorMessage = nil
                }
            }
        )
    }

    private var detailGoalModeErrorBinding: Binding<Bool> {
        Binding(
            get: { goalModeErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    goalModeErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var detailRenameEditorOverlay: some View {
        if let renameTarget {
            SessionNameEditorOverlay(
                target: renameTarget,
                onCancel: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.renameTarget = nil
                    }
                },
                onCommit: { name in
                    commitRename(renameTarget, name: name)
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var narrationPlayerOverlay: some View {
        if isNarrationPlayerPresented, let narrationPlayerAsset {
            ExplainerNarrationPlayerOverlay(
                asset: narrationPlayerAsset,
                isPresented: $isNarrationPlayerPresented
            )
            .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
            .zIndex(20)
        }
    }

    // Header de referencia: chevron (system, tint ink-soft) + título centrado
    // (nombre de sesión) + punto de estado que respira a la derecha.
    @ToolbarContentBuilder
    private var detailHeaderToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    if let session {
                        Circle()
                            .fill(statusColor(for: session))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text(session?.displayName ?? "Sesión")
                        .font(.system(size: 17, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let metadata = detailHeaderMetadata {
                    if let session,
                       RuntimeModelControlPolicy.isAvailable(
                           engine: session.agentEngine,
                           advertisedFeatureControl: session.canControlFeatures,
                           unsupportedReason: session.unsupportedReason
                       ) {
                        Button {
                            AppHaptics.shared.play(.conversationSelection)
                            isRuntimeSettingsPresented = true
                        } label: {
                            Text(metadata)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(0.35)
                                .foregroundStyle(AppTheme.inkMuted)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Modelo y razonamiento")
                        .accessibilityValue(
                            RuntimeModelSwitcherPresentation.accessibilityValue(
                                model: session.model,
                                effort: session.reasoningEffort
                            )
                        )
                        .accessibilityHint("Abre el selector de modelo y nivel de razonamiento")
                        .accessibilityIdentifier("detail-runtime-model-switcher")
                    } else {
                        Text(metadata)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(0.35)
                            .foregroundStyle(AppTheme.inkMuted)
                            .lineLimit(1)
                            .accessibilityLabel("Origen, modelo y razonamiento \(metadata)")
                    }
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.42, maximumDistance: 18) {
                if let session { beginRename(session) }
            }
            .accessibilityHint("Mantener presionado para renombrar")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                if let session {
                    let goalModeEnabled = displayedGoalModeEnabled(for: session)
                    GoalModeToggleButton(
                        isEnabled: goalModeEnabled,
                        isSupported: session.agentEngine != .claude
                    ) {
                        toggleGoalMode(for: session)
                    }
                }

                if let onCreateSession {
                    Button(action: onCreateSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .v2RaisedSurface(fill: AppTheme.accent, topLight: AppTheme.surfaceTopLightStrong)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.9))
                    .accessibilityLabel("Crear nueva sesión")
                    .accessibilityHint("Abre Nueva sesión en un toque")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var detailHeaderMetadata: String? {
        guard let session else { return nil }
        let source = store.sessionSourceLabel(for: windowId)?
            .replacingOccurrences(of: "Mac personal", with: "Personal")
            .uppercased()
        let model = RuntimeModelSwitcherPresentation.compactModelLabel(session.model)
        let effort = RuntimeModelSwitcherPresentation.compactEffortLabel(session.reasoningEffort)
        let values = [source, model, effort].compactMap { value -> String? in
            guard let value, !value.isEmpty, value != "MODELO", value != "AUTO" else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func toggleGoalMode(for session: KycodeSessionSummary) {
        guard session.agentEngine != .claude else { return }
        let nextEnabled = !displayedGoalModeEnabled(for: session)
        withAnimation(.easeInOut(duration: 0.16)) {
            store.stageGoalMode(windowId: session.windowId, enabled: nextEnabled)
            goalModeErrorMessage = nil
        }
        AppHaptics.shared.play(.goalModeToggle)
    }

    private func displayedGoalModeEnabled(for session: KycodeSessionSummary) -> Bool {
        store.displayedGoalModeEnabled(windowId: session.windowId)
    }

    private func isDetailBusyStatus(_ session: KycodeSessionSummary) -> Bool {
        session.visualActivityStatus == "working" || session.visualActivityStatus == "approval"
    }

    private func detailStatusLabel(for session: KycodeSessionSummary) -> String {
        KycodeInterfaceCopyPolicy.sessionActivityStatus(session.visualActivityStatus)
    }

    private var fullScreenComposerRecoveryIdentifier: String {
        "composer.\(windowId)"
    }

    private var savedMessagesStorageKey: String {
        "kycode.mobile.savedMessages.\(windowId)"
    }

    private func scheduleTranscriptSearch(_ value: String) {
        transcriptSearchTask?.cancel()
        transcriptSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedTranscriptSearchText = value
            transcriptSearchMatchIndex = 0
            ensureSearchMatchesAreVisible()
        }
    }

    private func rebuildTranscriptSearchDocuments() {
        let snapshot = allMessages
        transcriptIndexTask?.cancel()
        transcriptIndexTask = Task {
            let documents = await Task.detached(priority: .utility) {
                Dictionary(
                    uniqueKeysWithValues: snapshot.map {
                        ($0.id, kycodeSearchNormalize($0.content))
                    }
                )
            }.value
            guard !Task.isCancelled else { return }
            transcriptSearchDocuments = documents
            pruneSavedMessages()
        }
    }

    private func scheduleComposerDraftPersistence(_ value: String) {
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            persistComposerDraft(value)
        }
    }

    private func persistComposerDraft(_ value: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: composerDraftStorageKey)
        } else {
            UserDefaults.standard.set(value, forKey: composerDraftStorageKey)
        }
    }

    private func pruneSavedMessages() {
        guard !allMessages.isEmpty else { return }
        let availableIds = Set(allMessages.map(\.id))
        let pruned = Set(savedMessageIds.intersection(availableIds).sorted().prefix(Self.maximumSavedMessageCount))
        guard pruned != savedMessageIds else { return }
        savedMessageIds = pruned
        persistSavedMessages()
    }

    private func persistSavedMessages() {
        UserDefaults.standard.set(
            savedMessageIds.sorted().prefix(Self.maximumSavedMessageCount).joined(separator: "\n"),
            forKey: savedMessagesStorageKey
        )
    }

    private func moveTranscriptSearch(by offset: Int) {
        guard !transcriptSearchMatches.isEmpty else { return }
        transcriptSearchMatchIndex = (
            transcriptSearchMatchIndex + offset + transcriptSearchMatches.count
        ) % transcriptSearchMatches.count
        ensureSearchMatchesAreVisible()
        AppHaptics.shared.play(.conversationSelection)
    }

    private func ensureSearchMatchesAreVisible() {
        guard let selectedId = selectedTranscriptSearchMessageId,
              let index = allMessages.firstIndex(where: { $0.id == selectedId }) else {
            return
        }
        let requiredSuffixCount = allMessages.count - index
        visibleMessageLimit = max(visibleMessageLimit, requiredSuffixCount)
    }

    private func quoteMessage(_ message: KycodeMessage) {
        let normalized = message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "\n> ")
        let excerpt = String(normalized.prefix(320))
        let quote = "> \(excerpt)\(normalized.count > excerpt.count ? "…" : "")\n\n"
        composer = composerTextTrimmed.isEmpty ? quote : "\(composer)\n\(quote)"
        isComposerFocused = true
        AppHaptics.shared.play(.conversationSelection)
    }

    private func toggleSavedMessage(_ message: KycodeMessage) {
        if savedMessageIds.contains(message.id) {
            savedMessageIds.remove(message.id)
        } else {
            if savedMessageIds.count >= Self.maximumSavedMessageCount,
               let oldestDeterministicId = savedMessageIds.sorted().first {
                savedMessageIds.remove(oldestDeterministicId)
            }
            savedMessageIds.insert(message.id)
        }
        persistSavedMessages()
        AppHaptics.shared.play(.conversationSelection)
    }

    private var toolbarClusterFill: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.cardSurfaceRaised.opacity(controlMetrics.isTablet ? 0.98 : 0.90),
                AppTheme.cardSurface.opacity(controlMetrics.isTablet ? 0.98 : 0.86)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var detailStack: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isTranscriptSearchPresented {
                    transcriptSearchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                SessionTranscriptPane(
                    session: session,
                    visibleMessages: visibleMessages,
                    contentRevision: messageTimelineRevision,
                    hasAuthoritativeDetail: store.hasAuthoritativeDetail(for: windowId),
                    detailLoadState: store.detailLoadState(for: windowId),
                    hasOlderMessages: hasOlderMessages,
                    olderMessageCount: max(0, allMessages.count - visibleMessages.count),
                    isProcessing: isProcessing,
                    processingLabel: processingLabel,
                    headerView: nil,
                    followBottomRequest: transcriptFollowRequest,
                    selectedSearchMessageId: selectedTranscriptSearchMessageId,
                    floatingComposerHeight: composerOcclusionHeight,
                    savedMessageIds: savedMessageIds,
                    fileBasePath: session?.projectPath,
                    promptTransformTimedOutMessageIds: store.promptTransformTimedOutMessageIds(
                        windowId: windowId
                    ),
                    onLoadOlderMessages: loadOlderMessages,
                    onRetryDetail: {
                        Task {
                            await store.refreshDetail(windowId: windowId)
                            syncMessageTimeline()
                        }
                    },
                    onRequestLatest: {
                        Task {
                            // "Ir al final" is also a recovery action: fetch the
                            // authoritative detail before reasserting the tail.
                            // This repairs a missed live patch instead of merely
                            // scrolling to the end of stale local data.
                            await store.refreshDetail(windowId: windowId)
                            syncMessageTimeline()
                            transcriptFollowRequest &+= 1
                        }
                    },
                    onQuoteMessage: quoteMessage,
                    onToggleSavedMessage: toggleSavedMessage,
                    onRetryVoiceMessage: { message in
                        store.retryVoiceTranscription(messageId: message.id)
                    },
                    onRetryPromptImprover: { message in
                        await store.retryPromptImprover(
                            windowId: windowId,
                            messageId: message.id
                        )
                    },
                    onOpenFile: { reference in
                        AppHaptics.shared.play(.conversationSelection)
                        presentedFileReference = reference
                    },
                    onOpenReaderDocument: { document in
                        AppHaptics.shared.play(.conversationSelection)
                        explanationViewerModel.present(document)
                    }
                )
                .equatable()
            }

            composerBar
                .background(composerBarBackground)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ComposerOcclusionHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .padding(.horizontal, controlMetrics.isTablet ? 18 : 8)
                .padding(.bottom, controlMetrics.isTablet ? 10 : 4)
                .zIndex(10)
        }
        .onPreferenceChange(ComposerOcclusionHeightPreferenceKey.self) { height in
            guard height > 0, abs(composerOcclusionHeight - height) > 0.5 else { return }
            composerOcclusionHeight = height
        }
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.inkMuted)

            TextField("Buscar en esta conversación", text: $transcriptSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: transcriptSearchText) { _, value in
                    scheduleTranscriptSearch(value)
                }
                .accessibilityIdentifier("transcript-search-field")

            Text(transcriptSearchMatches.isEmpty ? "0/0" : "\(transcriptSearchMatchIndex + 1)/\(transcriptSearchMatches.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.inkMuted)
                .monospacedDigit()
                .accessibilityLabel(
                    transcriptSearchMatches.isEmpty
                        ? "Sin coincidencias"
                        : "Coincidencia \(transcriptSearchMatchIndex + 1) de \(transcriptSearchMatches.count)"
                )

            Button {
                moveTranscriptSearch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 34, height: 44)
            }
            .disabled(transcriptSearchMatches.isEmpty)
            .accessibilityLabel("Coincidencia anterior")

            Button {
                moveTranscriptSearch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 34, height: 44)
            }
            .disabled(transcriptSearchMatches.isEmpty)
            .accessibilityLabel("Coincidencia siguiente")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(AppTheme.ink)
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(AppTheme.inputSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.line).frame(height: 1)
        }
    }

    private func loadOlderMessages() {
        let nextLimit = min(allMessages.count, visibleMessageLimit + Self.messagePageSize)
        guard nextLimit > visibleMessageLimit else { return }
        visibleMessageLimit = nextLimit
    }

    private func syncMessageTimeline() {
        messageTimeline = KycodeMessageChronologyPolicy.ordered(session?.messages ?? [])
        messageTimelineRevision &+= 1
    }

    private var composerBar: some View {
        VStack(spacing: controlMetrics.composerVerticalSpacing) {
            if let composerSessionBlockedReason {
                Label(composerSessionBlockedReason, systemImage: "lock.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppTheme.cloudWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-session-blocked-reason")
            }

            if let featureUpdateErrorText, let failedFeatureUpdateRequest {
                InlineActionErrorCard(text: featureUpdateErrorText, buttonTitle: "Reintentar cambio") {
                    Task {
                        await updateFeatures(
                            promptImproverEnabled: failedFeatureUpdateRequest.promptImproverEnabled,
                            explainerEnabled: failedFeatureUpdateRequest.explainerEnabled,
                            source: failedFeatureUpdateRequest.source
                        )
                    }
                }
                .accessibilityIdentifier("feature-update-retry-error")
            }

            // Global/background failures are intentionally not repeated above
            // the composer. Send, voice, attachment, and sub-agent failures are
            // rendered below by their own local retry controls.

            if let voiceDraft, shouldShowVoiceDraftStatusCard {
                voiceDraftStatusCard(voiceDraft)
            }

            if let voiceErrorText, !voiceErrorText.isEmpty, voiceDraft == nil {
                InlineActionErrorCard(text: voiceErrorText, buttonTitle: "Reintentar micrófono") {
                    self.voiceErrorText = nil
                    handleVoiceButtonTap()
                }
                .accessibilityIdentifier("voice-capture-retry-error")
            }

            if let sendErrorText, !sendErrorText.isEmpty, voiceDraft == nil {
                InlineActionErrorCard(text: sendErrorText, buttonTitle: "Reintentar") {
                    Task {
                        if retrySubagentOnError {
                            await submitCreateSubagentComposer(engine: selectedSubagentEngine)
                        } else {
                            await submitComposer()
                        }
                    }
                }
            }

            if let imageAttachmentError, !imageAttachmentError.isEmpty {
                InlineActionErrorCard(text: imageAttachmentError, buttonTitle: "Cerrar") {
                    self.imageAttachmentError = nil
                }
            }

            if let composerUndoText, composerUndoAction != nil {
                ComposerUndoBanner(
                    message: composerUndoText,
                    accessibilityHint: composerUndoAccessibilityHint,
                    onUndo: performComposerUndo
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let progress = store.imageUploadProgress, progress.windowId == windowId {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .tint(AppTheme.accent)
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.inkSoft)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Subiendo imágenes \(progress.completed) de \(progress.total)")
            }

            if let subagentStatusText, !subagentStatusText.isEmpty {
                Label(subagentStatusText, systemImage: "clock.badge.checkmark")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let pendingSubagentDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        pendingSubagentDraft.childMessageSentAt == nil
                            ? "Borrador de subagente: editá y tocá Enviar para iniciar al hijo y avisar al padre."
                            : "El hijo ya inició. Tocá Enviar para reintentar únicamente el aviso al padre.",
                        systemImage: "cpu"
                    )
                    .font(.system(size: 11.5, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)

                    if pendingSubagentParentNoteSource != nil {
                        Button {
                            syncPendingSubagentParentNote()
                            isReviewingSubagentParentNote = true
                        } label: {
                            Label(
                                subagentParentNoteWasEdited
                                    ? "Aviso al padre editado"
                                    : "Revisar aviso al padre",
                                systemImage: "text.bubble"
                            )
                            .font(.system(size: 11.5, weight: .semibold, design: .default))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.inkSoft)
                        .accessibilityIdentifier("composer-review-subagent-parent-note")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("composer-staged-subagent-notice")
            }

            if let narrationErrorText, !narrationErrorText.isEmpty {
                InlineActionErrorCard(text: narrationErrorText, buttonTitle: "Cerrar") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.narrationErrorText = nil
                    }
                }
            }

            composerFloatingSurface
        }
    }

    private var composerFloatingSurface: AnyView {
        AnyView(Group {
            if isRecordingVoice || isTranscribingVoice {
                AnyView(composerRecordingSurface)
            } else {
                AnyView(composerTextSurface)
            }
        }
        .v2InsetSurface())
    }

    // One compact row keeps the transcript visually dominant.
    // Keep this boundary type-erased. On physical iOS 26, the previous single
    // deeply-nested generic view tree overflowed Swift's metadata resolver as
    // soon as a conversation instantiated the composer (EXC_BAD_ACCESS in
    // `composerTextSurface`). Splitting and erasing the controls preserves the
    // exact UI while keeping runtime metadata construction bounded.
    private var composerTextSurface: AnyView {
        AnyView(VStack(spacing: 4) {
            if !imageAttachments.isEmpty {
                AnyView(composerAttachmentTray)
            }

            HStack(alignment: .center, spacing: controlMetrics.composerHorizontalSpacing) {
                AnyView(composerPhotosPicker)
                AnyView(composerTextAction(
                    title: "Improver",
                    symbol: "wand.and.stars",
                    control: .promptImprover,
                    isActive: promptImproverEnabled
                ) {
                    await togglePromptImprover()
                })
                AnyView(composerTextAction(
                    title: "Explainer",
                    symbol: "text.viewfinder",
                    control: .explainer,
                    isActive: explainerEnabled
                ) {
                    await toggleExplainer()
                })
                AnyView(composerInlineField)
                AnyView(composerContextActionButton)
            }
            .frame(height: controlMetrics.composerFloatingControlSize)
        }
        .padding(.horizontal, controlMetrics.isTablet ? 10 : 6)
        .padding(.vertical, controlMetrics.isTablet ? 8 : 4)
        .frame(maxHeight: imageAttachments.isEmpty ? (controlMetrics.isTablet ? 72 : 60) : (controlMetrics.isTablet ? 140 : 120))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 22)
                .onEnded { value in
                    guard value.translation.height > 42 else { return }
                    guard abs(value.translation.width) < 90 else { return }
                    isComposerFocused = false
                }
        ))
    }

    private var composerActionsRow: some View {
        HStack(spacing: 18) {
            composerTextAction(
                title: "Improver",
                symbol: "wand.and.stars",
                control: .promptImprover,
                isActive: promptImproverEnabled
            ) {
                await togglePromptImprover()
            }

            composerTextAction(
                title: "Explainer",
                symbol: "text.viewfinder",
                control: .explainer,
                isActive: explainerEnabled
            ) {
                await toggleExplainer()
            }

            Spacer(minLength: 8)

            createSubagentComposerButton
            playNarrationComposerButton
            minimizeComposerButton
        }
    }

    private var composerAttachmentTray: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button {
                    let removed = imageAttachments
                    withAnimation(.easeOut(duration: 0.16)) {
                        imageAttachments.removeAll()
                    }
                    let message = removed.count == 1
                        ? "Se quitó una imagen"
                        : "Se quitaron \(removed.count) imágenes"
                    offerComposerUndo(.attachments(removed), message: message)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 36, height: 48)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar todas las imágenes")
                .accessibilityIdentifier("composer-remove-all-attachments")

                Text("\(imageAttachments.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(AppTheme.accent, in: Rectangle())
                    .accessibilityLabel(
                        imageAttachments.count == 1
                            ? "1 imagen adjunta"
                            : "\(imageAttachments.count) imágenes adjuntas"
                    )
                    .accessibilityIdentifier("composer-attachment-count")
                    .allowsHitTesting(false)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
                        HStack(spacing: 4) {
                            Button {
                                previewedAttachment = attachment
                            } label: {
                                if let image = UIImage(data: attachment.data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 48, height: 48)
                                        .clipShape(Rectangle())
                                } else {
                                    Rectangle()
                                        .fill(AppTheme.inputSurface)
                                        .frame(width: 48, height: 48)
                                        .overlay(Image(systemName: "photo").foregroundStyle(AppTheme.inkMuted))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Imagen \(index + 1) de \(imageAttachments.count), \(attachment.name), " +
                                ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
                            )
                            .accessibilityHint("Abre la vista previa")

                            ComposerAttachmentRemoveButton(
                                name: attachment.name,
                                accessibilityIdentifier: "composer-remove-attachment-\(attachment.id)"
                            ) {
                                guard let removedIndex = imageAttachments.firstIndex(where: { $0.id == attachment.id }) else {
                                    return
                                }
                                let removed = imageAttachments.remove(at: removedIndex)
                                offerComposerUndo(.attachments([removed]), message: "Se quitó una imagen")
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            composerPhotosPicker
            composerInlineField
            composerContextActionButton
        }
    }

    private var composerPhotosPicker: some View {
        Menu {
            Section("Adjuntar") {
                Button {
                    isPhotoLibraryPresented = true
                } label: {
                    Label("Elegir de Fotos", systemImage: "photo.on.rectangle")
                }
                .disabled(attachmentSlotsRemaining == 0)

                Button {
                    isCameraPresented = true
                } label: {
                    Label("Tomar foto", systemImage: "camera")
                }
                .disabled(
                    attachmentSlotsRemaining == 0 ||
                    !KycodeImageAttachmentComposerPolicy.allowsCamera(
                        in: imageAttachmentComposerPhase
                    ) ||
                    !UIImagePickerController.isSourceTypeAvailable(.camera)
                )

                Button {
                    pasteImageFromClipboard()
                } label: {
                    Label("Pegar imagen", systemImage: "doc.on.clipboard")
                }
                .disabled(attachmentSlotsRemaining == 0)

                Text("\(attachmentSlotsRemaining)/\(KycodeImageAttachmentPolicy.maximumCount)")
            }

            Section("Prompt rápido") {
                Button("Estado") {
                    insertQuickPrompt("Dame un estado breve y concreto.")
                }
                Button("Qué falta") {
                    insertQuickPrompt("¿Qué falta para terminar? Listalo de forma pragmática.")
                }
                Button("Próximo") {
                    insertQuickPrompt("¿Cuál es la siguiente mejor acción? Ejecutala si es segura.")
                }
            }

            Section("Editor") {
                Button {
                    isComposerFocused = false
                    isFullScreenComposerPresented = true
                } label: {
                    Label(
                        "Editar en pantalla completa",
                        systemImage: "arrow.up.left.and.arrow.down.right"
                    )
                }
                .accessibilityIdentifier("composer-expand-editor")

                if !composer.isEmpty {
                    Button {
                        let cleared = composer
                        composer = ""
                        offerComposerUndo(.text(cleared), message: "Texto limpiado")
                    } label: {
                        Label("Limpiar mensaje", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("composer-clear-text")
                }
            }

            Section("Sesión") {
                Button {
                    isChoosingSubagentEngine = true
                } label: {
                    Label(
                        isCreatingSubagent ? "Creando subagente…" : "Crear subagente",
                        systemImage: "cpu"
                    )
                }
                .disabled(!canCreateSubagentComposer)
                .accessibilityHint(
                    "Prepara un hijo editable. Nada se envía hasta tocar Enviar dentro de esa sesión."
                )
                .accessibilityIdentifier("composer-create-subagent")
            }
        } label: {
            Group {
                if isImportingImages {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AppTheme.accent)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.inkSoft)
                }
            }
            .frame(
                width: controlMetrics.featureToolbarButtonWidth,
                height: controlMetrics.featureToolbarButtonHeight
            )
            .background(Color.clear)
            .overlay(alignment: .topTrailing) {
                if !imageAttachments.isEmpty {
                    Text("\(imageAttachments.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(AppTheme.accent, in: Rectangle())
                        .offset(x: 5, y: -5)
                }
            }
            .frame(
                width: max(44, controlMetrics.featureToolbarButtonWidth),
                height: max(44, controlMetrics.featureToolbarButtonHeight)
            )
            .contentShape(Rectangle())
        }
        .disabled(
            isImportingImages ||
            isSending
        )
        .accessibilityLabel("Más acciones")
        .accessibilityValue("\(imageAttachments.count) de \(KycodeImageAttachmentPolicy.maximumCount) imágenes")
        .accessibilityHint("Abre adjuntos, prompts rápidos y creación de subagentes")
        .accessibilityIdentifier("composer-more-actions")
    }

    // Compact icon-only feature actions; VoiceOver keeps the full names.
    private func composerTextAction(
        title: String,
        symbol: String,
        control: FeatureToolbarControl,
        isActive: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        let isBusy = updatingFeature == control
        let color = featureToolbarForeground(isActive: isActive)

        return Button {
            AppHaptics.shared.play(
                control == .promptImprover ? .promptImproverToggle : .explainerToggle
            )
            Task { await action() }
        } label: {
            ZStack(alignment: .bottom) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: controlMetrics.featureToolbarIconSize, weight: .semibold))
                }
                if isActive {
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: controlMetrics.featureToolbarIndicatorWidth,
                            height: controlMetrics.featureToolbarIndicatorHeight
                        )
                        .padding(.bottom, controlMetrics.featureToolbarIndicatorBottomPadding)
                }
            }
            .frame(
                width: controlMetrics.featureToolbarButtonWidth,
                height: controlMetrics.featureToolbarButtonHeight
            )
            .background(
                isActive ? AppTheme.cardSurfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.s, style: .continuous)
            )
            .overlay(alignment: .top) {
                if isActive {
                    Rectangle()
                        .fill(AppTheme.surfaceTopLight)
                        .frame(height: 1)
                        .padding(.horizontal, AppTheme.Radius.s)
                }
            }
            .foregroundStyle(color)
            .opacity(canControlFeatures ? 1 : 0.42)
            .frame(
                width: max(44, controlMetrics.featureToolbarButtonWidth),
                height: max(44, controlMetrics.featureToolbarButtonHeight)
            )
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.18), value: isBusy)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.9))
        .disabled(featureControlsDisabled)
        .accessibilityLabel(title)
        .accessibilityValue(
            (isActive ? "Activado" : "Desactivado") +
                (isBusy ? ", sincronizando" : "")
        )
        .accessibilityHint(
            featureAccessibilityHint(
                control: control,
                isActive: isActive,
                isBusy: isBusy
            )
        )
    }

    // Utilidad de ícono (sub-agente / narración / minimizar): calmo, sin caja.
    private func composerUtilityIcon(
        symbol: String,
        tint: Color,
        isBusy: Bool,
        disabled: Bool,
        badge: Bool,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: 1)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92, opacity: 0.9))
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }

    // El campo crece hasta tres líneas; el estado normal permanece en 36 pt.
    private var composerInlineField: some View {
        TextField(
            "",
            text: $composer,
            prompt: Text("Mensaje").foregroundStyle(AppTheme.inkMuted),
            axis: .vertical
        )
        .font(.system(size: controlMetrics.isTablet ? 17 : 15, weight: .regular, design: .default))
        .foregroundColor(AppTheme.ink)
        .tint(AppTheme.accent)
        .lineLimit(1...3)
        .focused($isComposerFocused)
        .submitLabel(.send)
        .onSubmit {
            guard canSubmitComposer,
                  composerConnectionBlockedReason == nil,
                  !isSending,
                  !isImportingImages else { return }
            Task { await submitComposer() }
        }
        .composerMessageAccessibility()
        .accessibilityIdentifier("composer-message")
        .padding(.leading, 10)
        .padding(
            .trailing,
            controlMetrics.isTablet ? (composer.isEmpty ? 44 : 84) : 10
        )
        .padding(.vertical, controlMetrics.isTablet ? 10 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: controlMetrics.isTablet ? 52 : 36)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if isComposerFocused {
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.72))
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            if controlMetrics.isTablet {
                ComposerInlineEditorControls(
                    canClear: !composer.isEmpty,
                    onExpand: {
                        isComposerFocused = false
                        isFullScreenComposerPresented = true
                    },
                    onClear: {
                        let cleared = composer
                        composer = ""
                        offerComposerUndo(.text(cleared), message: "Texto limpiado")
                    }
                )
                .padding(.trailing, 1)
            }
        }
    }

    @ViewBuilder
    private var composerMetadataRow: some View {
        if !composer.isEmpty || !imageAttachments.isEmpty {
            HStack(spacing: 8) {
                if !composer.isEmpty {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppTheme.statusReady)
                        .accessibilityLabel("Borrador guardado")
                }
                Spacer(minLength: 8)
                if composer.count >= 500 {
                    Text("\(composer.count)")
                        .foregroundStyle(AppTheme.inkMuted)
                        .monospacedDigit()
                }
                if !imageAttachments.isEmpty {
                    Text("\(imageAttachments.count)/\(KycodeImageAttachmentPolicy.maximumCount)")
                        .foregroundStyle(AppTheme.inkMuted)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .default))
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var composerContextActionButton: some View {
        Group {
            switch composerConnectivityState {
            case .online:
                ComposerContextActionCluster(showsSend: canSubmitComposer) {
                    voiceComposerButton
                        .id("composer-voice-action")
                } sendControl: {
                    sendComposerButton
                        .id("composer-send-action")
                }
            case .reconnecting:
                composerReconnectingIndicator
            case .retryRequired, .offline:
                composerReconnectButton
            }
        }
        .frame(height: controlMetrics.composerFloatingControlSize)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private var composerReconnectingIndicator: some View {
        FloatingComposerButtonChrome(
            size: controlMetrics.composerFloatingPrimarySize,
            fill: AppTheme.inputSurface,
            ring: AppTheme.accent.opacity(0.36),
            isProminent: false
        ) {
            ProgressView()
                .tint(AppTheme.accent)
                .scaleEffect(controlMetrics.composerProgressScale)
        }
        .frame(
            width: max(44, controlMetrics.composerFloatingPrimarySize),
            height: max(44, controlMetrics.composerFloatingPrimarySize)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reconectando")
        .accessibilityValue("Tu borrador está guardado")
        .accessibilityIdentifier("composer-reconnect-status")
    }

    private var composerReconnectButton: some View {
        Button {
            AppHaptics.shared.play(.reconnectRequest)
            Task {
                await store.retryAutoConnect()
            }
        } label: {
            FloatingComposerButtonChrome(
                size: controlMetrics.composerFloatingPrimarySize,
                fill: AppTheme.inputSurface,
                ring: AppTheme.accent.opacity(0.46),
                isProminent: false
            ) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: controlMetrics.composerIconSize, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(
                width: max(44, controlMetrics.composerFloatingPrimarySize),
                height: max(44, controlMetrics.composerFloatingPrimarySize)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Reintentar conexión")
        .accessibilityHint("Conserva tu borrador y vuelve a conectar")
        .accessibilityIdentifier("composer-reconnect-action")
    }

    private var composerRecordingSurface: some View {
        HStack(spacing: 10) {
            if isTranscribingVoice {
                voiceComposerButton
                Text("Transcribiendo")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.inkSoft)
                Spacer(minLength: 8)
            } else {
                cancelVoiceRecordingButton
                if KycodeImageAttachmentComposerPolicy.showsAttachmentControl(in: .recording) {
                    composerPhotosPicker
                }
                recordingFeatureControls
                VoiceRecordingDot()
                Text(formattedVoiceDraftDuration(recordingDuration))
                    .font(.system(size: 15, weight: .medium, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()

                voiceWaveform
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)

                voiceComposerButton
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxHeight: 60)
    }

    private var recordingFeatureControls: some View {
        HStack(spacing: 2) {
            composerTextAction(
                title: "Improver",
                symbol: "wand.and.stars",
                control: .promptImprover,
                isActive: promptImproverEnabled
            ) {
                await togglePromptImprover()
            }
            composerTextAction(
                title: "Explainer",
                symbol: "text.viewfinder",
                control: .explainer,
                isActive: explainerEnabled
            ) {
                await toggleExplainer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-feature-controls")
    }

    private var composerSurfaceBackground: some View {
        Color.clear
    }

    private var sendComposerButton: some View {
        let canSend = !(
            isSending ||
            isCreatingSubagent ||
            isImportingImages ||
            isVoiceBusy ||
            !store.isConnected ||
            store.isShowingCachedSessions ||
            store.isReconnecting ||
            store.canRetryReconnectManually ||
            !canSubmitComposer ||
            !(session?.supportsMobileBridgeMessaging ?? false)
        )

        return Button {
            Task {
                await submitComposer()
            }
        } label: {
            FloatingComposerButtonChrome(
                size: controlMetrics.composerFloatingPrimarySize,
                fill: canSend ? AppTheme.accentSend : AppTheme.inkMuted.opacity(0.26),
                ring: canSend ? AppTheme.accent.opacity(0.62) : AppTheme.divider.opacity(0.38),
                isProminent: canSend
            ) {
                if isSending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(controlMetrics.composerProgressScale)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: controlMetrics.composerIconSize, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : AppTheme.inkMuted)
                    .offset(x: controlMetrics.isTablet ? 2 : 1)
                }
            }
            .frame(
                width: max(44, controlMetrics.composerFloatingPrimarySize),
                height: max(44, controlMetrics.composerFloatingPrimarySize)
            )
            .contentShape(Rectangle())
        }
        .disabled(!canSend)
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(sendComposerAccessibilityLabel)
        .accessibilityHint(sendComposerAccessibilityHint)
        .accessibilityIdentifier("composer-send-message")
    }

    private var sendComposerAccessibilityHint: String {
        if isImportingImages {
            return "Preparando imágenes. Esperá a que termine para enviarlas con el mensaje."
        }
        if let composerConnectionBlockedReason {
            return composerConnectionBlockedReason
        }
        return imageAttachments.isEmpty
            ? "Envía el texto a esta sesión"
            : "Envía texto e imágenes conservando su orden"
    }

    private var sendComposerAccessibilityLabel: String {
        if composerSubmissionText.isEmpty, !imageAttachments.isEmpty {
            return "Enviar \(imageAttachments.count) \(imageAttachments.count == 1 ? "imagen" : "imágenes")"
        }
        if !imageAttachments.isEmpty {
            return "Enviar mensaje con \(imageAttachments.count) \(imageAttachments.count == 1 ? "imagen" : "imágenes")"
        }
        return "Enviar mensaje"
    }

    private var minimizeComposerButton: some View {
        let isMinimized = session?.minimized ?? false
        let isDisabled = session == nil || isUpdatingMinimized

        return composerUtilityIcon(
            symbol: isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus",
            tint: isMinimized ? AppTheme.accent : AppTheme.inkSoft,
            isBusy: isUpdatingMinimized,
            disabled: isDisabled,
            badge: false,
            accessibilityLabel: isMinimized ? "Restaurar sesión" : "Minimizar sesión"
        ) {
            Task {
                await setMinimizedFromDetail(!isMinimized)
            }
        }
    }

    private var composerControlsDockBackground: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            AppTheme.cardSurface.opacity(0.98),
                            AppTheme.cardSurfaceRaised.opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.divider.opacity(0.72))
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
        }
        .shadow(color: AppTheme.shadowDeep.opacity(controlMetrics.isTablet ? 0.62 : 0.48), radius: controlMetrics.isTablet ? 18 : 14, x: 0, y: controlMetrics.isTablet ? 8 : 7)
    }

    private var composerBarBackground: some View {
        Color.clear
    }

    private var createSubagentComposerButton: some View {
        Button {
            isChoosingSubagentEngine = true
        } label: {
            Group {
                if isCreatingSubagent {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AppTheme.accent)
                } else {
                    SubagentBotGlyph()
                        .foregroundStyle(canCreateSubagentComposer ? AppTheme.accent : AppTheme.inkMuted)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if canCreateSubagentComposer && !isCreatingSubagent {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: 1)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92, opacity: 0.9))
        .disabled(!canCreateSubagentComposer)
        .accessibilityLabel(isCreatingSubagent ? "Creando sub-agente" : "Crear sub-agente")
        .accessibilityHint("Prepara un hijo editable. Nada se envía hasta tocar Enviar dentro de esa sesión.")
        .accessibilityIdentifier("composer-create-subagent")
    }

    private var playNarrationComposerButton: some View {
        let isGenerating = narrationGeneratingMessageId == latestNarratableMessage?.id && narrationGeneratingMessageId != nil
        return composerUtilityIcon(
            symbol: "play.fill",
            tint: canStartLatestNarration ? AppTheme.accent : AppTheme.inkMuted,
            isBusy: isGenerating,
            disabled: !canStartLatestNarration,
            badge: false,
            accessibilityLabel: "Reproducir explicación",
            accessibilityHint: "Genera y reproduce una narración de la última explicación. El audio queda guardado para próximos usos."
        ) {
            Task {
                await startLatestNarration()
            }
        }
    }

    @ViewBuilder
    private var voiceComposerControls: some View {
        if isRecordingVoice {
            HStack(alignment: .center, spacing: controlMetrics.composerRecordingControlSpacing) {
                voiceComposerButton
                cancelVoiceRecordingButton
            }
        } else {
            voiceComposerButton
        }
    }

    private var voiceWaveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<13, id: \.self) { index in
                Rectangle()
                    .fill(AppTheme.accent.opacity(index == 6 ? 1 : 0.72))
                    .frame(width: index == 6 ? 3 : 2, height: voiceWaveformHeight(at: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: recordingLevel)
    }

    private func voiceWaveformHeight(at index: Int) -> CGFloat {
        let pattern: [CGFloat] = [0.30, 0.55, 0.24, 0.72, 0.42, 0.86, 1, 0.86, 0.42, 0.72, 0.24, 0.55, 0.30]
        let energy = max(0.16, CGFloat(recordingLevel))
        return max(3, 22 * pattern[min(index, pattern.count - 1)] * energy)
    }

    private var voiceComposerButton: some View {
        Button {
            handleVoiceButtonTap()
        } label: {
            FloatingComposerButtonChrome(
                size: controlMetrics.composerFloatingControlSize,
                fill: voiceButtonBackground,
                ring: isRecordingVoice ? Color.red.opacity(0.54) : AppTheme.divider.opacity(0.48),
                isProminent: isRecordingVoice
            ) {
                if isTranscribingVoice {
                    ProgressView()
                        .tint(voiceButtonForeground)
                        .scaleEffect(controlMetrics.composerProgressScale)
                } else {
                    Image(systemName: voiceButtonIconName)
                        .font(.system(size: controlMetrics.composerUtilityIconSize, weight: .semibold))
                        .foregroundStyle(voiceButtonForeground)
                }
            }
            .overlay {
                if isRecordingVoice {
                    Rectangle()
                        .fill(Color.white.opacity(voicePulseActive ? 0.06 : 0.14))
                        .scaleEffect(voicePulseActive ? 1.12 : 0.98)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .shadow(
                color: isRecordingVoice
                    ? Color.red.opacity(0.30)
                    : AppTheme.accent.opacity(0.24),
                radius: 6,
                x: 0,
                y: 3
            )
        }
        .buttonStyle(
            ImmediateVoiceButtonStyle {
                handleVoiceTouchDown()
            }
        )
        .disabled(isTranscribingVoice || isRequestingVoicePermission)
        .opacity((canUseVoiceCapture || isRecordingVoice || isTranscribingVoice) ? 1 : 0.72)
        .accessibilityLabel(voiceButtonAccessibilityLabel)
        .accessibilityValue(voiceButtonAccessibilityValue)
        .accessibilityHint(voiceButtonAccessibilityHint)
        .accessibilityIdentifier("composer-microphone")
        .onAppear {
            syncVoicePulseAnimation()
            prepareVoiceCaptureResources()
        }
        .onChange(of: isRecordingVoice) { _, _ in
            syncVoicePulseAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            syncVoicePulseAnimation()
        }
        .onChange(of: isTranscribingVoice) { _, isTranscribing in
            guard isTranscribing else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                guard self.isTranscribingVoice else { return }
                AppHaptics.shared.play(.voiceStateTransition)
            }
        }
    }

    private var cancelVoiceRecordingButton: some View {
        Button {
            cancelVoiceRecording()
        } label: {
            FloatingComposerButtonChrome(
                size: controlMetrics.composerCancelVoiceSize,
                fill: AppTheme.cardSurfaceGlass.opacity(0.78),
                ring: AppTheme.divider.opacity(0.48),
                isProminent: false
            ) {
                Image(systemName: "xmark")
                    .font(.system(size: controlMetrics.isTablet ? 13 : 14, weight: .bold))
                    .foregroundStyle(AppTheme.inkSoft)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.9))
        .disabled(isTranscribingVoice)
        .opacity(isTranscribingVoice ? 0.45 : 1)
        .accessibilityLabel("Cancelar grabación")
    }

    private var voiceButtonAccessibilityLabel: String {
        if isTranscribingVoice { return "Micrófono" }
        if isRequestingVoicePermission { return "Solicitando acceso al micrófono" }
        if isRecordingVoice { return "Detener grabación" }
        return "Grabar mensaje de voz"
    }

    private var voiceButtonAccessibilityValue: String {
        if isTranscribingVoice { return "Transcribiendo" }
        if isRequestingVoicePermission { return "Esperando permiso" }
        if isRecordingVoice {
            return "Grabando, \(formattedVoiceDraftDuration(recordingDuration))"
        }
        return voiceCaptureBlockedReason == nil ? "Listo" : "No disponible"
    }

    private var voiceButtonAccessibilityHint: String {
        if isTranscribingVoice { return "Esperá mientras el audio se convierte en texto" }
        if isRequestingVoicePermission { return "Respondé al permiso del sistema" }
        if isRecordingVoice { return "Tocá para finalizar la grabación" }
        return voiceCaptureBlockedReason ?? "Tocá para empezar a grabar"
    }

    private func syncPendingSubagentParentNote() {
        guard let source = pendingSubagentParentNoteSource else {
            if pendingSubagentDraft == nil {
                subagentParentNoteDraft = ""
                subagentParentNoteWasEdited = false
                isReviewingSubagentParentNote = false
            }
            return
        }
        if subagentParentNoteWasEdited, !subagentParentNoteDraft.isEmpty {
            return
        }
        if subagentParentNoteDraft != source {
            subagentParentNoteDraft = source
            subagentParentNoteWasEdited = false
        }
    }

    private func submitComposer() async {
        guard KycodeComposerSubmissionPolicy.canBegin(
            isSending: isSending,
            isCreatingSubagent: isCreatingSubagent,
            isPreparingAttachments: isImportingImages,
            hasPayload: canSubmitComposer
        ) else { return }
        if let composerConnectionBlockedReason {
            sendErrorText = composerConnectionBlockedReason
            AppHaptics.shared.play(.messageSendError)
            return
        }
        let text = composerSubmissionText
        let attachments = imageAttachments
        let wasStagedSubagent = pendingSubagentDraft != nil
        let parentNotificationPrompt = wasStagedSubagent
            ? (subagentParentNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? pendingSubagentParentNoteSource
                : subagentParentNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        if wasStagedSubagent,
           pendingSubagentParentNoteSource != nil,
           parentNotificationPrompt == nil {
            sendErrorText = "El aviso al padre está vacío. Revisalo antes de enviar."
            isReviewingSubagentParentNote = true
            return
        }
        isSending = true
        sendErrorText = nil
        subagentStatusText = nil
        retrySubagentOnError = false
        voiceErrorText = nil
        transcriptFollowRequest += 1
        let result = await store.sendMessage(
            windowId: windowId,
            text: text,
            attachments: attachments,
            parentNotificationPrompt: parentNotificationPrompt
        )
        isSending = false
        guard result.shouldApplyToCurrentComposer else { return }
        if result.sent {
            AppHaptics.shared.play(.messageSendSuccess)
            composer = ""
            UserDefaults.standard.removeObject(forKey: composerDraftStorageKey)
            imageAttachments.removeAll()
            selectedPhotoItems = []
            imageAttachmentError = nil
            sendErrorText = nil
            retrySubagentOnError = false
            voiceErrorText = nil
            isComposerFocused = false
            if wasStagedSubagent {
                subagentParentNoteDraft = ""
                subagentParentNoteWasEdited = false
                isReviewingSubagentParentNote = false
            }
        } else {
            AppHaptics.shared.play(.messageSendError)
            sendErrorText = result.errorMessage ?? "No se pudo enviar. Reintentá."
            retrySubagentOnError = false
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImportingImages = true
        imageAttachmentError = nil
        defer { isImportingImages = false }

        let availableSlots = max(0, KycodeImageAttachmentPolicy.maximumCount - imageAttachments.count)
        guard availableSlots > 0 else {
            imageAttachmentError = "Podés adjuntar hasta \(KycodeImageAttachmentPolicy.maximumCount) imágenes."
            return
        }

        var imported: [KycodeImageAttachmentDraft] = []
        for item in items.prefix(availableSlots) {
            do {
                guard var data = try await item.loadTransferable(type: Data.self) else {
                    throw NSError(
                        domain: "KycodeMobile",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "No se pudo leer una de las imágenes."]
                    )
                }
                var mimeType = KycodeImageAttachmentPolicy.detectedMimeType(for: data)
                if mimeType == nil, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.92) {
                    data = jpeg
                    mimeType = "image/jpeg"
                }
                guard var mimeType else {
                    throw NSError(
                        domain: "KycodeMobile",
                        code: 415,
                        userInfo: [NSLocalizedDescriptionKey: "La imagen no está en PNG, JPEG, GIF o WebP."]
                    )
                }
                let optimized = await Task.detached(priority: .userInitiated) {
                    KycodeImageAttachmentOptimizer.optimized(data: data, mimeType: mimeType)
                }.value
                data = optimized.data
                mimeType = optimized.mimeType
                let fileName = "image-\(UUID().uuidString).\(KycodeImageAttachmentPolicy.fileExtension(for: mimeType))"
                let draft = KycodeImageAttachmentDraft(
                    id: UUID().uuidString,
                    name: fileName,
                    mimeType: mimeType,
                    data: data
                )
                try KycodeImageAttachmentPolicy.validate([draft])
                imported.append(draft)
            } catch {
                imageAttachmentError = error.localizedDescription
            }
        }
        do {
            try KycodeImageAttachmentPolicy.validate(imageAttachments + imported)
            imageAttachments.append(contentsOf: imported)
        } catch {
            imageAttachmentError = error.localizedDescription
            return
        }
        if items.count > availableSlots {
            imageAttachmentError = "Se adjuntaron \(availableSlots); el máximo es \(KycodeImageAttachmentPolicy.maximumCount)."
        }
    }

    private func appendImageAttachment(_ image: UIImage, sourceName: String) {
        guard attachmentSlotsRemaining > 0 else {
            imageAttachmentError = "Podés adjuntar hasta \(KycodeImageAttachmentPolicy.maximumCount) imágenes."
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            imageAttachmentError = "No se pudo preparar la imagen."
            return
        }
        let draft = KycodeImageAttachmentDraft(
            id: UUID().uuidString,
            name: "\(sourceName)-\(UUID().uuidString).jpg",
            mimeType: "image/jpeg",
            data: data
        )
        do {
            try KycodeImageAttachmentPolicy.validate(imageAttachments + [draft])
            withAnimation(.easeOut(duration: 0.16)) {
                imageAttachments.append(draft)
            }
            imageAttachmentError = nil
        } catch {
            imageAttachmentError = error.localizedDescription
        }
    }

    private func pasteImageFromClipboard() {
        guard let image = UIPasteboard.general.image else {
            imageAttachmentError = "No hay una imagen en el portapapeles."
            return
        }
        appendImageAttachment(image, sourceName: "clipboard")
    }

    private func insertQuickPrompt(_ text: String) {
        if composerTextTrimmed.isEmpty {
            composer = text
        } else {
            composer += composer.last?.isWhitespace == true ? text : "\n\(text)"
        }
        isComposerFocused = true
        AppHaptics.shared.play(.conversationSelection)
    }

    private func offerComposerUndo(_ action: ComposerUndoAction, message: String) {
        let token = UUID()
        composerUndoToken = token
        withAnimation(.easeOut(duration: 0.16)) {
            composerUndoAction = action
            composerUndoText = message
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, composerUndoToken == token else { return }
            withAnimation(.easeIn(duration: 0.14)) {
                composerUndoAction = nil
                composerUndoText = nil
            }
        }
    }

    private var composerUndoAccessibilityHint: String {
        switch composerUndoAction {
        case .text:
            return "Restaura el texto anterior"
        case .attachments(let attachments):
            return attachments.count == 1
                ? "Restaura la imagen quitada"
                : "Restaura las \(attachments.count) imágenes quitadas"
        case nil:
            return "Restaura el cambio anterior"
        }
    }

    private func performComposerUndo() {
        guard let action = composerUndoAction else { return }
        switch action {
        case .text(let text):
            composer = text
            isComposerFocused = true
        case .attachments(let attachments):
            let available = max(0, attachmentSlotsRemaining)
            imageAttachments.append(contentsOf: attachments.prefix(available))
        }
        composerUndoToken = UUID()
        withAnimation(.easeInOut(duration: 0.14)) {
            composerUndoAction = nil
            composerUndoText = nil
        }
        AppHaptics.shared.play(.conversationSelection)
    }

    private var inheritedSubagentEngineLabel: String {
        if let engine = session?.agentEngine {
            return "Heredar del padre (\(engine.displayName))"
        }
        return "Heredar del padre"
    }

    private func requestCreateSubagent(engine: KycodeAgentEngine?) {
        selectedSubagentEngine = engine
        Task {
            await submitCreateSubagentComposer(engine: engine)
        }
    }

    private func submitCreateSubagentComposer(engine: KycodeAgentEngine? = nil) async {
        guard canCreateSubagentComposer else { return }
        let text = composerSubmissionText
        guard !text.isEmpty else { return }

        selectedSubagentEngine = engine
        isCreatingSubagent = true
        sendErrorText = nil
        subagentStatusText = nil
        retrySubagentOnError = false
        voiceErrorText = nil
        let result = await store.createSubagent(
            windowId: windowId,
            text: text,
            engine: engine
        )
        isCreatingSubagent = false

        guard let result else {
            sendErrorText = store.errorMessage ?? "No se pudo crear el sub-agente. Reintentá."
            retrySubagentOnError = true
            return
        }

        if let nextWindowId = result.windowId, !nextWindowId.isEmpty {
            UserDefaults.standard.set(
                text,
                forKey: store.composerDraftStorageKey(
                    for: nextWindowId,
                    sourceWindowId: windowId
                )
            )
            sendErrorText = nil
            subagentStatusText = nil
            retrySubagentOnError = false
            isComposerFocused = false
            onNavigateToWindow?(nextWindowId)
        } else {
            sendErrorText = nil
            subagentStatusText = "Comando aceptado. Mobile agotó la espera; desktop todavía puede abrir el sub-agente."
            retrySubagentOnError = false
        }
    }

    private func startLatestNarration() async {
        guard let message = latestNarratableMessage else {
            narrationErrorText = "Todavía no hay una explicación para reproducir."
            return
        }
        await startNarration(for: message)
    }

    private func startNarration(for message: KycodeMessage) async {
        guard isNarratableAssistantMessage(message), narrationGeneratingMessageId == nil else { return }
        narrationErrorText = nil
        narrationGeneratingMessageId = message.id
        do {
            let asset = try await narrationService.narrationAsset(
                for: message.content,
                title: session?.displayName
            )
            narrationPlayerAsset = asset
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isNarrationPlayerPresented = true
            }
        } catch {
            narrationErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        narrationGeneratingMessageId = nil
    }

    private func isNarratableAssistantMessage(_ message: KycodeMessage) -> Bool {
        message.role != "user" && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareVoiceCaptureResources() {
        AppHaptics.shared.prepare(.voiceButtonPress)
        AppHaptics.shared.prepare(.voiceRecordingStart)
        AppHaptics.shared.prepare(.voiceRecordingStop)
        AppHaptics.shared.prepare(.voiceStateTransition)

        guard !backgroundRecording.hasInFlightRecording,
              !isRecordingVoice,
              !isFinalizingVoiceRecording else { return }
        voiceWarmupTask?.cancel()
        voiceWarmupTask = Task { @MainActor in
            _ = await backgroundRecording.prepareForRecordingIfAuthorized()
            guard !Task.isCancelled else { return }
            voiceWarmupTask = nil
        }
    }

    private func handleVoiceScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            syncVoiceRecordingFromGlobalState()
            if !backgroundRecording.hasInFlightRecording {
                prepareVoiceCaptureResources()
            }
        case .background:
            // The global recorder owns an active capture and is entitled to
            // continue through UIBackgroundModes=audio. Only stop visual work.
            stopVoiceDurationTimer()
            if !backgroundRecording.hasInFlightRecording {
                audioRecorder.invalidatePreparation(reason: "app en background sin captura")
            }
        case .inactive:
            // Permission sheets and Control Center temporarily make the scene
            // inactive. Do not tear down a valid capture for those transitions.
            break
        @unknown default:
            break
        }
    }

    private func handleVoiceAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return
        }

        // Category changes are emitted by our own warm-up and by narration;
        // startRecording validates the category again before activation.
        guard reason != .categoryChange, reason != .override else { return }
        audioRecorder.invalidatePreparation(reason: "ruta de audio \(reason.rawValue)")

        if isRecordingVoice, audioRecorder.hasActiveRecorder {
            finishVoiceRecordingVisualImmediately(captureTailPadding: false)
        } else if scenePhase == .active {
            prepareVoiceCaptureResources()
        }
    }

    private func handleVoiceAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            audioRecorder.invalidatePreparation(reason: "interrupción del sistema")
            if isRecordingVoice, audioRecorder.hasActiveRecorder {
                finishVoiceRecordingVisualImmediately(captureTailPadding: false)
            }
        case .ended:
            if scenePhase == .active {
                prepareVoiceCaptureResources()
            }
        @unknown default:
            break
        }
    }

    private func handleVoiceMediaServicesReset() {
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceWarmupTask?.cancel()
        audioRecorder.invalidatePreparation(reason: "media services reset")
        if isRecordingVoice {
            stopVoiceDurationTimer()
            audioRecorder.cancelRecording(prepareNext: false)
            applyInstantVoiceStateChange {
                isRecordingVoice = false
                recordingDuration = 0
                recordingLevel = 0
            }
            voiceErrorText = "El sistema de audio se reinició. Tocá el micrófono para volver a grabar."
        }
        prepareVoiceCaptureResources()
    }

    private func handleVoiceTouchDown() {
        let now = ProcessInfo.processInfo.systemUptime
        lastVoiceTouchDownUptime = now
        AppHaptics.shared.play(.voiceButtonPress)
        AppHaptics.shared.prepare(isRecordingVoice ? .voiceRecordingStop : .voiceRecordingStart)

        // A granted permission lets touch-down overlap recorder preparation
        // with the remainder of the physical tap. This never opens the mic.
        if !isRecordingVoice, audioRecorder.permission == .granted {
            prepareVoiceCaptureResources()
        }
    }

    private func playVoiceContactFeedbackFallbackIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard VoiceCapturePerformancePolicy.shouldPlayAccessibilityFeedbackFallback(
            lastTouchDownUptime: lastVoiceTouchDownUptime,
            actionUptime: now
        ) else {
            return
        }
        lastVoiceTouchDownUptime = now
        AppHaptics.shared.play(.voiceButtonPress)
    }

    private func handleVoiceButtonTap() {
        // VoiceOver and keyboard activation may invoke the action without a
        // physical pressed state, so retain one debounced fallback.
        playVoiceContactFeedbackFallbackIfNeeded()

        if isTranscribingVoice {
            return
        }

        if isRecordingVoice {
            finishVoiceRecordingVisualImmediately()
            return
        }

#if DEBUG
        if startVoiceFixtureIfConfigured() {
            return
        }
#endif

        if let reason = voiceCaptureBlockedReason {
            voiceErrorText = reason
            logVoice("Mic tap bloqueado: \(reason)", level: .error)
            return
        }

        voiceErrorText = nil
        switch audioRecorder.startPlan {
        case .rejectDeniedPermission:
            voiceErrorText = AudioRecordingService.RecordingError.microphoneDenied.localizedDescription
            showMicrophoneSettingsAlert = true
        case .requestPermission:
            requestVoicePermissionAndBegin()
        case .startPreparedRecorder, .prepareThenStart:
            beginVoiceRecordingVisualImmediately()
        }
    }

#if DEBUG
    /// Hook determinista de Simulator. No cambia producción: solo se activa
    /// cuando el proceso recibe explícitamente KYCODE_STABILITY_AUDIO_FIXTURE.
    private func startVoiceFixtureIfConfigured() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let filename = environment["KYCODE_STABILITY_AUDIO_FIXTURE"],
              !filename.isEmpty else {
            return false
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sourceURL = documents.appendingPathComponent(filename)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kycode-stability-\(UUID().uuidString).\(sourceURL.pathExtension)"
            )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        } catch {
            voiceErrorText = "No pude preparar el audio de prueba: \(error.localizedDescription)"
            return true
        }

        let duration = Double(environment["KYCODE_STABILITY_AUDIO_SECONDS"] ?? "") ?? 3
        lastRecordedVoiceDuration = duration
        isTranscribingVoice = false
        sendErrorText = nil
        voiceErrorText = nil
        let job = store.beginVoiceTranscription(windowId: windowId, duration: duration)
        store.attachRecordingAndStartVoiceTranscription(
            jobId: job.id,
            fileURL: temporaryURL,
            duration: duration
        )
        return true
    }
#endif

    private func applyInstantVoiceStateChange(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            updates()
        }
    }

    private func playVoiceStartFeedbackImmediately() {
        AppHaptics.shared.play(.voiceRecordingStart)
    }

    private func playVoiceStopFeedbackImmediately() {
        AppHaptics.shared.play(.voiceRecordingStop)
    }

    private func requestVoicePermissionAndBegin() {
        guard !isRequestingVoicePermission else { return }
        isRequestingVoicePermission = true
        voicePermissionTask?.cancel()
        voicePermissionTask = Task { @MainActor in
            let granted = await backgroundRecording.requestPermissionIfNeeded()
            guard !Task.isCancelled else { return }
            isRequestingVoicePermission = false
            voicePermissionTask = nil
            guard granted else {
                voiceErrorText = audioRecorder.lastError?.localizedDescription
                    ?? AudioRecordingService.RecordingError.microphoneDenied.localizedDescription
                showMicrophoneSettingsAlert = true
                return
            }
            _ = await backgroundRecording.prepareForRecordingIfAuthorized()
            guard !Task.isCancelled else { return }
            beginVoiceRecordingVisualImmediately()
        }
    }

    private func beginVoiceRecordingVisualImmediately() {
        guard !isVoiceBusy else { return }

        sendErrorText = nil
        voiceErrorText = nil
        applyInstantVoiceStateChange {
            lastRecordedVoiceDuration = 0
            recordingDuration = 0
            recordingLevel = 0
            isRecordingVoice = true
        }
        playVoiceStartFeedbackImmediately()

        let interactionStartedAt = lastVoiceTouchDownUptime
            ?? ProcessInfo.processInfo.systemUptime
        voiceStartTask?.cancel()
        voiceStartTask = Task { @MainActor in
            await startVoiceRecorderAfterVisualFlip(
                interactionStartedAt: interactionStartedAt
            )
        }
    }

    private func startVoiceRecorderAfterVisualFlip(
        interactionStartedAt: TimeInterval
    ) async {
        let started = await backgroundRecording.startRecording(
            windowId: windowId,
            interactionStartedAt: interactionStartedAt
        )
        if Task.isCancelled || !isRecordingVoice {
            if started, !backgroundRecording.belongs(to: windowId) {
                backgroundRecording.cancelRecording()
            }
            voiceStartTask = nil
            return
        }
        voiceStartTask = nil
        guard started else {
            stopVoiceDurationTimer()
            isRecordingVoice = false
            recordingDuration = 0
            recordingLevel = 0
            voiceErrorText = audioRecorder.lastError?.localizedDescription ?? "No pude iniciar la grabación."
            if case .microphoneDenied = audioRecorder.lastError {
                showMicrophoneSettingsAlert = true
            }
            logVoice("Falló el inicio de grabación: \(voiceErrorText ?? "sin detalle")", level: .error)
            return
        }

        syncVoiceRecordingFromGlobalState()
        startVoiceDurationTimer()
        if let metrics = audioRecorder.lastStartMetrics {
            logVoice(
                String(
                    format: "Grabación iniciada total=%.1fms warm=%@ target=%@",
                    metrics.contactToRecordingMilliseconds,
                    metrics.usedPreparedRecorder ? "sí" : "no",
                    metrics.meetsRecordingStartTarget ? "pass" : "medir-en-iPhone"
                )
            )
        } else {
            logVoice("Grabación iniciada")
        }
    }

    private func finishVoiceRecordingVisualImmediately(captureTailPadding: Bool = true) {
        guard isRecordingVoice else { return }

        // A second ultra-fast tap can arrive while Core Audio is activating.
        // Cancel it cleanly rather than create a failed transcription job or
        // let an orphan recorder start after the UI returned to idle.
        guard backgroundRecording.hasInFlightRecording,
              backgroundRecording.activeWindowId == windowId else {
            voiceStartTask?.cancel()
            voiceStartTask = nil
            audioRecorder.cancelPendingStart()
            backgroundRecording.cancelRecording()
            stopVoiceDurationTimer()
            applyInstantVoiceStateChange {
                isRecordingVoice = false
                recordingDuration = 0
                recordingLevel = 0
            }
            playVoiceStopFeedbackImmediately()
            prepareVoiceCaptureResources()
            return
        }

        let finalDuration = max(recordingDuration, backgroundRecording.duration)
        let pendingJob = store.beginVoiceTranscription(
            windowId: windowId,
            duration: finalDuration
        )

        stopVoiceDurationTimer()
        lastRecordedVoiceDuration = finalDuration
        applyInstantVoiceStateChange {
            isRecordingVoice = false
            isTranscribingVoice = false
            isFinalizingVoiceRecording = true
        }
        playVoiceStopFeedbackImmediately()
        voiceErrorText = nil
        sendErrorText = nil

        Task { @MainActor in
            await finishVoiceRecordingAndStartBackgroundTranscription(
                jobId: pendingJob.id,
                captureTailPadding: captureTailPadding
            )
        }
    }

    private func finishVoiceRecordingAndStartBackgroundTranscription(
        jobId: String,
        captureTailPadding: Bool
    ) async {
        if captureTailPadding {
            // Human speech often continues for a fraction of a second after
            // the finger begins the stop tap. Keep the recorder alive for a
            // tiny post-roll so the final syllable reaches the WAV while the
            // UI already acknowledges Stop immediately.
            try? await Task.sleep(
                for: .seconds(VoiceCapturePerformancePolicy.stopTailPaddingDuration)
            )
        }
        let result = await backgroundRecording.stopRecording()
        recordingDuration = 0
        recordingLevel = 0
        isFinalizingVoiceRecording = false

        guard let result else {
            let message = backgroundRecording.errorMessage
                ?? audioRecorder.lastError?.localizedDescription
                ?? "No pude cerrar la grabación."
            store.failVoiceTranscriptionPreparation(jobId: jobId, message: message)
            voiceErrorText = message
            logVoice("Grabación finalizada sin archivo válido", level: .error)
            return
        }

        store.attachRecordingAndStartVoiceTranscription(
            jobId: jobId,
            fileURL: result.fileURL,
            duration: result.duration
        )
        lastRecordedVoiceDuration = result.duration
        voiceErrorText = nil
        logVoice("Transcripción delegada al store job=\(jobId)")
    }

    private func retryPendingVoiceTranscription() async {
        guard let voiceDraft else { return }
        guard !isTranscribingVoice else { return }
        let activeDraft = voiceDraft

        isTranscribingVoice = true
        voiceErrorText = nil
        sendErrorText = nil
        logVoice("Reintento manual de transcripción file=\(activeDraft.fileURL.lastPathComponent)")

        guard let transcript = await store.transcribeAudioFile(filePath: activeDraft.fileURL.path) else {
            isTranscribingVoice = false
            syncVoiceDraftFromStore()
            return
        }

        isTranscribingVoice = false
        appendTranscriptToComposer(transcript)
        voiceErrorText = nil
        await submitComposer()
    }

    private func startVoiceDurationTimer() {
        stopVoiceDurationTimer()
        voiceDurationTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                guard backgroundRecording.belongs(to: windowId) else { return }
                recordingDuration = backgroundRecording.duration
                recordingLevel = backgroundRecording.level
            }
        }
        if let voiceDurationTimer {
            RunLoop.main.add(voiceDurationTimer, forMode: .common)
        }
    }

    private func stopVoiceDurationTimer() {
        voiceDurationTimer?.invalidate()
        voiceDurationTimer = nil
    }

    private func cancelVoiceRecording() {
        guard isRecordingVoice else { return }
        voiceStartTask?.cancel()
        voiceStartTask = nil
        audioRecorder.cancelPendingStart()
        stopVoiceDurationTimer()
        backgroundRecording.cancelRecording()
        isRecordingVoice = false
        isTranscribingVoice = false
        recordingDuration = 0
        recordingLevel = 0
        lastRecordedVoiceDuration = 0
        voiceErrorText = nil
        AppHaptics.shared.play(.destructiveDiscard)
        logVoice("Grabación cancelada")
    }

    private func teardownVoiceState(cancelRecording: Bool) {
        voicePermissionTask?.cancel()
        voicePermissionTask = nil
        voiceWarmupTask?.cancel()
        voiceWarmupTask = nil
        voiceStartTask?.cancel()
        voiceStartTask = nil
        stopVoiceDurationTimer()
        isRequestingVoicePermission = false
        isTranscribingVoice = false
        isRecordingVoice = false
        recordingDuration = 0
        recordingLevel = 0
        lastRecordedVoiceDuration = 0
        if cancelRecording,
           backgroundRecording.belongs(to: windowId),
           !isFinalizingVoiceRecording {
            // Teardown is now visual only. The app-global owner deliberately
            // keeps recording across navigation and background transitions.
            logVoice("Detalle cerrado; la grabación global continúa")
        }
    }

    private func syncVoiceRecordingFromGlobalState() {
        let belongsHere = backgroundRecording.belongs(to: windowId)
        let shouldShowRecording = VoiceCaptureContinuityPolicy.displaysLiveCapture(
            phase: backgroundRecording.phase,
            belongsToSession: belongsHere
        )
        applyInstantVoiceStateChange {
            isRecordingVoice = shouldShowRecording
            recordingDuration = belongsHere ? backgroundRecording.duration : 0
            recordingLevel = belongsHere ? backgroundRecording.level : 0
        }
        if backgroundRecording.phase == .recording, belongsHere, scenePhase == .active {
            startVoiceDurationTimer()
        } else {
            stopVoiceDurationTimer()
        }
        if belongsHere, let error = backgroundRecording.errorMessage, !error.isEmpty {
            voiceErrorText = error
        }
    }

    private func syncVoiceDraftFromStore() {
        guard let voiceDraft else {
            return
        }

        // Store-owned jobs already stream into an optimistic chat message and
        // send that same message when transcription finishes. Reusing the
        // legacy draft-recovery path here would duplicate the transcript in
        // the composer while the user is typing a new message.
        if activeVoiceJob != nil {
            voiceErrorText = activeVoiceJob?.phase == .failed
                ? activeVoiceJob?.errorMessage
                : nil
            sendErrorText = nil
            return
        }

        switch voiceDraft.transcriptStatus {
        case .success:
            if !isTranscribingVoice, let transcript = voiceDraft.transcriptText, !transcript.isEmpty {
                appendTranscriptToComposer(transcript)
                if voiceDraft.sendStatus == .failed {
                    sendErrorText = voiceDraft.errorMessage ?? "No se pudo enviar. Reintentá."
                } else {
                    sendErrorText = nil
                }
                voiceErrorText = nil
                return
            }
            if voiceDraft.sendStatus == .failed {
                sendErrorText = voiceDraft.errorMessage ?? "No se pudo enviar. Reintentá."
            } else {
                sendErrorText = nil
            }
            voiceErrorText = nil
        case .failed:
            voiceErrorText = voiceDraft.errorMessage ?? "Transcripción falló. Reintentá."
        case .pending:
            if !isTranscribingVoice {
                voiceErrorText = nil
            }
        }
    }

    private func discardCurrentVoiceDraft() {
        guard let voiceDraft else { return }
        store.deleteVoiceDraft(voiceDraft)
        composer = ""
        sendErrorText = nil
        voiceErrorText = nil
        isComposerFocused = false
        AppHaptics.shared.play(.destructiveDiscard)
        logVoice("Voice draft descartado por el usuario")
    }

    private func syncVoicePulseAnimation() {
        if isRecordingVoice, !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled {
            voicePulseActive = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                voicePulseActive = true
            }
        } else {
            voicePulseActive = false
        }
    }

    @ViewBuilder
    private func voiceDraftStatusCard(_ draft: VoiceDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    switch voicePhase {
                    case .transcribing, .sending:
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.85)
                    case .error:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(AppTheme.statusError)
                    default:
                        Image(systemName: "waveform")
                            .foregroundStyle(AppTheme.gold)
                    }
                }
                .font(.system(size: 13, weight: .bold))

                VStack(alignment: .leading, spacing: 4) {
                    Text(voiceDraftTitle(for: draft))
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                    Text(voiceDraftSubtitle(for: draft))
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(AppTheme.inkMuted)
                }

                Spacer(minLength: 10)

                Text(formattedVoiceDraftDuration(draft.duration))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkSoft)
            }

            HStack(spacing: 8) {
                switch voicePhase {
                case .transcribing, .sending:
                    EmptyView()
                case .draftReady:
                    draftActionButton("Editar") {
                        if let transcript = draft.transcriptText, composerTextTrimmed.isEmpty {
                            composer = transcript
                        }
                        isComposerFocused = true
                    }
                    draftActionButton("Enviar", isProminent: true) {
                        Task {
                            await submitComposer()
                        }
                    }
                    draftActionButton("Descartar", role: .destructive) {
                        showDiscardVoiceDraftAlert = true
                    }
                case .error:
                    if draft.transcriptStatus == .failed {
                        draftActionButton("Reintentar audio", isProminent: true) {
                            Task {
                                await retryPendingVoiceTranscription()
                            }
                        }
                    } else {
                        draftActionButton("Enviar", isProminent: true) {
                            Task {
                                await submitComposer()
                            }
                        }
                        draftActionButton("Editar") {
                            if let transcript = draft.transcriptText, composerTextTrimmed.isEmpty {
                                composer = transcript
                            }
                            isComposerFocused = true
                        }
                    }
                    draftActionButton("Descartar", role: .destructive) {
                        showDiscardVoiceDraftAlert = true
                    }
                default:
                    draftActionButton("Pasar a texto", isProminent: true) {
                        Task {
                            await retryPendingVoiceTranscription()
                        }
                    }
                    draftActionButton("Descartar", role: .destructive) {
                        showDiscardVoiceDraftAlert = true
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            AppTheme.highlightBackground,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
    }

    private func voiceDraftTitle(for draft: VoiceDraft) -> String {
        switch voicePhase {
        case .transcribing:
            return "Pasando el audio a texto..."
        case .sending:
            return "Enviando el mensaje..."
        case .draftReady:
            return "Audio guardado. Listo para enviar."
        case .error:
            if draft.transcriptStatus == .failed {
                return "No pude transcribir el audio."
            }
            return "No pude enviar el mensaje."
        default:
            return "Grabación guardada."
        }
    }

    private func voiceDraftSubtitle(for draft: VoiceDraft) -> String {
        switch voicePhase {
        case .transcribing:
            return "El audio ya está guardado en el teléfono."
        case .sending:
            return "No borro el audio hasta que el bridge confirme el envío."
        case .draftReady:
            return "Podés editar el texto antes de mandarlo o descartarlo."
        case .error:
            return draft.errorMessage ?? "El audio sigue guardado para que no se pierda."
        default:
            return "Si cerrás la app, este borrador sigue disponible."
        }
    }

    private func draftActionButton(
        _ title: String,
        isProminent: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .default))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(role == .destructive ? AppTheme.statusError : (isProminent ? Color.white : AppTheme.ink))
                .background(
                    Rectangle()
                        .fill(isProminent ? AppTheme.accent : AppTheme.cardSurfaceRaised)
                )
        }
        .buttonStyle(.plain)
        .compactTouchTarget()
    }

    private func logVoice(_ message: String, level: LogLevel = .debug) {
        let line = "[VoiceComposer] \(message)"
        LoggingService.logToFile(level: level, message: line)
        NSLog("%@", line)
    }

    private func syncFeatureState() {
        promptImproverEnabled = session?.features?.promptImproverEnabled ?? false
        explainerEnabled = session?.features?.explainerEnabled ?? false
    }

    private var minimizedToolbarButton: some View {
        let isMinimized = session?.minimized ?? false
        let isDisabled = session == nil || isUpdatingMinimized

        return Button {
            Task {
                await setMinimizedFromDetail(!isMinimized)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    .fill(toolbarIconButtonFill(isActive: isMinimized))
                    .frame(width: controlMetrics.featureToolbarButtonWidth, height: controlMetrics.featureToolbarButtonHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                            .stroke(Color.clear, lineWidth: 1)
                    )
                    .shadow(color: Color.clear, radius: 0)

                if isUpdatingMinimized {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(AppTheme.inkMuted)
                        .scaleEffect(controlMetrics.featureToolbarProgressScale)
                } else {
                    Image(systemName: isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus.square")
                        .font(.system(size: controlMetrics.isTablet ? 22 : controlMetrics.featureToolbarIconSize, weight: .semibold))
                        .foregroundStyle(isDisabled ? AppTheme.inkMuted : AppTheme.ink)
                }
            }
            .frame(width: controlMetrics.featureToolbarButtonWidth, height: controlMetrics.featureToolbarButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.9))
        .disabled(isDisabled)
        .accessibilityLabel(isMinimized ? "Restaurar sesión" : "Minimizar sesión")
    }

    private func setMinimizedFromDetail(_ minimized: Bool) async {
        guard let session else { return }
        isUpdatingMinimized = true
        let updated = await store.setSessionMinimized(windowId: session.windowId, minimized: minimized)
        isUpdatingMinimized = false
        if updated, minimized {
            dismiss()
        }
    }

    private func beginRename(_ session: KycodeSessionSummary) {
        RenameSessionHaptics.shared.longPressDetected()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            renameTarget = SessionRenameTarget(windowId: session.windowId, currentName: session.displayName)
        }
    }

    private func commitRename(_ target: SessionRenameTarget, name: String) {
        let trimmedName = String(name.prefix(SessionRenameRules.maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            RenameSessionHaptics.shared.nameError()
            renameErrorMessage = "El nombre no puede estar vacío."
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            renameTarget = nil
        }

        Task {
            let updated = await store.renameSession(windowId: target.windowId, newName: trimmedName)
            if !updated {
                await MainActor.run {
                    RenameSessionHaptics.shared.nameError()
                    renameTarget = SessionRenameTarget(
                        windowId: target.windowId,
                        currentName: target.currentName,
                        draftName: trimmedName
                    )
                    renameErrorMessage = SessionRenameRules.retryMessage(serverMessage: store.errorMessage)
                }
            } else {
                await MainActor.run {
                    RenameSessionHaptics.shared.nameSaved()
                }
            }
        }
    }

    private func togglePromptImprover() async {
        guard canControlFeatures else { return }
        await updateFeatures(
            promptImproverEnabled: !promptImproverEnabled,
            explainerEnabled: explainerEnabled,
            source: .promptImprover
        )
    }

    private func toggleExplainer() async {
        guard canControlFeatures else { return }
        await updateFeatures(
            promptImproverEnabled: promptImproverEnabled,
            explainerEnabled: !explainerEnabled,
            source: .explainer
        )
    }

    private func updateFeatures(
        promptImproverEnabled: Bool,
        explainerEnabled: Bool,
        source: FeatureToolbarControl
    ) async {
        self.promptImproverEnabled = promptImproverEnabled
        self.explainerEnabled = explainerEnabled
        isUpdatingFeatures = true
        updatingFeature = source
        failedFeatureUpdateRequest = nil
        featureUpdateErrorText = nil

        let result = await featureMutationQueue.submit(
            FeatureUpdateRequest(
                promptImproverEnabled: promptImproverEnabled,
                explainerEnabled: explainerEnabled,
                source: source
            )
        ) { request in
            await store.setFeatures(
                windowId: windowId,
                promptImproverEnabled: request.promptImproverEnabled,
                explainerEnabled: request.explainerEnabled
            )
        }

        guard case let .completed(finalRequest, succeeded) = result else {
            return
        }
        isUpdatingFeatures = false
        updatingFeature = nil
        if !succeeded {
            failedFeatureUpdateRequest = finalRequest
            featureUpdateErrorText = featureUpdateFailureMessage(for: finalRequest)
            syncFeatureState()
        }
    }

    private func featureUpdateFailureMessage(for request: FeatureUpdateRequest) -> String {
        let isEnabling: Bool
        let featureName: String
        switch request.source {
        case .promptImprover:
            isEnabling = request.promptImproverEnabled
            featureName = "Improver"
        case .explainer:
            isEnabling = request.explainerEnabled
            featureName = "Explainer"
        }

        let action = isEnabling ? "activar" : "desactivar"
        let reason = store.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty
            ? "No se pudo \(action) \(featureName). Revisá la conexión y reintentá."
            : "No se pudo \(action) \(featureName). \(reason)"
    }

    private func featureAccessibilityHint(
        control: FeatureToolbarControl,
        isActive: Bool,
        isBusy: Bool
    ) -> String {
        if isBusy {
            return "El cambio está en curso; podés tocar de nuevo para elegir el estado final"
        }
        switch control {
        case .promptImprover:
            return isActive
                ? "Desactiva la mejora para los próximos mensajes; no interrumpe una mejora ya iniciada"
                : "Mejora los próximos mensajes antes de enviarlos"
        case .explainer:
            return isActive
                ? "Desactiva el modo explicador para los próximos mensajes"
                : "Activa el modo explicador para los próximos mensajes"
        }
    }

    private func featureToolbarButton(
        symbol: String,
        control: FeatureToolbarControl,
        isActive: Bool,
        accessibilityLabel: String,
        action: @escaping () async -> Void
    ) -> some View {
        let isBusy = updatingFeature == control
        let metrics = controlMetrics

        return Button {
            AppHaptics.shared.play(
                control == .promptImprover ? .promptImproverToggle : .explainerToggle
            )
            Task {
                await action()
            }
        } label: {
            ZStack(alignment: .bottom) {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(featureToolbarForeground(isActive: isActive))
                            .scaleEffect(metrics.featureToolbarProgressScale)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: metrics.featureToolbarIconSize, weight: .semibold))
                            .foregroundStyle(featureToolbarForeground(isActive: isActive))
                    }
                }
                .frame(width: metrics.featureToolbarIconFrame, height: metrics.featureToolbarIconFrame)
                .accessibilityHidden(true)

                if isActive || isBusy {
                    Rectangle()
                        .fill(featureToolbarIndicator(isBusy: isBusy))
                        .frame(
                            width: isBusy ? metrics.featureToolbarBusyIndicatorWidth : metrics.featureToolbarIndicatorWidth,
                            height: metrics.featureToolbarIndicatorHeight
                        )
                        .padding(.bottom, metrics.featureToolbarIndicatorBottomPadding)
                }
            }
            .frame(width: metrics.featureToolbarButtonWidth, height: metrics.featureToolbarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    .fill(toolbarIconButtonFill(isActive: isActive))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
            )
            .shadow(color: Color.clear, radius: 0)
            .contentShape(Rectangle())
            .opacity(canControlFeatures ? 1 : 0.42)
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.18), value: isBusy)
            .animation(.easeInOut(duration: 0.18), value: featureControlsDisabled)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.9))
        .disabled(featureControlsDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isBusy ? "Sincronizando" : (isActive ? "Activado" : "Desactivado"))
        .accessibilityHint("Se sincroniza con desktop")
    }

    private func toolbarIconButtonFill(isActive: Bool) -> LinearGradient {
        let top: Color
        let bottom: Color
        if isActive {
            top = AppTheme.cloudAccentSoft
            bottom = AppTheme.highlightBackground.opacity(0.82)
        } else {
            top = AppTheme.cardSurfaceRaised
            bottom = AppTheme.cardSurface
        }

        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func featureToolbarForeground(isActive: Bool) -> Color {
        if !canControlFeatures {
            return AppTheme.inkMuted
        }
        return isActive ? AppTheme.accent : AppTheme.inkMuted
    }

    private func toolbarIconButtonBorder(isActive: Bool) -> Color {
        return isActive ? AppTheme.cardBorderActive : AppTheme.cardBorder
    }

    private func featureToolbarIndicator(isBusy: Bool) -> Color {
        isBusy ? AppTheme.inkMuted.opacity(0.78) : AppTheme.accent.opacity(0.72)
    }

    private func statusColor(for session: KycodeSessionSummary) -> Color {
        switch session.visualActivityStatus {
        case "working", "approval":
            return AppTheme.statusBusy
        case "error":
            return AppTheme.statusError
        case "ready", "done":
            return AppTheme.statusReady
        case "idle":
            return AppTheme.inkMuted
        default:
            return AppTheme.inkMuted
        }
    }
}

@MainActor
private struct SubagentParentNoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    private let originalText: String
    private let onSave: (String) -> Void
    @State private var workingText: String

    init(text: String, onSave: @escaping (String) -> Void) {
        originalText = text
        self.onSave = onSave
        _workingText = State(initialValue: text)
    }

    private var normalizedText: String {
        workingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedOriginalText: String {
        originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingChanges: Bool {
        normalizedText != normalizedOriginalText
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Este mensaje se inyecta en la sesión padre después de que el hijo acepta su tarea.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkMuted)

                TextEditor(text: $workingText)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.ink)
                    .tint(AppTheme.accent)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(10)
                    .background(AppTheme.cardSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.m))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.m)
                            .stroke(AppTheme.divider, lineWidth: 1)
                    }
                    .accessibilityLabel("Aviso de coordinación al padre")
                    .accessibilityIdentifier("subagent-parent-note-editor")
            }
            .padding(16)
            .background(AppTheme.backgroundSolid.ignoresSafeArea())
            .navigationTitle("Aviso al padre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(AppTheme.inkSoft)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hasPendingChanges ? "Guardar" : "Sin cambios") {
                        onSave(normalizedText)
                        dismiss()
                    }
                    .disabled(normalizedText.isEmpty || !hasPendingChanges)
                    .foregroundStyle(
                        hasPendingChanges ? AppTheme.accent : AppTheme.inkMuted
                    )
                    .accessibilityHint(
                        hasPendingChanges
                            ? "Guarda el aviso editado"
                            : "Editá el aviso para guardar"
                    )
                    .accessibilityIdentifier("subagent-parent-note-save")
                }
            }
        }
        .interactiveDismissDisabled(hasPendingChanges)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                editorFocused = true
            }
        }
    }
}

#if DEBUG
struct SubagentParentNoteEditorUITestHarness: View {
    @State private var isPresented = true
    @State private var savedText: String?

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            if let savedText {
                Text("Guardado: \(savedText)")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityIdentifier("subagent-parent-note-saved")
            }
        }
        .sheet(isPresented: $isPresented) {
            SubagentParentNoteEditorSheet(
                text: "Avisar al padre cuando el análisis esté listo."
            ) { updatedText in
                savedText = updatedText
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
#endif

private struct ComposerOcclusionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 60

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum KycodeTranscriptPresentationState: Equatable {
    case loading
    case failed(String)
    case incomplete(Int)
    case empty
    case processing
    case content
}

enum KycodeTranscriptPresentationPolicy {
    static func resolve(
        hasAuthoritativeDetail: Bool,
        hasMessages: Bool,
        expectedMessageCount: Int,
        isProcessing: Bool,
        detailLoadState: KycodeSessionDetailLoadState
    ) -> KycodeTranscriptPresentationState {
        if hasMessages { return .content }
        if case let .failed(message) = detailLoadState { return .failed(message) }
        if detailLoadState == .loading || !hasAuthoritativeDetail { return .loading }
        if isProcessing { return .processing }
        if expectedMessageCount > 0 { return .incomplete(expectedMessageCount) }
        return .empty
    }
}

private struct SessionTranscriptPane: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: KycodeSessionSummary?
    let visibleMessages: [KycodeMessage]
    let contentRevision: UInt64
    let hasAuthoritativeDetail: Bool
    let detailLoadState: KycodeSessionDetailLoadState
    let hasOlderMessages: Bool
    let olderMessageCount: Int
    let isProcessing: Bool
    let processingLabel: String
    let headerView: AnyView?
    let followBottomRequest: Int
    let selectedSearchMessageId: String?
    let floatingComposerHeight: CGFloat
    let savedMessageIds: Set<String>
    let fileBasePath: String?
    var promptTransformTimedOutMessageIds: Set<String> = []
    let onLoadOlderMessages: () -> Void
    let onRetryDetail: () -> Void
    let onRequestLatest: () -> Void
    let onQuoteMessage: (KycodeMessage) -> Void
    let onToggleSavedMessage: (KycodeMessage) -> Void
    let onRetryVoiceMessage: (KycodeMessage) -> Void
    let onRetryPromptImprover: (KycodeMessage) async -> KycodeSendResult
    let onOpenFile: (KycodeFileReference) -> Void
    let onOpenReaderDocument: (KycodeReaderDocument) -> Void

    @State private var didPerformInitialScroll = false
    @State private var followBottom = true
    @State private var unseenTailCount = 0
    @State private var didCaptureMessageBaseline = false
    @State private var knownMessageIds = Set<String>()
    @State private var visuallyStreamingMessageIds = Set<String>()
    @State private var bottomAnchorRevision = 0

    private struct SessionPresentationRevision: Equatable {
        let windowId: String?
        let messageCount: Int
        let activityStatus: String?
        let runtimeStatusDetail: String?
        let rawPrompt: String?
        let originalPrompt: String?
        let improvedPrompt: String?
    }

    private var sessionPresentationRevision: SessionPresentationRevision {
        SessionPresentationRevision(
            windowId: session?.windowId,
            messageCount: session?.messageCount ?? 0,
            activityStatus: session?.visualActivityStatus,
            runtimeStatusDetail: session?.runtimeStatusDetail,
            rawPrompt: session?.rawPrompt,
            originalPrompt: session?.originalPrompt,
            improvedPrompt: session?.improvedPrompt
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentRevision == rhs.contentRevision
            && lhs.sessionPresentationRevision == rhs.sessionPresentationRevision
            && lhs.hasAuthoritativeDetail == rhs.hasAuthoritativeDetail
            && lhs.detailLoadState == rhs.detailLoadState
            && lhs.hasOlderMessages == rhs.hasOlderMessages
            && lhs.olderMessageCount == rhs.olderMessageCount
            && lhs.isProcessing == rhs.isProcessing
            && lhs.processingLabel == rhs.processingLabel
            && (lhs.headerView == nil) == (rhs.headerView == nil)
            && lhs.followBottomRequest == rhs.followBottomRequest
            && lhs.selectedSearchMessageId == rhs.selectedSearchMessageId
            && lhs.floatingComposerHeight == rhs.floatingComposerHeight
            && lhs.savedMessageIds == rhs.savedMessageIds
            && lhs.fileBasePath == rhs.fileBasePath
            && lhs.promptTransformTimedOutMessageIds == rhs.promptTransformTimedOutMessageIds
    }

    private var bottomAnchorId: String {
        bottomAnchorId(for: bottomAnchorRevision)
    }

    private func bottomAnchorId(for revision: Int) -> String {
        "detail-bottom-\(revision)"
    }

    // A stable revision for the transcript's semantic tail. `bottomAnchorId`
    // alone is not enough while PROCESSING stays mounted: a final assistant
    // message can arrive behind the same processing anchor and remain below the
    // viewport. Including the latest message makes every completed turn advance
    // the reader to the actual response instead of leaving the improved prompt
    // on screen and making the answer look missing/misparsed.
    private var transcriptTailRevision: String {
        let latestMessage = visibleMessages.last
        return [
            latestMessage?.id ?? "none",
            String(contentRevision),
            String(visibleMessages.count),
            isProcessing ? "processing" : "settled",
        ].joined(separator: "|")
    }

    private var presentationState: KycodeTranscriptPresentationState {
        KycodeTranscriptPresentationPolicy.resolve(
            hasAuthoritativeDetail: hasAuthoritativeDetail,
            hasMessages: !visibleMessages.isEmpty,
            expectedMessageCount: session?.messageCount ?? 0,
            isProcessing: isProcessing,
            detailLoadState: detailLoadState
        )
    }

    private var detailFailureMessage: String? {
        guard case let .failed(message) = detailLoadState else { return nil }
        return message
    }

    private var runtimeFailureMessage: String? {
        guard let session else { return nil }
        return KycodeRuntimeFailurePresentationPolicy.message(
            activityStatus: session.visualActivityStatus,
            detail: session.runtimeStatusDetail
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = TranscriptReadingMetrics(size: geometry.size)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.messageSpacing) {
                            if let headerView {
                                headerView
                            }
                            conversationContent(for: session, metrics: metrics)
                            Color.clear
                                .frame(
                                    height: TranscriptFloatingControlLayout.transcriptTailClearance(
                                        composerHeight: floatingComposerHeight,
                                        baseline: metrics.bottomPadding
                                    )
                                )
                                .id(bottomAnchorId)
                                .onAppear {
                                    followBottom = true
                                }
                        }
                        .frame(maxWidth: metrics.contentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, metrics.topPadding)
                    }
                    .scrollIndicators(metrics.isReader ? .visible : .hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(.bottom)
                    .accessibilityIdentifier("session-transcript-scroll")
                    .background(transcriptBackground(isReader: metrics.isReader))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard value.translation.height > 8 else { return }
                                followBottom = false
                            }
                    )
                    .onAppear {
                        captureMessageBaselineIfNeeded(visibleMessages)
                        guard !didPerformInitialScroll else { return }
                        didPerformInitialScroll = true
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: visibleMessages) { _, messages in
                        reconcileVisualStreamingMessages(messages)
                    }
                    .onChange(of: transcriptTailRevision) { _, _ in
                        guard didPerformInitialScroll else { return }
                        if followBottom {
                            unseenTailCount = 0
                            // Streaming changes the layout many times per second.
                            // An overlapping 220 ms animation for every fragment
                            // creates visible stalls and can leave the anchor
                            // behind. Track it synchronously until the turn settles.
                            scrollToBottom(proxy, animated: !isProcessing)
                        } else {
                            unseenTailCount += 1
                        }
                    }
                    .onChange(of: followBottomRequest) { _, _ in
                        guard didPerformInitialScroll else { return }
                        followBottom = true
                        unseenTailCount = 0
                        scrollToBottom(proxy, animated: false, forceLayout: true)
                    }
                    .onChange(of: selectedSearchMessageId) { _, messageId in
                        guard let messageId else { return }
                        followBottom = false
                        if reduceMotion {
                            proxy.scrollTo(messageId, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo(messageId, anchor: .center)
                            }
                        }
                    }

                    if !followBottom {
                        Button {
                            followBottom = true
                            unseenTailCount = 0
                            AppHaptics.shared.play(.conversationSelection)
                            onRequestLatest()
                            scrollToBottom(proxy, animated: false, forceLayout: true)
                        } label: {
                            Label(
                                unseenTailCount > 0 ? "\(unseenTailCount) nuevos" : "Ir al final",
                                systemImage: "arrow.down"
                            )
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(AppTheme.accent, in: Rectangle())
                                .shadow(color: Color.clear, radius: 0)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.9))
                        .padding(.trailing, 16)
                        .padding(
                            .bottom,
                            TranscriptFloatingControlLayout.scrollButtonBottomPadding(
                                composerHeight: floatingComposerHeight
                            )
                        )
                        .accessibilityLabel("Ir al mensaje más reciente")
                        .accessibilityIdentifier("transcript-scroll-to-bottom")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func conversationContent(for session: KycodeSessionSummary?, metrics: TranscriptReadingMetrics) -> some View {
        switch presentationState {
        case .loading:
            transcriptLoadingView
        case let .failed(message):
            transcriptUnavailableView(
                title: "No se pudo cargar la conversación",
                detail: message,
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                accessibilityIdentifier: "session-transcript-failed"
            )
        case let .incomplete(messageCount):
            transcriptUnavailableView(
                title: "Faltan mensajes",
                detail: "La sesión informa \(messageCount) \(messageCount == 1 ? "mensaje" : "mensajes"), pero todavía no llegaron al teléfono.",
                systemImage: "text.badge.exclamationmark",
                accessibilityIdentifier: "session-transcript-incomplete"
            )
        case .empty:
            Text("Sin mensajes.")
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.inkSoft)
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
                .accessibilityIdentifier("session-transcript-empty")
        case .processing:
            ProcessingIndicator(label: processingLabel, detail: session?.runtimeStatusDetail)
                .id("processing-indicator")
        case .content:
            if let detailFailureMessage {
                InlineActionErrorCard(
                    text: detailFailureMessage,
                    buttonTitle: "Reintentar",
                    action: onRetryDetail
                )
                .accessibilityIdentifier("session-transcript-refresh-error")
            }
            if hasOlderMessages {
                loadOlderMessagesButton(metrics: metrics)
            }

            let latestUserMessageId = visibleMessages.last(where: { $0.role == "user" })?.id
            ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                if shouldShowDateSeparator(at: index) {
                    Text(dateSeparatorLabel(for: message.timestamp))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.inkMuted)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(AppTheme.cardSurfaceRaised.opacity(0.72), in: Rectangle())
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isHeader)
                }

                MessageBubble(
                    message: message,
                    windowId: session?.windowId ?? "",
                    metrics: metrics,
                    sessionOriginalPrompt: message.id == latestUserMessageId ? session?.originalPrompt ?? session?.rawPrompt : nil,
                    sessionImprovedPrompt: message.id == latestUserMessageId ? session?.improvedPrompt : nil,
                    visuallyStreamAssistantContent: visuallyStreamingMessageIds.contains(message.id),
                    responseIsProcessing: isProcessing,
                    promptTransformTimedOut: promptTransformTimedOutMessageIds.contains(message.id),
                    isSearchMatch: message.id == selectedSearchMessageId,
                    isSaved: savedMessageIds.contains(message.id),
                    fileBasePath: fileBasePath,
                    onQuote: { onQuoteMessage(message) },
                    onToggleSaved: { onToggleSavedMessage(message) },
                    onRetryVoice: { onRetryVoiceMessage(message) },
                    onRetryPromptImprover: { await onRetryPromptImprover(message) },
                    onOpenFile: onOpenFile,
                    onOpenReaderDocument: onOpenReaderDocument,
                    onVisualStreamCompleted: {
                        visuallyStreamingMessageIds.remove(message.id)
                    }
                )
                    .id(message.id)
            }
            if isProcessing {
                ProcessingIndicator(label: processingLabel, detail: session?.runtimeStatusDetail)
                    .id("processing-indicator")
            }
        }

        if detailFailureMessage == nil, let runtimeFailureMessage {
            InlineErrorCard(text: runtimeFailureMessage)
                .accessibilityIdentifier("session-runtime-error-card")
        }
    }

    private var transcriptLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.accentGreen)
            Text("Cargando conversación…")
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
            Text("Preparando los mensajes más recientes.")
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(AppTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-transcript-loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func transcriptUnavailableView(
        title: String,
        detail: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(AppTheme.inkMuted)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(AppTheme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Reintentar", action: onRetryDetail)
                .font(.system(size: 13, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 100, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("session-transcript-retry")
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func loadOlderMessagesButton(metrics: TranscriptReadingMetrics) -> some View {
        Button {
            onLoadOlderMessages()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                Text("Más (\(olderMessageCount))")
                    .font(.system(size: metrics.isWideReader ? 13 : 12, weight: .bold, design: .default))
            }
            .foregroundStyle(AppTheme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                AppTheme.cardSurfaceGlass.opacity(0.42),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.9))
        .accessibilityLabel("Cargar \(olderMessageCount) mensajes más antiguos")
    }

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard visibleMessages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let current = date(from: visibleMessages[index].timestamp)
        let previous = date(from: visibleMessages[index - 1].timestamp)
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    private func dateSeparatorLabel(for timestamp: Double) -> String {
        let value = date(from: timestamp)
        if Calendar.current.isDateInToday(value) { return "Hoy" }
        if Calendar.current.isDateInYesterday(value) { return "Ayer" }
        return value.formatted(date: .abbreviated, time: .omitted)
    }

    private func date(from timestamp: Double) -> Date {
        Date(timeIntervalSince1970: max(0, timestamp) / 1000)
    }

    private func captureMessageBaselineIfNeeded(_ messages: [KycodeMessage]) {
        guard !didCaptureMessageBaseline, !messages.isEmpty else { return }
        knownMessageIds = Set(messages.map(\.id))
        didCaptureMessageBaseline = true
    }

    private func reconcileVisualStreamingMessages(_ messages: [KycodeMessage]) {
        guard didCaptureMessageBaseline else {
            captureMessageBaselineIfNeeded(messages)
            return
        }

        let currentIds = Set(messages.map(\.id))
        for message in messages where
            !knownMessageIds.contains(message.id)
            && message.role != "user"
            && !message.id.lowercased().hasPrefix("explainer-") {
            visuallyStreamingMessageIds.insert(message.id)
        }
        knownMessageIds.formUnion(currentIds)
        visuallyStreamingMessageIds.formIntersection(currentIds)
    }

    @ViewBuilder
    private func transcriptBackground(isReader: Bool) -> some View {
        if isReader {
            ZStack {
                LinearGradient(
                    colors: [
                        AppTheme.cloudAbyss,
                        AppTheme.commandSurface.opacity(0.86),
                        AppTheme.cloudAbyss
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        AppTheme.cloudCyan.opacity(0.105),
                        Color.clear,
                        AppTheme.terminalGreen.opacity(0.045),
                        Color.black.opacity(0.34)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AppTheme.glassStroke.opacity(0.22))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea()
        } else {
            BreathingBackground()
        }
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        forceLayout: Bool = false
    ) {
        let targetId: String
        if forceLayout {
            bottomAnchorRevision &+= 1
            targetId = bottomAnchorId(for: bottomAnchorRevision)
        } else {
            targetId = bottomAnchorId
        }
        let semanticTailId = isProcessing
            ? "processing-indicator"
            : visibleMessages.last?.id

        DispatchQueue.main.async {
            // First reveal the last semantic element. This makes SwiftUI lay
            // out very long/actively changing transcripts before resolving the
            // clearance anchor that lives beneath the floating composer.
            if forceLayout, let semanticTailId {
                proxy.scrollTo(semanticTailId, anchor: .bottom)
            }

            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(targetId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(targetId, anchor: .bottom)
            }

            guard forceLayout else { return }
            // A streaming patch or composer-height preference can land in the
            // same render pass as the tap. Re-assert once after layout settles;
            // no animation means this cannot queue competing scroll animations.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        }
    }
}

private struct TranscriptReadingMetrics {
    let size: CGSize

    var isTablet: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    var isWideReader: Bool { size.width >= 768 }
    var isReader: Bool { true }
    var horizontalPadding: CGFloat { isTablet ? 34 : (isWideReader ? 28 : 20) }
    var topPadding: CGFloat { isTablet ? 16 : 8 }
    // The transcript scrolls beneath the floating composer, while this tail
    // clearance guarantees the final message remains fully revealable.
    var bottomPadding: CGFloat { isTablet ? 112 : (isWideReader ? 96 : 92) }
    var messageSpacing: CGFloat { isTablet ? 18 : 4 }
    var contentMaxWidth: CGFloat {
        if isTablet { return min(size.width - 128, 680) }
        return isWideReader ? min(size.width - 56, 1010) : max(size.width - 28, 280)
    }
    var assistantMessageMaxWidth: CGFloat { isTablet ? min(contentMaxWidth, 660) : contentMaxWidth }
    var userMessageMaxWidth: CGFloat {
        if isTablet { return min(contentMaxWidth * 0.72, 560) }
        return isWideReader ? min(contentMaxWidth * 0.70, 700) : min(contentMaxWidth * 0.84, 340)
    }
    var readerHorizontalInset: CGFloat {
        if isWideReader {
            return size.width >= 1024 ? 58 : 38
        }
        return size.width < 360 ? 14 : 16
    }
    var readerVerticalInset: CGFloat { isWideReader ? (size.width >= 1024 ? 34 : 28) : 20 }
    var readerCornerRadius: CGFloat { 0 }
}

private enum ReaderPalette {
    static let paper = AppTheme.cloudPanelRaised
    static let paperAlt = AppTheme.cloudPanel
    static let ink = AppTheme.ink
    static let inkSoft = AppTheme.inkSoft
    static let inkMuted = AppTheme.inkMuted
    static let chrome = AppTheme.cloudAbyss
    static let chromeBorder = AppTheme.glassStroke
    static let paperBorder = AppTheme.glassStroke
    static let paperHighlight = AppTheme.cloudCyan.opacity(0.48)
    static let codeBackground = AppTheme.codeSurface
    static let codeInk = AppTheme.ink
    static let darkCodeBackground = AppTheme.codeSurface
}

// "Pensando": tres puntos con bounce escalonado (delays 0 / .15 / .3s).
// Reemplaza el spinner.
private struct ThinkingDots: View {
    var color: Color = AppTheme.inkSoft
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private var shouldAnimate: Bool {
        !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .offset(y: shouldAnimate && animate ? -3 : 0)
                    .opacity(shouldAnimate ? (animate ? 1 : 0.5) : 0.78)
                    .animation(
                        shouldAnimate
                            ? .easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15)
                            : nil,
                        value: animate
                    )
            }
        }
        .onAppear { animate = shouldAnimate }
        .onChange(of: reduceMotion) { _, _ in animate = shouldAnimate }
        .accessibilityHidden(true)
    }
}

private struct VoiceRecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled {
            Circle()
                .fill(AppTheme.statusError)
                .frame(width: 9, height: 9)
        } else {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                let isVisible = Int(context.date.timeIntervalSince1970 / 0.55) % 2 == 0
                Circle()
                    .fill(AppTheme.statusError)
                    .frame(width: 9, height: 9)
                    .opacity(isVisible ? 1 : 0.25)
            }
        }
    }
}

private struct ProcessingIndicator: View {
    let label: String
    let detail: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    ThinkingDots()
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.inkSoft)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(AppTheme.inkMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [label, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        )
        .accessibilityIdentifier("session-processing-indicator")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct InlineActionErrorCard: View {
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(buttonTitle, action: action)
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.cloudDangerBackground,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct ImageAttachmentPreview: View {
    let attachment: KycodeImageAttachmentDraft
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Vista previa de \(attachment.name)")
                } else {
                    ContentUnavailableView(
                        "No se puede previsualizar",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(attachment.name)
                    )
                    .foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(
                    "\(attachment.name) · " +
                    ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.82))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar", action: onClose)
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .toolbarBackground(.black.opacity(0.82), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct MessageBubble: View {
    let message: KycodeMessage
    var windowId: String? = nil
    let metrics: TranscriptReadingMetrics
    let sessionOriginalPrompt: String?
    let sessionImprovedPrompt: String?
    let visuallyStreamAssistantContent: Bool
    let responseIsProcessing: Bool
    var promptTransformTimedOut = false
    let isSearchMatch: Bool
    let isSaved: Bool
    let fileBasePath: String?
    let onQuote: () -> Void
    let onToggleSaved: () -> Void
    let onRetryVoice: () -> Void
    let onRetryPromptImprover: () async -> KycodeSendResult
    let onOpenFile: (KycodeFileReference) -> Void
    let onOpenReaderDocument: (KycodeReaderDocument) -> Void
    let onVisualStreamCompleted: () -> Void

    @State private var appeared = false
    @State private var copiedNoticeVisible = false
    @State private var visualStreamAccessibilityValue = ""
    @State private var isRetryingPromptImprover = false
    @State private var isAwaitingPromptRetryResolution = false
    @State private var hasAcceptedPromptRetryContext = false
    @State private var acceptedPromptRetryFallbackBaseline: String?
    @State private var promptRetryHasResolvedOutput = false
    @State private var promptRetryError: String?
    @State private var promptRetryResolutionTimeoutTask: Task<Void, Never>?

    private var isUser: Bool { message.role == "user" }
    private var isReaderAssistant: Bool { metrics.isReader && !isUser }
    private var exposesVisualStreamTestState: Bool {
        !isUser && ProcessInfo.processInfo.environment["KYCODE_UI_TEST_VISUAL_STREAM"] == "1"
    }
    private var messageAccessibilityIdentifier: String {
        exposesVisualStreamTestState ? "progressive-message-\(message.id)" : "message-\(message.id)"
    }
    private var messageAccessibilityValue: String {
        if message.id.hasPrefix("voice-") {
            return "ack-timestamp-ms:\(Int(message.timestamp))"
        }
        return exposesVisualStreamTestState ? visualStreamAccessibilityValue : exactTimestampLabel
    }
    private var normalizedOriginalPrompt: String? {
        normalizePromptText(message.originalPrompt)
            ?? normalizePromptText(sessionOriginalPrompt)
            ?? normalizePromptText(message.content)
    }
    private var improvedPromptDocument: KycodeReaderDocument? {
        KycodeImprovedPromptPolicy.document(
            for: message,
            sessionImprovedPrompt: sessionImprovedPrompt
        )
    }
    private var normalizedSessionImprovedPrompt: String? {
        normalizePromptText(sessionImprovedPrompt)
    }
    private var displayContent: String {
        normalizedOriginalPrompt ?? message.content
    }

    private var copyableText: String {
        (isUser ? displayContent : message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var voiceStatusTitle: String? {
        VoiceTranscriptionPolicy.statusTitle(for: message.status)
    }

    private var voiceTranscriptionFailed: Bool {
        message.status == VoiceTranscriptionJobPhase.failed.messageStatus
    }

    private var promptTransformFailed: Bool {
        isUser && KycodePromptTransformStatePolicy.isFailed(message)
    }

    private var promptTransformPending: Bool {
        isUser && !promptTransformTimedOut
            && KycodePromptTransformStatePolicy.shouldShowPendingIndicator(
            for: message,
            responseIsProcessing: responseIsProcessing,
            hasResolvedFallbackOutput: improvedPromptDocument != nil
        )
    }

    private var promptTransformHasActionableFailure: Bool {
        isUser && (promptTransformFailed || promptTransformTimedOut || promptRetryError != nil)
    }

    private var promptTransformFailureTitle: String {
        if promptTransformTimedOut {
            return "No llegó el resultado de la mejora"
        }
        if promptRetryError != nil && !promptTransformFailed {
            return "Todavía no llegó el resultado"
        }
        return "No se pudo mejorar el prompt"
    }

    private var promptTransformStateSignature: String {
        [
            message.transformStatus ?? "",
            message.transformedPrompt ?? "",
            message.improvedPrompt ?? "",
            message.transformErrorReason ?? "",
            normalizedSessionImprovedPrompt ?? ""
        ].joined(separator: "|")
    }

    private var promptTransformFailureDetail: String {
        if promptTransformTimedOut {
            return "El prompt original sigue intacto. Podés volver a intentarlo."
        }
        let reason = message.transformErrorReason?.lowercased() ?? ""
        if reason.contains("sidecar_unavailable") {
            return "El servicio de transformación no está disponible."
        }
        if reason.contains("timeout") {
            return "La mejora tardó demasiado y se interrumpió."
        }
        if reason.contains("abort") || reason.contains("cancel") {
            return "La mejora se canceló antes de terminar."
        }
        return "El prompt original quedó intacto y podés volver a intentarlo."
    }

    private var promptRetryStatusText: String {
        if isRetryingPromptImprover {
            return "Enviando reintento…"
        }
        if isAwaitingPromptRetryResolution {
            return "Reintento aceptado…"
        }
        return "Mejorando el prompt…"
    }

    private var explanationDocument: KycodeReaderDocument? {
        KycodeExplanationPolicy.document(for: message)
    }

    var body: some View {
        Group {
            if let explanationDocument {
                explanationLauncherMessage(explanationDocument)
            } else if isReaderAssistant {
                readerAssistantMessage
            } else {
                compactMessage
            }
        }
        // Entrada de turno: offset(y: 10 → 0) + opacity 0 → 1, ~320ms easeOut.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) { appeared = true }
        }
        .onChange(of: promptTransformStateSignature) { _, _ in
            reconcileAcceptedPromptRetry()
        }
        .onDisappear {
            promptRetryResolutionTimeoutTask?.cancel()
            promptRetryResolutionTimeoutTask = nil
        }
        .padding(3)
        .background(
            isSearchMatch ? AppTheme.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
        )
        .overlay {
            if isSearchMatch {
                RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                    .stroke(Color.clear, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if copiedNoticeVisible {
                Label("Copiado", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(Color.black.opacity(0.82), in: Rectangle())
                    .offset(y: -18)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contextMenu {
            Button(action: onQuote) {
                Label("Responder citando", systemImage: "arrowshape.turn.up.left")
            }

            Button(action: onToggleSaved) {
                Label(
                    isSaved ? "Quitar de guardados" : "Guardar mensaje",
                    systemImage: isSaved ? "bookmark.slash" : "bookmark"
                )
            }

            if !copyableText.isEmpty {
                ShareLink(item: copyableText) {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }
            }

            if !copyableText.isEmpty {
                Button {
                    copyMessage()
                } label: {
                    Label("Copiar mensaje", systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityAction(named: "Copiar mensaje") {
            guard !copyableText.isEmpty else { return }
            copyMessage()
        }
        .accessibilityAction(named: "Responder citando", onQuote)
        .accessibilityAction(named: isSaved ? "Quitar de guardados" : "Guardar mensaje", onToggleSaved)
    }

    private func explanationLauncherMessage(_ document: KycodeReaderDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                Text("EXPLAINER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                Spacer(minLength: 0)
                Text(relativeTime(from: message.timestamp))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(AppTheme.inkMuted)
                    .accessibilityIdentifier(messageAccessibilityIdentifier)
                    .accessibilityValue(messageAccessibilityValue)
            }
            .foregroundStyle(AppTheme.accent)

            Button {
                onOpenReaderDocument(document)
            } label: {
                ExplanationLauncher(document: document)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.90))
            .accessibilityLabel("Ver explicación")
            .accessibilityHint("Abre la explicación en el lector")
            .accessibilityIdentifier("explanation-open-\(message.id)")
        }
        .frame(maxWidth: metrics.assistantMessageMaxWidth, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    // Transcripción a ancho completo: sin caja de "papel", sin rail cian/verde,
    // sin glow. Sólo etiqueta + cuerpo sobre el ground.
    // Transcripción a ancho completo: sin caja, sin rail, sin glow.
    // Assistant (KyCode): etiqueta inkMuted + cuerpo ink, ancho completo.
    private var readerAssistantMessage: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))

                Text("FERMÍN")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.35)

                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 18, height: 2)
                Spacer(minLength: 0)
                Text(relativeTime(from: message.timestamp))
                    .font(.system(size: 10.5, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
                    .accessibilityValue(messageAccessibilityValue)
                    .accessibilityIdentifier(messageAccessibilityIdentifier)
            }
            .foregroundStyle(AppTheme.accent)

            if let attachments = message.imageAttachments, !attachments.isEmpty {
                MessageAttachmentGrid(attachments: attachments, windowId: windowId)
            }

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressiveAssistantMarkdownText(
                    messageId: message.id,
                    markdown: message.content,
                    presentation: metrics.isWideReader ? .readerAssistant : .compactReaderAssistant,
                    fileBasePath: fileBasePath,
                    enabled: visuallyStreamAssistantContent,
                    responseIsProcessing: responseIsProcessing,
                    onOpenFile: onOpenFile,
                    onProgress: { progressValue in
                        guard exposesVisualStreamTestState else { return }
                        visualStreamAccessibilityValue = progressValue
                    },
                    onCompleted: onVisualStreamCompleted
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: metrics.assistantMessageMaxWidth, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            Color.clear,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.accent)
                .frame(width: 2)
                .padding(.vertical, 13)
                .offset(x: 1)
        }
        .textSelection(.enabled)
    }

    private var exactTimestampLabel: String {
        guard message.timestamp > 0 else { return "Sin hora" }
        return Date(timeIntervalSince1970: message.timestamp / 1000)
            .formatted(date: .abbreviated, time: .standard)
    }

    private func copyMessage() {
        UIPasteboard.general.string = copyableText
        AppHaptics.shared.play(.conversationSelection)
        withAnimation(.easeOut(duration: 0.14)) {
            copiedNoticeVisible = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.12)) {
                copiedNoticeVisible = false
            }
        }
    }

    private func retryPromptImprover() {
        guard !isRetryingPromptImprover else { return }
        let fallbackBaseline = normalizedSessionImprovedPrompt
        isRetryingPromptImprover = true
        promptRetryError = nil
        AppHaptics.shared.play(.conversationSelection)
        Task {
            let result = await onRetryPromptImprover()
            isRetryingPromptImprover = false
            if result.sent {
                beginAcceptedPromptRetryWait(fallbackBaseline: fallbackBaseline)
            } else {
                promptRetryError = result.errorMessage ?? "No se pudo reintentar."
                AppHaptics.shared.play(.messageSendError)
            }
        }
    }

    private func beginAcceptedPromptRetryWait(fallbackBaseline: String?) {
        promptRetryResolutionTimeoutTask?.cancel()
        acceptedPromptRetryFallbackBaseline = fallbackBaseline
        hasAcceptedPromptRetryContext = true
        promptRetryHasResolvedOutput = false
        isAwaitingPromptRetryResolution = true
        reconcileAcceptedPromptRetry()
        guard isAwaitingPromptRetryResolution else { return }
        promptRetryResolutionTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard isAwaitingPromptRetryResolution else { return }
            isAwaitingPromptRetryResolution = false
            promptRetryResolutionTimeoutTask = nil
            promptRetryError =
                "El reintento fue aceptado, pero todavía no llegó el resultado. Podés probar de nuevo."
        }
    }

    private func reconcileAcceptedPromptRetry() {
        guard hasAcceptedPromptRetryContext else { return }
        let hasNewResolvedFallback = improvedPromptDocument != nil
            && normalizedSessionImprovedPrompt != nil
            && normalizedSessionImprovedPrompt != acceptedPromptRetryFallbackBaseline
        if KycodePromptTransformStatePolicy.hasResolvedOutput(message)
            || hasNewResolvedFallback {
            promptRetryHasResolvedOutput = true
            promptRetryError = nil
        } else if KycodePromptTransformStatePolicy.isFailed(message) {
            return
        } else {
            promptRetryError = nil
            return
        }
        isAwaitingPromptRetryResolution = false
        promptRetryResolutionTimeoutTask?.cancel()
        promptRetryResolutionTimeoutTask = nil
    }

    // Mensaje propio al final, como Fermín: compacto y claramente distinguible.
    private var compactMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachments = message.imageAttachments, !attachments.isEmpty {
                MessageAttachmentGrid(attachments: attachments, windowId: windowId)
            }

            if !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownBubbleText(
                    markdown: displayContent,
                    isUser: true,
                    presentation: .compact,
                    fileBasePath: fileBasePath,
                    onOpenFile: onOpenFile
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !promptRetryHasResolvedOutput
                && promptRetryError == nil
                && (promptTransformPending || isRetryingPromptImprover || isAwaitingPromptRetryResolution) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                    Text(promptRetryStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(minHeight: 36)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("prompt-improver-loading-\(message.id)")
            } else if promptTransformHasActionableFailure && !promptRetryHasResolvedOutput {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        promptTransformFailureTitle,
                        systemImage: promptTransformTimedOut
                            ? "clock.badge.exclamationmark"
                            : "exclamationmark.triangle.fill"
                    )
                        .font(.system(size: 11, weight: .bold))
                    Text(promptRetryError ?? promptTransformFailureDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Button("Reintentar") {
                        retryPromptImprover()
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 88, minHeight: 36)
                    .v2RaisedSurface(
                        fill: Color.white.opacity(0.14),
                        topLight: Color.white.opacity(0.12)
                    )
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Reintentar mejora del prompt")
                    .accessibilityIdentifier("prompt-improver-retry-\(message.id)")
                }
                .padding(10)
                .v2InsetSurface(fill: Color.black.opacity(0.15))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("prompt-improver-error-\(message.id)")
            }

            if let voiceStatusTitle {
                HStack(spacing: 7) {
                    if voiceTranscriptionFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.white)
                    } else {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.mini)
                    }
                    Text(voiceStatusTitle)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 4)
                    if voiceTranscriptionFailed {
                        Button("Reintentar", action: onRetryVoice)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .compactTouchTarget()
                            .accessibilityLabel("Reintentar transcripción")
                            .accessibilityIdentifier("voice-message-retry-\(message.id)")
                    }
                }
                .accessibilityElement(children: voiceTranscriptionFailed ? .contain : .combine)
                .accessibilityLabel(voiceStatusTitle)
                .accessibilityValue("ack-timestamp-ms:\(Int(message.timestamp))")
                .accessibilityIdentifier("voice-message-status-\(message.id)")
            }

            if let improvedPromptDocument {
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        onOpenReaderDocument(improvedPromptDocument)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Ver prompt mejorado")
                                .font(.system(size: 11.5, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98, opacity: 0.86))
                    .accessibilityLabel("Ver prompt mejorado")
                    .accessibilityHint("Abre el prompt mejorado en el lector")
                    .accessibilityIdentifier("improved-prompt-open-\(message.id)")

                    Spacer(minLength: 10)
                    messageTimestamp
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("VOS")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(Color.white.opacity(0.68))
                    Spacer(minLength: 10)
                    messageTimestamp
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(
            AppTheme.userBubble,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                .stroke(AppTheme.surfaceTopLight, lineWidth: 1)
        }
        .frame(maxWidth: metrics.userMessageMaxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .textSelection(.enabled)
    }

    private var messageTimestamp: some View {
        Text(relativeTime(from: message.timestamp))
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.68))
            .accessibilityValue(messageAccessibilityValue)
            .accessibilityIdentifier(messageAccessibilityIdentifier)
    }

    // Byline: toda la cadena "Nombre · hora" en un solo color (12/600).
    // KyCode → inkMuted; Vos → accent.
    private func messageByline(name: String, color: Color) -> some View {
        Text("\(name) · \(relativeTime(from: message.timestamp))")
            .font(.system(size: 12, weight: .semibold, design: .default))
            .foregroundStyle(color)
    }

    private func relativeTime(from timestamp: Double) -> String {
        guard timestamp > 0 else { return "now" }
        let delta = max(0, Date().timeIntervalSince1970 - timestamp / 1000)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        return "\(Int(delta / 86_400))d"
    }

    private func normalizePromptText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ComposerAttachmentRemoveButton: View {
    let name: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.82), in: Rectangle())
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quitar \(name)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#if DEBUG
struct ServerSwitcherUITestHarness: View {
    @State private var selectedProfileId = "personal"
    @State private var switchingProfileId: String?

    private let profiles = [
        KycodeConnectionProfile(
            id: "puky",
            name: "Puky",
            mode: .ferminCode,
            remoteBaseURL: "https://desktop.example.com",
            preferredBonjourServiceHint: nil,
            lastDiscoveredBonjourURL: nil,
            lastDiscoveredBonjourToken: nil,
            lastDiscoveredBonjourNetworkPrefix: nil
        ),
        KycodeConnectionProfile(
            id: "personal",
            name: "Mac personal",
            mode: .personal,
            remoteBaseURL: "https://relay.example.com/fermin-code",
            preferredBonjourServiceHint: nil,
            lastDiscoveredBonjourURL: nil,
            lastDiscoveredBonjourToken: nil,
            lastDiscoveredBonjourNetworkPrefix: nil
        ),
        KycodeConnectionProfile(
            id: "all",
            name: "Todo",
            mode: .all,
            remoteBaseURL: nil,
            preferredBonjourServiceHint: nil,
            lastDiscoveredBonjourURL: nil,
            lastDiscoveredBonjourToken: nil,
            lastDiscoveredBonjourNetworkPrefix: nil
        ),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("KyCode")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(AppTheme.ink)

                Text("Switcher de servidor")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            PhoneDashboardBottomDock {
                EmptyView()
            } actions: {
                HStack(spacing: 10) {
                    DashboardServerSwitcher(
                        profiles: profiles,
                        selectedProfileId: selectedProfileId,
                        switchingProfileId: switchingProfileId,
                        isConnected: true,
                        reduceMotion: false,
                        onSelectProfile: selectProfile
                    )

                    Button {} label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(AppTheme.accent, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Acciones y vistas")
                    .accessibilityIdentifier("server-switcher-floating-menu")
                }
            }
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }

    private func selectProfile(_ profileId: String) {
        guard profileId != selectedProfileId, switchingProfileId == nil else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            switchingProfileId = profileId
            selectedProfileId = profileId
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.easeOut(duration: 0.16)) {
                switchingProfileId = nil
            }
        }
    }
}

struct PhoneRecordingParityUITestHarness: View {
    @State private var navigationPath: [String] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sesión \(index + 1)")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(AppTheme.ink)
                                Text("Vista previa de una conversación activa en KyCode.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppTheme.inkSoft)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(AppTheme.cardSurfaceRaised, in: Rectangle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
                }

                PhoneDashboardBottomDock {
                    Button {
                        navigationPath = ["recording-session"]
                    } label: {
                        BackgroundRecordingIndicator(
                            phase: .recording,
                            duration: 42,
                            sessionName: "Sesión de grabación activa"
                        )
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.97, opacity: 0.92))
                    .accessibilityIdentifier("background-recording-indicator")
                    .frame(maxWidth: 280, alignment: .leading)
                    .layoutPriority(1)
                } actions: {
                    Button {} label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(AppTheme.accent, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Acciones y vistas")
                    .accessibilityIdentifier("phone-parity-floating-menu")
                }
            }
            .background(AppTheme.backgroundSolid.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { _ in
                VStack(spacing: 18) {
                    Text("Sesión de grabación activa")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                        .accessibilityIdentifier("phone-parity-recording-detail")
                    Text("La grabación global continúa")
                        .foregroundStyle(AppTheme.inkSoft)
                    Button("Volver a Home") {
                        navigationPath.removeAll()
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("phone-parity-back-home")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.backgroundSolid.ignoresSafeArea())
                .navigationTitle("Sesión")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct PromptImproverUITestHarness: View {
    @StateObject private var readerModel = ExplanationViewerViewModel()

    private let message = KycodeMessage(
        id: "user-ui-test",
        role: "user",
        type: "user",
        content: "Necesito un resumen corto del estado.",
        originalPrompt: "Necesito un resumen corto del estado.",
        transformedPrompt: nil,
        improvedPrompt: """
        # Prompt mejorado confidencial

        Prepará un resumen ejecutivo del estado actual con:

        - avances verificables;
        - bloqueos reales;
        - siguiente acción concreta.
        """,
        timestamp: 1_785_000_000_000,
        status: nil,
        imageAttachments: nil
    )

    var body: some View {
        GeometryReader { geometry in
            let metrics = TranscriptReadingMetrics(size: geometry.size)
            MessageBubble(
                message: message,
                metrics: metrics,
                sessionOriginalPrompt: nil,
                sessionImprovedPrompt: nil,
                visuallyStreamAssistantContent: false,
                responseIsProcessing: false,
                isSearchMatch: false,
                isSaved: false,
                fileBasePath: nil,
                onQuote: {},
                onToggleSaved: {},
                onRetryVoice: {},
                onRetryPromptImprover: { .success },
                onOpenFile: { _ in },
                onOpenReaderDocument: { readerModel.present($0) },
                onVisualStreamCompleted: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .fullScreenCover(
            isPresented: Binding(
                get: { readerModel.isPresented },
                set: { if !$0 { readerModel.dismiss() } }
            )
        ) {
            ExplanationViewerSheet(viewModel: readerModel)
        }
    }
}

struct CompactActionTouchTargetsUITestHarness: View {
    @State private var noticeCount = 0
    @State private var copyCount = 0
    @State private var voiceRetryCount = 0
    @State private var showsError = true

    private let failedVoiceMessage = KycodeMessage(
        id: "voice-touch-target",
        role: "user",
        type: "voice",
        content: "Audio pendiente de transcripción",
        originalPrompt: "Audio pendiente de transcripción",
        transformedPrompt: nil,
        improvedPrompt: nil,
        timestamp: 1_785_000_000_000,
        status: VoiceTranscriptionJobPhase.failed.messageStatus,
        imageAttachments: nil
    )

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Acciones secundarias")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(AppTheme.ink)

                    ConnectionNoticeCard(
                        text: "Se perdió la conexión. Podés seguir leyendo.",
                        isBusy: false,
                        actionTitle: "Reconectar",
                        action: { noticeCount += 1 }
                    )

                    if showsError {
                        InlineErrorCard(
                            text: "No se pudo actualizar la sesión.",
                            onDismiss: { showsError = false },
                            onCopy: { copyCount += 1 }
                        )
                    }

                    MessageBubble(
                        message: failedVoiceMessage,
                        metrics: TranscriptReadingMetrics(size: geometry.size),
                        sessionOriginalPrompt: nil,
                        sessionImprovedPrompt: nil,
                        visuallyStreamAssistantContent: false,
                        responseIsProcessing: false,
                        isSearchMatch: false,
                        isSaved: false,
                        fileBasePath: nil,
                        onQuote: {},
                        onToggleSaved: {},
                        onRetryVoice: { voiceRetryCount += 1 },
                        onRetryPromptImprover: { .success },
                        onOpenFile: { _ in },
                        onOpenReaderDocument: { _ in },
                        onVisualStreamCompleted: {}
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    Text("reconectar=\(noticeCount) copiar=\(copyCount) voz=\(voiceRetryCount)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.inkMuted)
                        .accessibilityIdentifier("compact-action-counts")
                }
                .padding(20)
            }
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }
}

struct PromptImproverReconciliationUITestHarness: View {
    @State private var resolved = false
    @StateObject private var readerModel = ExplanationViewerViewModel()

    private var message: KycodeMessage {
        KycodeMessage(
            id: "user-ui-test-reconciliation",
            role: "user",
            type: "user",
            content: "Ordená los próximos pasos de esta sesión.",
            originalPrompt: "Ordená los próximos pasos de esta sesión.",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 1_785_000_000_000,
            status: nil,
            imageAttachments: nil,
            transformStatus: " PROCESSING ",
            transformErrorReason: nil,
            promptTransformNote: resolved ? "Mejorado" : nil
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = TranscriptReadingMetrics(size: geometry.size)
            MessageBubble(
                message: message,
                metrics: metrics,
                sessionOriginalPrompt: nil,
                sessionImprovedPrompt: resolved
                    ? "Ordená los próximos pasos por impacto, dependencia y riesgo."
                    : nil,
                visuallyStreamAssistantContent: false,
                // Reproduce the reported race exactly: the assistant keeps
                // processing after the improved prompt is already available.
                responseIsProcessing: true,
                isSearchMatch: false,
                isSaved: false,
                fileBasePath: nil,
                onQuote: {},
                onToggleSaved: {},
                onRetryVoice: {},
                onRetryPromptImprover: { .success },
                onOpenFile: { _ in },
                onOpenReaderDocument: { readerModel.present($0) },
                onVisualStreamCompleted: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .overlay(alignment: .bottomLeading) {
            if !resolved {
                Button("Simular resolución del backend") {
                    resolved = true
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .background(AppTheme.accent, in: Rectangle())
                .padding(20)
                .accessibilityIdentifier("prompt-reconciliation-resolve")
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { readerModel.isPresented },
                set: { if !$0 { readerModel.dismiss() } }
            )
        ) {
            ExplanationViewerSheet(viewModel: readerModel)
        }
    }
}

struct PromptImproverTimeoutUITestHarness: View {
    @State private var timedOut = true
    @State private var resolved = false
    @StateObject private var readerModel = ExplanationViewerViewModel()

    private var message: KycodeMessage {
        KycodeMessage(
            id: "user-ui-test-timeout",
            role: "user",
            type: "user",
            content: "Ordená los riesgos de esta entrega.",
            originalPrompt: "Ordená los riesgos de esta entrega.",
            transformedPrompt: resolved
                ? "Ordená los riesgos por impacto, probabilidad y mitigación."
                : nil,
            improvedPrompt: resolved
                ? "Ordená los riesgos por impacto, probabilidad y mitigación."
                : nil,
            timestamp: 1_785_000_000_000,
            status: nil,
            imageAttachments: nil,
            transformStatus: resolved ? "done" : "processing",
            transformErrorReason: nil,
            promptTransformNote: resolved ? "Mejorado" : nil
        )
    }

    var body: some View {
        GeometryReader { geometry in
            MessageBubble(
                message: message,
                metrics: TranscriptReadingMetrics(size: geometry.size),
                sessionOriginalPrompt: nil,
                sessionImprovedPrompt: nil,
                visuallyStreamAssistantContent: false,
                responseIsProcessing: false,
                promptTransformTimedOut: timedOut,
                isSearchMatch: false,
                isSaved: false,
                fileBasePath: nil,
                onQuote: {},
                onToggleSaved: {},
                onRetryVoice: {},
                onRetryPromptImprover: {
                    try? await Task.sleep(for: .seconds(2))
                    timedOut = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        resolved = true
                    }
                    return .success
                },
                onOpenFile: { _ in },
                onOpenReaderDocument: { readerModel.present($0) },
                onVisualStreamCompleted: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }
}

struct PromptImproverFailureUITestHarness: View {
    @State private var retryResolved = false
    @StateObject private var readerModel = ExplanationViewerViewModel()

    private var message: KycodeMessage {
        KycodeMessage(
            id: "user-ui-test-failure",
            role: "user",
            type: "user",
            content: "Prepará un resumen de la sesión.",
            originalPrompt: "Prepará un resumen de la sesión.",
            transformedPrompt: retryResolved ? "Prepará un resumen ejecutivo con avances y próximos pasos." : nil,
            improvedPrompt: retryResolved ? "Prepará un resumen ejecutivo con avances y próximos pasos." : nil,
            timestamp: 1_785_000_000_000,
            status: retryResolved ? "sent" : "error",
            imageAttachments: nil,
            transformStatus: retryResolved ? "done" : " CANCELLED ",
            transformErrorReason: nil,
            promptTransformNote: retryResolved ? nil : "raw-error"
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = TranscriptReadingMetrics(size: geometry.size)
            MessageBubble(
                message: message,
                metrics: metrics,
                sessionOriginalPrompt: nil,
                sessionImprovedPrompt: nil,
                visuallyStreamAssistantContent: false,
                responseIsProcessing: false,
                isSearchMatch: false,
                isSaved: false,
                fileBasePath: nil,
                onQuote: {},
                onToggleSaved: {},
                onRetryVoice: {},
                onRetryPromptImprover: {
                    try? await Task.sleep(for: .seconds(2))
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        retryResolved = true
                    }
                    return .success
                },
                onOpenFile: { _ in },
                onOpenReaderDocument: { readerModel.present($0) },
                onVisualStreamCompleted: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }
}

struct PromptImproverFallbackRetryUITestHarness: View {
    private static let previousFallback = "Prepará un resumen ejecutivo anterior."
    private static let newFallback =
        "Prepará un resumen ejecutivo con avances, riesgos y próximos pasos."

    let startsWithStaleFallback: Bool
    @State private var sessionImprovedPrompt: String?
    @StateObject private var readerModel = ExplanationViewerViewModel()

    init(startsWithStaleFallback: Bool) {
        self.startsWithStaleFallback = startsWithStaleFallback
        _sessionImprovedPrompt = State(
            initialValue: startsWithStaleFallback ? Self.previousFallback : nil
        )
    }

    private var messageID: String {
        startsWithStaleFallback
            ? "user-ui-test-retry-stale-fallback"
            : "user-ui-test-retry-fallback"
    }

    private var message: KycodeMessage {
        KycodeMessage(
            id: messageID,
            role: "user",
            type: "user",
            content: "Prepará un resumen de la sesión.",
            originalPrompt: "Prepará un resumen de la sesión.",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 1_785_000_000_000,
            status: "error",
            imageAttachments: nil,
            transformStatus: " CANCELLED ",
            transformErrorReason: "old_failure",
            promptTransformNote: "raw-error"
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = TranscriptReadingMetrics(size: geometry.size)
            MessageBubble(
                message: message,
                metrics: metrics,
                sessionOriginalPrompt: nil,
                sessionImprovedPrompt: sessionImprovedPrompt,
                visuallyStreamAssistantContent: false,
                responseIsProcessing: false,
                isSearchMatch: false,
                isSaved: false,
                fileBasePath: nil,
                onQuote: {},
                onToggleSaved: {},
                onRetryVoice: {},
                onRetryPromptImprover: {
                    try? await Task.sleep(for: .seconds(2))
                    return .success
                },
                onOpenFile: { _ in },
                onOpenReaderDocument: { readerModel.present($0) },
                onVisualStreamCompleted: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                if startsWithStaleFallback {
                    Button("Reemitir resultado anterior") {
                        sessionImprovedPrompt = "  \(Self.previousFallback)  "
                    }
                    .accessibilityIdentifier("prompt-retry-reemit-stale-fallback")
                }
                Button("Publicar resultado nuevo") {
                    sessionImprovedPrompt = Self.newFallback
                }
                .accessibilityIdentifier("prompt-retry-publish-new-fallback")
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background(AppTheme.accent, in: Rectangle())
            .padding(20)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { readerModel.isPresented },
                set: { if !$0 { readerModel.dismiss() } }
            )
        ) {
            ExplanationViewerSheet(viewModel: readerModel)
        }
    }
}

struct VoiceCaptureLatencyUITestHarness: View {
    @State private var isRecording = false
    @State private var contactCount = 0
    @State private var actionCount = 0

    var body: some View {
        VStack(spacing: 20) {
            Text(isRecording ? "Grabando" : "Listo")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.ink)
                .accessibilityIdentifier("voice-latency-state")

            Button {
                actionCount += 1
                isRecording.toggle()
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(isRecording ? Color.red : AppTheme.accentSend)
                    .clipShape(Circle())
            }
            .buttonStyle(
                ImmediateVoiceButtonStyle {
                    contactCount += 1
                    AppHaptics.shared.play(.voiceButtonPress)
                }
            )
            .accessibilityLabel(isRecording ? "Detener grabación" : "Grabar mensaje de voz")
            .accessibilityValue(
                "\(isRecording ? "recording" : "idle") contact=\(contactCount) action=\(actionCount)"
            )
            .accessibilityIdentifier("voice-latency-microphone")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .onAppear {
            AppHaptics.shared.prepare(.voiceButtonPress)
        }
    }
}

struct ComposerOverlapUITestHarness: View {
    @State private var composerHeight: CGFloat = 60
    @State private var expanded = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppTheme.backgroundSolid.ignoresSafeArea()

            Button {
                // The production action scrolls the transcript to its tail.
            } label: {
                Label("Ir al final", systemImage: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(AppTheme.accent)
            }
            .padding(.trailing, 16)
            .padding(
                .bottom,
                TranscriptFloatingControlLayout.scrollButtonBottomPadding(
                    composerHeight: composerHeight
                )
            )
            .accessibilityIdentifier("transcript-scroll-to-bottom")

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if expanded {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Button {
                                // Mirrors opening the production preview.
                            } label: {
                                Image(systemName: "photo.fill")
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 48, height: 48)
                                    .background(AppTheme.cardSurfaceRaised)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Ver imagen-adjunta.jpg")
                            .accessibilityIdentifier("composer-attachment-fixture-preview")

                            ComposerAttachmentRemoveButton(
                                name: "imagen-adjunta.jpg",
                                accessibilityIdentifier: "composer-remove-attachment-fixture"
                            ) {
                                // Mirrors removing one production attachment.
                            }
                        }
                        Text("imagen-adjunta.jpg")
                            .foregroundStyle(AppTheme.inkSoft)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                }
                HStack(spacing: 6) {
                    Text("Mensaje")
                        .foregroundStyle(AppTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ComposerContextActionCluster(showsSend: expanded) {
                        Button {
                            // Mirrors the floating production microphone.
                        } label: {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(AppTheme.accent)
                        }
                        .accessibilityLabel("Grabar mensaje de voz")
                        .accessibilityIdentifier("composer-microphone")
                    } sendControl: {
                        Button {
                            // Mirrors the production send action.
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.accentSend)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Enviar mensaje con imagen")
                        .accessibilityIdentifier("composer-send-message")
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: expanded ? 120 : 60)
            .background(AppTheme.cardSurface)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposerOcclusionHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-occlusion-surface")

            if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_ATTACHMENTS"] != "1" {
                Button(expanded ? "Contraer adjuntos" : "Simular adjuntos") {
                    expanded.toggle()
                }
                .foregroundStyle(AppTheme.ink)
                .padding(.trailing, 90)
                .padding(.bottom, 8)
                .accessibilityIdentifier("composer-toggle-height")
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_ATTACHMENTS"] == "1" {
                expanded = true
                composerHeight = 120
            }
        }
        .onPreferenceChange(ComposerOcclusionHeightPreferenceKey.self) { composerHeight = $0 }
    }
}

@MainActor
struct ComposerActionPriorityUITestHarness: View {
    @StateObject private var store: KycodeConnectionStore
    @StateObject private var backgroundRecording = BackgroundRecordingState()
    private let composerDraftStorageKey = KycodeComposerDraftStoragePolicy.storageKey(
        profileId: "puky",
        remoteWindowId: "composer-action-priority"
    )

    init() {
        let legacyKey = "kycode.mobile.composerDraft.composer-action-priority"
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_LEGACY_COMPOSER_DRAFT"] == "1" {
            UserDefaults.standard.set(
                "Borrador anterior sin origen: revisar antes de recuperar.",
                forKey: legacyKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        UserDefaults.standard.removeObject(
            forKey: KycodeComposerDraftStoragePolicy.storageKey(
                profileId: "puky",
                remoteWindowId: "composer-action-priority"
            )
        )
        let store = KycodeConnectionStore(initialProfileIdOverride: "puky")
        store.seedComposerActionPriorityUITestFixture()
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_RETRY_REQUIRED"] == "1" {
            store.seedComposerRetryRequiredUITestFixture()
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_RECONNECT"] == "1" {
            store.seedComposerReconnectUITestFixture()
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        NavigationStack {
            KycodeSessionDetailView(
                windowId: "composer-action-priority",
                composerDraftStorageKey: composerDraftStorageKey
            )
        }
        .environmentObject(store)
        .environmentObject(backgroundRecording)
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .task {
            guard ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_RECONNECT"] == "1" else {
                return
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            store.resolveComposerReconnectUITestFixture()
        }
    }
}

struct TranscriptBottomJumpUITestHarness: View {
    private let messages: [KycodeMessage] = {
        let chronological = (0..<36).map { index in
            KycodeMessage(
                id: index == 5
                    ? "mobile-user-54f78bb3-2cbe-4c38-b39c-b6e4d01f054d"
                    : index == 15
                    ? "mobile-user-38ff4c6a-05ee-40fc-871d-1d398976fd75"
                    : "transcript-jump-\(index)",
                role: index.isMultiple(of: 3) ? "user" : "assistant",
                type: index.isMultiple(of: 3) ? "user" : "codex",
                content: index == 35
                    ? "FINAL DEL TIMELINE — contenido más reciente"
                    : index == 5
                    ? "RETRY VIEJO A — debe conservar su lugar cronológico"
                    : index == 15
                    ? "RETRY VIEJO B — no debe aparecer al final"
                    : "Mensaje \(index). Contenido suficientemente largo para probar un timeline activo y extenso sin depender de datos externos.",
                originalPrompt: nil,
                transformedPrompt: nil,
                improvedPrompt: nil,
                timestamp: 1_785_000_000_000 + Double(index * 1_000),
                status: nil,
                imageAttachments: nil
            )
        }
        let retryIds: Set<String> = [
            "mobile-user-54f78bb3-2cbe-4c38-b39c-b6e4d01f054d",
            "mobile-user-38ff4c6a-05ee-40fc-871d-1d398976fd75",
        ]
        return chronological.filter { !retryIds.contains($0.id) }
            + chronological.filter { retryIds.contains($0.id) }
    }()

    private var orderedMessages: [KycodeMessage] {
        KycodeMessageChronologyPolicy.ordered(messages)
    }

    private var session: KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: "transcript-bottom-jump",
            sessionId: "transcript-bottom-jump",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "ui-tests",
            projectPath: nil,
            projectName: "UI Tests",
            windowName: "Scroll",
            displayName: "Scroll",
            sidecarMode: "test",
            sidecarUrl: nil,
            activityStatus: "working",
            runtimeStatus: "WORKING",
            runtimeStatusDetail: "Working",
            features: nil,
            runMode: nil,
            goalStartedAt: nil,
            messageCount: messages.count,
            updatedAt: 1_785_000_040_000,
            createdAt: 1_785_000_000_000,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: orderedMessages.last?.content,
            isMinimized: false,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: messages
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SessionTranscriptPane(
                session: session,
                visibleMessages: orderedMessages,
                contentRevision: 0,
                hasAuthoritativeDetail: true,
                detailLoadState: .loaded,
                hasOlderMessages: false,
                olderMessageCount: 0,
                isProcessing: true,
                processingLabel: "Procesando...",
                headerView: nil,
                followBottomRequest: 0,
                selectedSearchMessageId: nil,
                floatingComposerHeight: 120,
                savedMessageIds: [],
                fileBasePath: nil,
                onLoadOlderMessages: {},
                onRetryDetail: {},
                onRequestLatest: {},
                onQuoteMessage: { _ in },
                onToggleSavedMessage: { _ in },
                onRetryVoiceMessage: { _ in },
                onRetryPromptImprover: { _ in .success },
                onOpenFile: { _ in },
                onOpenReaderDocument: { _ in }
            )
            .equatable()

            HStack {
                Text("Mensaje")
                    .foregroundStyle(AppTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 120)
            .background(AppTheme.cardSurface)
            .accessibilityIdentifier("transcript-jump-composer")
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }
}

struct TranscriptAvailabilityUITestHarness: View {
    @State private var detailLoadState: KycodeSessionDetailLoadState =
        .failed("La sesión sigue ahí. Reintentá para recuperar los mensajes más recientes.")
    @State private var hasAuthoritativeDetail = false
    @State private var messages: [KycodeMessage] = []

    private var session: KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: "transcript-availability",
            sessionId: "transcript-availability",
            engine: "codex",
            model: "gpt-5.6-luna",
            reasoningEffort: "low",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "ui-tests",
            projectPath: nil,
            projectName: "UI Tests",
            windowName: "Disponibilidad",
            displayName: "Disponibilidad",
            sidecarMode: "test",
            sidecarUrl: nil,
            activityStatus: "ready",
            runtimeStatus: "WAITING",
            runtimeStatusDetail: "Waiting",
            features: nil,
            runMode: nil,
            goalStartedAt: nil,
            messageCount: 2,
            updatedAt: 1_785_000_040_000,
            createdAt: 1_785_000_000_000,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: "RECUPERACIÓN_OK",
            isMinimized: false,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: hasAuthoritativeDetail ? messages : nil
        )
    }

    var body: some View {
        SessionTranscriptPane(
            session: session,
            visibleMessages: messages,
            contentRevision: UInt64(messages.count),
            hasAuthoritativeDetail: hasAuthoritativeDetail,
            detailLoadState: detailLoadState,
            hasOlderMessages: false,
            olderMessageCount: 0,
            isProcessing: false,
            processingLabel: "Procesando...",
            headerView: nil,
            followBottomRequest: 0,
            selectedSearchMessageId: nil,
            floatingComposerHeight: 0,
            savedMessageIds: [],
            fileBasePath: nil,
            onLoadOlderMessages: {},
            onRetryDetail: retryDetail,
            onRequestLatest: {},
            onQuoteMessage: { _ in },
            onToggleSavedMessage: { _ in },
            onRetryVoiceMessage: { _ in },
            onRetryPromptImprover: { _ in .success },
            onOpenFile: { _ in },
            onOpenReaderDocument: { _ in }
        )
        .equatable()
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
    }

    private func retryDetail() {
        detailLoadState = .loading
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            messages = [
                KycodeMessage(
                    id: "transcript-availability-recovered",
                    role: "assistant",
                    type: "codex",
                    content: "RECUPERACIÓN_OK",
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: 1_785_000_040_000,
                    status: "completed",
                    imageAttachments: nil
                )
            ]
            hasAuthoritativeDetail = true
            detailLoadState = .loaded
        }
    }
}
#endif

private struct MessageAttachmentGrid: View {
    let attachments: [KycodeMessageImageAttachment]
    var windowId: String? = nil

    private var columns: [GridItem] {
        attachments.count == 1
            ? [GridItem(.flexible())]
            : [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(attachments) { attachment in
                MessageAttachmentPreview(attachment: attachment, windowId: windowId)
                    .aspectRatio(attachments.count == 1 ? 4 / 3 : 1, contentMode: .fit)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachments.count) \(attachments.count == 1 ? "imagen adjunta" : "imágenes adjuntas")")
    }
}

private struct MessageAttachmentPreview: View {
    @EnvironmentObject private var store: KycodeConnectionStore
    let attachment: KycodeMessageImageAttachment
    var windowId: String? = nil

    @State private var remoteData: Data?
    @State private var failed = false

    private var image: UIImage? {
        UIImage(data: attachment.previewData ?? remoteData ?? Data())
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("No disponible")
                        .font(.caption2)
                }
                .foregroundStyle(AppTheme.inkMuted)
            } else {
                ProgressView()
                    .tint(AppTheme.accent)
            }
        }
        .clipShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(Color.clear, lineWidth: 1)
        }
        .task(id: attachment.path) {
            guard attachment.previewData == nil,
                  remoteData == nil,
                  let path = attachment.path,
                  !path.isEmpty else {
                return
            }
            do {
                remoteData = try await store.fetchAttachmentData(path: path, windowId: windowId)
            } catch {
                failed = true
            }
        }
        .accessibilityLabel(attachment.name)
    }
}

struct MarkdownBubbleText: View {
    let markdown: String
    let isUser: Bool
    var presentation: MarkdownTextPresentation = .compact
    var fileBasePath: String? = nil
    var onOpenFile: (KycodeFileReference) -> Void = { _ in }
    var readerPalette: KycodeDocumentReaderPalette? = nil

    private var blocks: [MarkdownBlock] {
        MarkdownMessageRenderer.blocks(
            for: KycodeFileLinkifier.prepareMarkdown(markdown, basePath: fileBasePath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(
                    block: block,
                    isUser: isUser,
                    presentation: presentation,
                    readerPalette: readerPalette
                )
                .padding(.top, spacingBefore(block, at: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let reference = KycodeFileLinkifier.reference(fromViewerURL: url) else {
                return .systemAction
            }
            onOpenFile(reference)
            return .handled
        })
    }

    private func spacingBefore(_ block: MarkdownBlock, at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        guard presentation == .fileViewer else { return 9 }

        let previous = blocks[index - 1]
        if case .list = previous, case .list = block {
            return ReaderReadingRhythm.listContinuation
        }

        switch block {
        case .heading(let level, _):
            return level == 1 ? ReaderReadingRhythm.chapter : ReaderReadingRhythm.section
        case .sectionLabel:
            return ReaderReadingRhythm.section
        case .paragraph:
            if case .heading = previous {
                return ReaderReadingRhythm.afterHeading
            }
            return ReaderReadingRhythm.paragraph
        case .list:
            return ReaderReadingRhythm.afterHeading
        case .quote, .code, .image, .table:
            return ReaderReadingRhythm.block
        case .thematicBreak:
            return ReaderReadingRhythm.section
        }
    }
}

private struct ProgressiveAssistantMarkdownText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let messageId: String
    let markdown: String
    let presentation: MarkdownTextPresentation
    let fileBasePath: String?
    let enabled: Bool
    let responseIsProcessing: Bool
    let onOpenFile: (KycodeFileReference) -> Void
    let onProgress: (String) -> Void
    let onCompleted: () -> Void

    @State private var visibleMarkdown = ""
    @State private var visibleCharacterCount = 0
    @State private var isRevealing = false

    private var revision: VisualStreamRevision {
        VisualStreamRevision(
            messageId: messageId,
            contentLength: markdown.count,
            contentHash: markdown.hashValue,
            enabled: enabled,
            responseIsProcessing: responseIsProcessing,
            reduceMotion: reduceMotion
        )
    }

    private var accessibilityProgressValue: String {
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_VISUAL_STREAM"] == "1" {
            return isRevealing
                ? "streaming-\(visibleCharacterCount)-of-\(markdown.count)"
                : "complete-\(markdown.count)"
        }
        return isRevealing ? "Respuesta en curso" : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MarkdownBubbleText(
                markdown: visibleMarkdown,
                isUser: false,
                presentation: presentation,
                fileBasePath: fileBasePath,
                onOpenFile: onOpenFile
            )

            if isRevealing {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 18, height: 2)
                    .accessibilityHidden(true)
            }
        }
        .task(id: revision) {
            await revealCurrentTarget()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(markdown)
        .accessibilityValue(accessibilityProgressValue)
        .accessibilityIdentifier("progressive-message-\(messageId)")
    }

    @MainActor
    private func revealCurrentTarget() async {
        let characters = Array(markdown)
        let shouldAnimate = KycodeMobileVisualStreamPolicy.shouldAnimate(
            enabled: enabled,
            reduceMotion: reduceMotion,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            contentLength: characters.count
        )

        guard shouldAnimate else {
            visibleCharacterCount = characters.count
            visibleMarkdown = markdown
            isRevealing = false
            reportProgress()
            if enabled && !responseIsProcessing {
                onCompleted()
            }
            return
        }

        if visibleCharacterCount > characters.count || !markdown.hasPrefix(visibleMarkdown) {
            visibleCharacterCount = 0
            visibleMarkdown = ""
        }

        isRevealing = visibleCharacterCount < characters.count
        reportProgress()
        while visibleCharacterCount < characters.count {
            guard !Task.isCancelled else { return }
            let nextCount = KycodeMobileVisualStreamPolicy.nextVisibleCharacterCount(
                current: visibleCharacterCount,
                target: characters.count
            )
            visibleCharacterCount = nextCount
            visibleMarkdown = String(characters.prefix(nextCount))
            reportProgress()
            if nextCount < characters.count {
                try? await Task.sleep(
                    for: .milliseconds(Int(KycodeMobileVisualStreamPolicy.commitIntervalMilliseconds))
                )
            }
        }

        guard !Task.isCancelled else { return }
        isRevealing = false
        reportProgress()
        if !responseIsProcessing {
            onCompleted()
        }
    }

    @MainActor
    private func reportProgress() {
        guard ProcessInfo.processInfo.environment["KYCODE_UI_TEST_VISUAL_STREAM"] == "1" else { return }
        onProgress(
            isRevealing
                ? "streaming-\(visibleCharacterCount)-of-\(markdown.count)"
                : "complete-\(markdown.count)"
        )
    }
}

private struct VisualStreamRevision: Hashable {
    let messageId: String
    let contentLength: Int
    let contentHash: Int
    let enabled: Bool
    let responseIsProcessing: Bool
    let reduceMotion: Bool
}

enum MarkdownTextPresentation {
    case compact
    case readerAssistant
    case compactReaderAssistant
    case readerUser
    case fileViewer
}

/// A deliberate reading scale shared by the immersive reader and transcript.
/// Keeping these values together prevents one-off font choices from flattening
/// the hierarchy as Markdown gains more block types.
private enum ReaderTypographyScale {
    static let documentBody: CGFloat = 18
    static let documentSection: CGFloat = 23
    static let documentListMarker: CGFloat = 17
    static let documentQuote: CGFloat = 19
    static let documentCode: CGFloat = 14
    static let documentLineSpacing: CGFloat = 10
    static let documentListLineSpacing: CGFloat = 8

    static func documentHeading(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 40, weight: .bold, design: .serif)
        case 2:
            return .system(size: 30, weight: .bold, design: .serif)
        case 3:
            return .system(size: 24, weight: .semibold, design: .serif)
        default:
            return .system(size: 20, weight: .semibold, design: .serif)
        }
    }

    static func documentHeadingTracking(level: Int) -> CGFloat {
        switch level {
        case 1: return -0.45
        case 2: return -0.30
        case 3: return -0.15
        default: return 0
        }
    }
}

private enum ReaderReadingRhythm {
    static let listContinuation: CGFloat = 12
    static let afterHeading: CGFloat = 16
    static let paragraph: CGFloat = 20
    static let block: CGFloat = 24
    static let section: CGFloat = 32
    static let chapter: CGFloat = 40
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let isUser: Bool
    let presentation: MarkdownTextPresentation
    let readerPalette: KycodeDocumentReaderPalette?

    private var isFileViewer: Bool { presentation == .fileViewer }
    private var isReaderAssistant: Bool {
        presentation == .readerAssistant
            || presentation == .compactReaderAssistant
            || isFileViewer
    }
    private var isWideReaderAssistant: Bool { presentation == .readerAssistant }
    private var isReaderUser: Bool { presentation == .readerUser }
    private var readerSectionSize: CGFloat { isFileViewer ? ReaderTypographyScale.documentSection : (isWideReaderAssistant ? 23 : 18) }
    private var readerBodySize: CGFloat { isFileViewer ? ReaderTypographyScale.documentBody : (isWideReaderAssistant ? 19 : 15.5) }
    private var readerListMarkerSize: CGFloat { isFileViewer ? ReaderTypographyScale.documentListMarker : (isWideReaderAssistant ? 16 : 14) }
    private var readerListBodySize: CGFloat { isFileViewer ? ReaderTypographyScale.documentBody : (isWideReaderAssistant ? 18 : 15.5) }
    private var readerQuoteSize: CGFloat { isFileViewer ? ReaderTypographyScale.documentQuote : (isWideReaderAssistant ? 18 : 15.5) }
    private var readerCodeSize: CGFloat { isFileViewer ? ReaderTypographyScale.documentCode : (isWideReaderAssistant ? 15 : 13) }
    private var readerLineSpacing: CGFloat { isFileViewer ? ReaderTypographyScale.documentLineSpacing : (isWideReaderAssistant ? 6 : 5) }
    private var readerListLineSpacing: CGFloat { isFileViewer ? ReaderTypographyScale.documentListLineSpacing : (isWideReaderAssistant ? 5 : 3) }
    private var readerTopPadding: CGFloat { isFileViewer ? 0 : (isWideReaderAssistant ? 10 : 6) }
    private var readerHeadingTopPadding: CGFloat { isFileViewer ? 0 : (isWideReaderAssistant ? 8 : 4) }
    private var readerCodeHorizontalPadding: CGFloat { isFileViewer ? 14 : (isWideReaderAssistant ? 14 : 10) }
    private var readerCodeVerticalPadding: CGFloat { isFileViewer ? 14 : (isWideReaderAssistant ? 12 : 9) }
    private var bodyColor: Color {
        if isUser { return .white }
        if let readerPalette { return readerPalette.ink }
        return isReaderAssistant ? ReaderPalette.ink : AppTheme.ink
    }
    private var strongColor: Color {
        if isUser { return .white }
        if let readerPalette { return readerPalette.ink }
        return isReaderAssistant ? ReaderPalette.ink : AppTheme.ink
    }
    private var mutedColor: Color {
        if isUser { return Color.white.opacity(0.82) }
        if let readerPalette { return readerPalette.inkMuted }
        return isReaderAssistant ? ReaderPalette.inkMuted : AppTheme.inkMuted
    }
    private var accentColor: Color {
        readerPalette?.accent ?? AppTheme.accent
    }
    private var codeBackground: Color {
        readerPalette?.codeBackground ?? ReaderPalette.darkCodeBackground
    }

    var body: some View {
        switch block {
        case .sectionLabel(let text):
            MarkdownInlineText(
                attributed: text,
                isUser: isUser,
                font: .system(size: isReaderAssistant ? readerSectionSize : (isReaderUser ? 20 : 18), weight: .bold, design: isFileViewer ? .serif : .default),
                foregroundColorOverride: strongColor,
                lineSpacing: isReaderAssistant ? readerListLineSpacing : 3,
                linkColor: accentColor
            )
            .padding(.top, isReaderAssistant ? readerTopPadding : 6)
        case .paragraph(let text):
            MarkdownInlineText(
                attributed: text,
                isUser: isUser,
                font: .system(
                    size: isReaderAssistant ? readerBodySize : (isReaderUser ? 18 : 17),
                    weight: isReaderAssistant ? .regular : .medium,
                    design: isFileViewer ? .serif : (isReaderAssistant ? .default : .rounded)
                ),
                foregroundColorOverride: bodyColor,
                lineSpacing: isReaderAssistant ? readerLineSpacing : 3,
                linkColor: accentColor
            )
        case .heading(let level, let text):
            MarkdownInlineText(
                attributed: text,
                isUser: isUser,
                font: headingFont(for: level),
                foregroundColorOverride: strongColor,
                lineSpacing: isReaderAssistant ? readerLineSpacing : 3,
                linkColor: accentColor
            )
            .tracking(isFileViewer ? ReaderTypographyScale.documentHeadingTracking(level: level) : 0)
            .padding(.top, isReaderAssistant ? readerHeadingTopPadding : 0)
        case .list(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: isReaderAssistant ? readerListMarkerSize : 14, weight: .bold, design: .default))
                    .foregroundStyle(mutedColor)
                MarkdownInlineText(
                    attributed: text,
                    isUser: isUser,
                    font: .system(
                        size: isReaderAssistant ? readerListBodySize : (isReaderUser ? 18 : 17),
                        weight: isReaderAssistant ? .regular : .medium,
                        design: isFileViewer ? .serif : (isReaderAssistant ? .default : .rounded)
                    ),
                    foregroundColorOverride: bodyColor,
                    lineSpacing: isReaderAssistant ? readerListLineSpacing : 3,
                    linkColor: accentColor
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isReaderAssistant ? 2 : 0)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(isUser ? Color.white.opacity(0.45) : accentColor.opacity(0.78))
                    .frame(width: isReaderAssistant ? 4 : 3)
                MarkdownInlineText(
                    attributed: text,
                    isUser: isUser,
                    font: .system(
                        size: isReaderAssistant ? readerQuoteSize : 16,
                        weight: .medium,
                        design: isFileViewer ? .serif : (isReaderAssistant ? .default : .rounded)
                    ).italic(),
                    foregroundColorOverride: bodyColor,
                    lineSpacing: isReaderAssistant ? readerListLineSpacing : 3,
                    linkColor: accentColor
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isFileViewer ? 16 : 0)
            .padding(.vertical, isFileViewer ? 14 : (isReaderAssistant ? (isWideReaderAssistant ? 8 : 5) : 0))
            .background(
                isFileViewer ? (readerPalette?.raisedSurface ?? Color.clear) : Color.clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
            )
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Rectangle()
                        .fill(AppTheme.terminalGreen)
                        .frame(width: 6, height: 6)
                    Text(language?.uppercased() ?? "CODE")
                        .font(.system(size: isReaderAssistant ? 10 : 9, weight: .bold, design: .default))
                        .foregroundStyle((readerPalette?.codeAccent ?? accentColor).opacity(0.96))
                        .tracking(1.1)
                    Spacer(minLength: 0)
                }

                ScrollView(.horizontal) {
                    highlightedCode(code, language: language)
                        .font(.system(size: isReaderAssistant ? readerCodeSize : 14, weight: .medium, design: .monospaced))
                        .lineSpacing(isReaderAssistant ? (isWideReaderAssistant ? 5 : 3) : 2)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, isReaderAssistant ? readerCodeHorizontalPadding : 12)
            .padding(.vertical, isReaderAssistant ? readerCodeVerticalPadding : 10)
            .background(
                isUser ? Color.white.opacity(0.12) : codeBackground,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.m, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
            )
            .padding(.vertical, isReaderAssistant ? (isWideReaderAssistant ? 6 : 4) : 0)
        case .image(let alt, let url):
            MarkdownDocumentImage(alt: alt, url: url, readerPalette: readerPalette)
        case .table(let headers, let rows):
            MarkdownDocumentTable(
                headers: headers,
                rows: rows,
                foreground: bodyColor,
                muted: mutedColor,
                readerPalette: readerPalette
            )
        case .thematicBreak:
            Rectangle()
                .fill(mutedColor.opacity(0.28))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .padding(.vertical, isFileViewer ? 8 : 4)
        }
    }

    private func highlightedCode(_ code: String, language: String?) -> Text {
        let lines = code.components(separatedBy: "\n")
        return lines.enumerated().reduce(Text("")) { output, item in
            let (index, line) = item
            let highlightedLine = FileViewerSyntaxHighlighter
                .segments(for: line, language: language)
                .reduce(Text("")) { partial, segment in
                    partial + Text(segment.text).foregroundColor(codeColor(for: segment.kind))
                }
            return output + highlightedLine + (index < lines.count - 1 ? Text("\n") : Text(""))
        }
    }

    private func codeColor(for kind: FileViewerTokenKind) -> Color {
        if isUser { return Color.white.opacity(0.98) }
        switch kind {
        case .plain:
            return readerPalette?.codeInk ?? AppTheme.ink
        case .keyword:
            return readerPalette?.codeAccent ?? accentColor
        case .string:
            return readerPalette?.string ?? Color.green.opacity(0.92)
        case .number:
            return readerPalette?.number ?? Color.cyan.opacity(0.92)
        case .comment:
            return readerPalette?.comment ?? AppTheme.inkMuted
        }
    }

    private func headingFont(for level: Int) -> Font {
        if isFileViewer {
            return ReaderTypographyScale.documentHeading(level: level)
        }
        if isReaderAssistant {
            if isWideReaderAssistant {
                switch level {
                case 1:
                    return .system(size: 26, weight: .bold, design: .default)
                case 2:
                    return .system(size: 24, weight: .bold, design: .default)
                case 3:
                    return .system(size: 22, weight: .bold, design: .default)
                default:
                    return .system(size: 20, weight: .bold, design: .default)
                }
            } else {
                switch level {
                case 1:
                    return .system(size: 21, weight: .bold, design: .default)
                case 2:
                    return .system(size: 20, weight: .bold, design: .default)
                case 3:
                    return .system(size: 19, weight: .bold, design: .default)
                default:
                    return .system(size: 18, weight: .bold, design: .default)
                }
            }
        }
        if isReaderUser {
            return .system(size: 20, weight: .bold, design: .default)
        }
        switch level {
        case 1:
            return .system(size: 22, weight: .bold, design: .default)
        case 2:
            return .system(size: 20, weight: .bold, design: .default)
        case 3:
            return .system(size: 18, weight: .bold, design: .default)
        default:
            return .system(size: 17, weight: .bold, design: .default)
        }
    }
}

private struct MarkdownDocumentImage: View {
    let alt: String
    let url: URL?
    let readerPalette: KycodeDocumentReaderPalette?

    private var isRemoteImage: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    var body: some View {
        Group {
            if isRemoteImage, let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(readerPalette?.accent ?? AppTheme.accent)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    case .failure:
                        unavailableImage
                    @unknown default:
                        unavailableImage
                    }
                }
            } else {
                unavailableImage
            }
        }
        .background(
            readerPalette?.surface ?? AppTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt.isEmpty ? "Imagen del documento" : alt)
    }

    private var unavailableImage: some View {
        Label(
            alt.isEmpty ? "Imagen no disponible" : alt,
            systemImage: "photo"
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(readerPalette?.inkMuted ?? AppTheme.inkMuted)
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct MarkdownDocumentTable: View {
    let headers: [AttributedString]
    let rows: [[AttributedString]]
    let foreground: Color
    let muted: Color
    let readerPalette: KycodeDocumentReaderPalette?

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        tableCell(headers[index], isHeader: true)
                    }
                }

                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { columnIndex in
                            tableCell(value(at: rowIndex, column: columnIndex), isHeader: false)
                                .background(
                                    rowIndex.isMultiple(of: 2)
                                        ? (readerPalette?.surface ?? AppTheme.cardSurface).opacity(0.52)
                                        : Color.clear
                                )
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(
            readerPalette?.raisedSurface ?? AppTheme.codeSurface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabla de \(headers.count) columnas y \(rows.count) filas")
    }

    private func value(at row: Int, column: Int) -> AttributedString {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else {
            return AttributedString("")
        }
        return rows[row][column]
    }

    private func tableCell(_ value: AttributedString, isHeader: Bool) -> some View {
        MarkdownInlineText(
            attributed: value,
            isUser: false,
            font: .system(size: 14, weight: isHeader ? .semibold : .regular),
            foregroundColorOverride: isHeader ? foreground : muted,
            lineSpacing: 3,
            linkColor: readerPalette?.accent
        )
        .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, isHeader ? 11 : 10)
        .background(isHeader ? (readerPalette?.surface ?? AppTheme.cardSurface) : Color.clear)
    }
}

private struct MarkdownInlineText: View {
    let attributed: AttributedString
    let isUser: Bool
    let font: Font
    var foregroundColorOverride: Color? = nil
    var lineSpacing: CGFloat = 3
    var linkColor: Color? = nil

    var body: some View {
        composedText
            .foregroundColor(foregroundColorOverride ?? (isUser ? .white : AppTheme.ink))
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composedText: Text {
        let runs = Array(attributed.runs)
        guard !runs.isEmpty else {
            return Text(String(attributed.characters)).font(font)
        }

        return runs.reduce(Text("")) { partial, run in
            partial + textSegment(for: run)
        }
    }

    private func textSegment(for run: AttributedString.Runs.Element) -> Text {
        let content = String(attributed[run.range].characters)
        guard !content.isEmpty else { return Text("") }

        let intent = run.inlinePresentationIntent
        let isCode = intent?.contains(.code) == true
        let isBold = intent?.contains(.stronglyEmphasized) == true
        let isItalic = intent?.contains(.emphasized) == true
        let isLink = run.link != nil

        // Keep the attributed slice: rebuilding it from `String` preserved the
        // underline but silently discarded `.link`, producing dead URLs.
        var text = Text(AttributedString(attributed[run.range]))

        if isCode {
            text = text.font(.system(size: 15, weight: isBold ? .bold : .semibold, design: .monospaced))
        } else {
            text = text.font(font)
        }

        if isBold {
            text = text.bold()
        }

        if isItalic {
            text = text.italic()
        }

        if isLink {
            text = text
                .foregroundColor(isUser ? Color.white : (linkColor ?? AppTheme.accent))
                .underline()
        }

        return text
    }
}

enum MarkdownBlock {
    case sectionLabel(AttributedString)
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list(marker: String, text: AttributedString)
    case quote(AttributedString)
    case code(language: String?, content: String)
    case image(alt: String, url: URL?)
    case table(headers: [AttributedString], rows: [[AttributedString]])
    case thematicBreak
}

enum MarkdownMessageRenderer {
    static func blocks(for markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.paragraph(AttributedString(" "))]
        }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                paragraphBuffer.removeAll()
                return
            }
            blocks.append(.paragraph(inlineText(from: text)))
            paragraphBuffer.removeAll()
        }

        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(
                    .code(
                        language: language.isEmpty ? nil : language,
                        content: codeLines.joined(separator: "\n")
                    )
                )
                continue
            }

            if let image = imageBlock(from: trimmed) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               isTableDelimiter(lines[index + 1]),
               let headers = tableCells(from: rawLine),
               !headers.isEmpty {
                flushParagraph()
                index += 2
                var rows: [[AttributedString]] = []
                while index < lines.count,
                      let cells = tableCells(from: lines[index]),
                      !cells.isEmpty,
                      !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rows.append(cells.map(inlineText))
                    index += 1
                }
                blocks.append(
                    .table(
                        headers: headers.map(inlineText),
                        rows: rows
                    )
                )
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if let section = sectionLabel(from: trimmed) {
                flushParagraph()
                blocks.append(.sectionLabel(inlineText(from: section.label)))
                if let trailingText = section.trailingText, !trailingText.isEmpty {
                    paragraphBuffer.append(trailingText)
                }
                index += 1
                continue
            }

            if let heading = headingBlock(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if let list = listBlock(from: trimmed) {
                flushParagraph()
                blocks.append(list)
                index += 1
                continue
            }

            if let firstQuoteLine = quoteLine(from: trimmed) {
                flushParagraph()
                var quoteLines = [firstQuoteLine]
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let nextQuoteLine = quoteLine(from: candidate) else { break }
                    quoteLines.append(nextQuoteLine)
                    index += 1
                }
                blocks.append(.quote(inlineText(from: quoteLines.joined(separator: "\n"))))
                continue
            }

            paragraphBuffer.append(rawLine)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func inlineText(from source: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: KycodeInteractiveLink.autolinkBareWebURLs(in: source),
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(source)
        }
    }

    static func previewText(for markdown: String) -> AttributedString {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n").map { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                return ""
            }
            if let strippedQuote = quoteLine(from: line) {
                line = strippedQuote
            }
            if let section = sectionLabel(from: line) {
                if let trailingText = section.trailingText, !trailingText.isEmpty {
                    return "\(section.label)\n\(trailingText)"
                }
                return section.label
            }
            if let list = listBlock(from: line) {
                switch list {
                case .list(let marker, let text):
                    return "\(marker) \(String(text.characters))"
                default:
                    break
                }
            }
            if case .heading(_, let text)? = headingBlock(from: line) {
                return String(text.characters)
            }
            return line
        }

        let collapsed = lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return inlineText(from: collapsed.isEmpty ? " " : collapsed)
    }

    private static func imageBlock(from line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["),
              line.hasSuffix(")"),
              let separator = line.range(of: "](") else {
            return nil
        }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        let alt = String(line[altStart..<separator.lowerBound])
        let destinationStart = separator.upperBound
        let destinationEnd = line.index(before: line.endIndex)
        let rawDestination = String(line[destinationStart..<destinationEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = rawDestination
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !destination.isEmpty else { return nil }
        return .image(alt: alt, url: URL(string: destination))
    }

    private static func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard let cells = tableCells(from: line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let dashes = cell
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
        }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "_", "*"].contains(marker) && compact.allSatisfy { $0 == marker }
    }

    private static func headingBlock(from line: String) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard level > 0, level <= 6 else { return nil }
        let content = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .heading(level: level, text: inlineText(from: content))
    }

    private static func sectionLabel(from line: String) -> (label: String, trailingText: String?)? {
        let normalized = strippedStrongMarkers(from: line)
        guard let colonIndex = normalized.firstIndex(of: ":") else { return nil }

        let labelPart = normalized[..<colonIndex].trimmingCharacters(in: .whitespaces)
        let trailing = normalized[normalized.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

        guard !labelPart.isEmpty, labelPart.count <= 48 else { return nil }
        guard labelPart.first?.isLetter == true || labelPart.first == "¿" else { return nil }
        guard !labelPart.contains("http"), !labelPart.contains("`") else { return nil }

        return ("\(labelPart):", trailing.isEmpty ? nil : trailing)
    }

    private static func listBlock(from line: String) -> MarkdownBlock? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let content = String(line.dropFirst(2))
            return .list(marker: "•", text: inlineText(from: content))
        }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].last == "." else { return nil }
        let numberPortion = parts[0].dropLast()
        guard !numberPortion.isEmpty, numberPortion.allSatisfy(\.isNumber) else { return nil }
        return .list(marker: String(parts[0]), text: inlineText(from: String(parts[1])))
    }

    private static func quoteLine(from line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func strippedStrongMarkers(from line: String) -> String {
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("__"), line.hasSuffix("__"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

private struct ExplainerNarrationPlayerOverlay: View {
    let asset: ExplainerNarrationAsset
    @Binding var isPresented: Bool
    @StateObject private var playback = NarrationPlaybackController()

    private var currentWordIndex: Int {
        guard !asset.words.isEmpty else { return -1 }
        if let exact = asset.words.first(where: { playback.currentTime >= $0.startTime && playback.currentTime <= $0.endTime }) {
            return exact.index
        }
        return asset.words.last(where: { $0.startTime <= playback.currentTime })?.index ?? 0
    }

    private var chapterDisplays: [NarrationChapterDisplay] {
        let wordCount = asset.words.count
        let fallbackEnd = max(wordCount - 1, 0)
        guard !asset.sections.isEmpty else {
            return [
                NarrationChapterDisplay(
                    number: 1,
                    title: asset.title.isEmpty ? "Narración" : asset.title,
                    startWordIndex: 0,
                    endWordIndex: fallbackEnd
                )
            ]
        }

        var cursor = 0
        return asset.sections.enumerated().map { index, section in
            let estimatedCount = max(1, Self.wordCount(for: section))
            let isLast = index == asset.sections.count - 1
            let start = min(cursor, fallbackEnd)
            let proposedEnd = cursor + estimatedCount - 1
            let end = isLast ? fallbackEnd : min(max(proposedEnd, start), fallbackEnd)
            cursor = end + 1

            return NarrationChapterDisplay(
                number: index + 1,
                title: section.title.isEmpty ? "Audio \(index + 1)" : section.title,
                startWordIndex: start,
                endWordIndex: end
            )
        }
    }

    private var currentChapter: NarrationChapterDisplay {
        let chapters = chapterDisplays
        guard !chapters.isEmpty else {
            return NarrationChapterDisplay(number: 1, title: "Narración", startWordIndex: 0, endWordIndex: 0)
        }
        let current = max(currentWordIndex, 0)
        return chapters.first(where: { current >= $0.startWordIndex && current <= $0.endWordIndex }) ?? chapters.last ?? chapters[0]
    }

    private var transcriptBlocks: [NarrationTranscriptBlock] {
        guard !asset.words.isEmpty else { return [] }
        guard !asset.sections.isEmpty else {
            return [
                NarrationTranscriptBlock(
                    id: "fallback-body",
                    kind: .paragraph,
                    words: asset.words
                )
            ]
        }

        var cursor = 0
        var blocks: [NarrationTranscriptBlock] = []
        let totalChapters = asset.sections.count

        for (sectionIndex, section) in asset.sections.enumerated() {
            let chapterNumber = sectionIndex + 1
            let titleCount = Self.wordCount(in: section.title)
            let titleWords = Self.words(from: asset.words, cursor: &cursor, count: titleCount)
            blocks.append(
                NarrationTranscriptBlock(
                    id: "chapter-\(chapterNumber)-title",
                    kind: .chapterTitle(number: chapterNumber, total: totalChapters, fallbackTitle: section.title),
                    words: titleWords
                )
            )

            for (paragraphIndex, paragraph) in section.paragraphs.enumerated() {
                let paragraphWords = Self.words(
                    from: asset.words,
                    cursor: &cursor,
                    count: Self.wordCount(in: paragraph)
                )
                guard !paragraphWords.isEmpty else { continue }
                blocks.append(
                    NarrationTranscriptBlock(
                        id: "chapter-\(chapterNumber)-paragraph-\(paragraphIndex)",
                        kind: .paragraph,
                        words: paragraphWords
                    )
                )
            }
        }

        if cursor < asset.words.count {
            blocks.append(
                NarrationTranscriptBlock(
                    id: "remaining-words",
                    kind: .paragraph,
                    words: Array(asset.words[cursor...])
                )
            )
        }

        return blocks
    }

    var body: some View {
        GeometryReader { geometry in
            let isTablet = geometry.size.width >= 700
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .background(.ultraThinMaterial)
                    .onTapGesture {
                        close()
                    }

                VStack(spacing: 0) {
                    compactNarrationHeader(isTablet: isTablet)

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    narrationTranscript

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    narrationControls(isTablet: isTablet)
                }
                .frame(
                    width: min(geometry.size.width - (isTablet ? 88 : 24), isTablet ? 820 : 560),
                    height: min(geometry.size.height - (isTablet ? 96 : 30), isTablet ? 760 : 720)
                )
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.cardSurfaceGlass.opacity(0.96),
                                    AppTheme.cardSurface.opacity(0.99)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
                .shadow(color: Color.clear, radius: 0)
                .padding(.horizontal, isTablet ? 44 : 12)
                .padding(.vertical, isTablet ? 48 : 22)
            }
        }
        .onAppear {
            do {
                try playback.load(asset: asset)
                playback.play()
            } catch {
                NSLog("%@", "[narration:player] \(error.localizedDescription)")
            }
        }
        .onDisappear {
            playback.stop()
        }
    }

    private func compactNarrationHeader(isTablet: Bool) -> some View {
        let chapters = chapterDisplays
        let chapter = currentChapter

        return HStack(spacing: 9) {
            Circle()
                .fill(AppTheme.gold.opacity(0.95))
                .frame(width: isTablet ? 7 : 6, height: isTablet ? 7 : 6)
                .accessibilityHidden(true)

            Text("Cap. \(chapter.number)/\(max(chapters.count, 1))")
                .font(.system(size: isTablet ? 13 : 12, weight: .bold, design: .default))
                .foregroundStyle(AppTheme.gold.opacity(0.95))
                .lineLimit(1)

            Text("·")
                .font(.system(size: isTablet ? 14 : 13, weight: .bold, design: .default))
                .foregroundStyle(Color.white.opacity(0.34))
                .accessibilityHidden(true)

            Text(chapter.title)
                .font(.system(size: isTablet ? 14 : 13, weight: .bold, design: .default))
                .foregroundStyle(Color.white.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button {
                close()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.075))
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .frame(width: isTablet ? 40 : 38, height: isTablet ? 40 : 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.94, opacity: 0.86))
            .accessibilityLabel("Cerrar reproductor")
        }
        .padding(.leading, isTablet ? 22 : 16)
        .padding(.trailing, isTablet ? 16 : 12)
        .padding(.vertical, isTablet ? 12 : 9)
        .background(
            LinearGradient(
                colors: [
                    ReaderPalette.chrome.opacity(0.92),
                    AppTheme.cardSurface.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capítulo \(chapter.number) de \(max(chapters.count, 1)): \(chapter.title)")
    }

    private var narrationTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(transcriptBlocks) { block in
                        transcriptBlockView(block)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .background(
                LinearGradient(
                    colors: [
                        ReaderPalette.paperAlt,
                        ReaderPalette.paper
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .onChange(of: currentWordIndex) { _, index in
                guard index >= 0, index % 5 == 0 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptBlockView(_ block: NarrationTranscriptBlock) -> some View {
        switch block.kind {
        case .chapterTitle(let number, let total, let fallbackTitle):
            VStack(alignment: .leading, spacing: 6) {
                Text("Cap. \(number)/\(total)")
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .textCase(.uppercase)
                    .foregroundStyle(ReaderPalette.inkMuted)

                if block.words.isEmpty {
                    Text(fallbackTitle)
                        .font(.system(size: 16, weight: .bold, design: .default))
                        .foregroundStyle(ReaderPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    NarrationWordWrapLayout(spacing: 4, lineSpacing: 5) {
                        ForEach(block.words) { word in
                            narrationWord(word, currentIndex: currentWordIndex, isTitle: true)
                                .id(word.index)
                        }
                    }
                }
            }
            .padding(.top, number == 1 ? 0 : 8)
            .padding(.bottom, 0)

        case .paragraph:
            NarrationWordWrapLayout(spacing: 5, lineSpacing: 10) {
                ForEach(block.words) { word in
                    narrationWord(word, currentIndex: currentWordIndex)
                        .id(word.index)
                }
            }
        }
    }

    private func narrationWord(_ word: ExplainerNarrationWord, currentIndex: Int, isTitle: Bool = false) -> some View {
        let isCurrent = word.index == currentIndex
        let isSpoken = word.index < currentIndex
        return Text(word.text)
            .font(.system(size: isTitle ? 16 : 19, weight: isCurrent || isTitle ? .bold : .regular, design: isTitle ? .rounded : .default))
            .lineLimit(1)
            .foregroundStyle(isCurrent ? Color.white : (isSpoken ? ReaderPalette.ink : ReaderPalette.inkSoft))
            .padding(.horizontal, isCurrent ? 7 : 1)
            .padding(.vertical, isTitle ? 2 : 3)
            .background(
                Rectangle()
                    .fill(isCurrent ? AppTheme.gold.opacity(0.92) : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isCurrent)
    }

    private func narrationControls(isTablet: Bool) -> some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, asset.duration, 0.1)
            )
            .tint(AppTheme.gold)
            .accessibilityLabel("Progreso de narración")

            HStack(spacing: 10) {
                Button {
                    playback.toggle()
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(AppTheme.accent)
                            .shadow(color: Color.clear, radius: 0)

                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isTablet ? 18 : 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                    .frame(width: isTablet ? 46 : 44, height: isTablet ? 46 : 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.95, opacity: 0.88))
                .accessibilityLabel(playback.isPlaying ? "Pausar narración" : "Reproducir narración")

                Text(Self.formattedTime(playback.currentTime))
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .leading)

                ForEach(NarrationPlaybackController.supportedRates, id: \.self) { rate in
                    Button {
                        playback.setPlaybackRate(rate)
                    } label: {
                        Text(Self.formattedRate(rate))
                            .font(.system(size: 11, weight: .bold, design: .default))
                            .foregroundStyle(playback.playbackRate == rate ? Color.black.opacity(0.84) : Color.white.opacity(0.72))
                            .frame(width: 34, height: 28)
                            .background(
                                Rectangle()
                                    .fill(playback.playbackRate == rate ? AppTheme.gold.opacity(0.96) : Color.white.opacity(0.075))
                            )
                            .overlay(
                                Rectangle()
                                    .stroke(Color.clear, lineWidth: 1)
                            )
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.96, opacity: 0.86))
                    .accessibilityLabel("Velocidad \(Self.formattedRate(rate))")
                }

                Spacer(minLength: 0)

                Text(Self.formattedTime(max(playback.duration, asset.duration)))
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .foregroundStyle(AppTheme.inkMuted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, isTablet ? 22 : 16)
        .padding(.top, 10)
        .padding(.bottom, isTablet ? 14 : 12)
    }

    private func close() {
        playback.pause()
        withAnimation(.easeInOut(duration: 0.22)) {
            isPresented = false
        }
    }

    private static func formattedTime(_ time: TimeInterval) -> String {
        let clamped = max(0, Int(time.rounded(.down)))
        return String(format: "%01d:%02d", clamped / 60, clamped % 60)
    }

    private static func formattedRate(_ rate: Double) -> String {
        if rate.rounded() == rate {
            return "\(Int(rate))x"
        }
        return String(format: "%.1fx", rate)
    }

    private static func wordCount(for section: ExplainerNarrationSection) -> Int {
        ([section.title] + section.paragraphs)
            .joined(separator: " ")
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func words(
        from words: [ExplainerNarrationWord],
        cursor: inout Int,
        count: Int
    ) -> [ExplainerNarrationWord] {
        guard count > 0, cursor < words.count else { return [] }
        let start = cursor
        let end = min(cursor + count, words.count)
        cursor = end
        return Array(words[start..<end])
    }
}

private struct NarrationChapterDisplay: Identifiable, Hashable {
    let number: Int
    let title: String
    let startWordIndex: Int
    let endWordIndex: Int

    var id: Int { number }
}

private struct NarrationTranscriptBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case chapterTitle(number: Int, total: Int, fallbackTitle: String)
        case paragraph
    }

    let id: String
    let kind: Kind
    let words: [ExplainerNarrationWord]
}

private final class NarrationPlaybackController: NSObject, ObservableObject {
    static let supportedRates: [Double] = [1, 2, 3]

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Double = 1

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var playStartTime: CFTimeInterval = 0
    private var playStartAudioTime: TimeInterval = 0
    private var displayLink: CADisplayLink?

    func load(asset: ExplainerNarrationAsset) throws {
        stop()
        let file = try AVAudioFile(forReading: asset.audioURL)
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(playbackRate)
        timePitch.pitch = 0

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()

        audioFile = file
        self.engine = engine
        self.playerNode = playerNode
        self.timePitch = timePitch
        sampleRate = file.processingFormat.sampleRate
        duration = max(Double(file.length) / max(sampleRate, 1), asset.duration)
        currentTime = 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let engine, let playerNode, audioFile != nil else { return }
        if currentTime >= duration - 0.04 {
            currentTime = 0
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        timePitch?.rate = Float(playbackRate)
        timePitch?.pitch = 0
        scheduleFromCurrentTime()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("%@", "[narration:player] \(error.localizedDescription)")
                return
            }
        }
        playStartTime = CACurrentMediaTime()
        playStartAudioTime = currentTime
        playerNode.play()
        isPlaying = true
        startDisplayLink()
    }

    func pause() {
        updateCurrentTimeFromClock()
        playerNode?.pause()
        isPlaying = false
        stopDisplayLink()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        timePitch = nil
        engine = nil
        audioFile = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopDisplayLink()
    }

    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let wasPlaying = isPlaying
        if wasPlaying {
            playerNode?.stop()
        }
        let clamped = min(max(0, time), max(duration, 0))
        currentTime = clamped
        if wasPlaying {
            play()
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 3)
        if isPlaying {
            updateCurrentTimeFromClock()
        }
        playbackRate = clamped
        timePitch?.rate = Float(clamped)
        timePitch?.pitch = 0
        if isPlaying {
            playerNode?.stop()
            play()
        }
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard playerNode != nil else {
            stopDisplayLink()
            return
        }
        updateCurrentTimeFromClock()
        if isPlaying, currentTime >= max(duration - 0.04, 0) {
            currentTime = duration
            playerNode?.stop()
            isPlaying = false
            stopDisplayLink()
        }
    }

    private func scheduleFromCurrentTime() {
        guard let audioFile, let playerNode else { return }
        playerNode.stop()

        let startFrame = AVAudioFramePosition(min(max(currentTime, 0), duration) * sampleRate)
        let remainingFrames = max(audioFile.length - startFrame, 0)
        guard remainingFrames > 0 else { return }

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames),
            at: nil
        )
    }

    private func updateCurrentTimeFromClock() {
        guard isPlaying else { return }
        let elapsed = CACurrentMediaTime() - playStartTime
        currentTime = min(max(0, playStartAudioTime + elapsed * playbackRate), duration)
    }
}

private struct NarrationWordWrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = max(proposal.width ?? 320, 180)
        return measuredSize(maxWidth: maxWidth, subviews: subviews)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func measuredSize(maxWidth: CGFloat, subviews: Subviews) -> CGSize {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + lineHeight)
    }
}

private struct SubagentBotGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .stroke(lineWidth: 1.35)
                .frame(width: 15, height: 12)
                .offset(y: 1.5)

            HStack(spacing: 4.5) {
                Circle().frame(width: 2.2, height: 2.2)
                Circle().frame(width: 2.2, height: 2.2)
            }
            .offset(y: 0.5)

            Capsule()
                .frame(width: 6, height: 1.3)
                .offset(y: 4.5)

            Rectangle()
                .frame(width: 1.2, height: 3)
                .offset(y: -7)

            Circle()
                .frame(width: 2.6, height: 2.6)
                .offset(y: -9.2)

            HStack(spacing: 16.2) {
                Capsule().frame(width: 1.8, height: 5)
                Capsule().frame(width: 1.8, height: 5)
            }
            .offset(y: 1.5)
        }
        .frame(width: 21, height: 21)
    }
}

private struct FloatingComposerButtonChrome<Content: View>: View {
    let size: CGFloat
    let fill: Color
    let ring: Color
    var isProminent = false
    let content: Content

    init(
        size: CGFloat,
        fill: Color,
        ring: Color,
        isProminent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.size = size
        self.fill = fill
        self.ring = ring
        self.isProminent = isProminent
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.s, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(isProminent ? AppTheme.surfaceTopLightStrong : AppTheme.surfaceTopLight)
                    .frame(height: 1)
                    .padding(.horizontal, AppTheme.Radius.s)
            }
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.s, style: .continuous))
    }
}

private struct PremiumCircleButtonChrome: View {
    let size: CGFloat
    let fill: Color
    let ring: Color
    var isProminent = false

    var body: some View {
        Rectangle()
            .fill(fill)
            .frame(width: size, height: size)
    }
}

private struct CircleComposerButton: View {
    let icon: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(background, in: Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct ComposerOptionsSheet: View {
    @Binding var promptImproverEnabled: Bool
    @Binding var explainerEnabled: Bool

    let codeContextEnabled: Bool?
    let canControlFeatures: Bool
    let isUpdatingFeatures: Bool
    let onPromptImproverChanged: (Bool) -> Void
    let onExplainerChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sync desktop.")
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(AppTheme.inkSoft)

            ComposerToggleRow(
                title: "Prompt Improver",
                subtitle: "Mejora el prompt antes de enviarlo",
                icon: "square.and.pencil",
                isOn: Binding(
                    get: { promptImproverEnabled },
                    set: { newValue in
                        promptImproverEnabled = newValue
                        onPromptImproverChanged(newValue)
                    }
                ),
                disabled: isUpdatingFeatures || !canControlFeatures
            )

            ComposerToggleRow(
                title: "Explainer",
                subtitle: "Activa el modo explicador sincronizado",
                icon: "text.magnifyingglass",
                isOn: Binding(
                    get: { explainerEnabled },
                    set: { newValue in
                        explainerEnabled = newValue
                        onExplainerChanged(newValue)
                    }
                ),
                disabled: isUpdatingFeatures || !canControlFeatures
            )

            if let codeContextEnabled {
                HStack {
                    Text("Code context")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(AppTheme.inkMuted)
                    Spacer()
                    Text(codeContextEnabled ? "On" : "Off")
                        .font(.system(size: 13, weight: .bold, design: .default))
                        .foregroundStyle(codeContextEnabled ? AppTheme.accentGreen : AppTheme.inkMuted)
                }
            }
        }
        .padding(18)
        .background(BreathingBackground())
    }
}

private struct ComposerToggleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let isOn: Binding<Bool>
    let disabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(AppTheme.cardSurfaceRaised)
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .default))
                        .foregroundStyle(AppTheme.ink)
                    Text(isOn.wrappedValue ? "On" : "Off")
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .foregroundStyle(isOn.wrappedValue ? AppTheme.accentGreen : AppTheme.inkMuted)
                }
            }

            Spacer(minLength: 10)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.accentGreen)
        }
        .padding(14)
        .background(
            AppTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.l, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
        .accessibilityHint(subtitle)
    }
}
