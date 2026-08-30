import Foundation

public enum FerminRelayDurableCommandState: String, Codable, CaseIterable, Sendable {
    case accepted
    case leased
    case engineDurable
    case sentToChild
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        switch normalized {
        case "accepted": self = .accepted
        case "leased": self = .leased
        case "enginedurable": self = .engineDurable
        case "senttochild": self = .sentToChild
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled", "canceled": self = .cancelled
        default: self = .unknown
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .unknown: return true
        case .accepted, .leased, .engineDurable, .sentToChild: return false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed, .cancelled, .unknown: return true
        case .accepted, .leased, .engineDurable, .sentToChild, .completed: return false
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

public struct FerminRelayDurableCommandAcknowledgement: Codable, Equatable, Sendable {
    public let ok: Bool
    public let commandID: String
    public let commandState: FerminRelayDurableCommandState?
    public let inserted: Bool?
    public let durable: Bool?
    public let queuedAt: Double?
    public let windowID: String?
    public let sessionID: String?
    public let sessionName: String?
    public let sourceWindowID: String?
    public let sourceSessionID: String?
    public let projectPath: String?
    public let projectName: String?
    public let clientMessageID: String?
    public let messageID: String?
    public let parentCommandID: String?
    public let name: String?
    public let minimized: Bool?
    public let runMode: String?
    public let goalStartedAt: Double?
    public let engine: String?

    public init(
        ok: Bool,
        commandID: String,
        commandState: FerminRelayDurableCommandState?,
        inserted: Bool?,
        durable: Bool?,
        queuedAt: Double?,
        windowID: String? = nil,
        sessionID: String? = nil,
        sessionName: String? = nil,
        sourceWindowID: String? = nil,
        sourceSessionID: String? = nil,
        projectPath: String? = nil,
        projectName: String? = nil,
        clientMessageID: String? = nil,
        messageID: String? = nil,
        parentCommandID: String? = nil,
        name: String? = nil,
        minimized: Bool? = nil,
        runMode: String? = nil,
        goalStartedAt: Double? = nil,
        engine: String? = nil
    ) {
        self.ok = ok
        self.commandID = commandID
        self.commandState = commandState
        self.inserted = inserted
        self.durable = durable
        self.queuedAt = queuedAt
        self.windowID = windowID
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sourceWindowID = sourceWindowID
        self.sourceSessionID = sourceSessionID
        self.projectPath = projectPath
        self.projectName = projectName
        self.clientMessageID = clientMessageID
        self.messageID = messageID
        self.parentCommandID = parentCommandID
        self.name = name
        self.minimized = minimized
        self.runMode = runMode
        self.goalStartedAt = goalStartedAt
        self.engine = engine
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case commandID = "commandId"
        case commandState, inserted, durable, queuedAt
        case windowID = "windowId"
        case sessionID = "sessionId"
        case sessionName
        case sourceWindowID = "sourceWindowId"
        case sourceSessionID = "sourceSessionId"
        case projectPath, projectName
        case clientMessageID = "clientMessageId"
        case messageID = "messageId"
        case parentCommandID = "parentCommandId"
        case name, minimized, runMode, goalStartedAt, engine
    }

    private enum AliasCodingKeys: String, CodingKey { case state }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok)
        commandID = values.relayString(forKey: .commandID)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        commandState = values.relayValue(
            FerminRelayDurableCommandState.self,
            forKey: .commandState
        ) ?? aliases.relayValue(FerminRelayDurableCommandState.self, forKey: .state)
        inserted = values.relayBoolIfPresent(forKey: .inserted)
        durable = values.relayBoolIfPresent(forKey: .durable)
        queuedAt = values.relayDoubleIfPresent(forKey: .queuedAt)
        windowID = values.relayStringIfPresent(forKey: .windowID)
        sessionID = values.relayStringIfPresent(forKey: .sessionID)
        sessionName = values.relayStringIfPresent(forKey: .sessionName)
        sourceWindowID = values.relayStringIfPresent(forKey: .sourceWindowID)
        sourceSessionID = values.relayStringIfPresent(forKey: .sourceSessionID)
        projectPath = values.relayStringIfPresent(forKey: .projectPath)
        projectName = values.relayStringIfPresent(forKey: .projectName)
        clientMessageID = values.relayStringIfPresent(forKey: .clientMessageID)
        messageID = values.relayStringIfPresent(forKey: .messageID)
        parentCommandID = values.relayStringIfPresent(forKey: .parentCommandID)
        name = values.relayStringIfPresent(forKey: .name)
        minimized = values.relayBoolIfPresent(forKey: .minimized)
        runMode = values.relayStringIfPresent(forKey: .runMode)
        goalStartedAt = values.relayDoubleIfPresent(forKey: .goalStartedAt)
        engine = values.relayStringIfPresent(forKey: .engine)
    }
}

