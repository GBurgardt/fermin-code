import Foundation

public enum FerminRelayHistoryState: String, Codable, CaseIterable, Sendable {
    case all
    case active
    case archived
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value.lowercased()) ?? .unknown
    }
}

public enum FerminRelayHistorySort: String, Codable, CaseIterable, Sendable {
    case relevance
    case recent
    case name
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value.lowercased()) ?? .unknown
    }
}

public struct FerminRelaySessionHistoryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionUUID: String?
    public let projectKey: String
    public let projectName: String
    public let sessionID: String
    public let sessionName: String
    public let sessionPath: String
    public let createdAt: Double
    public let updatedAt: Double
    public let state: FerminRelayHistoryState
    public let windowID: String?
    public let archivedID: String?
    public let score: Double
    public let preview: String
    public let matchedIn: String?
    public let canResume: Bool

    public init(
        id: String,
        sessionUUID: String? = nil,
        projectKey: String = "",
        projectName: String = "",
        sessionID: String = "",
        sessionName: String = "",
        sessionPath: String = "",
        createdAt: Double = 0,
        updatedAt: Double = 0,
        state: FerminRelayHistoryState = .unknown,
        windowID: String? = nil,
        archivedID: String? = nil,
        score: Double = 0,
        preview: String = "",
        matchedIn: String? = nil,
        canResume: Bool = false
    ) {
        self.id = id
        self.sessionUUID = sessionUUID
        self.projectKey = projectKey
        self.projectName = projectName
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sessionPath = sessionPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.windowID = windowID
        self.archivedID = archivedID
        self.score = score
        self.preview = preview
        self.matchedIn = matchedIn
        self.canResume = canResume
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionUUID = "sessionUuid"
        case projectKey, projectName
        case sessionID = "sessionId"
        case sessionName, sessionPath, createdAt, updatedAt, state
        case windowID = "windowId"
        case archivedID = "archivedId"
        case score, preview, matchedIn, canResume
    }

    private enum AliasCodingKeys: String, CodingKey { case sessionUUID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.relayString(forKey: .id)
        let aliases = try decoder.container(keyedBy: AliasCodingKeys.self)
        sessionUUID = values.relayStringIfPresent(forKey: .sessionUUID)
            ?? aliases.relayStringIfPresent(forKey: .sessionUUID)
        projectKey = values.relayString(forKey: .projectKey)
        projectName = values.relayString(forKey: .projectName)
        sessionID = values.relayString(forKey: .sessionID)
        sessionName = values.relayString(forKey: .sessionName)
        sessionPath = values.relayString(forKey: .sessionPath)
        createdAt = values.relayDouble(forKey: .createdAt)
        updatedAt = values.relayDouble(forKey: .updatedAt)
        state = values.relayValue(FerminRelayHistoryState.self, forKey: .state) ?? .unknown
        windowID = values.relayStringIfPresent(forKey: .windowID)
        archivedID = values.relayStringIfPresent(forKey: .archivedID)
        score = values.relayDouble(forKey: .score)
        preview = values.relayString(forKey: .preview)
        matchedIn = values.relayStringIfPresent(forKey: .matchedIn)
        canResume = values.relayBool(forKey: .canResume)
    }
}

public struct FerminRelaySessionHistoryEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let items: [FerminRelaySessionHistoryItem]
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let hasMore: Bool
    public let updatedAt: Double
    public let searchMilliseconds: Double
    public let indexBuildMilliseconds: Double
    public let indexedSessions: Int
    public let indexedTerms: Int

    public init(
        ok: Bool = true,
        items: [FerminRelaySessionHistoryItem],
        offset: Int = 0,
        limit: Int = 0,
        total: Int = 0,
        hasMore: Bool = false,
        updatedAt: Double = 0,
        searchMilliseconds: Double = 0,
        indexBuildMilliseconds: Double = 0,
        indexedSessions: Int = 0,
        indexedTerms: Int = 0
    ) {
        self.ok = ok
        self.items = items
        self.offset = offset
        self.limit = limit
        self.total = total
        self.hasMore = hasMore
        self.updatedAt = updatedAt
        self.searchMilliseconds = searchMilliseconds
        self.indexBuildMilliseconds = indexBuildMilliseconds
        self.indexedSessions = indexedSessions
        self.indexedTerms = indexedTerms
    }

    private enum CodingKeys: String, CodingKey {
        case ok, items, offset, limit, total, hasMore, updatedAt
        case searchMilliseconds = "searchMs"
        case indexBuildMilliseconds = "indexBuildMs"
        case indexedSessions, indexedTerms
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        items = values.relayArray(FerminRelaySessionHistoryItem.self, forKey: .items)
        offset = values.relayInt(forKey: .offset)
        limit = values.relayInt(forKey: .limit)
        total = values.relayInt(forKey: .total, default: items.count)
        hasMore = values.relayBool(forKey: .hasMore)
        updatedAt = values.relayDouble(forKey: .updatedAt)
        searchMilliseconds = values.relayDouble(forKey: .searchMilliseconds)
        indexBuildMilliseconds = values.relayDouble(forKey: .indexBuildMilliseconds)
        indexedSessions = values.relayInt(forKey: .indexedSessions)
        indexedTerms = values.relayInt(forKey: .indexedTerms)
    }
}

