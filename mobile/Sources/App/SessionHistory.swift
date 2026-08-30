import Foundation

enum KycodeSessionHistoryState: String, Codable, CaseIterable, Sendable {
    case all
    case active
    case archived

    var title: String {
        switch self {
        case .all: return "Todas"
        case .active: return "Abiertas"
        case .archived: return "Anteriores"
        }
    }
}

enum KycodeSessionHistorySort: String, Codable, CaseIterable, Sendable {
    case relevance
    case recent
    case name

    var title: String {
        switch self {
        case .relevance: return "Relevancia"
        case .recent: return "Recientes"
        case .name: return "Nombre"
        }
    }
}

enum KycodeSessionHistoryDateRange: String, CaseIterable, Sendable {
    case any
    case week
    case month
    case year

    var title: String {
        switch self {
        case .any: return "Cualquier fecha"
        case .week: return "7 días"
        case .month: return "30 días"
        case .year: return "1 año"
        }
    }

    func lowerBound(reference: Date = Date()) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        switch self {
        case .any:
            return nil
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: reference)
        case .month:
            return calendar.date(byAdding: .day, value: -30, to: reference)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: reference)
        }
    }
}

struct KycodeSessionHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sessionUUID: String?
    let projectKey: String
    let projectName: String
    let sessionId: String
    let sessionName: String
    let sessionPath: String
    let createdAt: Double
    let updatedAt: Double
    let state: KycodeSessionHistoryState
    let windowId: String?
    let archivedId: String?
    let score: Double
    let preview: String
    let matchedIn: String?
    let canResume: Bool
    var sourceProfileId: String? = nil
    var sourceProfileName: String? = nil
    var sourceHistoryId: String? = nil

    var updatedDate: Date {
        Date(timeIntervalSince1970: updatedAt / 1_000)
    }

    func routed(profileId: String, profileName: String) -> KycodeSessionHistoryItem {
        let remoteHistoryId = sourceHistoryId ?? id
        return KycodeSessionHistoryItem(
            id: KycodeCombinedSessionHistoryPolicy.presentedItemId(
                profileId: profileId,
                remoteHistoryId: remoteHistoryId
            ),
            sessionUUID: sessionUUID,
            projectKey: projectKey,
            projectName: projectName,
            sessionId: sessionId,
            sessionName: sessionName,
            sessionPath: sessionPath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            state: state,
            windowId: windowId.map {
                KycodeCombinedSessionPolicy.presentedWindowId(
                    profileId: profileId,
                    remoteWindowId: $0
                )
            },
            archivedId: archivedId,
            score: score,
            preview: preview,
            matchedIn: matchedIn,
            canResume: canResume,
            sourceProfileId: profileId,
            sourceProfileName: profileName,
            sourceHistoryId: remoteHistoryId
        )
    }
}

struct KycodeSessionHistoryEnvelope: Codable, Sendable {
    let ok: Bool
    let items: [KycodeSessionHistoryItem]
    let offset: Int
    let limit: Int
    let total: Int
    let hasMore: Bool
    let updatedAt: Double
    let searchMs: Double
    let indexBuildMs: Double
    let indexedSessions: Int
    let indexedTerms: Int
}

struct KycodeCombinedSessionHistorySource: Sendable {
    let profileId: String
    let profileName: String
    let envelope: KycodeSessionHistoryEnvelope
}

enum KycodeCombinedSessionHistoryPolicy {
    static func presentedItemId(profileId: String, remoteHistoryId: String) -> String {
        "\(profileId)::history::\(remoteHistoryId)"
    }

