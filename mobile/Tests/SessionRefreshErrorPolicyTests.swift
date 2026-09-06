import Foundation
import XCTest
@testable import KyCode

private final class SessionRefreshMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class KycodeSessionPinningPolicyTests: XCTestCase {
    @MainActor
    func testPinnedMutationStaysOptimisticUntilCompletionAndRollsBackTerminalFailures() async throws {
        for terminalState in [KycodeDurableCommandState.completed, .failed, .unknown] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SessionRefreshMockURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let store = KycodeConnectionStore(urlSession: session, initialProfileIdOverride: "puky")
            defer { store.disconnect() }
            store.baseURLInput = "https://mock.kycode.test"
            store.authTokenInput = "test-token"
            var remotePinned = true
            var puts = 0
            SessionRefreshMockURLProtocol.handler = { request in
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
                if request.httpMethod == "PUT" {
                    XCTAssertEqual(url.path, "/api/mobile/sessions/pin-window/pinned")
                    let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map { stream in
                        stream.open()
                        defer { stream.close() }
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        return Data(bytes.prefix(max(0, count)))
                    })
                    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    XCTAssertEqual(payload["pinned"] as? Bool, false)
                    XCTAssertNotNil(UUID(uuidString: payload["idempotencyKey"] as? String ?? ""))
                    puts += 1
                    return (response, Data(#"{"ok":true,"windowId":"pin-window","commandId":"pin-command","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}"#.utf8))
                }
                let item: [String: Any] = [
                    "windowId": "pin-window", "sessionId": "pin-window", "engine": "codex",
                    "projectKey": "qa", "displayName": "Pin QA", "sidecarMode": "relay",
                    "activityStatus": "ready", "messageCount": 0, "updatedAt": 1,
                    "canSend": true, "isPinned": remotePinned
                ]
                let envelope: [String: Any] = url.path.hasSuffix("/pin-window")
                    ? ["ok": true, "item": item]
                    : ["ok": true, "items": [item]]
                return (response, try JSONSerialization.data(withJSONObject: envelope))
            }
            await store.refreshSessionsNow()
            XCTAssertEqual(store.sessions.first?.isPinned, true)
            let accepted = await store.setSessionPinned(windowId: "pin-window", pinned: false)
            XCTAssertTrue(accepted)
            XCTAssertTrue(store.isPinningSession("pin-window"))
            XCTAssertEqual(store.sessions.first?.isPinned, false)
            let duplicate = await store.setSessionPinned(windowId: "pin-window", pinned: true)
            XCTAssertFalse(duplicate)
            XCTAssertEqual(puts, 1)
            await store.refreshSessionsNow()
            XCTAssertEqual(store.sessions.first?.isPinned, false, "An old snapshot cannot undo the pending pin.")
            remotePinned = terminalState != .completed
            store.applyDurableCommandStateChanged(KycodeCommandStateChangedEvent(
                commandId: "pin-command", state: terminalState,
                error: terminalState == .completed ? nil : "pin rejected"
            ))
            await store.refreshSessionsNow()
            XCTAssertFalse(store.isPinningSession("pin-window"))
            XCTAssertEqual(store.sessions.first?.isPinned, remotePinned)
            if terminalState != .completed {
                XCTAssertEqual(store.errorMessage, "No se pudo sincronizar el estado fijado de la sesión. pin rejected")
            }
            store.disconnect()
        }
    }

    func testSharedPinsOverrideLegacyLocalPreferencesAndSurviveDetailReconciliation() throws {
        var unpinned = try summary(windowId: "shared-unpinned", displayName: "Unpinned")
        unpinned.isPinned = false
        var pinned = try summary(windowId: "shared-pinned", displayName: "Pinned")
        pinned.isPinned = true
        XCTAssertEqual(KycodeSessionPinningPolicy.pinnedSessions(
            in: [unpinned, pinned], unpinnedWindowIds: [pinned.windowId]
        ).map(\.windowId), [pinned.windowId])
        let encoded = try JSONEncoder().encode(unpinned)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(wire["isPinned"] as? Bool, false, "Match the relay's real snapshot field.")
        XCTAssertNil(wire["pinned"])
        let decoded = try JSONDecoder().decode(KycodeSessionSummary.self, from: encoded)
        XCTAssertEqual(decoded.isPinned, false)
        var older = unpinned
        older.isPinned = true
        older.updatedAt -= 1
        XCTAssertEqual(KycodeSessionDetailReconciliationPolicy.merging(
            current: unpinned, incoming: older
        ).isPinned, false)
    }

    func testSessionsArePinnedByDefaultAndRoundTripUnpinnedStorage() throws {
        let first = try summary(windowId: "session-a", displayName: "A")
        let second = try summary(windowId: "session-b", displayName: "B")

        XCTAssertEqual(
            KycodeSessionPinningPolicy.pinnedSessions(
                in: [first, second],
                unpinnedWindowIds: []
            ).map(\.windowId),
            ["session-a", "session-b"]
        )

        let storage = KycodeSessionPinningPolicy.storageValue(
            for: ["session-b", "session-a"]
        )
        XCTAssertEqual(storage, "session-a\nsession-b")
        XCTAssertEqual(
            KycodeSessionPinningPolicy.identifiers(from: storage),
            ["session-a", "session-b"]
        )
    }

    func testUnpinnedSessionMovesOutOfPrimaryListAndCanReturn() throws {
        let first = try summary(windowId: "session-a", displayName: "A")
        let second = try summary(windowId: "session-b", displayName: "B")
        let sessions = [first, second]
        var unpinned: Set<String> = ["session-b"]

        XCTAssertEqual(
            KycodeSessionPinningPolicy.pinnedSessions(
                in: sessions,
                unpinnedWindowIds: unpinned
            ).map(\.windowId),
            ["session-a"]
        )
        XCTAssertEqual(
            KycodeSessionPinningPolicy.unpinnedSessions(
                in: sessions,
                unpinnedWindowIds: unpinned
            ).map(\.windowId),
            ["session-b"]
        )

        unpinned.remove("session-b")
        XCTAssertEqual(
            KycodeSessionPinningPolicy.pinnedSessions(
                in: sessions,
                unpinnedWindowIds: unpinned
            ).map(\.windowId),
            ["session-a", "session-b"]
        )
    }