public struct FerminRelaySessionHistoryQuery: Equatable, Sendable {
    public var text: String
    public var state: FerminRelayHistoryState
    public var sort: FerminRelayHistorySort
    public var projectPath: String?
    public var fromMilliseconds: UInt64?
    public var offset: Int
    public var limit: Int
    public var refresh: Bool

    public init(
        text: String = "",
        state: FerminRelayHistoryState = .all,
        sort: FerminRelayHistorySort = .recent,
        projectPath: String? = nil,
        fromMilliseconds: UInt64? = nil,
        offset: Int = 0,
        limit: Int = 30,
        refresh: Bool = false
    ) {
        self.text = text
        self.state = state
        self.sort = sort
        self.projectPath = projectPath
        self.fromMilliseconds = fromMilliseconds
        self.offset = offset
        self.limit = limit
        self.refresh = refresh
    }

    public var queryItems: [URLQueryItem] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSort: FerminRelayHistorySort = normalizedText.isEmpty || sort != .recent
            ? sort
            : .relevance
        var items = [
            URLQueryItem(name: "query", value: normalizedText),
            URLQueryItem(name: "state", value: state == .unknown ? "all" : state.rawValue),
            URLQueryItem(name: "sort", value: effectiveSort == .unknown ? "recent" : effectiveSort.rawValue),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
        ]
        if let projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectPath.isEmpty {
            items.append(URLQueryItem(name: "projectPath", value: projectPath))
        }
        if let fromMilliseconds {
            items.append(URLQueryItem(name: "from", value: String(fromMilliseconds)))
        }
        if refresh {
            items.append(URLQueryItem(name: "refresh", value: "1"))
        }
        return items
    }
}

public enum FerminRelayPromptImproverVariant: String, Codable, CaseIterable, Sendable {
    case standard
    case motivational
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value.lowercased()) ?? .unknown
    }
}

public struct FerminRelayPromptImproverPreference: Codable, Hashable, Sendable {
    public let version: Int
    public let variant: FerminRelayPromptImproverVariant
    public let updatedAt: String?

    public init(
        version: Int = 1,
        variant: FerminRelayPromptImproverVariant = .standard,
        updatedAt: String? = nil
    ) {
        self.version = version
        self.variant = variant
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case version, variant, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = values.relayInt(forKey: .version, default: 1)
        variant = values.relayValue(FerminRelayPromptImproverVariant.self, forKey: .variant)
            ?? .standard
        updatedAt = values.relayStringIfPresent(forKey: .updatedAt)
    }
}

public struct FerminRelayPromptImproverPreferenceEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let preference: FerminRelayPromptImproverPreference
    public let variants: [FerminRelayPromptImproverVariant]

    public init(
        ok: Bool = true,
        preference: FerminRelayPromptImproverPreference,
        variants: [FerminRelayPromptImproverVariant] = []
    ) {
        self.ok = ok
        self.preference = preference
        self.variants = variants
    }

    private enum CodingKeys: String, CodingKey { case ok, preference, variants }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        preference = values.relayValue(
            FerminRelayPromptImproverPreference.self,
            forKey: .preference
        ) ?? FerminRelayPromptImproverPreference()
        variants = values.relayArray(FerminRelayPromptImproverVariant.self, forKey: .variants)
    }
}
