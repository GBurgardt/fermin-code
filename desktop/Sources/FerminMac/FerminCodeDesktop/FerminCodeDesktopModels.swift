import Foundation
import FerminCore

enum FerminCodeDesktopCreationPhase: Equatable {
    case idle
    case submitting
    case waitingForConfirmation
}

enum FerminCodeDesktopErrorPresentation {
    static func message(for error: Error, action: String) -> String {
        if let userError = error as? FerminCodeDesktopUserError {
            return userError.message
        }
        if let durableError = error as? FerminRelayDurableCommandError {
            switch durableError {
            case .rejected: return "El relay rechazó el comando para \(action)."
            case .incompleteAcknowledgement:
                return "El relay no confirmó de forma durable el comando para \(action)."
            case .notDurable:
                return "El relay respondió sin persistir el comando para \(action)."
            case .capacityExceeded:
                return "Hay demasiados comandos pendientes; esperá antes de \(action)."
            }
        }
        if let relayError = error as? FerminRelayHTTPError {
            switch relayError {
            case .invalidToken:
                return "El token no fue aceptado. Revisalo en Ajustes."
            case let .httpStatus(statusCode, _, serverMessage):
                if statusCode == 401 || statusCode == 403 {
                    return "El token no fue aceptado. Revisalo en Ajustes."
                }
                if statusCode == 404 {
                    return "El relay activo no admite \(action). Actualizá el servicio e intentá de nuevo."
                }
                let detail = serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "No se pudo \(action) (HTTP \(statusCode))."
                }
                return "No se pudo \(action) (HTTP \(statusCode)): \(detail)"
            case let .transport(code):
                let urlCode = URLError.Code(rawValue: code)
                switch urlCode {
                case .timedOut:
                    return "Se agotó el tiempo al intentar \(action)."
                case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                    return "No hay conexión para \(action)."
                default:
                    return "No se pudo conectar con el relay para \(action)."
                }
            default:
                return relayError.localizedDescription
            }
        }
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 403 {
            return "El token no fue aceptado. Revisalo en Ajustes."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "Se agotó el tiempo al intentar \(action)."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "No hay conexión para \(action)."
            default: break
            }
        }
        return "No se pudo \(action)."
    }
}

enum FerminCodeDesktopDetailLoadState: Equatable {
    case idle
    case loading
    case revalidating
    case loaded
    case failed(String)

    var isLoading: Bool {
        self == .loading || self == .revalidating
    }

    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

enum FerminCodeDesktopHistoryLoadState: Equatable {
    case idle
    case loading
    case revalidating
    case loaded
    case partial(String)
    case failed(String)

    var isLoading: Bool {
        self == .loading || self == .revalidating
    }

    var partialMessage: String? {
        guard case let .partial(message) = self else { return nil }
        return message
    }

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}
import UniformTypeIdentifiers

enum FerminCodeDesktopPreferences {
    static let profileKey = "fermin.code.desktop.profile"
    static let unpinnedSessionIDsKey = "fermin.code.desktop.unpinnedSessionIDs.v1"

    static func profile(from defaults: UserDefaults) -> FerminCodeRelayProfile {
        guard let rawValue = defaults.string(forKey: profileKey),
              let profile = FerminCodeRelayProfile(rawValue: rawValue) else {
            return .todo
        }
        return profile
    }

    static func saveProfile(_ profile: FerminCodeRelayProfile, to defaults: UserDefaults) {
        defaults.set(profile.rawValue, forKey: profileKey)
    }

    static func unpinnedSessionIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: unpinnedSessionIDsKey) ?? [])
    }

    static func saveUnpinnedSessionIDs(_ identifiers: Set<String>, to defaults: UserDefaults) {
        defaults.set(identifiers.sorted(), forKey: unpinnedSessionIDsKey)
    }
}

enum FerminCodeDesktopSessionPinningPolicy {
    static func identifier(for item: FerminCodeRelaySourcedSession) -> String {
        let sessionID = item.session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = sessionID.isEmpty ? item.session.windowID : sessionID
        return "\(item.source.rawValue)::\(stableID)"
    }

    static func isPinned(
        _ item: FerminCodeRelaySourcedSession,
        unpinnedSessionIDs: Set<String>
    ) -> Bool {
        item.session.isPinned ?? !unpinnedSessionIDs.contains(identifier(for: item))
    }

    static func pinnedSessions(
        in sessions: [FerminCodeRelaySourcedSession],
        unpinnedSessionIDs: Set<String>
    ) -> [FerminCodeRelaySourcedSession] {
        sessions.filter { isPinned($0, unpinnedSessionIDs: unpinnedSessionIDs) }
    }

    static func unpinnedSessions(
        in sessions: [FerminCodeRelaySourcedSession],
        unpinnedSessionIDs: Set<String>
    ) -> [FerminCodeRelaySourcedSession] {
        sessions.filter { !isPinned($0, unpinnedSessionIDs: unpinnedSessionIDs) }
    }
}

enum FerminCodeDesktopSessionNamePolicy {
    static let maximumLength = 64

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        validationMessage(for: value) == nil
    }

    static func validationMessage(for value: String) -> String? {
        let value = normalized(value)
        if value.isEmpty {
            return "Escribí un nombre para la sesión."
        }
        if value.count > maximumLength {
            return "Usá hasta \(maximumLength) caracteres."
        }
        return nil
    }
}

enum FerminCodeDesktopComposerAvailability {
    static func blockingMessage(for session: FerminRelaySession?) -> String? {
        guard let session else { return "Elegí una sesión para enviar." }
        guard !session.canSend else { return nil }

        let reason = session.unsupportedReason?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reason.isEmpty { return reason }
        if session.isMinimized == true {
            return "Restaurá la sesión para volver a enviar."
        }
        return "Esta sesión todavía no está lista para recibir mensajes."
    }
}

enum FerminCodeDesktopConnectionPhase: Equatable, Sendable {
    case missingCredential
    case loading
    case online
    case stale
    case offline

