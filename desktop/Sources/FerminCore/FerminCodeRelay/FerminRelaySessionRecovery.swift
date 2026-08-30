import Foundation

public struct FerminRelayRecoverableSessionItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let projectName: String
    public let projectPath: String?
    public let sessionName: String
    public let createdAt: Double
    public let updatedAt: Double
    public let archived: Bool
    public let score: Double
    public let preview: String
    public let matchedIn: String?
    public let canRecover: Bool

    public init(
        id: String,
        projectName: String = "",
        projectPath: String? = nil,
        sessionName: String = "",
        createdAt: Double = 0,
        updatedAt: Double = 0,
        archived: Bool = false,
        score: Double = 0,
        preview: String = "",
        matchedIn: String? = nil,
        canRecover: Bool = false
    ) {
        self.id = id
        self.projectName = projectName
        self.projectPath = projectPath
        self.sessionName = sessionName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.score = score
        self.preview = preview
        self.matchedIn = matchedIn
        self.canRecover = canRecover
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectName, projectPath, sessionName, createdAt, updatedAt
        case archived, score, preview, matchedIn, canRecover
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.relayString(forKey: .id)
        projectName = values.relayString(forKey: .projectName)
        projectPath = values.relayStringIfPresent(forKey: .projectPath)
        sessionName = values.relayString(forKey: .sessionName)
        createdAt = values.relayDouble(forKey: .createdAt)
        updatedAt = values.relayDouble(forKey: .updatedAt)
        archived = values.relayBool(forKey: .archived)
        score = values.relayDouble(forKey: .score)
        preview = values.relayString(forKey: .preview)
        matchedIn = values.relayStringIfPresent(forKey: .matchedIn)
        canRecover = values.relayBool(forKey: .canRecover)
    }
}

public struct FerminRelaySessionRecoveryEnvelope: Codable, Hashable, Sendable {
    public let ok: Bool
    public let items: [FerminRelayRecoverableSessionItem]
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let hasMore: Bool
    public let updatedAt: Double

    public init(
        ok: Bool = true,
        items: [FerminRelayRecoverableSessionItem],
        offset: Int = 0,
        limit: Int = 0,
        total: Int = 0,
        hasMore: Bool = false,
        updatedAt: Double = 0
    ) {
        self.ok = ok
        self.items = items
        self.offset = offset
        self.limit = limit
        self.total = total
        self.hasMore = hasMore
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case ok, items, offset, limit, total, hasMore, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = values.relayBool(forKey: .ok, default: true)
        items = values.relayArray(FerminRelayRecoverableSessionItem.self, forKey: .items)
        offset = values.relayInt(forKey: .offset)
        limit = values.relayInt(forKey: .limit)
        total = values.relayInt(forKey: .total, default: items.count)
        hasMore = values.relayBool(forKey: .hasMore)
        updatedAt = values.relayDouble(forKey: .updatedAt)
    }
}

public struct FerminRelaySessionRecoveryQuery: Equatable, Sendable {
    public var text: String
    public var offset: Int
    public var limit: Int

    public init(text: String = "", offset: Int = 0, limit: Int = 30) {
        self.text = text
        self.offset = offset
        self.limit = limit
    }

    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(
                name: "query",
                value: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
        ]
    }
}

public typealias FerminRelayRecoverSessionEnvelope = FerminRelayHistoryResumeEnvelope