public struct FerminRelayCommandStateChangedEvent: Codable, Equatable, Sendable {
    public let commandID: String
    public let state: FerminRelayDurableCommandState
    public let error: String?

    public init(
        commandID: String,
        state: FerminRelayDurableCommandState,
        error: String? = nil
    ) {
        self.commandID = commandID
        self.state = state
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case commandID = "commandId", state, error }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandID = values.relayString(forKey: .commandID)
        state = values.relayValue(FerminRelayDurableCommandState.self, forKey: .state)
            ?? .unknown
        error = values.relayStringIfPresent(forKey: .error)
    }
}

public enum FerminRelayTrackedCommandOperation: String, Codable, Sendable {
    case createSession
    case sendMessage
    case interrupt
    case retryPromptTransform
    case minimize
    case setPinned
    case rename
    case archive
    case delete
    case setFeatures
    case setRunMode
    case setModel
    case createSubagent
    case resumeHistory
    case recoverSession
}

public struct FerminRelayTrackedCommandContext: Codable, Equatable, Sendable {
    public let operation: FerminRelayTrackedCommandOperation
    public let source: FerminCodeRelaySource
    public let windowID: String?
    public let messageID: String?
    public let sessionID: String?
    public let mutationID: String?

    public init(
        operation: FerminRelayTrackedCommandOperation,
        source: FerminCodeRelaySource,
        windowID: String? = nil,
        messageID: String? = nil,
        sessionID: String? = nil,
        mutationID: String? = nil
    ) {
        self.operation = operation
        self.source = source
        self.windowID = windowID
        self.messageID = messageID
        self.sessionID = sessionID
        self.mutationID = mutationID
    }
}

public enum FerminRelayCommandTransition: Equatable, Sendable {
    case ignored
    case pending(FerminRelayTrackedCommandContext?)
    case completed(FerminRelayTrackedCommandContext?)
    case failed(
        FerminRelayTrackedCommandContext?,
        FerminRelayDurableCommandState,
        String?
    )
}

public enum FerminRelayDurableCommandError: Error, Equatable, Sendable {
    case rejected(FerminRelayDurableCommandState?)
    case incompleteAcknowledgement
    case notDurable
    case capacityExceeded(maximumPendingCommands: Int)
}