    static func combine(
        _ sources: [KycodeCombinedSessionHistorySource],
        query: KycodeSessionHistoryQuery
    ) -> KycodeSessionHistoryEnvelope {
        var routedById: [String: KycodeSessionHistoryItem] = [:]
        for source in sources {
            for item in source.envelope.items {
                let routed = item.routed(
                    profileId: source.profileId,
                    profileName: source.profileName
                )
                if let current = routedById[routed.id], current.updatedAt >= routed.updatedAt {
                    continue
                }
                routedById[routed.id] = routed
            }
        }

        let sorted = KycodeSessionHistorySearch.cachedResults(
            Array(routedById.values),
            query: query
        )
        let offset = max(0, query.offset)
        let limit = min(100, max(1, query.limit))
        let page = offset < sorted.count
            ? Array(sorted.dropFirst(offset).prefix(limit))
            : []
        let total = sources.reduce(0) { $0 + max(0, $1.envelope.total) }

        return KycodeSessionHistoryEnvelope(
            ok: true,
            items: page,
            offset: offset,
            limit: limit,
            total: total,
            hasMore: offset + page.count < total,
            updatedAt: sources.map(\.envelope.updatedAt).max() ?? 0,
            searchMs: sources.reduce(0) { $0 + $1.envelope.searchMs },
            indexBuildMs: sources.reduce(0) { $0 + $1.envelope.indexBuildMs },
            indexedSessions: sources.reduce(0) { $0 + $1.envelope.indexedSessions },
            indexedTerms: sources.reduce(0) { $0 + $1.envelope.indexedTerms }
        )
    }
}

private func kycodeSessionHistoryRepresentationHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

enum KycodeSessionHistoryETagCache {
    private struct Store: Codable {
        var order: [String] = []
        var values: [String: String] = [:]
    }

    static let keyPrefix = "kycode.session-history.etag."
    static let maximumRepresentations = 24

    static func load(
        profileId: String,
        representationKey: String = "",
        defaults: UserDefaults = .standard
    ) -> String? {
        loadStore(profileId: profileId, defaults: defaults)?
            .values[kycodeSessionHistoryRepresentationHash(representationKey)]
    }

    static func save(
        profileId: String,
        representationKey: String = "",
        etag: String,
        defaults: UserDefaults = .standard
    ) {
        let trimmed = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let representation = kycodeSessionHistoryRepresentationHash(representationKey)
        var store = loadStore(profileId: profileId, defaults: defaults) ?? Store()
        store.order.removeAll { $0 == representation }
        store.order.append(representation)
        store.values[representation] = trimmed
        while store.order.count > maximumRepresentations, let oldest = store.order.first {
            store.order.removeFirst()
            store.values.removeValue(forKey: oldest)
        }
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: keyPrefix + profileId)
    }

    static func clear(profileId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + profileId)
    }

    private static func loadStore(profileId: String, defaults: UserDefaults) -> Store? {
        guard let data = defaults.data(forKey: keyPrefix + profileId),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return nil
        }
        return store
    }
}

enum KycodeSessionHistoryResponseCache {
    private struct Store: Codable {
        var order: [String] = []
        var values: [String: KycodeSessionHistoryEnvelope] = [:]
    }

    static let keyPrefix = "kycode.session-history.response."
    static let maximumRepresentations = 24
    static let maximumBytes = 1_024 * 1_024

    static func load(
        profileId: String,
        representationKey: String = "",
        defaults: UserDefaults = .standard
    ) -> KycodeSessionHistoryEnvelope? {
        loadStore(profileId: profileId, defaults: defaults)?
            .values[kycodeSessionHistoryRepresentationHash(representationKey)]
    }

    static func save(
        profileId: String,
        representationKey: String = "",
        envelope: KycodeSessionHistoryEnvelope,
        defaults: UserDefaults = .standard
    ) {
        let representation = kycodeSessionHistoryRepresentationHash(representationKey)
        var store = loadStore(profileId: profileId, defaults: defaults) ?? Store()
        store.order.removeAll { $0 == representation }
        store.order.append(representation)
        store.values[representation] = envelope
        while !store.order.isEmpty {
            guard let data = try? JSONEncoder().encode(store) else { return }
            if store.order.count <= maximumRepresentations, data.count <= maximumBytes {
                defaults.set(data, forKey: keyPrefix + profileId)
                return
            }
            let oldest = store.order.removeFirst()
            store.values.removeValue(forKey: oldest)
        }
        defaults.removeObject(forKey: keyPrefix + profileId)
    }