    private func summary(windowId: String, displayName: String) throws -> KycodeSessionSummary {
        try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: Data(
                """
                {"windowId":"\(windowId)","sessionId":"\(windowId)","engine":"codex","projectKey":"projects","displayName":"\(displayName)","sidecarMode":"relay","activityStatus":"ready","messageCount":0,"updatedAt":1,"canSend":true}
                """.utf8
            )
        )
    }
}

final class SessionRefreshErrorPolicyTests: XCTestCase {
    override func tearDown() {
        SessionRefreshMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testRuntimeFailureRequiresAnErrorStateAndAConcreteDiagnostic() {
        XCTAssertEqual(
            KycodeRuntimeFailurePresentationPolicy.message(
                activityStatus: "error",
                detail: "  El mensaje llegó, pero Codex bloqueó el hilo.  "
            ),
            "El mensaje llegó, pero Codex bloqueó el hilo."
        )
        XCTAssertNil(
            KycodeRuntimeFailurePresentationPolicy.message(
                activityStatus: "working",
                detail: "No debe interrumpir un turno activo"
            )
        )
        XCTAssertNil(
            KycodeRuntimeFailurePresentationPolicy.message(
                activityStatus: "error",
                detail: "  "
            )
        )
    }

    func testOnlyExpectedMissingWindow404IsClassifiedAsTransient() {
        let missingWindow = NSError(
            domain: "KycodeMobile",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "window not found"]
        )
        let unrelated404 = NSError(
            domain: "KycodeMobile",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "project not found"]
        )
        let serverFailure = NSError(
            domain: "KycodeMobile",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "window not found"]
        )
        let missingSession = NSError(
            domain: "KycodeMobile",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "session not found"]
        )
        let codedMissingSession = NSError(
            domain: "KycodeMobile",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey: "gone",
                KycodeSessionRefreshErrorPolicy.serverErrorCodeUserInfoKey: "SESSION_NOT_FOUND",
            ]
        )

        XCTAssertTrue(KycodeSessionRefreshErrorPolicy.isMissingWindow(missingWindow))
        XCTAssertTrue(KycodeSessionRefreshErrorPolicy.isMissingWindow(missingSession))
        XCTAssertTrue(KycodeSessionRefreshErrorPolicy.isMissingWindow(codedMissingSession))
        XCTAssertFalse(KycodeSessionRefreshErrorPolicy.isMissingWindow(unrelated404))
        XCTAssertFalse(KycodeSessionRefreshErrorPolicy.isMissingWindow(serverFailure))
    }

    func testStreamErrorPayloadKeepsMissingWindowSilentAndParsesDiagnostics() {
        XCTAssertNil(
            KycodeSessionRefreshErrorPolicy.streamDiagnosticMessage(
                from: #"{"ok":false,"error":"window not found","at":123}"#
            )
        )
        XCTAssertNil(KycodeSessionRefreshErrorPolicy.streamDiagnosticMessage(from: "Windows Not Found"))
        XCTAssertEqual(
            KycodeSessionRefreshErrorPolicy.streamDiagnosticMessage(
                from: #"{"ok":false,"error":"workspace unavailable","at":123}"#
            ),
            "workspace unavailable"
        )
    }

    func testDashboardSnapshotPolicySeparatesLoadingCacheFailureContentAndEmpty() {
        let pukyLoading = sourceState(id: "puky", phase: .loading, attempt: 7)
        let personalLoading = sourceState(id: "personal", phase: .loading, attempt: 7)
        let pukySucceeded = sourceState(id: "puky", phase: .succeeded, attempt: 7)
        let personalSucceeded = sourceState(id: "personal", phase: .succeeded, attempt: 7)
        let personalFailed = sourceState(id: "personal", phase: .failed, attempt: 7)

        XCTAssertEqual(
            dashboardState(sourceStates: [], sessionCount: 0),
            .loading,
            "A cold dashboard must not claim that an unqueried source is empty."
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, personalLoading],
                sessionCount: 0,
                isConnected: true
            ),
            .loading,
            "One connected empty source is not authoritative while the other is still loading."
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, sourceState(id: "personal", phase: .idle, attempt: 0)],
                sessionCount: 0,
                isConnected: true
            ),
            .loading,
            "Todo must not call an unqueried source empty merely because the other source connected."
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukyLoading, personalLoading],
                sessionCount: 2,
                isShowingCachedSessions: true,
                isBootstrapping: true
            ),
            .showingCache
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, personalFailed],
                sessionCount: 2,
                isConnected: true
            ),
            .partialSourceFailure
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, personalFailed],
                sessionCount: 0,
                isConnected: true,
                isReconnecting: true,
                canRetry: true,
                hasError: true
            ),
            .failedNoData,
            "A confirmed failure must remain actionable while background reconnect continues."
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, personalSucceeded],
                sessionCount: 0,
                isConnected: true
            ),
            .authoritativeEmpty
        )
        XCTAssertEqual(
            dashboardState(
                sourceStates: [pukySucceeded, personalSucceeded],
                sessionCount: 2,
                isConnected: true
            ),
            .content
        )
    }

    func testAllSourceCommitPolicyRequiresEverySourceInTheSameSuccessfulAttempt() {
        let required = ["puky", "personal"]

        XCTAssertTrue(
            KycodeAllSourceCommitPolicy.shouldCommit(
                requiredProfileIds: required,
                sourceStates: [
                    sourceState(id: "puky", phase: .succeeded, attempt: 19),
                    sourceState(id: "personal", phase: .succeeded, attempt: 19),
                ],
                attemptGeneration: 19
            )
        )
        XCTAssertFalse(
            KycodeAllSourceCommitPolicy.shouldCommit(
                requiredProfileIds: required,
                sourceStates: [
                    sourceState(id: "puky", phase: .succeeded, attempt: 18),
                    sourceState(id: "personal", phase: .succeeded, attempt: 19),
                ],
                attemptGeneration: 19
            ),
            "A late result from an older Todo refresh must never unlock a mixed commit."
        )
        XCTAssertFalse(
            KycodeAllSourceCommitPolicy.shouldCommit(
                requiredProfileIds: required,
                sourceStates: [
                    sourceState(id: "puky", phase: .succeeded, attempt: 19),
                    sourceState(id: "personal", phase: .failed, attempt: 19),
                ],
                attemptGeneration: 19
            )
        )
    }

    func testDashboardEmptyCopyDoesNotCallHiddenSessionsEmpty() {
        XCTAssertEqual(
            KycodeDashboardEmptyCopyPolicy.title(
                minimizedCount: 2,
                showMinimizedSessions: false
            ),
            "Sesiones minimizadas"
        )
        XCTAssertEqual(
            KycodeDashboardEmptyCopyPolicy.title(
                minimizedCount: 0,
                showMinimizedSessions: false
            ),
            "Sin sesiones"
        )
    }

    func testDashboardSearchIndexRevisionTracksExactlyEverySearchableField() throws {
        let baseline = try dashboardSearchSummary()
        let baselineRevision = DashboardSearchIndexRevision(session: baseline)
        let baselineDocument = DashboardSearchDocument(revision: baselineRevision)
        let cases: [(
            source: String,
            expectedMatchLabel: String,
            oldQuery: String,
            newQuery: String,
            session: KycodeSessionSummary
        )] = [
            (
                "collaborationSessionName",
                "nombre",
                "nombre-viejo",
                "nombre-nuevo",
                try dashboardSearchSummary(overrides: ["windowName": "nombre-nuevo"])
            ),
            (
                "collaborationProjectDisplayName",
                "proyecto",
                "proyecto-viejo",
                "proyecto-nuevo",
                try dashboardSearchSummary(overrides: ["collaborationProjectName": "proyecto-nuevo"])
            ),
            (
                "projectName",
                "carpeta",
                "carpeta-vieja",
                "carpeta-nueva",
                try dashboardSearchSummary(overrides: ["projectName": "carpeta-nueva"])
            ),
            (
                "projectPath",
                "ruta",
                "/ruta/vieja",
                "/ruta/nueva",
                try dashboardSearchSummary(overrides: ["projectPath": "/ruta/nueva"])
            ),
            (
                "lastMessagePreview",
                "mensaje",
                "mensaje-viejo",
                "mensaje-nuevo",
                try dashboardSearchSummary(overrides: ["lastMessagePreview": "mensaje-nuevo"])
            ),
            (
                "rawPrompt",
                "prompt",
                "prompt-viejo",
                "prompt-nuevo",
                try dashboardSearchSummary(overrides: ["rawPrompt": "prompt-nuevo"])
            ),
        ]

        for item in cases {
            let changedRevision = DashboardSearchIndexRevision(session: item.session)
            let changedDocument = DashboardSearchDocument(revision: changedRevision)

            XCTAssertNotEqual(
                changedRevision,
                baselineRevision,
                "Changing \(item.source) must invalidate the search index."
            )
            XCTAssertTrue(baselineDocument.contains(item.oldQuery))
            XCTAssertFalse(baselineDocument.contains(item.newQuery))
            XCTAssertFalse(changedDocument.contains(item.oldQuery))
            XCTAssertTrue(changedDocument.contains(item.newQuery))
            XCTAssertEqual(changedDocument.matchingField(item.newQuery), item.expectedMatchLabel)
        }

        let metadataOnlyChange = try dashboardSearchSummary(
            overrides: [
                "displayName": "fallback-no-indexado",
                "updatedAt": 99,
                "messageCount": 77,
            ]
        )
        XCTAssertEqual(
            DashboardSearchIndexRevision(session: metadataOnlyChange),
            baselineRevision,
            "Metadata outside the effective search document must not rebuild the index."
        )

        let normalizedEquivalent = try dashboardSearchSummary(
            overrides: [
                "windowName": "  NÓMBRE-VIEJO  ",
                "collaborationProjectName": " PROYÉCTO-VIEJO ",
                "projectName": " CARPÉTA-VIEJA ",
                "projectPath": " /RÚTA/VIEJA ",
                "lastMessagePreview": " MENSAJE-VIEJO ",
                "rawPrompt": " PRÓMPT-VIEJO ",
            ]
        )
        XCTAssertEqual(
            DashboardSearchIndexRevision(session: normalizedEquivalent),
            baselineRevision,
            "Case, diacritics and outer whitespace that preserve the effective document must not rebuild it."
        )

        let second = try dashboardSearchSummary(
            overrides: [
                "windowId": "search-window-b",
                "sessionId": "search-session-b",
            ]
        )
        XCTAssertEqual(
            DashboardSearchIndexRevision.snapshot(for: [baseline, second]),
            DashboardSearchIndexRevision.snapshot(for: [second, baseline]),
            "A presentation-only session reorder must not invalidate the search index."
        )
    }

    private func dashboardSearchSummary(
        overrides: [String: Any] = [:]
    ) throws -> KycodeSessionSummary {
        var payload: [String: Any] = [
            "windowId": "search-window",
            "sessionId": "search-session",
            "engine": "codex",
            "projectKey": "projects",
            "projectPath": "/ruta/vieja",
            "projectName": "carpeta-vieja",
            "windowName": "nombre-viejo",
            "displayName": "fallback-visible",
            "sidecarMode": "relay",
            "activityStatus": "ready",
            "messageCount": 4,
            "updatedAt": 1,
            "rawPrompt": "prompt-viejo",
            "lastMessagePreview": "mensaje-viejo",
            "canSend": true,
            "collaborationProjectName": "proyecto-viejo",
        ]
        payload.merge(overrides) { _, replacement in replacement }
        return try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func dashboardState(
        sourceStates: [KycodeSourceConnectionState],
        sessionCount: Int,
        isShowingCachedSessions: Bool = false,
        isConnected: Bool = false,
        isBootstrapping: Bool = false,
        isReconnecting: Bool = false,
        canRetry: Bool = false,
        hasError: Bool = false
    ) -> KycodeDashboardSnapshotState {
        KycodeDashboardSnapshotPolicy.resolve(
            sourceStates: sourceStates,
            sessionCount: sessionCount,
            isShowingCachedSessions: isShowingCachedSessions,
            isConnected: isConnected,
            isBootstrapping: isBootstrapping,
            isReconnecting: isReconnecting,
            canRetry: canRetry,
            hasError: hasError
        )
    }

    private func sourceState(
        id: String,
        phase: KycodeSourceSnapshotPhase,
        attempt: UInt64
    ) -> KycodeSourceConnectionState {
        KycodeSourceConnectionState(
            id: id,
            name: id == "puky" ? "Puky" : "Personal",
            isLoading: phase == .loading,
            isConnected: phase == .succeeded,
            sessionCount: 0,
            connectionLabel: nil,
            errorMessage: phase == .failed ? "Sin conexión" : nil,
            snapshotPhase: phase,
            attemptGeneration: attempt,
            hasRetainedSnapshot: false
        )
    }

    func testTranscriptPresentationDistinguishesLoadingFailureIncompleteAndRealEmpty() {
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: false,
                hasMessages: false,
                expectedMessageCount: 2,
                isProcessing: false,
                detailLoadState: .idle
            ),
            .loading
        )
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: false,
                hasMessages: false,
                expectedMessageCount: 2,
                isProcessing: false,
                detailLoadState: .failed("No se pudo cargar la conversación.")
            ),
            .failed("No se pudo cargar la conversación.")
        )
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: true,
                hasMessages: false,
                expectedMessageCount: 2,
                isProcessing: false,
                detailLoadState: .loaded
            ),
            .incomplete(2)
        )
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: true,
                hasMessages: false,
                expectedMessageCount: 0,
                isProcessing: false,
                detailLoadState: .loaded
            ),
            .empty
        )
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: true,
                hasMessages: false,
                expectedMessageCount: 0,
                isProcessing: true,
                detailLoadState: .loaded
            ),
            .processing
        )
        XCTAssertEqual(
            KycodeTranscriptPresentationPolicy.resolve(
                hasAuthoritativeDetail: true,
                hasMessages: true,
                expectedMessageCount: 2,
                isProcessing: false,
                detailLoadState: .failed("No se pudo actualizar la conversación.")
            ),
            .content,
            "A refresh failure must preserve an already visible transcript."
        )
    }

    @MainActor
    func testDetailFailureBecomesRouteScopedAndRetryReturnsToLoaded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionRefreshMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var detailReturnsValidPayload = false

        SessionRefreshMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/sessions/detail-state-window") {
                if detailReturnsValidPayload {
                    return (
                        response,
                        Data(
                            #"{"ok":true,"item":{"windowId":"detail-state-window","sessionId":"session-detail-state","engine":"codex","projectKey":"project","displayName":"Detalle","sidecarMode":"local","activityStatus":"ready","runtimeStatus":"WAITING","messageCount":1,"updatedAt":2,"canSend":true,"messages":[{"id":"detail-state-message","role":"assistant","type":"codex","content":"RECUPERADO","timestamp":2,"status":"completed"}]}}"#.utf8
                        )
                    )
                }
                return (response, Data(#"{"ok":true,"item":"#.utf8))
            }
            return (
                response,
                Data(
                    #"{"ok":true,"items":[{"windowId":"detail-state-window","sessionId":"session-detail-state","engine":"codex","projectKey":"project","displayName":"Detalle","sidecarMode":"local","activityStatus":"ready","runtimeStatus":"WAITING","messageCount":1,"updatedAt":2,"canSend":true}]}"#.utf8
                )
            )
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        await store.refreshSessionsNow()
        for _ in 0..<100 {
            if case .failed = store.detailLoadState(for: "detail-state-window") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case let .failed(message) = store.detailLoadState(for: "detail-state-window") else {
            return XCTFail("The failed detail must not remain loading or look empty.")
        }
        XCTAssertEqual(
            message,
            "La sesión sigue ahí. Reintentá para recuperar los mensajes más recientes."
        )
        XCTAssertFalse(store.hasAuthoritativeDetail(for: "detail-state-window"))
        XCTAssertEqual(store.sessions.first?.messageCount, 1)
        XCTAssertNil(store.errorMessage, "A background detail failure belongs to its session, not a global alert.")

        detailReturnsValidPayload = true
        await store.refreshDetail(windowId: "detail-state-window")

        XCTAssertEqual(store.detailLoadState(for: "detail-state-window"), .loaded)
        XCTAssertTrue(store.hasAuthoritativeDetail(for: "detail-state-window"))
        XCTAssertEqual(store.sessionDetails["detail-state-window"]?.messages?.first?.content, "RECUPERADO")
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    @MainActor
    func testRepeatedMissingWindowRefreshesStaySilentAndSnapshotDoesNotReinsertStaleWindow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionRefreshMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var detailExists = true
        var listContainsWindow = true
        let item =
            """
            {"windowId":"stale-window","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"Stale","sidecarMode":"local","activityStatus":"ready","messageCount":0,"updatedAt":1,"canSend":true}
            """

        SessionRefreshMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let isDetail = url.path.hasSuffix("/sessions/stale-window")
            let statusCode = isDetail && !detailExists ? 404 : 200
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if isDetail {
                return detailExists
                    ? (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
                    : (response, Data(#"{"ok":false,"code":"SESSION_NOT_FOUND","error":"gone"}"#.utf8))
            }
            let items = listContainsWindow ? item : ""
            return (response, Data(#"{"ok":true,"items":[\#(items)]}"#.utf8))
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        await store.refreshSessionsNow()
        for _ in 0..<50 where store.sessionDetails["stale-window"] == nil {
            await store.refreshDetail(windowId: "stale-window")
            if store.sessionDetails["stale-window"] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.sessionDetails["stale-window"])

        detailExists = false
        await store.refreshDetail(windowId: "stale-window")
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.detail(for: "stale-window"))

        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "stale-window")
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.sessions.isEmpty, "A stale snapshot must not reinsert a window whose detail returned 404.")

        listContainsWindow = false
        await store.refreshSessionsNow()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}

private final class FerminCleanStateMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class FerminTodoRaceMockURLProtocol: URLProtocol {
    static var handler: ((FerminTodoRaceMockURLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            fail(with: URLError(.badServerResponse))
            return
        }
        handler(self, request)
    }

    override func stopLoading() {}

    func succeed(response: HTTPURLResponse, data: Data) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class FerminTodoRefreshRaceController: @unchecked Sendable {
    enum Disposition {
        case immediate(String)
        case deferred(String)
    }

    private typealias PendingResponse = (
        request: FerminTodoRaceMockURLProtocol,
        response: HTTPURLResponse,
        data: Data
    )

    private let lock = NSLock()
    private var isRaceEnabled = false
    private var deferredProfileIds: Set<String> = []
    private var requestOrdinals: [String: Int] = [:]
    private var pendingResponses: [PendingResponse] = []

    func beginRace(deferredProfileIds: Set<String> = ["puky", "personal"]) {
        lock.lock()
        isRaceEnabled = true
        self.deferredProfileIds = deferredProfileIds
        requestOrdinals = [:]
        pendingResponses = []
        lock.unlock()
    }

    func disposition(for profileId: String) -> Disposition {
        lock.lock()
        defer { lock.unlock() }
        guard isRaceEnabled else { return .immediate("committed") }
        let ordinal = (requestOrdinals[profileId] ?? 0) + 1
        requestOrdinals[profileId] = ordinal
        return ordinal == 1 && deferredProfileIds.contains(profileId)
            ? .deferred("race-a")
            : .immediate("race-b")
    }

    func retain(
        request: FerminTodoRaceMockURLProtocol,
        response: HTTPURLResponse,
        data: Data
    ) {
        lock.lock()
        pendingResponses.append((request, response, data))
        lock.unlock()
    }

    var blockedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingResponses.count
    }

    func releaseFirstRound() {
        lock.lock()
        let responses = pendingResponses
        pendingResponses = []
        lock.unlock()
        for pending in responses {
            pending.request.succeed(response: pending.response, data: pending.data)
        }
    }
}

private struct FerminCachedSessionsFixture: Encodable {
    let schemaVersion: Int
    let profileId: String
    let cachedAt: Date
    let sessions: [KycodeSessionSummary]
}

final class FerminCleanStateAcceptanceTests: XCTestCase {
    private let cachedSessionsKey = "kycode.mobile.cachedSessions.v1"
    private let sessionDisplayOrdersKey = "kycode.mobile.sessionDisplayOrders.v1"
    private let profilesKey = "kycode.mobile.connectionProfiles"
    private let selectedProfileKey = "kycode.mobile.selectedProfileId"
    private let credentialMigrationVersionKey = "kycode.mobile.connectionCredentialMigrationVersion"
    private var previousDefaults: [String: Any] = [:]
    private var absentDefaults: Set<String> = []
    private var previousPukyToken: String?
    private var previousPersonalToken: String?
    private var previousForceInternet: String?

    override func setUp() {
        super.setUp()
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                previousDefaults[key] = value
            } else {
                absentDefaults.insert(key)
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(3, forKey: credentialMigrationVersionKey)
        previousPukyToken = KycodeKeychain.loadAuthToken(profileId: "puky")
        previousPersonalToken = KycodeKeychain.loadAuthToken(profileId: "personal")
        previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)
    }

    override func tearDown() {
        FerminCleanStateMockURLProtocol.handler = nil
        FerminTodoRaceMockURLProtocol.handler = nil
        for key in defaultsKeys {
            if let value = previousDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else if absentDefaults.contains(key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let previousPukyToken {
            KycodeKeychain.saveAuthToken(previousPukyToken, profileId: "puky")
        } else {
            KycodeKeychain.deleteAuthToken(profileId: "puky")
        }
        if let previousPersonalToken {
            KycodeKeychain.saveAuthToken(previousPersonalToken, profileId: "personal")
        } else {
            KycodeKeychain.deleteAuthToken(profileId: "personal")
        }
        if let previousForceInternet {
            setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
        } else {
            unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
        }
        super.tearDown()
    }

    @MainActor
    func testAuthoritativeEmptyPersonalAndPukySnapshotsClearStaleCardsAndRelaunchCache() async throws {
        try await assertAuthoritativeEmptySnapshotClearsProfile("personal")
        try await assertAuthoritativeEmptySnapshotClearsProfile("puky")
    }

    @MainActor
    func testAuthoritativeEmptySnapshotsFromBothMacsLeaveTodoEmpty() async throws {
        KycodeKeychain.saveAuthToken("clean-state-puky-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("clean-state-personal-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminCleanStateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var snapshotsAreEmpty = false
        defer { session.invalidateAndCancel() }

        FerminCleanStateMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            XCTAssertEqual(url.host, "relay.example.com")
            let profileId = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"
            let windowId = "\(profileId)-stale-window"
            let item = self.summaryJSON(windowId: windowId, displayName: "\(profileId) stale")
            if url.path.hasSuffix("/api/mobile/sessions") {
                let items = snapshotsAreEmpty ? "" : item
                return (response, self.snapshotData(items: items))
            }
            if url.path.hasSuffix("/api/mobile/sessions/\(windowId)") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            throw URLError(.badURL)
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all"
        )
        await store.retryAutoConnect()

        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            Set(["personal::personal-stale-window", "puky::puky-stale-window"])
        )
        XCTAssertNotNil(UserDefaults.standard.data(forKey: cachedSessionsKey))

        snapshotsAreEmpty = true
        await store.refreshSessionsNow()

        XCTAssertTrue(store.sessions.isEmpty, "Todo must remove cards absent from both authoritative snapshots.")
        XCTAssertTrue(store.sessionDetails.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: store.sourceConnectionStates.map { ($0.id, $0.sessionCount) }),
            ["puky": 0, "personal": 0]
        )
        let sourceStates = Dictionary(
            uniqueKeysWithValues: store.sourceConnectionStates.map { ($0.id, $0) }
        )
        XCTAssertEqual(sourceStates["puky"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(sourceStates["personal"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(
            sourceStates["puky"]?.attemptGeneration,
            sourceStates["personal"]?.attemptGeneration,
            "Todo is authoritative only when both sources finish the same attempt."
        )
        XCTAssertEqual(store.dashboardSnapshotState, .authoritativeEmpty)
        XCTAssertNil(
            UserDefaults.standard.data(forKey: cachedSessionsKey),
            "An empty authoritative Todo snapshot must delete the stale on-disk card cache."
        )

        let relaunched = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all"
        )
        XCTAssertTrue(relaunched.sessions.isEmpty, "Todo must remain empty after a cold relaunch.")
        XCTAssertFalse(relaunched.isShowingCachedSessions)
        store.disconnect()
        relaunched.disconnect()
    }

    @MainActor
    func testTodoPartialFailurePreservesLastCompleteCommitAndCache() async throws {
        KycodeKeychain.saveAuthToken("partial-puky-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("partial-personal-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminCleanStateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var shouldFailPersonal = false
        defer { session.invalidateAndCancel() }

        FerminCleanStateMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let isPuky = url.path.hasPrefix("/fermin-code-puky/")
            let profileId = isPuky ? "puky" : "personal"
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            if url.path.hasSuffix("/api/mobile/sessions") {
                if profileId == "personal", shouldFailPersonal {
                    throw URLError(.timedOut)
                }
                let suffix = shouldFailPersonal && profileId == "puky" ? "fresh" : "committed"
                let item = self.summaryJSON(
                    windowId: "\(profileId)-\(suffix)-window",
                    displayName: "\(profileId) \(suffix)"
                )
                return (response, self.snapshotData(items: item))
            }

            if url.path.contains("/api/mobile/sessions/") {
                let windowId = try XCTUnwrap(url.pathComponents.last)
                let item = self.summaryJSON(windowId: windowId, displayName: windowId)
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            throw URLError(.badURL)
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all"
        )
        await store.retryAutoConnect()

        let committedWindowIds = Set([
            "personal::personal-committed-window",
            "puky::puky-committed-window",
        ])
        XCTAssertEqual(Set(store.sessions.map(\.windowId)), committedWindowIds)
        let committedCache = try XCTUnwrap(
            UserDefaults.standard.data(forKey: cachedSessionsKey)
        )

        shouldFailPersonal = true
        await store.refreshSessionsNow()

        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            committedWindowIds,
            "A fresh Puky result must not replace the last complete Todo commit when Personal fails."
        )
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: cachedSessionsKey),
            committedCache,
            "A mixed fresh/stale aggregate must never replace the durable cache."
        )
        let sourceStates = Dictionary(
            uniqueKeysWithValues: store.sourceConnectionStates.map { ($0.id, $0) }
        )
        XCTAssertEqual(sourceStates["puky"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(sourceStates["personal"]?.snapshotPhase, .failed)
        XCTAssertEqual(
            sourceStates["puky"]?.attemptGeneration,
            sourceStates["personal"]?.attemptGeneration
        )
        XCTAssertEqual(store.dashboardSnapshotState, .partialSourceFailure)
        XCTAssertTrue(store.isConnected, "The healthy source remains available without claiming a full Todo refresh.")
        store.disconnect()
    }

    @MainActor
    func testTodoIgnoresLatePreviousRefreshResult() async throws {
        KycodeKeychain.saveAuthToken("race-puky-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("race-personal-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminTodoRaceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let race = FerminTodoRefreshRaceController()
        defer {
            race.releaseFirstRound()
            session.invalidateAndCancel()
        }

        FerminTodoRaceMockURLProtocol.handler = { requestProtocol, request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                requestProtocol.fail(with: URLError(.badServerResponse))
                return
            }
            let profileId = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"

            if url.path.hasSuffix("/api/mobile/sessions") {
                let disposition = race.disposition(for: profileId)
                let suffix: String
                let shouldDefer: Bool
                switch disposition {
                case let .immediate(value):
                    suffix = value
                    shouldDefer = false
                case let .deferred(value):
                    suffix = value
                    shouldDefer = true
                }
                let item = self.summaryJSON(
                    windowId: "\(profileId)-\(suffix)-window",
                    displayName: "\(profileId) \(suffix)"
                )
                let data = self.snapshotData(items: item)
                if shouldDefer {
                    race.retain(request: requestProtocol, response: response, data: data)
                } else {
                    requestProtocol.succeed(response: response, data: data)
                }
                return
            }
            if url.path.contains("/api/mobile/sessions/") {
                guard let windowId = url.pathComponents.last else {
                    requestProtocol.fail(with: URLError(.badURL))
                    return
                }
                let item = self.summaryJSON(windowId: windowId, displayName: windowId)
                requestProtocol.succeed(
                    response: response,
                    data: Data(#"{"ok":true,"item":\#(item)}"#.utf8)
                )
                return
            }
            requestProtocol.fail(with: URLError(.badURL))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all"
        )
        await store.retryAutoConnect()
        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            Set([
                "personal::personal-committed-window",
                "puky::puky-committed-window",
            ])
        )

        race.beginRace()
        let previousRefresh = Task { @MainActor in
            await store.refreshSessionsNow()
        }
        for _ in 0..<200 where race.blockedRequestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard race.blockedRequestCount == 2 else {
            race.releaseFirstRound()
            await previousRefresh.value
            return XCTFail("The first Todo refresh did not start both source requests.")
        }

        let currentRefresh = Task { @MainActor in
            await store.refreshSessionsNow()
        }
        await currentRefresh.value

        let currentWindowIds = Set([
            "personal::personal-race-b-window",
            "puky::puky-race-b-window",
        ])
        XCTAssertEqual(Set(store.sessions.map(\.windowId)), currentWindowIds)
        let currentCache = try XCTUnwrap(
            UserDefaults.standard.data(forKey: cachedSessionsKey)
        )
        let currentStates = Dictionary(
            uniqueKeysWithValues: store.sourceConnectionStates.map { ($0.id, $0) }
        )
        let currentAttempt = try XCTUnwrap(currentStates["puky"]?.attemptGeneration)
        XCTAssertEqual(currentStates["puky"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(currentStates["personal"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(currentStates["personal"]?.attemptGeneration, currentAttempt)

        race.releaseFirstRound()
        await previousRefresh.value

        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            currentWindowIds,
            "Late results from the previous attempt must not replace the current Todo commit."
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: cachedSessionsKey), currentCache)
        let finalStates = Dictionary(
            uniqueKeysWithValues: store.sourceConnectionStates.map { ($0.id, $0) }
        )
        XCTAssertEqual(finalStates["puky"]?.attemptGeneration, currentAttempt)
        XCTAssertEqual(finalStates["personal"]?.attemptGeneration, currentAttempt)
        XCTAssertEqual(finalStates["puky"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(finalStates["personal"]?.snapshotPhase, .succeeded)
        XCTAssertEqual(store.dashboardSnapshotState, .content)
        store.disconnect()
    }

    @MainActor
    func testLateManualConnectionCannotPublishAfterProfileHandoff() async throws {
        KycodeKeychain.saveAuthToken("handoff-personal-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("handoff-puky-token", profileId: "puky")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminCleanStateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let personalRequestStarted = expectation(description: "late Personal request started")
        let releasePersonalRequest = DispatchSemaphore(value: 0)
        let stalePersonal = summaryJSON(
            windowId: "personal-late-window",
            displayName: "Personal late"
        )
        let currentPuky = summaryJSON(
            windowId: "puky-current-window",
            displayName: "Puky current"
        )
        defer {
            releasePersonalRequest.signal()
            session.invalidateAndCancel()
        }

        FerminCleanStateMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            guard url.path.hasSuffix("/api/mobile/sessions") else {
                throw URLError(.badURL)
            }
            if url.host == "personal-late.mock" {
                personalRequestStarted.fulfill()
                _ = releasePersonalRequest.wait(timeout: .now() + 5)
                return (response, self.snapshotData(items: stalePersonal))
            }
            XCTAssertEqual(url.host, "relay.example.com")
            XCTAssertTrue(url.path.hasPrefix("/fermin-code-puky/"))
            return (response, self.snapshotData(items: currentPuky))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal"
        )
        store.baseURLInput = "https://personal-late.mock"
        store.authTokenInput = "handoff-personal-token"

        let lateConnection = Task { @MainActor in
            await store.connect()
        }
        await fulfillment(of: [personalRequestStarted], timeout: 2)

        await store.selectProfile(id: "puky")
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.sessions.map(\.windowId), ["puky-current-window"])
        XCTAssertTrue(store.isConnected)

        releasePersonalRequest.signal()
        await lateConnection.value

        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.sessions.map(\.windowId), ["puky-current-window"])
        XCTAssertEqual(
            KycodeKeychain.loadAuthToken(profileId: "puky"),
            "handoff-puky-token",
            "A late Personal response must never persist its token under Puky."
        )
        XCTAssertFalse(store.isConnecting)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    @MainActor
    func testLateResumePollCannotReplaceANewerTodoRefreshOrCache() async throws {
        KycodeKeychain.saveAuthToken("resume-race-puky-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("resume-race-personal-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminTodoRaceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let race = FerminTodoRefreshRaceController()
        defer {
            race.releaseFirstRound()
            session.invalidateAndCancel()
        }

        FerminTodoRaceMockURLProtocol.handler = { requestProtocol, request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                requestProtocol.fail(with: URLError(.badServerResponse))
                return
            }
            let profileId = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"

            if request.httpMethod == "POST",
               url.path.hasSuffix("/api/mobile/session-history/resume") {
                requestProtocol.succeed(
                    response: response,
                    data: Data(
                        #"{"ok":true,"queued":true,"commandId":"resume-race","queuedAt":1,"state":"queued","windowId":null,"sessionId":"puky-race-a-window","projectPath":"/tmp/projects"}"#.utf8
                    )
                )
                return
            }
            if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                let disposition = race.disposition(for: profileId)
                let suffix: String
                let shouldDefer: Bool
                switch disposition {
                case let .immediate(value):
                    suffix = value
                    shouldDefer = false
                case let .deferred(value):
                    suffix = value
                    shouldDefer = true
                }
                let item = self.summaryJSON(
                    windowId: "\(profileId)-\(suffix)-window",
                    displayName: "\(profileId) \(suffix)"
                )
                let data = self.snapshotData(items: item)
                if shouldDefer {
                    race.retain(request: requestProtocol, response: response, data: data)
                } else {
                    requestProtocol.succeed(response: response, data: data)
                }
                return
            }
            if request.httpMethod == "GET", url.path.contains("/api/mobile/sessions/") {
                guard let windowId = url.pathComponents.last else {
                    requestProtocol.fail(with: URLError(.badURL))
                    return
                }
                let item = self.summaryJSON(windowId: windowId, displayName: windowId)
                requestProtocol.succeed(
                    response: response,
                    data: Data(#"{"ok":true,"item":\#(item)}"#.utf8)
                )
                return
            }
            requestProtocol.fail(with: URLError(.badURL))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all"
        )
        await store.retryAutoConnect()

        race.beginRace(deferredProfileIds: ["puky"])
        let historyItem = KycodeSessionHistoryItem(
            id: "history-resume-race",
            sessionUUID: "history-resume-race",
            projectKey: "projects",
            projectName: "Projects",
            sessionId: "puky-race-a-window",
            sessionName: "Resume race",
            sessionPath: "/tmp/projects",
            createdAt: 1,
            updatedAt: 1,
            state: .archived,
            windowId: nil,
            archivedId: nil,
            score: 0,
            preview: "",
            matchedIn: nil,
            canResume: true
        ).routed(profileId: "puky", profileName: "Puky")

        let lateResume = Task { @MainActor in
            try await store.resumeSessionHistoryItem(historyItem)
        }
        for _ in 0..<200 where race.blockedRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard race.blockedRequestCount == 1 else {
            race.releaseFirstRound()
            _ = try await lateResume.value
            return XCTFail("The resume poll did not reach the deferred Puky snapshot.")
        }

        await store.refreshSessionsNow()
        let currentWindowIds = Set([
            "personal::personal-race-b-window",
            "puky::puky-race-b-window",
        ])
        XCTAssertEqual(Set(store.sessions.map(\.windowId)), currentWindowIds)
        let currentCache = try XCTUnwrap(
            UserDefaults.standard.data(forKey: cachedSessionsKey)
        )

        race.releaseFirstRound()
        let lateResumeWindowId = try await lateResume.value
        XCTAssertNil(lateResumeWindowId)
        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            currentWindowIds,
            "A late resume poll must not replace a newer Todo aggregate."
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: cachedSessionsKey), currentCache)
        XCTAssertEqual(store.dashboardSnapshotState, .content)
        store.disconnect()
    }

    @MainActor
    func testMalformedCachedSessionIdentitiesAreDiscardedAndAuthorityCanRecover() async throws {
        KycodeKeychain.saveAuthToken("cache-recovery-token", profileId: "puky")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminCleanStateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let authoritativeItem = summaryJSON(
            windowId: "authoritative-window",
            displayName: "Authoritative"
        )
        defer { session.invalidateAndCancel() }

        FerminCleanStateMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/api/mobile/sessions") {
                return (response, self.snapshotData(items: authoritativeItem))
            }
            if url.path.hasSuffix("/api/mobile/sessions/authoritative-window") {
                return (response, Data(#"{"ok":true,"item":\#(authoritativeItem)}"#.utf8))
            }
            throw URLError(.badURL)
        }

        let duplicate = try cachedSummary(
            windowId: "duplicate-window",
            displayName: "Duplicate"
        )
        let corruptCases: [(String, [KycodeSessionSummary])] = [
            ("duplicate windowId", [duplicate, duplicate]),
            (
                "empty windowId",
                [try cachedSummary(windowId: "", sessionId: "session-empty-window", displayName: "Empty window")]
            ),
            (
                "empty sessionId",
                [try cachedSummary(windowId: "empty-session-window", sessionId: "", displayName: "Empty session")]
            ),
            (
                "padded identity",
                [try cachedSummary(windowId: " padded-window ", sessionId: " padded-session ", displayName: "Padded")]
            ),
        ]

        for (label, sessions) in corruptCases {
            let fixture = FerminCachedSessionsFixture(
                schemaVersion: 1,
                profileId: "puky",
                cachedAt: Date(),
                sessions: sessions
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(fixture),
                forKey: cachedSessionsKey
            )

            let store = KycodeConnectionStore(
                urlSession: session,
                initialProfileIdOverride: "puky"
            )
            XCTAssertTrue(store.sessions.isEmpty, "\(label) must fail closed before dictionary construction.")
            XCTAssertFalse(store.isShowingCachedSessions)
            XCTAssertNil(
                UserDefaults.standard.data(forKey: cachedSessionsKey),
                "\(label) must remove only the unusable cache blob."
            )

            store.baseURLInput = "https://puky.cache-recovery.test"
            store.authTokenInput = "cache-recovery-token"
            await store.refreshSessionsNow()

            XCTAssertEqual(store.sessions.map(\.windowId), ["authoritative-window"])
            XCTAssertEqual(store.dashboardSnapshotState, .content)
            XCTAssertNotNil(UserDefaults.standard.data(forKey: cachedSessionsKey))
            store.disconnect()
        }
    }

    @MainActor
    func testCachedSessionIdentityValidationAllowsSharedSessionIdAcrossDistinctWindows() throws {
        let sharedSessionId = "shared-provider-session"
        let sessions = [
            try cachedSummary(
                windowId: "first-window",
                sessionId: sharedSessionId,
                displayName: "First"
            ),
            try cachedSummary(
                windowId: "second-window",
                sessionId: sharedSessionId,
                displayName: "Second"
            ),
        ]
        let fixture = FerminCachedSessionsFixture(
            schemaVersion: 1,
            profileId: "puky",
            cachedAt: Date(),
            sessions: sessions
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(fixture),
            forKey: cachedSessionsKey
        )

        let store = KycodeConnectionStore(initialProfileIdOverride: "puky")

        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            Set(["first-window", "second-window"]),
            "Only windowId must be unique because it is the in-memory dictionary key."
        )
        XCTAssertEqual(Set(store.sessions.map(\.sessionId)), Set([sharedSessionId]))
        XCTAssertTrue(store.isShowingCachedSessions)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: cachedSessionsKey))
    }

    @MainActor
    func testCacheForAnotherProfileIsIgnoredWithoutDeletingIt() throws {
        let fixture = FerminCachedSessionsFixture(
            schemaVersion: 1,
            profileId: "personal",
            cachedAt: Date(),
            sessions: [
                try cachedSummary(
                    windowId: "personal-window",
                    displayName: "Personal"
                )
            ]
        )
        let personalCache = try JSONEncoder().encode(fixture)
        UserDefaults.standard.set(personalCache, forKey: cachedSessionsKey)

        let store = KycodeConnectionStore(initialProfileIdOverride: "puky")

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isShowingCachedSessions)
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: cachedSessionsKey),
            personalCache,
            "Selecting another profile must ignore, not destroy, a well-formed cache owned by Personal."
        )
    }

    @MainActor
    private func assertAuthoritativeEmptySnapshotClearsProfile(
        _ profileId: String
    ) async throws {
        UserDefaults.standard.removeObject(forKey: cachedSessionsKey)
        UserDefaults.standard.removeObject(forKey: sessionDisplayOrdersKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FerminCleanStateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var snapshotIsEmpty = false
        let windowId = "\(profileId)-stale-window"
        let item = summaryJSON(windowId: windowId, displayName: "\(profileId) stale")
        defer { session.invalidateAndCancel() }

        FerminCleanStateMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path == "/api/mobile/sessions" {
                return (
                    response,
                    self.snapshotData(items: snapshotIsEmpty ? "" : item)
                )
            }
            if url.path == "/api/mobile/sessions/\(windowId)" {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            throw URLError(.badURL)
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: profileId
        )
        store.baseURLInput = "https://\(profileId).clean-state.test"
        store.authTokenInput = "clean-state-token"
        await store.refreshSessionsNow()

        XCTAssertEqual(store.sessions.map(\.windowId), [windowId])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: cachedSessionsKey))

        snapshotIsEmpty = true
        await store.refreshSessionsNow()

        XCTAssertTrue(store.sessions.isEmpty, "\(profileId) must remove a card omitted by its authoritative snapshot.")
        XCTAssertTrue(store.sessionDetails.isEmpty)
        let sourceState = try XCTUnwrap(
            store.sourceConnectionStates.first(where: { $0.id == profileId })
        )
        XCTAssertEqual(sourceState.snapshotPhase, .succeeded)
        XCTAssertTrue(sourceState.hasRetainedSnapshot)
        XCTAssertEqual(store.dashboardSnapshotState, .authoritativeEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: cachedSessionsKey))

        let relaunched = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: profileId
        )
        XCTAssertTrue(relaunched.sessions.isEmpty, "\(profileId) must not resurrect a stale cached card.")
        XCTAssertFalse(relaunched.isShowingCachedSessions)
        store.disconnect()
        relaunched.disconnect()
    }

    private var defaultsKeys: [String] {
        [
            cachedSessionsKey,
            sessionDisplayOrdersKey,
            profilesKey,
            selectedProfileKey,
            credentialMigrationVersionKey,
        ]
    }

    private func snapshotData(items: String) -> Data {
        let now = Date().timeIntervalSince1970 * 1_000
        return Data(#"{"ok":true,"now":\#(now),"exportedAt":\#(now),"items":[\#(items)]}"#.utf8)
    }

    private func cachedSummary(
        windowId: String,
        sessionId: String? = nil,
        displayName: String
    ) throws -> KycodeSessionSummary {
        try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: Data(
                summaryJSON(
                    windowId: windowId,
                    sessionId: sessionId,
                    displayName: displayName
                ).utf8
            )
        )
    }

    private func summaryJSON(
        windowId: String,
        sessionId: String? = nil,
        displayName: String
    ) -> String {
        let resolvedSessionId = sessionId ?? windowId
        return """
        {"windowId":"\(windowId)","sessionId":"\(resolvedSessionId)","engine":"codex","projectKey":"projects","displayName":"\(displayName)","sidecarMode":"relay","activityStatus":"ready","messageCount":0,"updatedAt":1,"canSend":true}
        """
    }
}