    var label: String {
        switch self {
        case .missingCredential: return "Falta token"
        case .loading: return "Conectando"
        case .online: return "Conectado"
        case .stale: return "Estado atrasado"
        case .offline: return "Sin conexión"
        }
    }

    var symbolName: String {
        switch self {
        case .missingCredential: return "key.fill"
        case .loading: return "arrow.triangle.2.circlepath"
        case .online: return "wifi"
        case .stale: return "clock.fill"
        case .offline: return "wifi.slash"
        }
    }
}

struct FerminCodeDesktopSourceStatus: Equatable, Sendable, Identifiable {
    let source: FerminCodeRelaySource
    var phase: FerminCodeDesktopConnectionPhase
    var sessionCount: Int
    var detail: String?
    var lastUpdatedAt: Date?

    var id: FerminCodeRelaySource { source }
}

struct FerminCodeDesktopLiveMessage: Equatable, Sendable {
    var message: FerminRelayMessage
    var revision: Int
    var updatedAt: Double
    var isFinal: Bool

    mutating func apply(_ patch: FerminRelayLiveMessagePatch) -> Bool {
        guard patch.message.id == message.id else { return false }
        if patch.revision < revision { return false }
        if patch.revision == revision, patch.updatedAt <= updatedAt { return false }
        if !patch.isFinal,
           patch.message.content.count < message.content.count,
           message.content.hasPrefix(patch.message.content) {
            return false
        }
        message = patch.message
        revision = patch.revision
        updatedAt = patch.updatedAt
        isFinal = patch.isFinal
        return true
    }
}

struct FerminCodeDesktopOptimisticMessage: Equatable, Sendable, Identifiable {
    enum Delivery: Equatable, Sendable {
        case sending
        case accepted
        case failed(String)
    }

    let message: FerminRelayMessage
    var delivery: Delivery

    var id: String { message.id }
}