    static func clear(profileId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + profileId)
    }

    private static func loadStore(profileId: String, defaults: UserDefaults) -> Store? {
        guard let data = defaults.data(forKey: keyPrefix + profileId),
              data.count <= maximumBytes,
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.order.count <= maximumRepresentations else {
            return nil
        }
        return store
    }
}

enum KycodeSessionHistoryHTTPResponse {
    static func applyValidator(
        to request: inout URLRequest,
        profileId: String,
        representationKey: String,
        defaults: UserDefaults = .standard
    ) {
        guard let etag = KycodeSessionHistoryETagCache.load(
            profileId: profileId,
            representationKey: representationKey,
            defaults: defaults
        ) else { return }
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    static func resolve(
        statusCode: Int,
        data: Data,
        etag: String?,
        profileId: String,
        representationKey: String,
        defaults: UserDefaults = .standard
    ) throws -> KycodeSessionHistoryEnvelope {
        if statusCode == 304 {
            guard let cached = KycodeSessionHistoryResponseCache.load(
                profileId: profileId,
                representationKey: representationKey,
                defaults: defaults
            ) else {
                throw NSError(
                    domain: "KycodeMobile",
                    code: 304,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "El servidor confirmó que el historial no cambió, pero falta la copia local. Reintentá."
                    ]
                )
            }
            return cached
        }
        guard (200..<300).contains(statusCode) else {
            throw NSError(
                domain: "KycodeMobile",
                code: statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Error del servidor."
                ]
            )
        }
        let envelope = try JSONDecoder().decode(KycodeSessionHistoryEnvelope.self, from: data)
        KycodeSessionHistoryResponseCache.save(
            profileId: profileId,
            representationKey: representationKey,
            envelope: envelope,
            defaults: defaults
        )
        if let etag {
            KycodeSessionHistoryETagCache.save(
                profileId: profileId,
                representationKey: representationKey,
                etag: etag,
                defaults: defaults
            )
        }
        return envelope
    }
}

struct KycodeSessionHistoryResumeEnvelope: Codable, Sendable {
    let ok: Bool
    let queued: Bool
    let commandId: String?
    let queuedAt: Double?
    let state: String
    let windowId: String?
    let sessionId: String
    let projectPath: String?
}

struct KycodeSessionHistoryQuery: Equatable, Sendable {
    var text = ""
    var state: KycodeSessionHistoryState = .all
    var sort: KycodeSessionHistorySort = .recent
    var dateRange: KycodeSessionHistoryDateRange = .any
    var projectPath: String?
    var offset = 0
    var limit = 30
    var refresh = false

    var effectiveSort: KycodeSessionHistorySort {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sort == .recent {
            return .relevance
        }
        return sort
    }

    func queryItems(referenceDate: Date = Date()) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "query", value: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "sort", value: effectiveSort.rawValue),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
        ]
        if let projectPath, !projectPath.isEmpty {
            items.append(URLQueryItem(name: "projectPath", value: projectPath))
        }
        if let from = dateRange.lowerBound(reference: referenceDate) {
            items.append(URLQueryItem(name: "from", value: String(Int(from.timeIntervalSince1970 * 1_000))))
        }
        if refresh {
            items.append(URLQueryItem(name: "refresh", value: "1"))
        }
        return items
    }
}

