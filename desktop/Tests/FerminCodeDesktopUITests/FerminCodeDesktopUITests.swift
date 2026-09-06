import Darwin
import XCTest

@MainActor
final class FerminCodeDesktopUITests: XCTestCase, @unchecked Sendable {
    private var app: XCUIApplication!
    private var liveRecords: [LiveSessionRecord] = []
    private var isRunningLiveTest = false

    private func prepareTest(live: Bool = false) {
        continueAfterFailure = false
        app = XCUIApplication()
        isRunningLiveTest = live
        addTeardownBlock { [weak self] in
            await self?.finishTest()
        }
    }

    private func finishTest() {
        if isRunningLiveTest {
            let unresolved = cleanupSubmittedSessions()
            if !unresolved.isEmpty {
                attachRecoveryEvidence(
                    app: app,
                    records: unresolved,
                    reason: "UI-only teardown could not prove archival"
                )
            }
        }
        app?.terminate()
        app = nil
        liveRecords = []
        isRunningLiveTest = false
    }

    func testSmokeBrandingAndSourceSelector() throws {
        prepareTest()
        launchApp()

        _ = try requireElement(DesktopAX.root, in: app, timeout: 20)
        let brand = try requireElement(DesktopAX.brand, in: app)
        XCTAssertTrue(
            stringValue(of: brand)
                .folding(options: .diacriticInsensitive, locale: .current)
                .contains("FERMIN CODE")
        )

        _ = try requireElement(DesktopAX.profileSelector, in: app)
        for identifier in [DesktopAX.personalProfile, DesktopAX.pukyProfile, DesktopAX.todoProfile] {
            let profile = try requireEnabled(identifier, in: app)
            profile.click()
        }

        let newSession = try requireElement(DesktopAX.newSession, in: app)
        XCTAssertFalse(newSession.isEnabled, "Todo must not create an ambiguously routed session.")
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    func testSmokeEmptyCredentialsFixture() throws {
        prepareTest()
        app.launchArguments.append("--fermin-ui-empty-credentials")
        launchApp()

        _ = try requireElement(DesktopAX.root, in: app, timeout: 20)
        _ = try requireElement(DesktopAX.emptyCredentials, in: app, timeout: 20)
        for source in LiveRelaySource.allCases {
            let badge = try requireElement(DesktopAX.connection(source), in: app)
            let status = stringValue(of: badge).lowercased()
            XCTAssertTrue(
                status.contains("missing-credential") || status.contains("falta token"),
                "Expected a missing credential status for \(source.displayName), got: \(status)"
            )
        }
    }

    // Opt-in, loopback-only handoff checks. Run against a disposable .qa app
    // and relay; these deliberately leave the conversation for the other client.
    private func prepareLocalHandoff() throws -> LiveSessionRecord {
        let environment = ProcessInfo.processInfo.environment
        guard let relayURL = environment["FERMIN_LOCAL_RELAY_URL"],
              let url = URL(string: relayURL), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              let appID = environment["FERMIN_LOCAL_APP_ID"], appID.hasSuffix(".qa") else {
            throw XCTSkip("Local handoff requires an explicit loopback relay and a separate .qa app.")
        }
        prepareTest()
        app = XCUIApplication(bundleIdentifier: appID)
        app.launchEnvironment["FERMIN_CODE_PRIMARY_RELAY_URL"] = relayURL
        app.launchEnvironment["FERMIN_CODE_SECONDARY_RELAY_URL"] = relayURL
        launchApp()
        try selectProfile(DesktopAX.personalProfile)
        let badge = try requireElement(DesktopAX.connection(.personal), in: app)
        XCTAssertTrue(waitUntil(timeout: 30) {
            let status = self.stringValue(of: badge).lowercased()
            return status.contains("online") || status.contains("conectado")
        })
        return LiveSessionRecord(
            source: .personal,
            name: environment["FERMIN_LOCAL_SESSION_NAME"] ?? "QA Handoff",
            marker: "DESKTOP_HANDOFF_OK"
        )
    }

    func testLocalRelayStartsHandoff() throws {
        let record = try prepareLocalHandoff()
        try createSession(record)
        try sendAndSettle(record)
        attachLocalHandoffEvidence("desktop-handoff-start")
    }

    func testLocalRelayContinuesMobileHandoff() throws {
        let record = try prepareLocalHandoff()
        try setSearch(record.name)
        let row = try XCTUnwrap(waitForSessionRow(
            named: record.name, source: .personal, in: app, timeout: 30
        ))
        row.click()
        XCTAssertTrue(exactLabel("MOBILE_HANDOFF_OK", in: app).waitForExistence(timeout: 30))
        let returnRecord = LiveSessionRecord(
            source: .personal, name: record.name, marker: "DESKTOP_RETURN_OK"
        )
        try sendAndSettle(returnRecord)
        app.terminate()
        launchApp()
        XCTAssertTrue(exactLabel("DESKTOP_RETURN_OK", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
        attachLocalHandoffEvidence("desktop-handoff-return")
    }

    private func attachLocalHandoffEvidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    func testCaptureRepositoryScreenshots() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["FERMIN_REPOSITORY_SCREENSHOT_DIR"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set FERMIN_REPOSITORY_SCREENSHOT_DIR to capture repository screenshots.")
        }

        prepareTest()
        launchApp()

        _ = try requireElement(DesktopAX.root, in: app, timeout: 30)
        _ = waitUntil(timeout: 20) {
            self.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fermin.desktop.session.row."))
                .count > 0
        }
        try writeRepositoryScreenshot(named: "desktop-main", to: outputPath)

        let history = try requireEnabled("fermin.desktop.history.open", in: app, timeout: 20)
        history.click()
        _ = try requireElement("fermin.desktop.history.sheet", in: app, timeout: 30)
        try writeRepositoryScreenshot(named: "desktop-history", to: outputPath)
    }

    func testLiveProductionPersonalAndPuky() throws {
        try XCTSkipUnless(
            Self.liveAuthorizationIsPresent,
            "Run Scripts/run-desktop-live-ui.sh to authorize this destructive production test."
        )
        prepareTest(live: true)
        liveRecords = makeLiveRecords()
        launchApp()

        _ = try requireElement(DesktopAX.root, in: app, timeout: 30)
        try requireBothRelaysConnected()
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)

        for record in liveRecords {
            try createSession(record)
            try sendAndSettle(record)
        }

        try selectProfile(DesktopAX.todoProfile)
        for record in liveRecords {
            try verifySessionInTodo(record)
        }

        for record in liveRecords {
            try archiveSession(record, timeout: 150)
        }

        try selectProfile(DesktopAX.todoProfile)
        for record in liveRecords {
            try setSearch(record.name)
            XCTAssertNil(
                waitForSessionRow(
                    named: record.name,
                    source: record.source,
                    in: app,
                    timeout: 5
                ),
                "Archived QA session is still visible: \(record.manifestLine)"
            )
        }
        try setSearch("")
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    private static var liveAuthorizationIsPresent: Bool {
        let authorization = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/.fermin-code-live-ui-authorized")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authorization.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let contents = try? String(contentsOf: authorization, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private func launchApp() {
        app.launch()
        app.activate()
    }

    private func writeRepositoryScreenshot(named name: String, to directoryPath: String) throws {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try app.screenshot().pngRepresentation.write(
            to: directory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }

    private func makeLiveRecords() -> [LiveSessionRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let runID = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).uppercased())"
        return [
            LiveSessionRecord(
                source: .personal,
                name: "QA Desktop Personal \(runID)",
                marker: "FERMIN_DESKTOP_PERSONAL_\(runID)"
            ),
            LiveSessionRecord(
                source: .puky,
                name: "QA Desktop Puky \(runID)",
                marker: "FERMIN_DESKTOP_PUKY_\(runID)"
            ),
        ]
    }

    private func requireBothRelaysConnected() throws {
        for source in LiveRelaySource.allCases {
            let badge = try requireElement(DesktopAX.connection(source), in: app, timeout: 30)
            guard waitUntil(timeout: 60, condition: {
                let status = self.stringValue(of: badge).lowercased()
                return status.contains("online") || status.contains("conectado")
            }) else {
                throw DesktopUIHarnessError.timedOut(
                    "\(source.displayName) conectado; estado final: \(stringValue(of: badge))"
                )
            }
        }
    }

    private func selectProfile(_ identifier: String) throws {
        let profile = try requireEnabled(identifier, in: app)
        profile.click()
        _ = waitUntil(timeout: 2) { self.element(identifier, in: self.app).exists }
    }

    private func createSession(_ record: LiveSessionRecord) throws {
        try selectProfile(DesktopAX.profile(record.source))
        let connection = try requireElement(DesktopAX.connection(record.source), in: app)
        let status = stringValue(of: connection).lowercased()
        guard status.contains("online") || status.contains("conectado") else {
            throw DesktopUIHarnessError.unexpectedError(
                "\(record.source.displayName) dejó de estar conectado: \(status)"
            )
        }

        let newSession = try requireEnabled(DesktopAX.newSession, in: app, timeout: 30)
        newSession.click()
        _ = try requireElement(DesktopAX.createSheet, in: app, timeout: 30)
        _ = try requireElement(DesktopAX.createProject, in: app, timeout: 30)
        let nameField = try requireEnabled(DesktopAX.createName, in: app, timeout: 30)
        replaceText(in: nameField, with: record.name)

        let confirm = try requireEnabled(DesktopAX.createConfirm, in: app, timeout: 45)
        record.creationSubmitted = true
        confirm.click()

        guard waitUntil(timeout: 180, condition: {
            !self.element(DesktopAX.createSheet, in: self.app).exists
        }) else {
            throw DesktopUIHarnessError.timedOut(
                "crear \(record.name) en \(record.source.displayName) dentro de 180 segundos"
            )
        }
        guard let row = waitForSessionRow(
            named: record.name,
            source: record.source,
            in: app,
            timeout: 30
        ) else {
            throw DesktopUIHarnessError.missingElement(
                "fila de \(record.name) en \(record.source.displayName)"
            )
        }
        record.rowAccessibilityIdentifier = row.identifier.isEmpty ? nil : row.identifier
        _ = try requireElement(DesktopAX.transcript, in: app, timeout: 30)
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    private func sendAndSettle(_ record: LiveSessionRecord) throws {
        let composer = try requireElement(DesktopAX.composerText, in: app, timeout: 30)
        let prompt = "Reply with exactly this marker and nothing else: \(record.marker)"
        replaceText(in: composer, with: prompt)
        guard waitUntil(timeout: 15, condition: {
            self.stringValue(of: composer).contains(record.marker)
        }) else {
            throw DesktopUIHarnessError.timedOut(
                "editor editable para \(record.name)"
            )
        }
        let send = try requireEnabled(DesktopAX.composerSend, in: app, timeout: 60)
        send.click()

        let marker = exactLabel(record.marker, in: app)
        guard marker.waitForExistence(timeout: 180) else {
            throw DesktopUIHarnessError.timedOut(
                "respuesta exacta \(record.marker) en \(record.source.displayName)"
            )
        }
        guard waitForSettledState(marker: marker, timeout: 60) else {
            throw DesktopUIHarnessError.timedOut(
                "sesión \(record.name) estable después de responder"
            )
        }
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    private func waitForSettledState(marker: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        while Date() < deadline {
            let selectedSession = element(DesktopAX.selectedSession, in: app)
            let activity = stringValue(of: selectedSession).lowercased()
            let activityIsBusy = activity.contains("working")
                || activity.contains("processing")
                || activity.contains("sending")
                || activity.contains("creating")
            let settled = marker.exists
                && selectedSession.exists
                && !activityIsBusy
                && !element(DesktopAX.pendingCommand, in: app).exists
                && !element(DesktopAX.error, in: app).exists
            if settled {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= 2 { return true }
            } else {
                stableSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func verifySessionInTodo(_ record: LiveSessionRecord) throws {
        try setSearch(record.name)
        guard let row = waitForSessionRow(
            named: record.name,
            source: record.source,
            in: app,
            timeout: 30
        ) else {
            throw DesktopUIHarnessError.missingElement(
                "\(record.name) agregado en Todo"
            )
        }
        record.rowAccessibilityIdentifier = row.identifier.isEmpty
            ? record.rowAccessibilityIdentifier
            : row.identifier
        row.click()
        _ = try requireElement(DesktopAX.transcript, in: app, timeout: 30)
        guard exactLabel(record.marker, in: app).waitForExistence(timeout: 90) else {
            throw DesktopUIHarnessError.timedOut(
                "marker \(record.marker) al abrir desde Todo"
            )
        }

        let otherMarkers = liveRecords
            .filter { $0 !== record }
            .map(\.marker)
        for otherMarker in otherMarkers {
            XCTAssertFalse(
                exactLabel(otherMarker, in: app).exists,
                "Todo mixed \(otherMarker) into \(record.name)."
            )
        }
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    private func archiveSession(_ record: LiveSessionRecord, timeout: TimeInterval) throws {
        try selectProfile(DesktopAX.todoProfile)
        try setSearch(record.name)
        guard let row = waitForSessionRow(
            named: record.name,
            source: record.source,
            in: app,
            timeout: 30
        ) else {
            throw DesktopUIHarnessError.missingElement(
                "\(record.name) antes de archivar"
            )
        }
        record.rowAccessibilityIdentifier = row.identifier.isEmpty
            ? record.rowAccessibilityIdentifier
            : row.identifier
        row.click()

        let more = try requireEnabled(DesktopAX.sessionMore, in: app, timeout: 30)
        more.click()
        let archive = try archiveControl()
        archive.click()
        let confirm = try archiveConfirmationControl()
        confirm.click()

        guard waitUntil(timeout: timeout, condition: {
            self.existingSessionRow(
                named: record.name,
                source: record.source,
                in: self.app
            ) == nil
        }) else {
            throw DesktopUIHarnessError.timedOut("archivar \(record.name)")
        }
        record.archived = true
        XCTAssertFalse(element(DesktopAX.error, in: app).exists)
    }

    private func archiveControl() throws -> XCUIElement {
        let identified = element(DesktopAX.sessionArchive, in: app)
        if identified.waitForExistence(timeout: 10) { return identified }
        let fallback = app.menuItems["Archivar…"]
        guard fallback.waitForExistence(timeout: 5) else {
            throw DesktopUIHarnessError.missingElement(DesktopAX.sessionArchive)
        }
        return fallback
    }

    private func archiveConfirmationControl() throws -> XCUIElement {
        let identified = element(DesktopAX.archiveConfirm, in: app)
        if identified.waitForExistence(timeout: 10) { return identified }
        let fallback = app.buttons["Archivar"]
        guard fallback.waitForExistence(timeout: 5) else {
            throw DesktopUIHarnessError.missingElement(DesktopAX.archiveConfirm)
        }
        return fallback
    }

    private func setSearch(_ text: String) throws {
        let search = try requireEnabled(DesktopAX.sessionSearch, in: app, timeout: 20)
        replaceText(in: search, with: text)
    }

    private func cleanupSubmittedSessions() -> [LiveSessionRecord] {
        let submitted = liveRecords.filter { $0.creationSubmitted && !$0.archived }
        guard !submitted.isEmpty else { return [] }
        if app.state == .notRunning {
            app.launch()
        } else {
            app.activate()
        }
        dismissPresentedUI()
        _ = try? selectProfile(DesktopAX.todoProfile)

        for record in submitted {
            dismissPresentedUI()
            guard (try? setSearch(record.name)) != nil else { continue }
            if waitForSessionRow(
                named: record.name,
                source: record.source,
                in: app,
                timeout: 60
            ) == nil {
                if let refresh = try? requireEnabled("fermin.desktop.session.refresh", in: app, timeout: 5) {
                    refresh.click()
                }
            }
            if waitForSessionRow(
                named: record.name,
                source: record.source,
                in: app,
                timeout: 30
            ) != nil {
                _ = try? archiveSession(record, timeout: 90)
            }
        }
        _ = try? setSearch("")
        return submitted.filter { !$0.archived }
    }

    private func dismissPresentedUI() {
        guard app.state != .notRunning else { return }
        for _ in 0..<3 {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }
}