struct FerminCodeDesktopAttachmentDraft: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let data: Data

    init(
        id: String = UUID().uuidString,
        name: String,
        mimeType: String,
        data: Data
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

enum FerminCodeDesktopAttachmentPolicy {
    static let maximumCount = 10
    static let maximumBytes = 20 * 1_024 * 1_024
    static let maximumTotalBytes = 50 * 1_024 * 1_024
    static let supportedMIMETypes = [
        "image/png", "image/jpeg", "image/gif", "image/webp",
    ]

    static func remainingCount(existingCount: Int) -> Int {
        max(0, maximumCount - max(0, existingCount))
    }

    static func capacityDescription(existingCount: Int) -> String {
        let remaining = remainingCount(existingCount: existingCount)
        if remaining == 0 {
            return "Límite alcanzado. Quitá una imagen para adjuntar otra."
        }
        let noun = remaining == 1 ? "imagen disponible" : "imágenes disponibles"
        return "\(remaining) \(noun)."
    }

    static func validateAdditionCount(existingCount: Int, incomingCount: Int) throws {
        let remaining = remainingCount(existingCount: existingCount)
        guard incomingCount <= remaining else {
            if remaining == 0 {
                throw FerminCodeDesktopUserError(
                    "Ya adjuntaste el máximo de \(maximumCount) imágenes."
                )
            }
            let noun = remaining == 1 ? "imagen" : "imágenes"
            throw FerminCodeDesktopUserError(
                "Podés adjuntar \(remaining) \(noun) más."
            )
        }
    }

    static func supportsDropCandidate(_ url: URL) -> Bool {
        guard url.isFileURL,
              !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else { return false }
        return supportedMIMETypes.contains(mimeType)
    }

    static func isLocalFileDropPayload(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy(\.isFileURL)
    }

    static func detectedMIMEType(for data: Data) -> String? {
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

    static func validate(_ drafts: [FerminCodeDesktopAttachmentDraft]) throws {
        guard drafts.count <= maximumCount else {
            throw FerminCodeDesktopUserError("Podés adjuntar hasta 10 imágenes.")
        }
        guard drafts.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes else {
            throw FerminCodeDesktopUserError("Las imágenes superan el límite total de 50 MiB.")
        }
        for draft in drafts {
            guard !draft.data.isEmpty else {
                throw FerminCodeDesktopUserError("\(draft.name) está vacía.")
            }
            guard draft.data.count <= maximumBytes else {
                throw FerminCodeDesktopUserError("\(draft.name) supera el límite de 20 MiB.")
            }
            guard supportedMIMETypes.contains(draft.mimeType),
                  detectedMIMEType(for: draft.data) == draft.mimeType else {
                throw FerminCodeDesktopUserError(
                    "\(draft.name) no es PNG, JPEG, GIF o WebP válido."
                )
            }
        }
    }
}

enum FerminCodeDesktopFeatureConfirmationPolicy {
    static func confirms(
        patch: FerminRelayFeaturePatch,
        authoritative: FerminRelaySessionFeatures?
    ) -> Bool {
        guard let authoritative else { return false }
        let expectations: [Bool] = [
            patch.promptImproverEnabled.map {
                authoritative.promptImproverEnabled == $0
            },
            patch.explainerEnabled.map {
                authoritative.explainerEnabled == $0
            },
            patch.codeContextEnabled.map {
                authoritative.codeContextEnabled == $0
            },
        ].compactMap { $0 }
        return !expectations.isEmpty && expectations.allSatisfy { $0 }
    }
}

enum FerminCodeDesktopPromptPreferenceSelectionPolicy {
    static func commonVariant(
        profile: FerminCodeRelayProfile,
        preferences: [FerminCodeRelaySource: FerminRelayPromptImproverPreference]
    ) -> FerminRelayPromptImproverVariant? {
        let values = profile.sources.compactMap { preferences[$0]?.variant }
        guard values.count == profile.sources.count,
              let first = values.first,
              first != .unknown,
              values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

enum FerminCodeDesktopPromptPreferencePresentation {
    static let scopeHelp = "Elegir una variante no activa «Mejorar». Se usa sólo en los próximos mensajes de las sesiones donde esté activo; una mejora ya iniciada continúa."

    static func persistenceHelp(profile: FerminCodeRelayProfile) -> String {
        profile == .todo
            ? "Se guarda en Personal y Puky; cualquier resultado parcial se informa."
            : "Se guarda sólo en \(profile.displayName)."
    }
}

enum FerminCodeDesktopPromptImproverControlPresentation {
    static func help(
        canControl: Bool,
        isEnabled: Bool,
        variantLabel: String?
    ) -> String {
        guard canControl else {
            return "Esta sesión no permite cambiar el mejorador."
        }
        let variant = variantLabel.map { " · \($0)" } ?? ""
        return isEnabled
            ? "Próximos mensajes\(variant). La mejora actual continúa al apagarlo."
            : "Mejorar próximos mensajes\(variant)"
    }
}

enum FerminCodeDesktopFeatureControlPresentation {
    static func accessibilityValue(isEnabled: Bool) -> String {
        isEnabled ? "Activado" : "Desactivado"
    }
}

enum FerminCodeDesktopCommandTargetPolicy {
    static func targetsSelectedSession(
        context: FerminRelayTrackedCommandContext?,
        eventSource: FerminCodeRelaySource,
        selectedRoute: FerminCodeRelaySessionRoute?
    ) -> Bool {
        guard let context,
              let selectedRoute,
              let windowID = context.windowID else { return false }
        return context.source == eventSource
            && selectedRoute.source == eventSource
            && selectedRoute.windowID == windowID
    }

    static func shouldPresentFailure(
        context: FerminRelayTrackedCommandContext?,
        eventSource: FerminCodeRelaySource,
        selectedRoute: FerminCodeRelaySessionRoute?
    ) -> Bool {
        guard let context else { return true }
        guard context.source == eventSource else { return false }
        guard context.windowID != nil else { return true }
        return targetsSelectedSession(
            context: context,
            eventSource: eventSource,
            selectedRoute: selectedRoute
        )
    }

    static func targetsCurrentFeatureOverride(
        context: FerminRelayTrackedCommandContext?,
        eventSource: FerminCodeRelaySource,
        selectedRoute: FerminCodeRelaySessionRoute?,
        currentMutationID: String?
    ) -> Bool {
        targetsSelectedSession(
            context: context,
            eventSource: eventSource,
            selectedRoute: selectedRoute
        )
            && context?.operation == .setFeatures
            && context?.mutationID == currentMutationID
            && currentMutationID != nil
    }

    static func targetsCurrentRuntimeModelOverride(
        context: FerminRelayTrackedCommandContext?,
        eventSource: FerminCodeRelaySource,
        selectedRoute: FerminCodeRelaySessionRoute?,
        currentMutationID: String?
    ) -> Bool {
        targetsSelectedSession(
            context: context,
            eventSource: eventSource,
            selectedRoute: selectedRoute
        )
            && context?.operation == .setModel
            && context?.mutationID == currentMutationID
            && currentMutationID != nil
    }

    static func targetsCurrentGoalModeOverride(
        context: FerminRelayTrackedCommandContext?,
        eventSource: FerminCodeRelaySource,
        selectedRoute: FerminCodeRelaySessionRoute?,
        currentMutationID: String?
    ) -> Bool {
        targetsSelectedSession(
            context: context,
            eventSource: eventSource,
            selectedRoute: selectedRoute
        )
            && context?.operation == .setRunMode
            && context?.mutationID == currentMutationID
            && currentMutationID != nil
    }
}

struct FerminCodeDesktopUserError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct FerminCodeDesktopPresentedMessage: Identifiable, Equatable, Sendable {
    let message: FerminRelayMessage
    let delivery: FerminCodeDesktopOptimisticMessage.Delivery?
    let isStreaming: Bool

    init(
        message: FerminRelayMessage,
        delivery: FerminCodeDesktopOptimisticMessage.Delivery?,
        isStreaming: Bool = false
    ) {
        self.message = message
        self.delivery = delivery
        self.isStreaming = isStreaming
    }

    var id: String { message.id }
}

enum FerminCodeDesktopTranscriptPolicy {
    static func merge(
        authoritative: [FerminRelayMessage],
        live: [String: FerminCodeDesktopLiveMessage],
        optimistic: [FerminCodeDesktopOptimisticMessage]
    ) -> [FerminCodeDesktopPresentedMessage] {
        var messagesByID = Dictionary(uniqueKeysWithValues: authoritative.map { ($0.id, $0) })
        var streamingMessageIDs = Set<String>()
        for patch in live.values {
            if let current = messagesByID[patch.message.id],
               !patch.isFinal,
               current.content.count >= patch.message.content.count,
               current.content.hasPrefix(patch.message.content) {
                continue
            }
            messagesByID[patch.message.id] = patch.message
            if patch.isFinal {
                streamingMessageIDs.remove(patch.message.id)
            } else {
                streamingMessageIDs.insert(patch.message.id)
            }
        }

        var result = messagesByID.values.map {
            FerminCodeDesktopPresentedMessage(
                message: $0,
                delivery: nil,
                isStreaming: streamingMessageIDs.contains($0.id)
            )
        }
        let authoritativeIDs = Set(messagesByID.keys)
        result.append(contentsOf: optimistic.compactMap { item in
            guard !authoritativeIDs.contains(item.id) else { return nil }
            return FerminCodeDesktopPresentedMessage(
                message: item.message,
                delivery: item.delivery
            )
        })
        return result.sorted { left, right in
            if left.message.timestamp == right.message.timestamp {
                return left.id < right.id
            }
            return left.message.timestamp < right.message.timestamp
        }
    }
}

enum FerminCodeDesktopTranscriptWindowPolicy {
    static let initialLimit = 80
    static let pageSize = 80

    static func nextLimit(current: Int, total: Int) -> Int {
        min(max(current, 0) + pageSize, max(total, 0))
    }

    static func hiddenCount(total: Int, visible: Int) -> Int {
        max(0, total - visible)
    }
}

enum FerminCodeDesktopTranscriptAvailabilityPresentation {
    static func incompleteSummary(loadedCount: Int, reportedCount: Int) -> String? {
        let loaded = max(0, loadedCount)
        let reported = max(loaded, reportedCount)
        guard loaded > 0, reported > loaded else { return nil }
        return "\(loaded) de \(reported) mensajes cargados. Los anteriores todavía no están disponibles."
    }
}

enum FerminCodeDesktopTranscriptIdentityPolicy {
    static func messageRowID(
        route: FerminCodeRelaySessionRoute?,
        messageID: String
    ) -> String {
        let routeID = route?.id ?? "no-session"
        return "\(routeID.utf8.count):\(routeID)\(messageID)"
    }

    static func earlierMessagesAnchorID(
        route: FerminCodeRelaySessionRoute?,
        firstVisibleMessageID: String?
    ) -> String? {
        firstVisibleMessageID.map {
            messageRowID(route: route, messageID: $0)
        }
    }

    static func shouldApplyQueuedEarlierMessagesAnchor(
        expectedSessionInstanceID: String?,
        currentSessionInstanceID: String?
    ) -> Bool {
        guard let expectedSessionInstanceID else { return false }
        return currentSessionInstanceID == expectedSessionInstanceID
    }
}

enum FerminCodeDesktopMessageContentSegment: Equatable {
    case markdown(String)
    case heading(level: Int, content: String)
    case list([FerminCodeDesktopMessageListItem])
    case quote(String)
    case table(headers: [String], rows: [[String]])
    case code(language: String?, content: String)
}

struct FerminCodeDesktopMessageListItem: Equatable {
    let marker: String
    let content: String
}

enum FerminCodeDesktopMessageContentPolicy {
    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
        let sourceLine: String
    }

    static func segments(
        in content: String,
        allowsUnclosedFence: Bool = false
    ) -> [FerminCodeDesktopMessageContentSegment] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [FerminCodeDesktopMessageContentSegment] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var openFence: Fence?

        for line in lines {
            if let fence = openFence {
                if isClosingFence(line, matching: fence) {
                    result.append(
                        .code(
                            language: fence.language,
                            content: codeLines
                                .joined(separator: "\n")
                                .trimmingCharacters(in: .newlines)
                        )
                    )
                    codeLines.removeAll(keepingCapacity: true)
                    openFence = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let fence = openingFence(in: line) {
                appendMarkdownBlocks(markdownLines, to: &result)
                markdownLines.removeAll(keepingCapacity: true)
                openFence = fence
            } else {
                markdownLines.append(line)
            }
        }

        if let fence = openFence {
            if allowsUnclosedFence {
                result.append(
                    .code(
                        language: fence.language,
                        content: codeLines
                            .joined(separator: "\n")
                            .trimmingCharacters(in: .newlines)
                    )
                )
            } else {
                markdownLines.append(fence.sourceLine)
                markdownLines.append(contentsOf: codeLines)
            }
        }
        appendMarkdownBlocks(markdownLines, to: &result)

        return result.isEmpty ? [.markdown(content)] : result
    }

    private static func appendMarkdownBlocks(
        _ lines: [String],
        to result: inout [FerminCodeDesktopMessageContentSegment]
    ) {
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            let markdown = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !markdown.isEmpty {
                result.append(.markdown(markdown))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let table = table(in: lines, startingAt: index) {
                flushParagraph()
                result.append(
                    .table(headers: table.headers, rows: table.rows)
                )
                index = table.nextIndex
                continue
            }

            if let heading = heading(in: line) {
                flushParagraph()
                result.append(.heading(level: heading.level, content: heading.content))
                index += 1
                continue
            }

            if let firstItem = listItem(in: line) {
                flushParagraph()
                var items = [firstItem.item]
                var nextIndex = index + 1
                while nextIndex < lines.count,
                      let nextItem = listItem(in: lines[nextIndex]),
                      nextItem.isOrdered == firstItem.isOrdered {
                    items.append(nextItem.item)
                    nextIndex += 1
                }
                result.append(.list(items))
                index = nextIndex
                continue
            }

            if let firstQuote = quoteContent(in: line) {
                flushParagraph()
                var quoteLines = [firstQuote]
                var nextIndex = index + 1
                while nextIndex < lines.count,
                      let nextQuote = quoteContent(in: lines[nextIndex]) {
                    quoteLines.append(nextQuote)
                    nextIndex += 1
                }
                result.append(.quote(quoteLines.joined(separator: "\n")))
                index = nextIndex
                continue
            }

            paragraphLines.append(line)
            index += 1
        }
        flushParagraph()
    }

    private static func table(
        in lines: [String],
        startingAt index: Int
    ) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(in: lines[index]),
              let separator = tableCells(in: lines[index + 1]),
              separator.count == headers.count,
              separator.allSatisfy(isTableSeparatorCell) else { return nil }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count,
              !lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cells = tableCells(in: lines[nextIndex]) {
            let normalized = Array(cells.prefix(headers.count))
                + Array(repeating: "", count: max(0, headers.count - cells.count))
            rows.append(normalized)
            nextIndex += 1
        }
        return (headers, rows, nextIndex)
    }

    private static func tableCells(in line: String) -> [String]? {
        let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("|") else { return nil }

        let hasLeadingPipe = candidate.first == "|"
        let hasTrailingPipe = candidate.last == "|"
            && !candidate.dropLast().hasSuffix("\\")
        var cells: [String] = []
        var current = ""
        var escapesNextCharacter = false
        var isInsideCode = false

        for character in candidate {
            if escapesNextCharacter {
                current.append(character)
                escapesNextCharacter = false
            } else if character == "\\" {
                current.append(character)
                escapesNextCharacter = true
            } else if character == "`" {
                current.append(character)
                isInsideCode.toggle()
            } else if character == "|", !isInsideCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if hasLeadingPipe, !cells.isEmpty { cells.removeFirst() }
        if hasTrailingPipe, !cells.isEmpty { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableSeparatorCell(_ cell: String) -> Bool {
        var candidate = cell.trimmingCharacters(in: .whitespaces)
        if candidate.first == ":" { candidate.removeFirst() }
        if candidate.last == ":" { candidate.removeLast() }
        return candidate.count >= 3 && candidate.allSatisfy { $0 == "-" }
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let candidate = contentAfterPermittedIndent(in: line)
        guard let candidate else { return nil }
        let level = candidate.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = candidate.dropFirst(level)
        guard let first = remainder.first, first == " " || first == "\t" else { return nil }
        let content = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : (level, content)
    }

    private static func listItem(
        in line: String
    ) -> (item: FerminCodeDesktopMessageListItem, isOrdered: Bool)? {
        guard let candidate = contentAfterPermittedIndent(in: line), !candidate.isEmpty else {
            return nil
        }

        if let marker = candidate.first, marker == "-" || marker == "*" || marker == "+" {
            let remainder = candidate.dropFirst()
            guard let first = remainder.first, first == " " || first == "\t" else { return nil }
            let content = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return (
                FerminCodeDesktopMessageListItem(marker: "•", content: content),
                false
            )
        }

        let digits = candidate.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = candidate.dropFirst(digits.count)
        guard let punctuation = afterDigits.first,
              punctuation == "." || punctuation == ")" else { return nil }
        let remainder = afterDigits.dropFirst()
        guard let first = remainder.first, first == " " || first == "\t" else { return nil }
        let content = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return (
            FerminCodeDesktopMessageListItem(
                marker: "\(digits)\(punctuation)",
                content: content
            ),
            true
        )
    }

    private static func quoteContent(in line: String) -> String? {
        guard let candidate = contentAfterPermittedIndent(in: line), candidate.first == ">" else {
            return nil
        }
        let remainder = candidate.dropFirst()
        let content = remainder.first == " " ? remainder.dropFirst() : remainder[...]
        return String(content)
    }

    private static func contentAfterPermittedIndent(in line: String) -> Substring? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        return line.dropFirst(leadingSpaces)
    }

    private static func openingFence(in line: String) -> Fence? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        let candidate = line.dropFirst(leadingSpaces)
        guard let marker = candidate.first, marker == "`" || marker == "~" else { return nil }
        let length = candidate.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }

        let rawInfo = candidate
            .dropFirst(length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker != "`" || !rawInfo.contains("`") else { return nil }
        let language = rawInfo.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return Fence(marker: marker, length: length, language: language, sourceLine: line)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return false }
        let candidate = line.dropFirst(leadingSpaces)
        let length = candidate.prefix { $0 == fence.marker }.count
        guard length >= fence.length else { return false }
        return candidate.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

enum FerminCodeDesktopSessionDetailPolicy {
    static func matches(
        _ detail: FerminRelaySession,
        route: FerminCodeRelaySessionRoute,
        expectedSessionID: String? = nil
    ) -> Bool {
        guard detail.windowID == route.windowID else { return false }
        let normalizedExpectedSessionID = expectedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedExpectedSessionID.isEmpty
            || detail.sessionID == normalizedExpectedSessionID
    }
}

enum FerminCodeDesktopRuntimeModelPresentation {
    static func compactModelLabel(_ model: String?) -> String {
        let normalized = model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return "MODELO" }
        if normalized == "gpt-5.6" { return "SOL" }
        if normalized.hasPrefix("gpt-5.6-") {
            return String(normalized.dropFirst("gpt-5.6-".count)).uppercased()
        }
        return normalized.split(separator: "-").last.map(String.init)?.uppercased()
            ?? "MODELO"
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

    static func effortDescription(_ effort: String, fallback: String? = nil) -> String? {
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": return "Más rápido para tareas directas."
        case "medium": return "Equilibra velocidad y profundidad."
        case "high": return "Analiza con más detalle antes de responder."
        case "xhigh": return "Dedica más tiempo a problemas complejos."
        case "max": return "Usa el máximo razonamiento disponible."
        default:
            let value = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }
}

enum FerminCodeDesktopRuntimeSelectionSyncPolicy {
    static func shouldAdoptStoreSelection(
        isPresented: Bool,
        isApplying: Bool,
        hasPendingSelection: Bool
    ) -> Bool {
        !isApplying && (!isPresented || !hasPendingSelection)
    }
}

struct FerminCodeDesktopRuntimeDraft: Equatable {
    let model: String
    let effort: String
}

enum FerminCodeDesktopRuntimeDraftPolicy {
    static func draft(
        model: String,
        effort: String,
        baselineModel: String,
        baselineEffort: String
    ) -> FerminCodeDesktopRuntimeDraft? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !effort.isEmpty else { return nil }
        let hasChange = model != baselineModel
            || effort.caseInsensitiveCompare(baselineEffort) != .orderedSame
        return hasChange ? FerminCodeDesktopRuntimeDraft(model: model, effort: effort) : nil
    }
}

enum FerminCodeDesktopRuntimePopoverPolicy {
    static func blocksInteractiveDismiss(isApplying: Bool) -> Bool {
        isApplying
    }
}

enum FerminCodeDesktopRuntimeCatalogSelectionPolicy {
    static func resolvedModel(
        requested: String?,
        models: [FerminRelayAvailableModel]
    ) -> String? {
        if let requested,
           models.contains(where: { $0.model == requested }) {
            return requested
        }
        return models.first(where: { $0.isDefault == true })?.model
            ?? models.first?.model
    }
}

enum FerminCodeDesktopRuntimeApplyPolicy {
    static func canApply(
        model: String,
        effort: String,
        hasChange: Bool,
        isApplying: Bool
    ) -> Bool {
        !isApplying
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasChange
    }

    static func help(
        model: String,
        effort: String,
        hasChange: Bool,
        isApplying: Bool
    ) -> String {
        if isApplying { return "Aplicando modelo y razonamiento…" }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Elegí un modelo."
        }
        if effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Elegí un nivel de razonamiento."
        }
        if !hasChange { return "El modelo y el razonamiento ya están aplicados." }
        return "Aplicar a esta sesión"
    }
}

enum FerminCodeDesktopNewSessionRuntimePolicy {
    static let model = "gpt-5.6-sol"
    static let reasoningEffort = "max"
}

enum FerminCodeDesktopCredentialCoveragePolicy {
    static func missingSources(
        profile: FerminCodeRelayProfile,
        presence: [FerminCodeRelaySource: Bool]
    ) -> [FerminCodeRelaySource] {
        profile.sources.filter { presence[$0] != true }
    }

    static func hasConfiguredSource(
        profile: FerminCodeRelayProfile,
        presence: [FerminCodeRelaySource: Bool]
    ) -> Bool {
        profile.sources.contains { presence[$0] == true }
    }
}

enum FerminCodeDesktopCredentialFocusPolicy {
    static func preferredSource(
        presence: [FerminCodeRelaySource: Bool],
        current: FerminCodeRelaySource?,
        unsavedSources: Set<FerminCodeRelaySource>
    ) -> FerminCodeRelaySource? {
        if let current, unsavedSources.contains(current) { return current }
        if let sourceWithUnsavedInput = FerminCodeRelaySource.allCases.first(where: {
            unsavedSources.contains($0)
        }) {
            return sourceWithUnsavedInput
        }

        let firstMissing = FerminCodeRelaySource.allCases.first {
            presence[$0] != true
        }
        guard let current else { return firstMissing }
        return presence[current] == true ? firstMissing : current
    }
}

enum FerminCodeDesktopComposerFocusPolicy {
    static func shouldRestoreAfterModal(
        isModalPresented: Bool,
        hasSelectedSession: Bool
    ) -> Bool {
        !isModalPresented && hasSelectedSession
    }
}

enum FerminCodeDesktopComposerStatusPresentation {
    static func label(
        isSending: Bool,
        isAddingAttachments: Bool,
        blockingMessage: String?,
        hasDraft: Bool
    ) -> String? {
        if isSending { return "Enviando…" }
        if isAddingAttachments { return "Preparando imágenes…" }
        if let blockingMessage { return blockingMessage }
        return hasDraft ? "BORRADOR GUARDADO · ⌘↩" : nil
    }
}

enum FerminCodeDesktopComposerTextPresentation {
    static let maximumUTF8Bytes = 256 * 1_024
    private static let visibleUsageThreshold = maximumUTF8Bytes * 4 / 5

    static func hasVisibleContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func validationMessage(for text: String) -> String? {
        guard text.utf8.count > maximumUTF8Bytes else { return nil }
        return "El mensaje supera el límite de 256 KB. Reducilo antes de enviar."
    }

    static func usageLabel(for text: String) -> String? {
        let bytes = text.utf8.count
        guard bytes >= visibleUsageThreshold else { return nil }
        let kilobytes = (bytes + 1_023) / 1_024
        return bytes > maximumUTF8Bytes
            ? "\(kilobytes) KB · máximo 256 KB"
            : "\(kilobytes) de 256 KB"
    }
}

enum FerminCodeDesktopSubagentFormPolicy {
    static func taskValidationMessage(_ task: String) -> String? {
        guard FerminCodeDesktopComposerTextPresentation.validationMessage(for: task) != nil
        else { return nil }
        return "La tarea supera el límite de 256 KB. Reducila antes de crear."
    }

    static func taskUsageLabel(_ task: String) -> String? {
        FerminCodeDesktopComposerTextPresentation.usageLabel(for: task)
    }

    static func canConfirm(
        task: String,
        nameValidationMessage: String?,
        isCreating: Bool
    ) -> Bool {
        !isCreating
            && nameValidationMessage == nil
            && taskValidationMessage(task) == nil
            && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func confirmHelp(
        task: String,
        nameValidationMessage: String?,
        isCreating: Bool
    ) -> String {
        if isCreating { return "Creando el subagente…" }
        if let nameValidationMessage { return nameValidationMessage }
        if let taskValidationMessage = taskValidationMessage(task) {
            return taskValidationMessage
        }
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Describí una tarea para continuar."
        }
        return "Crear subagente (⌘↩)"
    }
}

enum FerminCodeDesktopRenameFormPolicy {
    static func validationMessage(name: String, currentName: String) -> String? {
        guard name != currentName else { return nil }
        if let validation = FerminCodeDesktopSessionNamePolicy.validationMessage(for: name) {
            return validation
        }
        guard FerminCodeDesktopSessionNamePolicy.normalized(name)
                != FerminCodeDesktopSessionNamePolicy.normalized(currentName) else {
            return "El nombre no cambia después de quitar los espacios exteriores."
        }
        return nil
    }

    static func canConfirm(name: String, currentName: String, isRenaming: Bool) -> Bool {
        !isRenaming
            && FerminCodeDesktopSessionNamePolicy.isValid(name)
            && FerminCodeDesktopSessionNamePolicy.normalized(name)
                != FerminCodeDesktopSessionNamePolicy.normalized(currentName)
    }

    static func confirmHelp(name: String, currentName: String, isRenaming: Bool) -> String {
        if isRenaming { return "Guardando el nuevo nombre…" }
        if let validation = validationMessage(name: name, currentName: currentName) {
            return validation
        }
        guard FerminCodeDesktopSessionNamePolicy.normalized(name)
                != FerminCodeDesktopSessionNamePolicy.normalized(currentName) else {
            return "Escribí un nombre distinto al actual."
        }
        return "Guardar el nuevo nombre"
    }
}

enum FerminCodeDesktopCreateFormPolicy {
    static func canConfirm(name: String, projectPath: String, isCreating: Bool) -> Bool {
        !isCreating
            && !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FerminCodeDesktopSessionNamePolicy.isValid(name)
    }

    static func confirmHelp(
        name: String,
        projectPath: String,
        isLoadingProjects: Bool,
        creationPhase: FerminCodeDesktopCreationPhase
    ) -> String {
        switch creationPhase {
        case .submitting: return "Enviando la solicitud…"
        case .waitingForConfirmation: return "Preparando la sesión…"
        case .idle: break
        }
        if let validation = FerminCodeDesktopSessionNamePolicy.validationMessage(for: name) {
            return validation
        }
        if isLoadingProjects {
            return "Esperá a que terminen de cargar los proyectos."
        }
        if projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Elegí un proyecto."
        }
        return "Crear sesión con Sol · MAX"
    }
}

enum FerminCodeDesktopCredentialActionPolicy {
    static func canSave(token: String, isSaving: Bool, isDeleting: Bool) -> Bool {
        !isSaving
            && !isDeleting
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func saveHelp(
        token: String,
        isConfigured: Bool,
        isSaving: Bool,
        isDeleting: Bool
    ) -> String {
        if isSaving { return "Guardando el token en Keychain…" }
        if isDeleting {
            return "Esperá a que termine la eliminación."
        }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isConfigured
                ? "Pegá un token nuevo para reemplazar el actual."
                : "Pegá un token para continuar."
        }
        return isConfigured ? "Reemplazar el token guardado" : "Guardar el token en Keychain"
    }
}

enum FerminCodeDesktopNewSessionActionPresentation {
    static func title(creationPhase: FerminCodeDesktopCreationPhase) -> String {
        switch creationPhase {
        case .idle: return "Nueva sesión"
        case .submitting: return "Enviando solicitud…"
        case .waitingForConfirmation: return "Esperando confirmación…"
        }
    }

    static func accessibilityValue(
        creationPhase: FerminCodeDesktopCreationPhase
    ) -> String {
        switch creationPhase {
        case .idle: return "Disponible"
        case .submitting: return "Solicitud en envío"
        case .waitingForConfirmation: return "Solicitud aceptada; sesión pendiente"
        }
    }

    static func help(
        profile: FerminCodeRelayProfile,
        credentialPresence: [FerminCodeRelaySource: Bool],
        isBootstrapping: Bool,
        creationPhase: FerminCodeDesktopCreationPhase
    ) -> String {
        switch creationPhase {
        case .submitting:
            return "Enviando la solicitud a \(profile.displayName). Podés seguir usando la app."
        case .waitingForConfirmation:
            return "\(profile.displayName) aceptó la solicitud. Esperando que la sesión quede lista."
        case .idle:
            break
        }
        if isBootstrapping {
            return "Esperá a que termine la conexión inicial."
        }
        let configuredSources = profile.sources.filter { credentialPresence[$0] == true }
        guard !configuredSources.isEmpty else {
            if let source = profile.singleSource {
                return "Configurá el token de \(source.displayName) para crear una sesión."
            }
            return "Configurá al menos un token para crear una sesión."
        }
        if profile == .todo {
            return configuredSources.count == 1
                ? "Crear una sesión en \(configuredSources[0].displayName)"
                : "Crear una sesión y elegir entre Personal o Puky"
        }
        let source = configuredSources[0]
        return "Crear una sesión en \(source.displayName)"
    }
}

enum FerminCodeDesktopActivityPresentation {
    enum State: Equatable, Sendable {
        case ready
        case busy
        case failed
        case inactive
        case unknown
    }

    static func state(for rawValue: String) -> State {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.contains("working")
            || value.contains("processing")
            || value.contains("sending")
            || value.contains("creating") {
            return .busy
        }
        if value.contains("error")
            || value.contains("failed")
            || value.contains("cancelled") {
            return .failed
        }
        if value.contains("waiting")
            || value.contains("ready")
            || value.contains("idle")
            || value.contains("completed") {
            return .ready
        }
        if value.contains("minimized")
            || value.contains("archived")
            || value.contains("offline") {
            return .inactive
        }
        return .unknown
    }

    static func label(for rawValue: String) -> String {
        switch state(for: rawValue) {
        case .ready: return "Lista"
        case .busy: return "Trabajando"
        case .failed: return "Con error"
        case .inactive: return "Inactiva"
        case .unknown: return "Estado desconocido"
        }
    }

    static func symbol(for rawValue: String) -> String {
        switch state(for: rawValue) {
        case .ready: return "circle.fill"
        case .busy: return "circle.dotted"
        case .failed: return "exclamationmark.triangle.fill"
        case .inactive, .unknown: return "circle"
        }
    }
}

enum FerminCodeDesktopRuntimeFailurePresentation {
    static func message(activityStatus: String, detail: String?) -> String? {
        guard FerminCodeDesktopActivityPresentation.state(for: activityStatus) == .failed else {
            return nil
        }
        let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }
}

enum FerminCodeDesktopPromptTransformPresentation {
    static let reconciliationThreshold: TimeInterval = 30
    // Backend b16 grants each of the two sequential observer phases six
    // minutes. Do not present a healthy, still-bounded transformation as
    // stalled before both budgets plus cleanup can elapse.
    static let stalledThreshold: TimeInterval = 13 * 60
    static let localRefreshNanoseconds: UInt64 = 5_000_000_000
    static let ongoingHelp =
        "Podés desactivar Mejorar para los próximos mensajes; esta mejora continúa."
    static let reconciliationHelp =
        "Fermín verifica esta mejora automáticamente. Cambiar Mejorar afecta sólo los próximos mensajes."

    enum State: Equatable, Sendable {
        case hidden
        case pending
        case reconciling
        case stalled
        case failed

        var needsReconciliation: Bool {
            self == .pending || self == .reconciling || self == .stalled
        }
    }

    static func state(
        status: String?,
        errorReason: String?,
        hasResult: Bool = false,
        timestamp: Double = 0,
        observedAt: TimeInterval? = nil,
        attemptStartedAt: TimeInterval? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> State {
        if hasResult { return .hidden }
        let value = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["done", "complete", "completed", "succeeded", "success"].contains(value) {
            return .hidden
        }
        let reason = errorReason?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reason.isEmpty
            || ["error", "failed", "failure", "cancelled", "canceled", "aborted"]
                .contains(value) {
            return .failed
        }
        if ["pending", "queued", "processing", "running", "in_progress", "in-progress", "started"]
            .contains(value) {
            let normalizedTimestamp = timestamp > 10_000_000_000
                ? timestamp / 1_000
                : timestamp
            let timestampIsCredible = normalizedTimestamp > 0
                && normalizedTimestamp <= now + reconciliationThreshold
            let attemptIsCredible = attemptStartedAt.map {
                $0 > 0 && $0 <= now + reconciliationThreshold
            } ?? false
            let sentAt = attemptIsCredible
                ? (attemptStartedAt ?? 0)
                : (timestampIsCredible
                    ? normalizedTimestamp
                    : (observedAt ?? normalizedTimestamp))
            if sentAt > 0, now - sentAt >= stalledThreshold {
                return .stalled
            }
            if sentAt > 0, now - sentAt >= reconciliationThreshold {
                return .reconciling
            }
            return .pending
        }
        return .hidden
    }

    static func failureDetail(status: String? = nil, errorReason: String?) -> String {
        let reason = [status, errorReason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .lowercased()
        if reason.contains("sidecar_unavailable")
            || reason.contains("observer_unavailable") {
            return "El servicio de mejora no está disponible."
        }
        if reason.contains("prompt_fidelity_timeout") {
            return "La verificación de fidelidad superó seis minutos y se interrumpió."
        }
        if reason.contains("prompt_improver_timeout") {
            return "La mejora superó seis minutos y se interrumpió."
        }
        if reason.contains("timeout") {
            return "La mejora o su verificación tardaron demasiado y se interrumpieron."
        }
        if reason.contains("abort") || reason.contains("cancel") {
            return "La mejora se canceló antes de terminar."
        }
        return "No se pudo mejorar el prompt; el original quedó intacto."
    }

    static func shouldRefreshLocally(_ state: State) -> Bool {
        state == .pending || state == .reconciling
    }
}

enum FerminCodeDesktopHistoryPresentation {
    static func stateLabel(_ state: FerminRelayHistoryState) -> String {
        switch state {
        case .all: return "TODAS"
        case .active: return "ACTIVA"
        case .archived: return "ARCHIVADA"
        case .unknown: return "ESTADO DESCONOCIDO"
        }
    }

    static func stateSymbol(_ state: FerminRelayHistoryState) -> String {
        switch state {
        case .active: return "circle.fill"
        case .archived: return "archivebox.fill"
        case .all, .unknown: return "questionmark.circle"
        }
    }

    static func resumeMutationKey(
        source: FerminCodeRelaySource,
        itemID: String
    ) -> String {
        "resume-\(source.rawValue)-\(itemID)"
    }
}

enum FerminCodeDesktopHistoryEscapeAction: Equatable {
    case clearQuery
    case resignFocus
    case dismissSheet
}

enum FerminCodeDesktopHistoryEscapePolicy {
    static func action(
        queryIsEmpty: Bool,
        isSearchFocused: Bool
    ) -> FerminCodeDesktopHistoryEscapeAction {
        guard queryIsEmpty else { return .clearQuery }
        return isSearchFocused ? .resignFocus : .dismissSheet
    }
}

enum FerminCodeDesktopSessionListPolicy {
    static func filterAndSort(
        _ sessions: [FerminCodeRelaySourcedSession],
        profile: FerminCodeRelayProfile,
        searchText: String,
        includeMinimized: Bool
    ) -> [FerminCodeRelaySourcedSession] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return sessions
            .filter { profile.accepts($0.source) }
            .filter { includeMinimized || $0.session.isMinimized != true }
            .filter { item in
                guard !query.isEmpty else { return true }
                let haystack = [
                    item.session.displayName,
                    item.session.sessionName,
                    item.session.projectName,
                    item.session.projectPath,
                    item.session.lastMessagePreview,
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    )
                return haystack.contains(query)
            }
            .sorted { left, right in
                if left.session.updatedAt == right.session.updatedAt {
                    if left.source != right.source {
                        return left.source.rawValue < right.source.rawValue
                    }
                    return left.session.displayName.localizedStandardCompare(
                        right.session.displayName
                    ) == .orderedAscending
                }
                return left.session.updatedAt > right.session.updatedAt
            }
    }

    static func hiddenMinimizedMatches(
        _ sessions: [FerminCodeRelaySourcedSession],
        profile: FerminCodeRelayProfile,
        searchText: String
    ) -> [FerminCodeRelaySourcedSession] {
        filterAndSort(
            sessions,
            profile: profile,
            searchText: searchText,
            includeMinimized: true
        )
        .filter { $0.session.isMinimized == true }
    }
}

struct FerminCodeDesktopSourcedHistoryItem: Identifiable, Hashable, Sendable {
    let source: FerminCodeRelaySource
    let item: FerminRelaySessionHistoryItem

    var id: String { "\(source.rawValue)::history::\(item.id)" }
}

struct FerminCodeDesktopSourcedRecoveryItem: Identifiable, Hashable, Sendable {
    let source: FerminCodeRelaySource
    let item: FerminRelayRecoverableSessionItem

    var id: String { "\(source.rawValue)::recovery::\(item.id)" }
}

struct FerminCodeDesktopPendingCommand: Identifiable, Equatable, Sendable {
    let id: String
    let source: FerminCodeRelaySource
    let operation: FerminRelayTrackedCommandOperation
    let windowID: String?
    let messageID: String?
    var state: FerminRelayDurableCommandState
    var error: String?

    var isTerminal: Bool { state.isTerminal }
}

struct FerminCodeDesktopPreview: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String, language: String?)
        case image(Data, mimeType: String?)
    }

    let id: String
    let name: String
    let path: String
    let content: Content
}

enum FerminCodeDesktopTimestamp {
    private static let formatterLock = NSLock()
    private static let sameDayFormatter = makeFormatter(format: "HH:mm")
    private static let olderFormatter = makeFormatter(format: "d MMM · HH:mm")

    static func date(millisecondsOrSeconds value: Double) -> Date? {
        guard value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func label(_ value: Double, now: Date = Date()) -> String? {
        guard let date = date(millisecondsOrSeconds: value) else { return nil }
        let formatter = Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now)
            ? sameDayFormatter
            : olderFormatter
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: date)
    }

    private static func makeFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}