public actor FerminRelayDurableCommandTracker {
    private struct Entry: Sendable {
        var state: FerminRelayDurableCommandState
        let context: FerminRelayTrackedCommandContext
        let registeredAt: TimeInterval
    }

    private struct OrphanedTerminal: Sendable {
        let state: FerminRelayDurableCommandState
        let error: String?
    }

    private var entries: [String: Entry] = [:]
    private var orphanedTerminals: [String: OrphanedTerminal] = [:]
    private var terminalOrder: [String] = []
    private var terminalIDs: Set<String> = []
    private let maximumTerminalIDs: Int
    private let maximumPendingCommands: Int
    private let pendingTTL: TimeInterval

    public init(
        maximumTerminalIDs: Int = 256,
        maximumPendingCommands: Int = 1_024,
        pendingTTL: TimeInterval = 10 * 60
    ) {
        self.maximumTerminalIDs = max(1, maximumTerminalIDs)
        self.maximumPendingCommands = max(1, maximumPendingCommands)
        self.pendingTTL = max(1, pendingTTL)
    }

    public var pendingCount: Int { entries.count }

    public func register(
        _ acknowledgement: FerminRelayDurableCommandAcknowledgement,
        context: FerminRelayTrackedCommandContext,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws -> FerminRelayCommandTransition {
        pruneExpired(now: now)
        let commandID = acknowledgement.commandID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard acknowledgement.ok else {
            throw FerminRelayDurableCommandError.rejected(acknowledgement.commandState)
        }
        guard !commandID.isEmpty,
              let state = acknowledgement.commandState,
              acknowledgement.inserted != nil,
              let queuedAt = acknowledgement.queuedAt,
              queuedAt > 0 else {
            throw FerminRelayDurableCommandError.incompleteAcknowledgement
        }
        guard acknowledgement.durable == true else {
            throw FerminRelayDurableCommandError.notDurable
        }
        return try register(commandID: commandID, state: state, context: context, now: now)
    }

    public func apply(
        _ event: FerminRelayCommandStateChangedEvent,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> FerminRelayCommandTransition {
        pruneExpired(now: now)
        let commandID = event.commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandID.isEmpty, !terminalIDs.contains(commandID) else {
            return .ignored
        }
        let current = entries[commandID]
        if let current, event.state.progressionRank < current.state.progressionRank {
            return .ignored
        }
        if event.state.isTerminal {
            entries.removeValue(forKey: commandID)
            if current == nil {
                orphanedTerminals[commandID] = OrphanedTerminal(
                    state: event.state,
                    error: event.error
                )
            }
            rememberTerminal(commandID)
            return event.state.isFailure
                ? .failed(current?.context, event.state, event.error)
                : .completed(current?.context)
        }
        if var current {
            current.state = event.state
            entries[commandID] = current
        }
        return .pending(current?.context)
    }

    public func reset() {
        entries.removeAll(keepingCapacity: false)
        orphanedTerminals.removeAll(keepingCapacity: false)
        terminalOrder.removeAll(keepingCapacity: false)
        terminalIDs.removeAll(keepingCapacity: false)
    }

    @discardableResult
    public func expirePending(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [FerminRelayTrackedCommandContext] {
        pruneExpired(now: now)
    }

    private func register(
        commandID: String,
        state: FerminRelayDurableCommandState,
        context: FerminRelayTrackedCommandContext,
        now: TimeInterval
    ) throws -> FerminRelayCommandTransition {
        if let orphaned = orphanedTerminals.removeValue(forKey: commandID) {
            return orphaned.state.isFailure
                ? .failed(context, orphaned.state, orphaned.error)
                : .completed(context)
        }
        guard !terminalIDs.contains(commandID) else { return .ignored }
        if state.isTerminal {
            rememberTerminal(commandID)
            return state.isFailure
                ? .failed(context, state, nil)
                : .completed(context)
        }
        guard entries[commandID] != nil || entries.count < maximumPendingCommands else {
            throw FerminRelayDurableCommandError.capacityExceeded(
                maximumPendingCommands: maximumPendingCommands
            )
        }
        entries[commandID] = Entry(state: state, context: context, registeredAt: now)
        return .pending(context)
    }

    @discardableResult
    private func pruneExpired(now: TimeInterval) -> [FerminRelayTrackedCommandContext] {
        let expiredIDs = entries.compactMap { commandID, entry in
            now - entry.registeredAt >= pendingTTL ? commandID : nil
        }
        return expiredIDs.compactMap { commandID in
            entries.removeValue(forKey: commandID)?.context
        }
    }

    private func rememberTerminal(_ commandID: String) {
        guard terminalIDs.insert(commandID).inserted else { return }
        terminalOrder.append(commandID)
        while terminalOrder.count > maximumTerminalIDs {
            let evicted = terminalOrder.removeFirst()
            terminalIDs.remove(evicted)
            orphanedTerminals.removeValue(forKey: evicted)
        }
    }
}