enum KycodeSessionHistorySearch {
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_AR"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func cachedResults(
        _ items: [KycodeSessionHistoryItem],
        query: KycodeSessionHistoryQuery
    ) -> [KycodeSessionHistoryItem] {
        let tokens = normalize(query.text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let from = query.dateRange.lowerBound()?.timeIntervalSince1970
        let filtered = items.filter { item in
            if query.state != .all, item.state != query.state { return false }
            if let projectPath = query.projectPath, !projectPath.isEmpty, item.sessionPath != projectPath {
                return false
            }
            if let from, item.updatedDate.timeIntervalSince1970 < from { return false }
            guard !tokens.isEmpty else { return true }
            let document = normalize([
                item.sessionName,
                item.projectName,
                item.sessionPath,
                item.preview,
                item.matchedIn ?? "",
            ].joined(separator: " "))
            return tokens.allSatisfy { token in
                document.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains(where: { $0.hasPrefix(token) })
            }
        }
        return filtered.sorted { left, right in
            switch query.effectiveSort {
            case .name:
                return left.sessionName.localizedCaseInsensitiveCompare(right.sessionName) == .orderedAscending
            case .relevance:
                if left.score != right.score { return left.score > right.score }
                return left.updatedAt > right.updatedAt
            case .recent:
                return left.updatedAt > right.updatedAt
            }
        }
    }
}

struct KycodeSessionHistoryCacheSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let profileId: String
    let cachedAt: Date
    let items: [KycodeSessionHistoryItem]
    let total: Int
    let libraryUpdatedAt: Double

    func isFresh(at date: Date = Date(), ttl: TimeInterval = 5 * 60) -> Bool {
        date.timeIntervalSince(cachedAt) <= ttl
    }
}

enum KycodeSessionHistoryCache {
    static let schemaVersion = 1
    static let maximumItems = 200
    static let maximumBytes = 1_024 * 1_024
    static let keyPrefix = "kycode.mobile.sessionHistory.v1."

    static func load(profileId: String, defaults: UserDefaults = .standard) -> KycodeSessionHistoryCacheSnapshot? {
        guard let data = defaults.data(forKey: keyPrefix + profileId),
              data.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(KycodeSessionHistoryCacheSnapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion,
              snapshot.profileId == profileId,
              snapshot.items.count <= maximumItems else {
            return nil
        }
        return snapshot
    }

    static func save(
        profileId: String,
        incoming: [KycodeSessionHistoryItem],
        total: Int,
        libraryUpdatedAt: Double,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        let existing = load(profileId: profileId, defaults: defaults)?.items ?? []
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for item in incoming {
            byId[item.id] = item
        }
        var items = byId.values.sorted { $0.updatedAt > $1.updatedAt }
        if items.count > maximumItems {
            items = Array(items.prefix(maximumItems))
        }
        while !items.isEmpty {
            let snapshot = KycodeSessionHistoryCacheSnapshot(
                schemaVersion: schemaVersion,
                profileId: profileId,
                cachedAt: now,
                items: items,
                total: total,
                libraryUpdatedAt: libraryUpdatedAt
            )
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            if data.count <= maximumBytes {
                defaults.set(data, forKey: keyPrefix + profileId)
                return
            }
            items.removeLast(max(1, items.count / 10))
        }
        defaults.removeObject(forKey: keyPrefix + profileId)
    }
}

enum KycodeSessionHistoryRecents {
    static let keyPrefix = "kycode.mobile.sessionHistory.recentSearches."
    static let limit = 5

    static func load(profileId: String, defaults: UserDefaults = .standard) -> [String] {
        Array((defaults.stringArray(forKey: keyPrefix + profileId) ?? []).prefix(limit))
    }

    @discardableResult
    static func record(
        _ query: String,
        profileId: String,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load(profileId: profileId, defaults: defaults) }
        let normalized = KycodeSessionHistorySearch.normalize(trimmed)
        let current = load(profileId: profileId, defaults: defaults)
        let next = [trimmed] + current.filter {
            KycodeSessionHistorySearch.normalize($0) != normalized
        }
        let capped = Array(next.prefix(limit))
        defaults.set(capped, forKey: keyPrefix + profileId)
        return capped
    }

    static func clear(profileId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + profileId)
    }
}
