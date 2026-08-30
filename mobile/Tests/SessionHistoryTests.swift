import XCTest
@testable import KyCode

final class SessionHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        id: String = "one",
        name: String = "Red doméstica",
        project: String = "Casa",
        path: String = "/Users/qa/projects/home",
        preview: String = "Configuramos el repetidor del WiFi.",
        state: KycodeSessionHistoryState = .archived,
        updatedAt: Double = 1_800_000_000_000,
        score: Double = 0
    ) -> KycodeSessionHistoryItem {
        KycodeSessionHistoryItem(
            id: id,
            sessionUUID: id,
            projectKey: "project-\(id)",
            projectName: project,
            sessionId: "session-\(id)",
            sessionName: name,
            sessionPath: path,
            createdAt: updatedAt - 1_000,
            updatedAt: updatedAt,
            state: state,
            windowId: state == .active ? "window-\(id)" : nil,
            archivedId: nil,
            score: score,
            preview: preview,
            matchedIn: "Chat",
            canResume: true
        )
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "SessionHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func envelope(searchMs: Double = 4.2) -> KycodeSessionHistoryEnvelope {
        KycodeSessionHistoryEnvelope(
            ok: true,
            items: [item()],
            offset: 0,
            limit: 30,
            total: 1,
            hasMore: false,
            updatedAt: 42,
            searchMs: searchMs,
            indexBuildMs: 8.1,
            indexedSessions: 510,
            indexedTerms: 12_409
        )
    }

    func testNormalizationIsCaseInsensitive() {
        XCTAssertEqual(KycodeSessionHistorySearch.normalize("WIFI"), "wifi")
    }

    func testNormalizationFoldsSpanishAccentsAndEnye() {
        XCTAssertEqual(KycodeSessionHistorySearch.normalize("CONEXIÓN AÑO"), "conexion ano")
    }

    func testPrefixSearchFindsWordInsidePreview() {
        var query = KycodeSessionHistoryQuery()
        query.text = "repet"
        XCTAssertEqual(KycodeSessionHistorySearch.cachedResults([item()], query: query).map(\.id), ["one"])
    }

    func testEveryQueryTokenMustMatch() {
        var query = KycodeSessionHistoryQuery()
        query.text = "repet wifi"
        XCTAssertEqual(KycodeSessionHistorySearch.cachedResults([item()], query: query).count, 1)
        query.text = "repet fibra"
        XCTAssertTrue(KycodeSessionHistorySearch.cachedResults([item()], query: query).isEmpty)
    }

    func testEmptySearchReturnsEveryCachedSession() {
        let results = KycodeSessionHistorySearch.cachedResults(
            [item(id: "one"), item(id: "two")],
            query: KycodeSessionHistoryQuery()
        )
        XCTAssertEqual(results.count, 2)
    }

    func testActiveFilterOnlyReturnsOpenSessions() {
        var query = KycodeSessionHistoryQuery()
        query.state = .active
        let results = KycodeSessionHistorySearch.cachedResults(
            [item(id: "open", state: .active), item(id: "old")],
            query: query
        )
        XCTAssertEqual(results.map(\.id), ["open"])
    }

    func testArchivedFilterOnlyReturnsPreviousSessions() {
        var query = KycodeSessionHistoryQuery()
        query.state = .archived
        let results = KycodeSessionHistorySearch.cachedResults(
            [item(id: "open", state: .active), item(id: "old")],
            query: query
        )
        XCTAssertEqual(results.map(\.id), ["old"])
    }

    func testProjectFilterComposesWithTextSearch() {
        var query = KycodeSessionHistoryQuery()
        query.text = "repet"
        query.projectPath = "/Users/qa/projects/home"
        let results = KycodeSessionHistorySearch.cachedResults(
            [
                item(id: "home"),
                item(id: "work", path: "/Users/qa/projects/work"),
            ],
            query: query
        )
        XCTAssertEqual(results.map(\.id), ["home"])
    }

    func testRecentSortUsesUpdatedTimestamp() {
        let results = KycodeSessionHistorySearch.cachedResults(
            [
                item(id: "old", updatedAt: 100),
                item(id: "new", updatedAt: 200),
            ],
            query: KycodeSessionHistoryQuery()
        )
        XCTAssertEqual(results.map(\.id), ["new", "old"])
    }

    func testNameSortUsesLocalizedCaseInsensitiveOrder() {
        var query = KycodeSessionHistoryQuery()
        query.sort = .name
        let results = KycodeSessionHistorySearch.cachedResults(
            [item(id: "z", name: "Zeta"), item(id: "a", name: "alpha")],
            query: query
        )
        XCTAssertEqual(results.map(\.id), ["a", "z"])
    }

    func testRelevanceSortUsesServerScoreThenRecency() {
        var query = KycodeSessionHistoryQuery()
        query.text = "wifi"
        query.sort = .relevance
        let results = KycodeSessionHistorySearch.cachedResults(
            [
                item(id: "low", preview: "wifi", updatedAt: 300, score: 10),
                item(id: "high", preview: "wifi", updatedAt: 100, score: 20),
            ],
            query: query
        )
        XCTAssertEqual(results.map(\.id), ["high", "low"])
    }

    func testNonEmptyQueryDefaultsToRelevance() {
        var query = KycodeSessionHistoryQuery()
        query.text = "wifi"
        query.sort = .recent
        XCTAssertEqual(query.effectiveSort, .relevance)
    }

    func testQueryItemsClampPaginationAndEncodeFilters() {
        var query = KycodeSessionHistoryQuery()
        query.text = "wifi casa"
        query.state = .archived
        query.limit = 500
        query.offset = -4
        query.projectPath = "/Users/qa/projects/home"
        let dictionary = Dictionary(uniqueKeysWithValues: query.queryItems(referenceDate: now).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(dictionary["query"], "wifi casa")
        XCTAssertEqual(dictionary["state"], "archived")
        XCTAssertEqual(dictionary["limit"], "100")
        XCTAssertEqual(dictionary["offset"], "0")
        XCTAssertEqual(dictionary["projectPath"], "/Users/qa/projects/home")
    }

    func testDateRangeAddsMillisecondsLowerBound() {
        var query = KycodeSessionHistoryQuery()
        query.dateRange = .week
        let from = query.queryItems(referenceDate: now).first(where: { $0.name == "from" })?.value
        XCTAssertEqual(from, "1799395200000")
    }

    func testCacheRoundTripPersistsLightweightResults() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        KycodeSessionHistoryCache.save(
            profileId: "puky",
            incoming: [item()],
            total: 1,
            libraryUpdatedAt: 42,
            defaults: defaults,
            now: now
        )
        let snapshot = KycodeSessionHistoryCache.load(profileId: "puky", defaults: defaults)
        XCTAssertEqual(snapshot?.items.map(\.id), ["one"])
        XCTAssertEqual(snapshot?.total, 1)
        XCTAssertEqual(snapshot?.libraryUpdatedAt, 42)
    }

    func testCacheIsScopedByDesktopProfile() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        KycodeSessionHistoryCache.save(
            profileId: "puky",
            incoming: [item()],
            total: 1,
            libraryUpdatedAt: 1,
            defaults: defaults
        )
        XCTAssertNil(KycodeSessionHistoryCache.load(profileId: "this-mac", defaults: defaults))
    }

    func testCacheFreshnessExpiresAfterFiveMinutes() {
        let snapshot = KycodeSessionHistoryCacheSnapshot(
            schemaVersion: 1,
            profileId: "puky",
            cachedAt: now,
            items: [],
            total: 0,
            libraryUpdatedAt: 1
        )
        XCTAssertTrue(snapshot.isFresh(at: now.addingTimeInterval(299)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(301)))
    }

    func testRecentSearchesDeduplicateAndKeepFive() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for query in ["uno", "dos", "tres", "cuatro", "cinco", "seis", "DOS"] {
            KycodeSessionHistoryRecents.record(query, profileId: "puky", defaults: defaults)
        }
        let recent = KycodeSessionHistoryRecents.load(profileId: "puky", defaults: defaults)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first, "DOS")
        XCTAssertEqual(recent.filter { $0.lowercased() == "dos" }.count, 1)
    }

    func testHistoryEnvelopeParsesBackendContract() throws {
        let data = """
        {
          "ok": true,
          "items": [{
            "id": "one",
            "sessionUUID": "one",
            "projectKey": "p",
            "projectName": "Casa",
            "sessionId": "s",
            "sessionName": "WiFi",
            "sessionPath": "/tmp",
            "createdAt": 1,
            "updatedAt": 2,
            "state": "archived",
            "windowId": null,
            "archivedId": null,
            "score": 96,
            "preview": "repetidor",
            "matchedIn": "Chat",
            "canResume": true
          }],
          "offset": 0,
          "limit": 30,
          "total": 1,
          "hasMore": false,
          "updatedAt": 2,
          "searchMs": 4.2,
          "indexBuildMs": 8.1,
          "indexedSessions": 510,
          "indexedTerms": 12409
        }
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(KycodeSessionHistoryEnvelope.self, from: data)
        XCTAssertEqual(envelope.items.first?.preview, "repetidor")
        XCTAssertEqual(envelope.indexedSessions, 510)
        XCTAssertEqual(envelope.searchMs, 4.2)
    }

    func testCombinedHistoryKeepsSourceRoutingAndPaginatesGlobally() {
        let puky = KycodeSessionHistoryEnvelope(
            ok: true,
            items: [
                item(id: "shared", updatedAt: 400),
                item(id: "puky-old", updatedAt: 100),
            ],
            offset: 0,
            limit: 30,
            total: 2,
            hasMore: false,
            updatedAt: 400,
            searchMs: 1,
            indexBuildMs: 2,
            indexedSessions: 2,
            indexedTerms: 10
        )
        let personal = KycodeSessionHistoryEnvelope(
            ok: true,
            items: [
                item(id: "shared", updatedAt: 300),
                item(id: "personal-old", updatedAt: 200),
            ],
            offset: 0,
            limit: 30,
            total: 2,
            hasMore: false,
            updatedAt: 300,
            searchMs: 3,
            indexBuildMs: 4,
            indexedSessions: 2,
            indexedTerms: 20
        )
        var query = KycodeSessionHistoryQuery()
        query.offset = 1
        query.limit = 2

        let combined = KycodeCombinedSessionHistoryPolicy.combine(
            [
                KycodeCombinedSessionHistorySource(
                    profileId: "puky",
                    profileName: "Puky",
                    envelope: puky
                ),
                KycodeCombinedSessionHistorySource(
                    profileId: "personal",
                    profileName: "Mac personal",
                    envelope: personal
                ),
            ],
            query: query
        )

        XCTAssertEqual(combined.total, 4)
        XCTAssertEqual(combined.items.map(\.id), [
            "personal::history::shared",
            "personal::history::personal-old",
        ])
        XCTAssertEqual(combined.items.first?.sourceHistoryId, "shared")
        XCTAssertEqual(combined.items.first?.sourceProfileName, "Mac personal")
        XCTAssertEqual(combined.items.first?.windowId, nil)
        XCTAssertTrue(combined.hasMore)
        XCTAssertEqual(combined.searchMs, 4)
        XCTAssertEqual(combined.indexedSessions, 4)
    }

    func testCombinedActiveHistoryRoutesWindowBackToItsDesktop() {
        let active = item(id: "active", state: .active)
        let routed = active.routed(profileId: "puky", profileName: "Puky")

        XCTAssertEqual(routed.id, "puky::history::active")
        XCTAssertEqual(routed.sourceHistoryId, "active")
        XCTAssertEqual(routed.windowId, "puky::window-active")
    }

    func testCachedSearchAcrossMaximumCorpusStaysBelowInteractionBudget() {
        let corpus = (0..<KycodeSessionHistoryCache.maximumItems).map { index in
            item(
                id: "\(index)",
                name: index == 137 ? "Repetidor principal" : "Sesión \(index)",
                preview: index == 137 ? "Cobertura WiFi en casa" : "Conversación \(index)"
            )
        }
        var query = KycodeSessionHistoryQuery()
        query.text = "repet wifi"

        let startedAt = CFAbsoluteTimeGetCurrent()
        let results = KycodeSessionHistorySearch.cachedResults(corpus, query: query)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertEqual(results.map(\.id), ["137"])
        print(String(format: "KYCODE_HISTORY_CACHE_SEARCH_MS=%.3f", elapsed * 1_000))
        XCTAssertLessThan(elapsed, 0.1, "Local search must stay below Apple's 100 ms interaction budget")
    }

    func testETagPersistsPerProfileAndRepresentationAndIsAppliedToRequest() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        KycodeSessionHistoryETagCache.save(
            profileId: "puky",
            representationKey: "?query=wifi",
            etag: "W/\"wifi\"",
            defaults: defaults
        )
        XCTAssertEqual(
            KycodeSessionHistoryETagCache.load(
                profileId: "puky",
                representationKey: "?query=wifi",
                defaults: defaults
            ),
            "W/\"wifi\""
        )
        XCTAssertNil(KycodeSessionHistoryETagCache.load(
            profileId: "puky",
            representationKey: "?query=otra",
            defaults: defaults
        ))
        XCTAssertNil(KycodeSessionHistoryETagCache.load(
            profileId: "otra-mac",
            representationKey: "?query=wifi",
            defaults: defaults
        ))

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/history")))
        KycodeSessionHistoryHTTPResponse.applyValidator(
            to: &request,
            profileId: "puky",
            representationKey: "?query=wifi",
            defaults: defaults
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "W/\"wifi\"")
    }

    func test200StoresResponseAnd304ReturnsTheSameRepresentation() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = envelope()
        let data = try JSONEncoder().encode(expected)
        let first = try KycodeSessionHistoryHTTPResponse.resolve(
            statusCode: 200,
            data: data,
            etag: "W/\"history-1\"",
            profileId: "puky",
            representationKey: "?query=repetidor",
            defaults: defaults
        )
        let revalidated = try KycodeSessionHistoryHTTPResponse.resolve(
            statusCode: 304,
            data: Data(),
            etag: nil,
            profileId: "puky",
            representationKey: "?query=repetidor",
            defaults: defaults
        )
        XCTAssertEqual(first.items.map(\.id), ["one"])
        XCTAssertEqual(revalidated.items.map(\.id), ["one"])
        XCTAssertEqual(
            KycodeSessionHistoryETagCache.load(
                profileId: "puky",
                representationKey: "?query=repetidor",
                defaults: defaults
            ),
            "W/\"history-1\""
        )
    }

    func test304WithoutMatchingCachedRepresentationThrowsDescriptiveError() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try KycodeSessionHistoryHTTPResponse.resolve(
            statusCode: 304,
            data: Data(),
            etag: nil,
            profileId: "puky",
            representationKey: "?query=missing",
            defaults: defaults
        )) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 304)
            XCTAssertTrue(nsError.localizedDescription.contains("falta la copia local"))
        }
    }

    func testRefreshFallbackOnlyTrustsARecentlyActiveSSEStream() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(KycodeSessionRefreshPolicy.hasRecentVerifiedStreamActivity(
            isStreaming: true,
            lastStreamActivityAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(KycodeSessionRefreshPolicy.hasRecentVerifiedStreamActivity(
            isStreaming: true,
            lastStreamActivityAt: now.addingTimeInterval(-24),
            now: now
        ))
        XCTAssertFalse(KycodeSessionRefreshPolicy.hasRecentVerifiedStreamActivity(
            isStreaming: false,
            lastStreamActivityAt: now,
            now: now
        ))
        XCTAssertFalse(KycodeSessionRefreshPolicy.shouldPoll(
            isStreaming: true,
            isReconnecting: false,
            lastStreamActivityAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(KycodeSessionRefreshPolicy.shouldPoll(
            isStreaming: false,
            isReconnecting: true,
            lastStreamActivityAt: nil,
            now: now
        ))
        XCTAssertTrue(KycodeSessionRefreshPolicy.shouldPoll(
            isStreaming: false,
            isReconnecting: false,
            lastStreamActivityAt: nil,
            now: now
        ))
        XCTAssertTrue(KycodeSessionRefreshPolicy.shouldPoll(
            isStreaming: true,
            isReconnecting: false,
            lastStreamActivityAt: now.addingTimeInterval(-25),
            now: now
        ))
        XCTAssertEqual(KycodeSessionRefreshPolicy.fallbackIntervalSeconds, 3)
    }

    func testSilentStreamRestartsAfterHeartbeatDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(KycodeSessionRefreshPolicy.shouldRestartStream(
            isStreaming: true,
            isReconnecting: false,
            lastStreamActivityAt: now.addingTimeInterval(-23),
            now: now
        ))
        XCTAssertTrue(KycodeSessionRefreshPolicy.shouldRestartStream(
            isStreaming: true,
            isReconnecting: false,
            lastStreamActivityAt: now.addingTimeInterval(-24),
            now: now
        ))
    }

    func testWorkingDetailSafetyNetIsBoundedByLastLiveUpdate() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(KycodeSessionRefreshPolicy.shouldRefreshWorkingDetail(
            isWorking: false,
            lastRefreshAt: nil,
            now: now
        ))
        XCTAssertFalse(KycodeSessionRefreshPolicy.shouldRefreshWorkingDetail(
            isWorking: true,
            lastRefreshAt: now.addingTimeInterval(-7),
            now: now
        ))
        XCTAssertTrue(KycodeSessionRefreshPolicy.shouldRefreshWorkingDetail(
            isWorking: true,
            lastRefreshAt: now.addingTimeInterval(-8),
            now: now
        ))
    }
}
