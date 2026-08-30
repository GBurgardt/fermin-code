import XCTest
@testable import KyCode

private final class NewSessionMockURLProtocol: URLProtocol {
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

private func newSessionRequestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw NSError(
            domain: "NewSessionFlowTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The request did not contain a body."]
        )
    }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
            return data
        } else {
            throw stream.streamError ?? URLError(.cannotDecodeRawData)
        }
    }
}

final class NewSessionFlowTests: XCTestCase {
    override func tearDown() {
        NewSessionMockURLProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.recentCreatedSessions")
        super.tearDown()
    }

    func testRoutableCredentialsKeepCreateAvailableFromAnEmptyOrReconnectingDashboard() {
        XCTAssertEqual(
            KycodeCreateSessionAccessPolicy.resolve(
                usesCombinedProfile: false,
                hasRoutableCredentials: true
            ),
            .available
        )
    }

    func testCombinedDashboardRequiresAnExplicitCreateOrigin() {
        XCTAssertEqual(
            KycodeCreateSessionAccessPolicy.resolve(
                usesCombinedProfile: true,
                hasRoutableCredentials: true
            ),
            .profileSelectionRequired
        )
    }

    func testMissingCreateCredentialsProducesActionableConfigurationState() {
        XCTAssertEqual(
            KycodeCreateSessionAccessPolicy.resolve(
                usesCombinedProfile: false,
                hasRoutableCredentials: false
            ),
            .credentialsRequired
        )
    }

    func testPendingCreationsFollowTheSelectedMacScope() {
        let puky = KycodeRecentCreatedSession(
            sessionId: "puky-pending",
            windowId: nil,
            projectPath: "/puky/projects",
            projectName: "projects",
            profileId: "puky",
            createdAt: .now,
            status: "pending"
        )
        let personal = KycodeRecentCreatedSession(
            sessionId: "personal-pending",
            windowId: nil,
            projectPath: "/personal/projects",
            projectName: "projects",
            profileId: "personal",
            createdAt: .now,
            status: "pending"
        )
        let legacy = KycodeRecentCreatedSession(
            sessionId: "legacy-pending",
            windowId: nil,
            projectPath: "/legacy/projects",
            projectName: "projects",
            createdAt: .now,
            status: "pending"
        )
        let entries = [puky, personal, legacy]

        XCTAssertEqual(
            KycodeRecentCreatedSessionScopePolicy.visibleEntries(
                entries,
                selectedProfileId: "puky"
            ).map(\.sessionId),
            ["puky-pending", "legacy-pending"]
        )
        XCTAssertEqual(
            KycodeRecentCreatedSessionScopePolicy.visibleEntries(
                entries,
                selectedProfileId: "personal"
            ).map(\.sessionId),
            ["personal-pending", "legacy-pending"]
        )
        XCTAssertEqual(
            KycodeRecentCreatedSessionScopePolicy.visibleEntries(
                entries,
                selectedProfileId: "all"
            ).map(\.sessionId),
            entries.map(\.sessionId)
        )
    }

    func testSessionNameRulesRejectEmptyWhitespaceAndOversizedValues() {
        XCTAssertEqual(
            KycodeSessionNameRules.validationMessage(for: ""),
            "El nombre no puede estar vacío."
        )
        XCTAssertEqual(
            KycodeSessionNameRules.validationMessage(for: "  \n\t  "),
            "El nombre no puede estar vacío."
        )
        XCTAssertNil(
            KycodeSessionNameRules.validationMessage(
                for: String(repeating: "x", count: KycodeSessionNameRules.maxLength)
            )
        )
        XCTAssertNotNil(
            KycodeSessionNameRules.validationMessage(
                for: String(repeating: "x", count: KycodeSessionNameRules.maxLength + 1)
            )
        )
        XCTAssertEqual(KycodeSessionNameRules.normalized("  Mi sesión  "), "Mi sesión")
    }

    @MainActor
    func testDefaultProjectUsesServerRootAndCreatePayloadContainsNamePathAndSolMax() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewSessionMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var observedPayload: [String: String]?
        let projectPath = "/Users/example/projects"
        let sessionName = "Nueva sesión QA"

        NewSessionMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path == "/api/mobile/projects" {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"rootPath":"\(projectPath)","items":[{"name":"child","path":"\(projectPath)/child","kind":"directory"}]}
                        """.utf8
                    )
                )
            }
            if url.path == "/api/mobile/sessions", request.httpMethod == "POST" {
                let body = try newSessionRequestBodyData(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                observedPayload = payload
                let requestedSessionId = try XCTUnwrap(payload["sessionId"])
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-create","queuedAt":null,"projectPath":"\(projectPath)","projectName":"projects","sessionId":"\(requestedSessionId)","sessionName":"\(sessionName)"}
                        """.utf8
                    )
                )
            }
            if url.path == "/api/mobile/sessions", request.httpMethod == "GET" {
                let requestedSessionId = try XCTUnwrap(observedPayload?["sessionId"])
                let summary = KycodeSessionSummary(
                    windowId: "window-created",
                    sessionId: requestedSessionId,
                    engine: "codex",
                    model: nil,
                    reasoningEffort: nil,
                    providerSessionId: nil,
                    providerSessionPath: nil,
                    projectKey: "project-key",
                    projectPath: projectPath,
                    projectName: "projects",
                    windowName: sessionName,
                    displayName: sessionName,
                    sidecarMode: "local",
                    sidecarUrl: nil,
                    activityStatus: "ready",
                    runtimeStatus: nil,
                    runtimeStatusDetail: nil,
                    features: nil,
                    messageCount: 0,
                    updatedAt: 1_786_554_252_856,
                    createdAt: 1_786_554_252_856,
                    rawPrompt: nil,
                    originalPrompt: nil,
                    improvedPrompt: nil,
                    lastMessagePreview: nil,
                    isMinimized: false,
                    canSend: true,
                    canControlFeatures: true,
                    unsupportedReason: nil,
                    messages: nil
                )
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: 1_786_554_252_856,
                            exportedAt: nil,
                            items: [summary]
                        )
                    )
                )
            }
            throw URLError(.unsupportedURL)
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let defaultProject = try await store.fetchDefaultProject()
        XCTAssertEqual(defaultProject.kind, "root")
        XCTAssertEqual(defaultProject.name, "~/projects")
        XCTAssertEqual(defaultProject.path, projectPath)

        let result = try await store.createSession(
            projectPath: defaultProject.path,
            sessionName: "  \(sessionName)  "
        )
        XCTAssertNil(result.windowId)
        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(observedPayload?["projectPath"], projectPath)
        XCTAssertEqual(observedPayload?["sessionName"], sessionName)
        XCTAssertEqual(observedPayload?["model"], "gpt-5.6-sol")
        XCTAssertEqual(observedPayload?["reasoningEffort"], "max")
        XCTAssertFalse((observedPayload?["sessionId"] ?? "").isEmpty)
    }

    @MainActor
    func testCreateSessionHandsOffImmediatelyAfterDurableAckWithoutPolling() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewSessionMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let projectPath = "/Users/example/projects"
        let sessionName = "Puky lenta"
        var requestedSessionId: String?
        var snapshotRequestCount = 0
        var virtualUptime: TimeInterval = 0

        NewSessionMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path == "/api/mobile/sessions", request.httpMethod == "POST" {
                let body = try newSessionRequestBodyData(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                let sessionId = try XCTUnwrap(payload["sessionId"])
                requestedSessionId = sessionId
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-slow-create","commandState":"accepted","inserted":true,"durable":true,"queuedAt":null,"projectPath":"\(projectPath)","projectName":"projects","sessionId":"\(sessionId)","sessionName":"\(sessionName)"}
                        """.utf8
                    )
                )
            }
            if url.path == "/api/mobile/sessions", request.httpMethod == "GET" {
                snapshotRequestCount += 1
                guard snapshotRequestCount == 122 else {
                    return (
                        response,
                        Data(#"{"ok":true,"now":1786825004173,"items":[]}"#.utf8)
                    )
                }
                let sessionId = try XCTUnwrap(requestedSessionId)
                let summary = KycodeSessionSummary(
                    windowId: sessionId,
                    sessionId: sessionId,
                    engine: "codex",
                    model: "gpt-5.6-luna",
                    reasoningEffort: "high",
                    providerSessionId: sessionId,
                    providerSessionPath: nil,
                    projectKey: "projects",
                    projectPath: projectPath,
                    projectName: "projects",
                    windowName: sessionName,
                    displayName: sessionName,
                    sidecarMode: "relay",
                    sidecarUrl: nil,
                    activityStatus: "ready",
                    runtimeStatus: "WAITING",
                    runtimeStatusDetail: nil,
                    features: nil,
                    messageCount: 0,
                    updatedAt: 1_786_825_066_803,
                    createdAt: 1_786_825_066_803,
                    rawPrompt: nil,
                    originalPrompt: nil,
                    improvedPrompt: nil,
                    lastMessagePreview: nil,
                    isMinimized: false,
                    canSend: true,
                    canControlFeatures: true,
                    unsupportedReason: nil,
                    messages: nil
                )
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: 1_786_825_066_803,
                            exportedAt: nil,
                            items: [summary]
                        )
                    )
                )
            }
            throw URLError(.unsupportedURL)
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            createSessionConfirmationTimeout: 150,
            createSessionForegroundConfirmationTimeout: 0,
            automaticallyReconcilesCreatedSessions: false,
            createSessionPollNow: { virtualUptime },
            createSessionPollSleep: { _ in virtualUptime += 0.5 }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let result = try await store.createSession(
            projectPath: projectPath,
            sessionName: sessionName
        )

        XCTAssertEqual(snapshotRequestCount, 0)
        XCTAssertEqual(virtualUptime, 0, accuracy: 0.001)
        XCTAssertEqual(result.sessionId, requestedSessionId)
        XCTAssertNil(result.windowId)
        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(store.recentCreatedSessions.map(\.sessionId), [requestedSessionId])
        XCTAssertEqual(store.recentCreatedSessions.first?.status, "pending")
    }

    @MainActor
    func testPendingSessionReconcilesInBackgroundByTwentySecondsWithoutStreamActivity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewSessionMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let projectPath = "/Users/example/projects"
        let sessionName = "Puky reconciliada"
        var requestedSessionId: String?
        var snapshotRequestCount = 0
        var virtualUptime: TimeInterval = 0
        var didObserveResolvedSnapshot = false
        let resolvedSnapshot = expectation(description: "Background polling observes the created session")

        NewSessionMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path == "/api/mobile/sessions", request.httpMethod == "POST" {
                let body = try newSessionRequestBodyData(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                let sessionId = try XCTUnwrap(payload["sessionId"])
                requestedSessionId = sessionId
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-background-create","commandState":"accepted","inserted":true,"durable":true,"queuedAt":null,"projectPath":"\(projectPath)","projectName":"projects","sessionId":"\(sessionId)","sessionName":"\(sessionName)"}
                        """.utf8
                    )
                )
            }
            if url.path == "/api/mobile/sessions", request.httpMethod == "GET" {
                snapshotRequestCount += 1
                guard virtualUptime >= 20 else {
                    return (
                        response,
                        Data(#"{"ok":true,"now":1786825004173,"items":[]}"#.utf8)
                    )
                }
                let sessionId = try XCTUnwrap(requestedSessionId)
                if !didObserveResolvedSnapshot {
                    didObserveResolvedSnapshot = true
                    resolvedSnapshot.fulfill()
                }
                let summary = KycodeSessionSummary(
                    windowId: sessionId,
                    sessionId: sessionId,
                    engine: "codex",
                    model: "gpt-5.6-sol",
                    reasoningEffort: "max",
                    providerSessionId: sessionId,
                    providerSessionPath: nil,
                    projectKey: "projects",
                    projectPath: projectPath,
                    projectName: "projects",
                    windowName: sessionName,
                    displayName: sessionName,
                    sidecarMode: "relay",
                    sidecarUrl: nil,
                    activityStatus: "ready",
                    runtimeStatus: "WAITING",
                    runtimeStatusDetail: nil,
                    features: nil,
                    messageCount: 0,
                    updatedAt: 1_786_825_066_803,
                    createdAt: 1_786_825_066_803,
                    rawPrompt: nil,
                    originalPrompt: nil,
                    improvedPrompt: nil,
                    lastMessagePreview: nil,
                    isMinimized: false,
                    canSend: true,
                    canControlFeatures: true,
                    unsupportedReason: nil,
                    messages: nil
                )
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: 1_786_825_066_803,
                            exportedAt: nil,
                            items: [summary]
                        )
                    )
                )
            }
            throw URLError(.unsupportedURL)
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            createSessionConfirmationTimeout: 150,
            createSessionForegroundConfirmationTimeout: 0,
            createSessionPollNow: { virtualUptime },
            createSessionPollSleep: { delay in
                let components = delay.components
                virtualUptime += TimeInterval(components.seconds)
                    + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
                await Task.yield()
            }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let result = try await store.createSession(
            projectPath: projectPath,
            sessionName: sessionName
        )
        XCTAssertNil(result.windowId)
        XCTAssertEqual(result.status, "pending")

        await fulfillment(of: [resolvedSnapshot], timeout: 2)
        for _ in 0..<100 where store.sessions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(virtualUptime, 21, accuracy: 0.001)
        XCTAssertEqual(snapshotRequestCount, 8)
        XCTAssertTrue(store.recentCreatedSessions.isEmpty)
        XCTAssertEqual(store.sessions.map(\.sessionId), [requestedSessionId])
    }

    @MainActor
    func testPendingCreationKeepsItsContextVisibleAfterOneMinute() throws {
        let entry = KycodeRecentCreatedSession(
            sessionId: "persisted-pending",
            windowId: nil,
            projectPath: "/Users/example/projects",
            projectName: "projects",
            sessionName: "Auditar onboarding",
            profileId: "puky",
            createdAt: Date().addingTimeInterval(-60),
            status: "pending"
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode([entry]),
            forKey: "kycode.mobile.recentCreatedSessions"
        )

        let store = KycodeConnectionStore(
            initialProfileIdOverride: "puky",
            automaticallyReconcilesCreatedSessions: false
        )

        XCTAssertEqual(store.recentCreatedSessions, [entry])
        XCTAssertEqual(store.recentCreatedSessions.first?.sessionName, "Auditar onboarding")
        XCTAssertEqual(store.recentCreatedSessions.first?.profileId, "puky")
    }

    @MainActor
    func testInvalidNameAndCreationFailureStayVisibleToTheCaller() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewSessionMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var requestCount = 0
        NewSessionMockURLProtocol.handler = { request in
            requestCount += 1
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"ok":false,"error":"creation rejected"}"#.utf8))
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        do {
            _ = try await store.createSession(projectPath: "/tmp/projects", sessionName: "   ")
            XCTFail("Whitespace-only names must not create a session")
        } catch {
            XCTAssertEqual(error.localizedDescription, "El nombre no puede estar vacío.")
        }
        XCTAssertEqual(requestCount, 0)

        do {
            _ = try await store.createSession(projectPath: "/tmp/projects", sessionName: "Nombre válido")
            XCTFail("Server creation failures must be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, "creation rejected")
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testCreateSheetKeepsCancelLoadingAndErrorPathsWithoutFolderBrowsing() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootViewURL = projectRoot
            .appendingPathComponent("Sources/App/Views/KycodeRootView.swift")
        let source = try String(contentsOf: rootViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("TextField(\"Ej. Revisar el nuevo onboarding\""))
        XCTAssertTrue(source.contains("Button(\"Cancelar\")"))
        XCTAssertTrue(source.contains("if isCreating"))
        XCTAssertTrue(source.contains("errorText = error.localizedDescription"))
        XCTAssertFalse(source.contains("guard result.windowId != nil"))
        XCTAssertTrue(source.contains("guard !isLoading else { return }"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Nombre de la sesión\")"))
        XCTAssertTrue(source.contains("No pude resolver la carpeta predeterminada. Reintentá."))
        XCTAssertTrue(source.contains("projectPath: defaultProject.path"))
        XCTAssertTrue(source.contains("sessionName: sessionName"))
        XCTAssertTrue(source.contains("showCreateSessionTargetChooser = true"))
        XCTAssertTrue(source.contains("create-session-target-personal"))
        XCTAssertTrue(source.contains("create-session-target-puky"))
        XCTAssertFalse(source.contains("create-session-search"))
        XCTAssertFalse(source.contains("create-project-\\(project.name)"))
    }
}
