import AppKit
import Foundation
import FerminCore
import SwiftUI
import XCTest
@testable import FerminMac

final class FerminCodeDesktopPreferencesTests: XCTestCase {
    func testProfilePersistsAndRestores() throws {
        let suiteName = "FerminCodeDesktopPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(FerminCodeDesktopPreferences.profile(from: defaults), .todo)
        FerminCodeDesktopPreferences.saveProfile(.puky, to: defaults)
        XCTAssertEqual(FerminCodeDesktopPreferences.profile(from: defaults), .puky)
    }
}

@MainActor
final class FerminCodeDesktopStoreTests: XCTestCase {
    func testPinnedStateSynchronizesThroughDesktopCommandsAndRemoteUpserts() async throws {
        func session(pinned: Bool, updatedAt: Double) -> FerminRelaySession {
            FerminRelaySession(
                windowID: "sync-window",
                sessionID: "sync-session",
                engine: "codex",
                projectPath: "/Users/test/projects/fermin-code",
                displayName: "Sesión sincronizada",
                activityStatus: "ready",
                updatedAt: updatedAt,
                isPinned: pinned,
                canSend: true
            )
        }

        let fixture = try makeFixture(initialSnapshotItems: [session(pinned: true, updatedAt: 1)])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }

        let initial = try XCTUnwrap(fixture.store.sourcedSessions.first)
        XCTAssertTrue(fixture.store.isSessionPinned(initial))

        fixture.store.setSessionPinned(initial, pinned: false)
        XCTAssertEqual(fixture.store.unpinnedSessions.map(\.session.windowID), ["sync-window"])
        try await waitUntilAsync { await fixture.relay.pinnedStateChanges() == [false] }
        await fixture.relay.emitStreamEvent(.sessionUpserted(session(pinned: false, updatedAt: 2)))
        try await waitUntil { fixture.store.unpinnedSessions.count == 1 }

        await fixture.relay.emitStreamEvent(.sessionUpserted(session(pinned: true, updatedAt: 3)))
        try await waitUntil { fixture.store.pinnedSessions.count == 1 }
        await fixture.relay.emitStreamEvent(.sessionUpserted(session(pinned: false, updatedAt: 4)))
        try await waitUntil { fixture.store.unpinnedSessions.count == 1 }

        let remotelyUnpinned = try XCTUnwrap(fixture.store.sourcedSessions.first)
        fixture.store.setSessionPinned(remotelyUnpinned, pinned: true)
        try await waitUntilAsync { await fixture.relay.pinnedStateChanges() == [false, true] }
        try await waitUntil { fixture.store.pinnedSessions.count == 1 }

        await fixture.relay.emitStreamEvent(.sessionUpserted(session(pinned: false, updatedAt: 5)))
        try await waitUntil { fixture.store.unpinnedSessions.count == 1 }
    }

    func testCreationStaysUnavailableUntilInitialBootstrapFinishes() async throws {
        let fixture = try makeFixture(refreshDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }

        XCTAssertTrue(fixture.store.isBootstrapping)
        XCTAssertFalse(fixture.store.canCreateSession)

        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        XCTAssertTrue(fixture.store.credentialPresence[.personal] == true)
        XCTAssertTrue(fixture.store.canCreateSession)
    }

    func testTodoCanCreateOnAnExplicitAvailableSource() async throws {
        let fixture = try makeFixture(profile: .todo, pukyToken: "test-puky-token")
        defer { fixture.store.stop() }

        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        XCTAssertTrue(fixture.store.canCreateSession)
        XCTAssertEqual(fixture.store.availableCreateSources, [.personal, .puky])
        await fixture.store.loadProjects(source: .puky)
        let created = await fixture.store.createSession(
            projectPath: "/Users/test/projects/fermin-code",
            name: "Creada desde Todo",
            source: .puky
        )

        let createdSources = await fixture.relay.createdSessionSources()
        let projectSources = await fixture.relay.projectSources()
        XCTAssertTrue(created)
        XCTAssertEqual(createdSources, [.puky])
        XCTAssertEqual(projectSources, [.puky])
        XCTAssertEqual(fixture.store.selectedRoute?.source, .puky)
    }

    func testPermanentDeleteRemainsAbsentAfterAuthoritativeReload() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        await fixture.store.deleteSelectedSessionPermanently()

        let deletedWindowIDs = await fixture.relay.permanentlyDeletedWindowIDs()
        XCTAssertEqual(deletedWindowIDs, ["base-window"])
        XCTAssertNil(fixture.store.selectedRoute)
        XCTAssertFalse(
            fixture.store.sourcedSessions.contains { $0.session.windowID == "base-window" }
        )

        await fixture.store.refreshAll()
        XCTAssertFalse(
            fixture.store.sourcedSessions.contains { $0.session.windowID == "base-window" }
        )
    }

    func testCreationShowsHonestPhasesAndRejectsADuplicateSubmission() async throws {
        let fixture = try makeFixture(
            refreshDelayNanoseconds: 40_000_000,
            createDelayNanoseconds: 40_000_000
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let firstCreation = Task {
            await fixture.store.createSession(
                projectPath: "/Users/test/projects/fermin-code",
                name: "Creación medida"
            )
        }
        try await waitUntil { fixture.store.creationPhase == .submitting }

        let duplicate = await fixture.store.createSession(
            projectPath: "/Users/test/projects/fermin-code",
            name: "Duplicada"
        )
        XCTAssertFalse(duplicate)

        try await waitUntil { fixture.store.creationPhase == .waitingForConfirmation }
        let created = await firstCreation.value

        XCTAssertTrue(created)
        XCTAssertEqual(fixture.store.creationPhase, .idle)
        XCTAssertFalse(fixture.store.isCreatingSession)
        let createRequests = await fixture.relay.createRequests()
        XCTAssertEqual(createRequests, 1)
    }

    func testCreateSheetRendersAtIdleDesignState() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        await fixture.store.loadProjects()
        XCTAssertEqual(fixture.store.creationPhase, .idle)

        let size = NSSize(width: 520, height: 348)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopCreateSessionView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_CREATE_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testSidebarRendersOngoingSessionCreation() async throws {
        let fixture = try makeFixture(createDelayNanoseconds: 350_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let creation = Task {
            await fixture.store.createSession(
                projectPath: "/Users/test/projects/fermin-code",
                name: "Creación en segundo plano"
            )
        }
        try await waitUntil { fixture.store.creationPhase == .submitting }

        let size = NSSize(width: 340, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopSidebar()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SIDEBAR_CREATING_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        let created = await creation.value
        XCTAssertTrue(created)
    }

    func testSidebarRendersWaitingForSessionConfirmation() async throws {
        let fixture = try makeFixture(
            slowCreatePolls: 3,
            refreshDelayNanoseconds: 60_000_000
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let creation = Task {
            await fixture.store.createSession(
                projectPath: "/Users/test/projects/fermin-code",
                name: "Confirmación visual"
            )
        }
        try await waitUntil {
            fixture.store.creationPhase == .waitingForConfirmation
        }

        let size = NSSize(width: 340, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopSidebar()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SIDEBAR_WAITING_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        let created = await creation.value
        XCTAssertTrue(created)
    }

    func testCredentialsSheetRendersAtItsFixedSize() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        await fixture.store.loadPromptPreferences()

        let size = NSSize(width: 660, height: 590)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopCredentialsView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_CREDENTIALS_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testHistorySheetRendersWithResults() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        await fixture.store.loadHistory()

        let size = NSSize(width: 780, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopHistoryView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_HISTORY_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testHistorySheetRendersRetryableFailureInsteadOfEmpty() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.selectProfile(.puky)
        await fixture.store.loadHistory()
        XCTAssertNotNil(fixture.store.historyLoadState.failureMessage)

        let size = NSSize(width: 780, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopHistoryView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_HISTORY_FAILURE_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testSubagentSheetRendersWithStructuredTaskFields() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.subagentDisplayNameDraft = "Auditor de accesibilidad"
        fixture.store.subagentTaskDraft = "Revisá el flujo de envío y documentá los casos borde."

        let size = NSSize(width: 520, height: 470)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopSubagentView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SUBAGENT_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testStalledPromptImproverRendersAVisibleRecoveryAction() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "stalled-prompt",
            role: "user",
            content: "Prepará una revisión completa de esta interfaz.",
            timestamp: Date().timeIntervalSince1970 - 120,
            status: "completed",
            transformStatus: "processing"
        )
        let size = NSSize(width: 640, height: 150)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_PROMPT_STALLED_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testMessageRowEquatableBoundaryOnlyInvalidatesRenderedState() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let timestamp = Date().timeIntervalSince1970
        let message = FerminRelayMessage(
            id: "stable-row",
            role: "assistant",
            content: "Contenido estable",
            timestamp: timestamp,
            status: "completed"
        )
        let item = FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
        let baseline = FerminCodeDesktopMessageRow(store: fixture.store, item: item)

        XCTAssertEqual(
            baseline,
            FerminCodeDesktopMessageRow(store: fixture.store, item: item),
            "Cambios ajenos al transcript no deben reconstruir una fila estable"
        )
        XCTAssertNotEqual(
            baseline,
            FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: item,
                isRetryingPromptTransform: true
            )
        )
        XCTAssertNotEqual(
            baseline,
            FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(
                    message: FerminRelayMessage(
                        id: "stable-row",
                        role: "assistant",
                        content: "Contenido actualizado",
                        timestamp: timestamp,
                        status: "completed"
                    ),
                    delivery: nil
                )
            )
        )
    }

    func testPendingPromptImproverRendersAsCurrentMessageWork() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "pending-prompt",
            role: "user",
            content: "Prepará una revisión completa de esta interfaz.",
            timestamp: Date().timeIntervalSince1970,
            status: "completed",
            transformStatus: "pending"
        )
        let size = NSSize(width: 640, height: 150)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_PROMPT_PENDING_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testFailedPromptImproverRendersHumanRecoveryCopy() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "failed-prompt",
            role: "user",
            content: "Prepará una revisión completa de esta interfaz.",
            timestamp: Date().timeIntervalSince1970,
            status: "completed",
            transformStatus: "error",
            transformErrorReason: "observer_error"
        )
        let size = NSSize(width: 640, height: 150)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_PROMPT_FAILED_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testMessageRowRendersCodeAsASeparateReadableBlock() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "markdown-code",
            role: "assistant",
            content: """
            ## Implementación

            - Copiá el ejemplo.
            - Verificá el resultado.

            ```swift
            let response = await client.send(requestWithANameThatMustNotWrap)
            print(response)
            ```

            El bloque se puede desplazar y copiar sin perder la respuesta completa.
            """,
            timestamp: Date().timeIntervalSince1970,
            status: "completed"
        )
        let size = NSSize(width: 620, height: 390)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_MARKDOWN_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testMessageRowRendersMarkdownTableWithReadableHeaders() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "markdown-table",
            role: "assistant",
            content: """
            ## Comparación

            | Modelo | Razonamiento | Uso sugerido |
            |---|---|---|
            | **SOL** | High | Trabajo cotidiano |
            | **SOL** | Max | Problemas complejos con más contexto |
            """,
            timestamp: Date().timeIntervalSince1970,
            status: "completed"
        )
        let size = NSSize(width: 420, height: 250)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 7_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_TABLE_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testMessageRowReflowsLinksAtCompactWidth() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "markdown-links",
            role: "assistant",
            content: """
            Revisá la [guía de accesibilidad](https://developer.apple.com/design/human-interface-guidelines/accessibility) antes de publicar.

            URL directa: https://example.com/\(String(repeating: "segmento-muy-largo", count: 7))
            """,
            timestamp: Date().timeIntervalSince1970,
            status: "completed"
        )
        let size = NSSize(width: 360, height: 230)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(message: message, delivery: nil)
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 6_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_LINKS_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testStreamingMessageRendersAnUnclosedCodeFenceWithoutRawMarkers() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let message = FerminRelayMessage(
            id: "streaming-code",
            role: "assistant",
            content: """
            Voy preparando el ejemplo:

            ```swift
            let partial = await client.load()
            """,
            timestamp: Date().timeIntervalSince1970,
            status: "streaming"
        )
        let size = NSSize(width: 620, height: 250)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageRow(
                store: fixture.store,
                item: FerminCodeDesktopPresentedMessage(
                    message: message,
                    delivery: nil,
                    isStreaming: true
                )
            )
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 6_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_STREAMING_CODE_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testRenameSheetRendersAsASingleFocusedTask() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let size = NSSize(width: 430, height: 235)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRenameView(
                currentName: "Sesión base",
                isPresented: .constant(true)
            )
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_RENAME_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testRenameSheetRendersADismissibleInlineError() throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.errorMessage = "No se pudo guardar el nombre. Revisá la conexión e intentá otra vez."
        let size = NSSize(width: 430, height: 283)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRenameView(
                currentName: "Sesión base",
                isPresented: .constant(true)
            )
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 6_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_RENAME_ERROR_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testComposerRendersLongTextAndAttachmentActionsAtCompactWidth() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        await fixture.store.setFeatures(promptImprover: true)
        XCTAssertTrue(fixture.store.selectedFeatures.promptImproverEnabled)
        fixture.store.composerText = Array(
            repeating: "Revisá cada caso borde, conservá el contexto y explicá la decisión.",
            count: 8
        ).joined(separator: "\n")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (1...3).map { index in
            let url = directory.appendingPathComponent("captura-\(index).png")
            var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            data.append(Data(repeating: UInt8(index), count: 1_024 * index))
            try data.write(to: url)
            return url
        }
        await fixture.store.addAttachments(from: urls)
        XCTAssertEqual(fixture.store.attachments.count, 3)

        let size = NSSize(width: 650, height: 220)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopComposer()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_COMPOSER_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testComposerKeepsTenLongAttachmentNamesInACompactWrappingGrid() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (1...10).map { index in
            let url = directory.appendingPathComponent(
                "captura-de-interfaz-con-nombre-muy-largo-\(index).png"
            )
            var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            data.append(Data(repeating: UInt8(index), count: 1_024 * index))
            try data.write(to: url)
            return url
        }
        await fixture.store.addAttachments(from: urls)
        XCTAssertEqual(fixture.store.attachments.count, 10)
        let firstAttachmentID = try XCTUnwrap(fixture.store.attachments.first?.id)

        let size = NSSize(width: 650, height: 220)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopComposer()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_MAX_ATTACHMENTS_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        fixture.store.removeAttachment(id: firstAttachmentID)
        XCTAssertEqual(fixture.store.attachments.count, 9)
        XCTAssertEqual(
            FerminCodeDesktopAttachmentPolicy.remainingCount(
                existingCount: fixture.store.attachments.count
            ),
            1
        )
    }

    func testComposerRendersAnEditableNextDraftWhileSending() async throws {
        let fixture = try makeFixture(sendDelayNanoseconds: 350_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = "Revisá este cambio y confirmá el resultado."

        let sending = Task { await fixture.store.sendComposer() }
        try await waitUntil { fixture.store.isSending }
        XCTAssertTrue(fixture.store.composerText.isEmpty)
        let selected = try XCTUnwrap(fixture.store.selectedSession)
        let route = try XCTUnwrap(fixture.store.selectedRoute)
        XCTAssertEqual(
            fixture.store.effectiveActivityStatus(for: selected, route: route),
            "processing"
        )

        let size = NSSize(width: 650, height: 180)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopComposer()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 6_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SENDING_COMPOSER_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        let sent = await sending.value
        XCTAssertTrue(sent)
        XCTAssertEqual(
            fixture.store.effectiveActivityStatus(for: selected, route: route),
            selected.activityStatus
        )
    }

    func testComposerRendersGuidanceForAWhitespaceOnlyDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = "  \n\t  "

        let size = NSSize(width: 650, height: 180)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopComposer()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertEqual(fixture.store.composerText, "  \n\t  ")
        XCTAssertGreaterThan(png.count, 6_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_WHITESPACE_COMPOSER_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testComposerRejectsAndRendersAnOversizedDraftBeforeTransport() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = String(
            repeating: "a",
            count: FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes + 1
        )

        XCTAssertFalse(fixture.store.canSend)
        let sent = await fixture.store.sendComposer()
        XCTAssertFalse(sent)
        XCTAssertEqual(
            fixture.store.composerText.utf8.count,
            FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes + 1
        )
        let sentMessageCount = await fixture.relay.sentMessageCount()
        XCTAssertEqual(sentMessageCount, 0)

        let size = NSSize(width: 720, height: 260)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopComposer()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_OVERSIZED_COMPOSER_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testDesktopRootRendersAtDesignWindowSize() async throws {
        let messages = [
            FerminRelayMessage(
                id: "design-user",
                role: "user",
                content: "Ordená el transcript por timestamp antes de recortar la ventana reciente.",
                originalPrompt: "Ordená el transcript por timestamp.",
                transformedPrompt: "Ordená el transcript por timestamp antes de recortar la ventana reciente.",
                timestamp: 100,
                status: "completed"
            ),
            FerminRelayMessage(
                id: "design-assistant",
                role: "assistant",
                content: "Listo. El orden ahora se resuelve antes de recortar.\n\n```swift\nmessages.sorted { $0.timestamp < $1.timestamp }\n```\n\nEl ACK atrasado ya no altera el final visible.",
                timestamp: 101,
                status: "completed"
            ),
        ]
        let selected = makeDetailSession(
            windowID: "design-main",
            sessionID: "design-main-session",
            displayName: "Continuar Fermín Code",
            activityStatus: "working",
            messages: messages,
            features: FerminRelaySessionFeatures(promptImproverEnabled: true)
        )
        let rows = [
            selected,
            makeDetailSession(windowID: "design-two", sessionID: "design-two-session", displayName: "Relay Puky · reconexión", activityStatus: "working", messages: []),
            makeDetailSession(windowID: "design-three", sessionID: "design-three-session", displayName: "Audio: cola y recuperación", messages: []),
            makeDetailSession(windowID: "design-four", sessionID: "design-four-session", displayName: "Paridad Desktop", activityStatus: "idle", messages: []),
            makeDetailSession(windowID: "design-five", sessionID: "design-five-session", displayName: "Notas de release", messages: []),
        ]
        let fixture = try makeFixture(
            initialSnapshotItems: rows,
            sendShouldFail: true,
            detailResponseItems: [selected]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { fixture.store.sourcedSessions.count == rows.count }
        fixture.store.selectSession(
            try XCTUnwrap(
                fixture.store.sourcedSessions.first {
                    $0.session.windowID == selected.windowID
                }
            )
        )
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        try await waitUntil { !fixture.store.isLoadingModels }
        fixture.store.composerText =
            "Agregá el test del ACK atrasado y corré la suite completa antes de tocar la UI."
        let designSendSucceeded = await fixture.store.sendComposer()
        XCTAssertFalse(designSendSucceeded)
        XCTAssertNotNil(fixture.store.composerSendErrorMessage)
        if let searchText = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SNAPSHOT_SEARCH_TEXT"
        ] {
            fixture.store.searchText = searchText
        }

        let size = NSSize(width: 1440, height: 900)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRootView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        XCTAssertEqual(
            Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh),
            size.width / size.height,
            accuracy: 0.001
        )

        if let path = ProcessInfo.processInfo.environment["FERMIN_DESKTOP_SNAPSHOT_PATH"],
           !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testDesktopRootRendersALongDismissibleErrorAtMinimumWidth() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.errorMessage =
            "No se pudo actualizar la sesión porque la conexión se interrumpió. El borrador sigue intacto; revisá el estado de Personal e intentá nuevamente cuando vuelva a estar disponible."

        let size = NSSize(width: 920, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRootView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 10_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_LONG_ERROR_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testSidebarRowRendersLongContentWithoutDisplacingMetadata() throws {
        let item = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "long-window",
                sessionID: "long-session",
                projectPath: "/Users/test/projects/cliente-con-un-nombre-muy-largo/fermin-code",
                projectName: "cliente-con-un-nombre-muy-largo-fermin-code",
                displayName: "Revisión integral de accesibilidad · entrega definitiva",
                activityStatus: "working",
                updatedAt: Date().timeIntervalSince1970,
                lastMessagePreview:
                    "Analizando los casos borde del compositor y la navegación entre sesiones.",
                canSend: false
            )
        )
        let size = NSSize(width: 320, height: 112)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopSessionRow(
                item: item,
                selected: true,
                showsSource: true
            )
            .frame(width: size.width, height: size.height)
            .background(FerminCodeDesktopPalette.sidebar)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 5_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_SIDEBAR_ROW_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testRuntimeControlsRenderAsACompactAlignedPair() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingModels }
        await fixture.store.setGoalMode(true)
        XCTAssertTrue(fixture.store.selectedGoalModeEnabled)

        let session = try XCTUnwrap(fixture.store.selectedSession)
        let size = NSSize(width: 150, height: 52)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRuntimeControls(session: session)
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 3_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_RUNTIME_CONTROLS_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testRuntimeControlsRenderWhileGoalModeIsSyncing() async throws {
        let fixture = try makeFixture(goalMutationDelayNanoseconds: 350_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingModels }

        let update = Task { await fixture.store.setGoalMode(true) }
        try await waitUntil { fixture.store.isUpdatingSelectedGoalMode }

        let session = try XCTUnwrap(fixture.store.selectedSession)
        let size = NSSize(width: 150, height: 52)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopRuntimeControls(session: session)
                .environmentObject(fixture.store)
                .padding(12)
                .frame(width: size.width, height: size.height)
                .background(FerminCodeDesktopPalette.canvas)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 3_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_RUNTIME_CONTROLS_BUSY_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        await update.value
    }

    func testSendAlwaysCarriesExplicitStandardMode() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }
        let session = try XCTUnwrap(fixture.store.sourcedSessions.first)
        fixture.store.selectProfile(.personal)
        fixture.store.selectSession(session)
        try await waitUntil { fixture.store.selectedSession?.windowID == session.session.windowID }

        fixture.store.composerText = "primer mensaje"
        let firstSent = await fixture.store.sendComposer()
        XCTAssertTrue(firstSent)

        fixture.store.composerText = "segundo mensaje"
        let secondSent = await fixture.store.sendComposer()
        XCTAssertTrue(secondSent)

        let modes = await fixture.relay.sentFastModes()
        XCTAssertEqual(modes, [false, false])
    }

    func testProfileCannotChangeWhileAMessageIsSending() async throws {
        let fixture = try makeFixture(sendDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = "mensaje en curso"

        let sending = Task { await fixture.store.sendComposer() }
        try await waitUntil { fixture.store.isSending }

        XCTAssertFalse(fixture.store.canChangeProfile)
        fixture.store.selectProfile(.puky)
        XCTAssertEqual(fixture.store.profile, .personal)
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "base-window")

        let sent = await sending.value
        XCTAssertTrue(sent)
        XCTAssertTrue(fixture.store.canChangeProfile)
        fixture.store.selectProfile(.puky)
        XCTAssertEqual(fixture.store.profile, .puky)
    }

    func testProfileCannotChangeBeforeANewSessionCanOpen() async throws {
        let fixture = try makeFixture(createDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let creation = Task {
            await fixture.store.createSession(
                projectPath: "/Users/test/projects/fermin-code",
                name: "Debe abrirse"
            )
        }
        try await waitUntil { fixture.store.isCreatingSession }

        XCTAssertFalse(fixture.store.canChangeProfile)
        fixture.store.selectProfile(.puky)
        XCTAssertEqual(fixture.store.profile, .personal)

        let created = await creation.value
        XCTAssertTrue(created)
        XCTAssertTrue(fixture.store.canChangeProfile)
        XCTAssertEqual(fixture.store.selectedSession?.displayName, "Debe abrirse")
    }

    func testBackgroundSessionCreationDoesNotReplaceANewerSelection() async throws {
        let fixture = try makeFixture(createDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let creation = Task {
            await fixture.store.createSession(
                projectPath: "/Users/test/projects/fermin-code",
                name: "Creada en segundo plano"
            )
        }
        try await waitUntil { fixture.store.isCreatingSession }
        try await selectBaseSession(in: fixture)
        let newerRoute = try XCTUnwrap(fixture.store.selectedRoute)

        let created = await creation.value

        XCTAssertTrue(created)
        XCTAssertEqual(fixture.store.selectedRoute, newerRoute)
        XCTAssertEqual(fixture.store.selectedSession?.windowID, "base-window")
        XCTAssertEqual(
            fixture.store.notice,
            "Sesión Creada en segundo plano creada en Primary."
        )
    }

    func testReadySessionCannotIssueAnInterrupt() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        XCTAssertFalse(fixture.store.canInterruptSelectedSession)
        await fixture.store.interruptSelectedSession()
        XCTAssertFalse(fixture.store.isInterruptingSelectedSession)
    }

    func testInterruptProgressDoesNotAppearOnTheNextSession() async throws {
        let fixture = try makeFixture(
            refreshDelayNanoseconds: 60_000_000,
            detailFetchDelaysNanoseconds: [500_000_000]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }

        let busySession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "busy-window",
                sessionID: "busy-session",
                displayName: "Sesión ocupada",
                activityStatus: "working",
                canSend: false
            )
        )
        fixture.store.selectSession(busySession)
        XCTAssertTrue(fixture.store.canInterruptSelectedSession)

        let interruptTask = Task {
            await fixture.store.interruptSelectedSession()
        }
        try await waitUntil { fixture.store.isInterruptingSelectedSession }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isInterruptingSelectedSession)
        XCTAssertFalse(fixture.store.canInterruptSelectedSession)
        await interruptTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testGlobalShortcutsStayDisabledBehindAModal() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isBootstrapping }

        XCTAssertTrue(fixture.store.canInvokeCreateShortcut)
        fixture.store.isHistoryPresented = true

        XCTAssertTrue(fixture.store.hasPresentedModal)
        XCTAssertFalse(fixture.store.canInvokeCreateShortcut)
        XCTAssertFalse(fixture.store.canInvokeComposerShortcut)
        XCTAssertFalse(fixture.store.canInvokeInterruptShortcut)
    }

    func testComposerDraftsStayScopedToTheirSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let firstSession = try XCTUnwrap(fixture.store.sourcedSessions.first)
        let secondSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "second-window",
                sessionID: "second-session",
                displayName: "Segunda sesión",
                activityStatus: "ready",
                canSend: true
            )
        )

        fixture.store.composerText = "borrador de la primera"
        fixture.store.selectSession(secondSession)
        XCTAssertEqual(fixture.store.composerText, "")

        fixture.store.composerText = "borrador de la segunda"
        fixture.store.selectSession(firstSession)
        XCTAssertEqual(fixture.store.composerText, "borrador de la primera")

        fixture.store.selectSession(secondSession)
        XCTAssertEqual(fixture.store.composerText, "borrador de la segunda")
    }

    func testFailedSendRestoresUntouchedTextAndAttachmentDraft() async throws {
        let fixture = try makeFixture(sendShouldFail: true)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let originalText = "  mensaje que todavía puedo editar\n"
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fermin-send-recovery-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        fixture.store.composerText = originalText
        await fixture.store.addAttachments(from: [imageURL])
        XCTAssertEqual(fixture.store.attachments.map(\.name), [imageURL.lastPathComponent])

        let sent = await fixture.store.sendComposer()

        XCTAssertFalse(sent)
        XCTAssertEqual(fixture.store.composerText, originalText)
        XCTAssertEqual(fixture.store.attachments.map(\.name), [imageURL.lastPathComponent])
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
        XCTAssertFalse(fixture.store.isSending)
        XCTAssertNotNil(fixture.store.composerSendErrorMessage)

        let retried = await fixture.store.retryComposerSend()
        XCTAssertFalse(retried)
        let retrySendCount = await fixture.relay.sentMessageCount()
        XCTAssertEqual(retrySendCount, 2)
        XCTAssertEqual(fixture.store.composerText, originalText)
        XCTAssertNotNil(fixture.store.composerSendErrorMessage)
    }

    func testAcceptedSendWithLostHTTPResponseReconcilesWithoutFalseFailure() async throws {
        let fixture = try makeFixture(sendAcceptedButResponseLostOnce: true)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "mensaje aceptado aunque se perdió el ACK"
        let sent = await fixture.store.sendComposer()

        XCTAssertTrue(sent)
        XCTAssertTrue(fixture.store.composerText.isEmpty)
        XCTAssertNil(fixture.store.composerSendErrorMessage)
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
        XCTAssertEqual(
            fixture.store.displayedMessages(limit: 100).filter { $0.message.role == "user" }.count,
            1
        )
        let requests = await fixture.relay.sentMessageRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].idempotencyKey, requests[0].clientMessageID)
    }

    func testAmbiguousSendRetryReusesIdempotencyIdentity() async throws {
        let fixture = try makeFixture(
            sendAcceptedButResponseLostOnce: true,
            detailFailureFetches: [2]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "reintento idempotente"
        let sent = await fixture.store.sendComposer()

        XCTAssertTrue(sent)
        XCTAssertNil(fixture.store.composerSendErrorMessage)
        let requests = await fixture.relay.sentMessageRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].clientMessageID, requests[1].clientMessageID)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
    }

    func testMixedFileDropExplainsTheInvalidItemAndAddsNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("captura.png")
        let textURL = directory.appendingPathComponent("notas.txt")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imageURL)
        try Data("no es una imagen".utf8).write(to: textURL)

        await fixture.store.addAttachments(from: [imageURL, textURL])

        XCTAssertTrue(fixture.store.attachments.isEmpty)
        XCTAssertTrue(fixture.store.errorMessage?.contains("notas.txt") == true)
        XCTAssertTrue(fixture.store.errorMessage?.contains("PNG, JPEG, GIF o WebP") == true)
    }

    func testUnreadableAttachmentNamesTheFileAndAddsNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("captura-ausente-\(UUID().uuidString).png")

        await fixture.store.addAttachments(from: [missingURL])

        XCTAssertTrue(fixture.store.attachments.isEmpty)
        XCTAssertTrue(
            fixture.store.errorMessage?.contains(missingURL.lastPathComponent) == true
        )
        XCTAssertTrue(fixture.store.errorMessage?.contains("No pudimos leer") == true)
    }

    func testAttachmentOnlySendKeepsVisibleOptimisticMetadata() async throws {
        let fixture = try makeFixture(sendCommandState: .accepted)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fermin-visible-upload-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        await fixture.store.addAttachments(from: [imageURL])
        let sent = await fixture.store.sendComposer()

        XCTAssertTrue(sent)
        let optimistic = try XCTUnwrap(fixture.store.optimisticMessages.first)
        XCTAssertEqual(optimistic.message.content, "")
        XCTAssertEqual(
            optimistic.message.imageAttachments.map(\.name),
            [imageURL.lastPathComponent]
        )
    }

    func testTransportFailureRestoresTheMessageAheadOfTheCurrentDraft() async throws {
        let fixture = try makeFixture(sendShouldFail: true, sendDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "mensaje que fallará"
        let sendTask = Task { await fixture.store.sendComposer() }
        try await waitUntil { fixture.store.isSending }
        fixture.store.composerText = "borrador nuevo"

        let sent = await sendTask.value
        XCTAssertFalse(sent)
        XCTAssertEqual(
            fixture.store.composerText,
            "mensaje que fallará\n\nborrador nuevo"
        )
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
        XCTAssertNotNil(fixture.store.composerSendErrorMessage)
    }

    func testTerminalCommandFailureRemainsRecoverable() async throws {
        let fixture = try makeFixture(sendCommandState: .failed)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "mensaje rechazado por el relay"
        let sent = await fixture.store.sendComposer()
        XCTAssertFalse(sent)

        let failedMessage = try XCTUnwrap(fixture.store.optimisticMessages.first)
        guard case .failed = failedMessage.delivery else {
            return XCTFail("El rechazo terminal no debe volver visualmente a aceptado.")
        }
        XCTAssertTrue(fixture.store.recoverFailedComposer(messageID: failedMessage.id))
        XCTAssertEqual(fixture.store.composerText, "mensaje rechazado por el relay")
    }

    func testFeatureSelectionStaysVisibleUntilAuthorityConfirmsIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        await fixture.store.setFeatures(promptImprover: true)

        XCTAssertTrue(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertFalse(fixture.store.selectedFeatures.explainerEnabled)
        XCTAssertFalse(fixture.store.selectedFeatures.codeContextEnabled)
    }

    func testPromptImproverCanBeActivatedAndDeactivated() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        await fixture.store.setFeatures(promptImprover: true)
        XCTAssertTrue(fixture.store.selectedFeatures.promptImproverEnabled)

        await fixture.store.setFeatures(promptImprover: false)
        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)

        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true, false])
    }

    func testSelectingTheCurrentPromptImproverStateDoesNotStartARequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        await fixture.store.setFeatures(promptImprover: false)

        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertTrue(values.isEmpty)
    }

    func testRapidPromptImproverReversalKeepsTheLatestIntent() async throws {
        let fixture = try makeFixture(featureDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let activation = Task {
            await fixture.store.setFeatures(promptImprover: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }

        await fixture.store.setFeatures(promptImprover: false)
        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertTrue(fixture.store.isUpdatingSelectedFeatures)

        await activation.value

        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true, false])
    }

    func testPromptImproverIntentSurvivesLeavingAndReturningToItsSession() async throws {
        let fixture = try makeFixture(featureDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let originalSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        let activation = Task {
            await fixture.store.setFeatures(promptImprover: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)
        fixture.store.selectSession(originalSession)

        XCTAssertTrue(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertTrue(fixture.store.isUpdatingSelectedFeatures)
        await fixture.store.setFeatures(promptImprover: false)
        await activation.value

        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true, false])
    }

    func testSupersededPromptImproverFailureDoesNotOutliveTheLatestIntent() async throws {
        let fixture = try makeFixture(
            heldFeatureCalls: [1],
            featureFailureCalls: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let activation = Task {
            await fixture.store.setFeatures(promptImprover: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }

        await fixture.store.setFeatures(promptImprover: false)
        await fixture.relay.releaseFeatureCall(1)
        await activation.value

        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertNil(fixture.store.errorMessage)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true, false])
    }

    func testCurrentPromptImproverFailureRemainsVisibleAndReverts() async throws {
        let fixture = try makeFixture(featureShouldFail: true)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        await fixture.store.setFeatures(promptImprover: true)

        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertTrue(fixture.store.errorMessage?.contains("funciones") == true)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true])
    }

    func testPromptImproverMutationDoesNotBlockOrErrorTheNextSession() async throws {
        let fixture = try makeFixture(
            featureDelayNanoseconds: 60_000_000,
            featureShouldFail: true
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let toggleTask = Task {
            await fixture.store.setFeatures(promptImprover: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        await toggleTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testStaleFeatureMutationCannotCrossAReusedWindowIntoANewSession() async throws {
        let fixture = try makeFixture(
            featureDelayNanoseconds: 60_000_000,
            heldFeatureCalls: [1],
            featureFailureCalls: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let staleActivation = Task {
            await fixture.store.setFeatures(promptImprover: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }
        try await waitUntilAsync {
            await fixture.relay.sentPromptImproverValues().count == 1
        }

        await fixture.store.setFeatures(promptImprover: false)
        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)

        let replacement = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "base-window",
                sessionID: "replacement-session",
                displayName: "Sesión reemplazada",
                messages: [
                    FerminRelayMessage(
                        id: "replacement-message",
                        role: "assistant",
                        content: "Pertenece sólo al reemplazo",
                        timestamp: 101,
                        status: "completed"
                    ),
                ],
                features: FerminRelaySessionFeatures(explainerEnabled: true)
            )
        )
        await fixture.relay.enqueueSnapshot([replacement.session], held: false)
        await fixture.relay.enqueueSnapshot([replacement.session], held: false)
        await fixture.relay.enqueueSnapshot([replacement.session], held: false)
        fixture.store.selectSession(replacement)

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        XCTAssertFalse(fixture.store.selectedFeatures.promptImproverEnabled)
        XCTAssertTrue(fixture.store.selectedFeatures.explainerEnabled)

        let replacementMutation = Task {
            await fixture.store.setFeatures(codeContext: true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedFeatures }

        await fixture.relay.releaseFeatureCall(1)
        await staleActivation.value
        await replacementMutation.value

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertFalse(fixture.store.isUpdatingSelectedFeatures)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertTrue(fixture.store.selectedFeatures.explainerEnabled)
        XCTAssertTrue(fixture.store.selectedFeatures.codeContextEnabled)
        let values = await fixture.relay.sentPromptImproverValues()
        XCTAssertEqual(values, [true, nil])
    }

    func testPromptRetryProgressDoesNotAppearOnTheNextSession() async throws {
        let fixture = try makeFixture(refreshDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let retryTask = Task {
            await fixture.store.retryPromptTransform(messageID: "shared-message")
        }
        try await waitUntil {
            fixture.store.isRetryingPromptTransform(messageID: "shared-message")
        }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(
            fixture.store.isRetryingPromptTransform(messageID: "shared-message")
        )
        _ = await retryTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testProjectLoadingDeduplicatesAndDiscardsAStaleProfileResponse() async throws {
        let fixture = try makeFixture(projectDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }

        let firstLoad = Task { await fixture.store.loadProjects() }
        try await waitUntil { fixture.store.isLoadingProjects }
        await fixture.store.loadProjects()
        fixture.store.selectProfile(.puky)
        await firstLoad.value

        let projectFetches = await fixture.relay.projectFetches()
        XCTAssertEqual(projectFetches, 1)
        XCTAssertTrue(fixture.store.projects.isEmpty)
        XCTAssertFalse(fixture.store.isLoadingProjects)
    }

    func testSuccessfulProjectRetryClearsOnlyItsPreviousError() async throws {
        let fixture = try makeFixture(projectFailureFetches: [1])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        await fixture.store.loadProjects()
        XCTAssertTrue(fixture.store.projects.isEmpty)
        XCTAssertNotNil(fixture.store.errorMessage)

        await fixture.store.loadProjects()
        XCTAssertFalse(fixture.store.projects.isEmpty)
        XCTAssertNil(fixture.store.errorMessage)
        let projectFetches = await fixture.relay.projectFetches()
        XCTAssertEqual(projectFetches, 2)
    }

    func testRefreshAllCoalescesOverlappingRequests() async throws {
        let fixture = try makeFixture(refreshDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isRefreshing && !fixture.store.sourcedSessions.isEmpty }

        let initialFetches = await fixture.relay.sessionFetches()
        let firstRefresh = Task { await fixture.store.refreshAll() }
        try await waitUntil { fixture.store.isRefreshing }
        await fixture.store.refreshAll()
        await firstRefresh.value

        let finalFetches = await fixture.relay.sessionFetches()
        XCTAssertEqual(finalFetches - initialFetches, 1)
        XCTAssertFalse(fixture.store.isRefreshing)
    }

    func testDeletingCredentialInvalidatesAnOlderRefreshResult() async throws {
        let fixture = try makeFixture(refreshDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isRefreshing && !fixture.store.sourcedSessions.isEmpty }

        let initialFetches = await fixture.relay.sessionFetches()
        let saveTask = Task {
            await fixture.store.saveCredential("token reemplazado", for: .personal)
        }
        try await waitUntilAsync {
            await fixture.relay.sessionFetches() > initialFetches
        }

        let cleared = await fixture.store.clearCredential(for: .personal)
        let saved = await saveTask.value

        XCTAssertTrue(saved)
        XCTAssertTrue(cleared)
        XCTAssertEqual(fixture.store.credentialPresence[.personal], false)
        XCTAssertFalse(fixture.store.sourcedSessions.contains { $0.source == .personal })
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .missingCredential)
    }

    func testHistoryLoadingDiscardsResultsFromThePreviousProfile() async throws {
        let fixture = try makeFixture(historyDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }

        let personalHistory = Task { await fixture.store.loadHistory() }
        try await waitUntil { fixture.store.isLoadingHistory }
        fixture.store.selectProfile(.puky)
        await personalHistory.value

        XCTAssertTrue(fixture.store.historyItems.isEmpty)
        XCTAssertEqual(fixture.store.historyTotal, 0)
        XCTAssertFalse(fixture.store.isLoadingHistory)
    }

    func testHistoryViewOwnsOneLoadAfterProfileChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.isHistoryPresented = true

        let size = NSSize(width: 780, height: 620)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopHistoryView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        try await waitUntilAsync { await fixture.relay.historyFetches() == 1 }
        let initialFetches = await fixture.relay.historyFetches()

        fixture.store.selectProfile(.todo)
        try await waitUntilAsync {
            await fixture.relay.historyFetches() >= initialFetches + 1
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        let finalFetches = await fixture.relay.historyFetches()
        XCTAssertEqual(finalFetches - initialFetches, 1)
        XCTAssertEqual(fixture.store.profile, .todo)
        XCTAssertEqual(fixture.store.historyItems.count, 1)
        XCTAssertEqual(fixture.store.historyTotal, 1)
        XCTAssertFalse(fixture.store.isLoadingHistory)
        XCTAssertNil(fixture.store.errorMessage)
        _ = hostingView
    }

    func testProfileChangeTaskCannotLoadHistoryAfterSheetClosesAndReopens() async throws {
        let fixture = try makeFixture(preferenceDelayNanoseconds: 400_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.isHistoryPresented = true

        let size = NSSize(width: 780, height: 620)
        let hostingView = NSHostingView(
            rootView: HistoryLifecycleHarness()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        try await waitUntilAsync { await fixture.relay.historyFetches() == 1 }
        let initialHistoryFetches = await fixture.relay.historyFetches()

        let initialPreferenceFetches = await fixture.relay.preferenceFetches()
        fixture.store.selectProfile(.todo)
        try await waitUntilAsync {
            await fixture.relay.preferenceFetches() > initialPreferenceFetches
        }

        fixture.store.isHistoryPresented = false
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        fixture.store.isHistoryPresented = true
        hostingView.layoutSubtreeIfNeeded()

        try await waitUntilAsync {
            await fixture.relay.historyFetches() >= initialHistoryFetches + 1
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let finalHistoryFetches = await fixture.relay.historyFetches()
        XCTAssertEqual(finalHistoryFetches - initialHistoryFetches, 1)
        XCTAssertEqual(fixture.store.profile, .todo)
        XCTAssertEqual(fixture.store.historyItems.count, 1)
        XCTAssertEqual(fixture.store.historyTotal, 1)
        XCTAssertFalse(fixture.store.isLoadingHistory)
        XCTAssertNil(fixture.store.errorMessage)
        _ = hostingView
    }

    func testHistoryResumeDoesNotHijackReplacementProfileOrSession() async throws {
        let fixture = try makeFixture(resumeHistoryDelayNanoseconds: 120_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)

        let resume = Task { await fixture.store.resumeHistoryItem(historyItem) }
        try await waitUntil { fixture.store.activeMutations.contains("resume") }

        fixture.store.isHistoryPresented = false
        fixture.store.selectProfile(.puky)
        let replacement = FerminCodeRelaySourcedSession(
            source: .puky,
            session: makeDetailSession(
                windowID: "replacement-window",
                sessionID: "replacement-session",
                displayName: "Contexto Puky",
                messages: []
            )
        )
        fixture.store.selectSession(replacement)
        fixture.store.errorMessage = "El contexto nuevo sigue vigente."
        let replacementInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        let resumed = await resume.value

        XCTAssertTrue(resumed)
        XCTAssertEqual(fixture.store.profile, .puky)
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, replacementInstanceID)
        XCTAssertFalse(fixture.store.isHistoryPresented)
        XCTAssertEqual(fixture.store.errorMessage, "El contexto nuevo sigue vigente.")
    }

    func testHistoryResumeDoesNotCloseReopenedHistory() async throws {
        let fixture = try makeFixture(resumeHistoryDelayNanoseconds: 120_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)
        let originalInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        let resume = Task { await fixture.store.resumeHistoryItem(historyItem) }
        try await waitUntil { fixture.store.activeMutations.contains("resume") }

        fixture.store.isHistoryPresented = false
        fixture.store.isHistoryPresented = true
        let resumed = await resume.value

        XCTAssertTrue(resumed)
        XCTAssertTrue(fixture.store.isHistoryPresented)
        XCTAssertEqual(fixture.store.profile, .personal)
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, originalInstanceID)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testHistoryResumeFailureDoesNotPublishIntoReplacementContext() async throws {
        let fixture = try makeFixture(
            resumeHistoryDelayNanoseconds: 120_000_000,
            resumeHistoryShouldFail: true
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)

        let resume = Task { await fixture.store.resumeHistoryItem(historyItem) }
        try await waitUntil { fixture.store.activeMutations.contains("resume") }

        fixture.store.isHistoryPresented = false
        fixture.store.selectProfile(.puky)
        let replacement = FerminCodeRelaySourcedSession(
            source: .puky,
            session: makeDetailSession(
                windowID: "replacement-error-window",
                sessionID: "replacement-error-session",
                displayName: "Contexto de error vigente",
                messages: []
            )
        )
        fixture.store.selectSession(replacement)
        fixture.store.errorMessage = "Error vigente de B."
        let replacementInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        let resumed = await resume.value

        XCTAssertFalse(resumed)
        XCTAssertEqual(fixture.store.profile, .puky)
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, replacementInstanceID)
        XCTAssertFalse(fixture.store.isHistoryPresented)
        XCTAssertEqual(fixture.store.errorMessage, "Error vigente de B.")
    }

    func testHistoryResumeStillHandsOffWhenNavigationIsUnchanged() async throws {
        let fixture = try makeFixture(resumeHistoryDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let alternate = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "alternate-window",
                sessionID: "alternate-session",
                displayName: "Sesión anterior",
                messages: []
            )
        )
        fixture.store.selectProfile(.personal)
        fixture.store.selectSession(alternate)
        let alternateInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)

        let resumed = await fixture.store.resumeHistoryItem(historyItem)

        XCTAssertTrue(resumed)
        XCTAssertFalse(fixture.store.isHistoryPresented)
        XCTAssertEqual(fixture.store.profile, .personal)
        XCTAssertNotEqual(fixture.store.selectedSessionInstanceID, alternateInstanceID)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "base-session")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testHistoryResumeSuccessDoesNotClearNewerFeedbackInTheSameContext() async throws {
        let fixture = try makeFixture(resumeHistoryDelayNanoseconds: 120_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)

        let resume = Task { await fixture.store.resumeHistoryItem(historyItem) }
        try await waitUntil { fixture.store.activeMutations.contains("resume") }
        fixture.store.errorMessage = "Error más nuevo del contexto actual."

        let resumed = await resume.value

        XCTAssertTrue(resumed)
        XCTAssertFalse(fixture.store.isHistoryPresented)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "base-session")
        XCTAssertEqual(
            fixture.store.errorMessage,
            "Error más nuevo del contexto actual."
        )
    }

    func testHistoryResumeFailureDoesNotOverwriteNewerFeedbackInTheSameContext() async throws {
        let fixture = try makeFixture(
            resumeHistoryDelayNanoseconds: 120_000_000,
            resumeHistoryShouldFail: true
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let historyItem = try await loadPersonalHistoryItem(in: fixture)

        let resume = Task { await fixture.store.resumeHistoryItem(historyItem) }
        try await waitUntil { fixture.store.activeMutations.contains("resume") }
        fixture.store.errorMessage = "Error más nuevo del contexto actual."

        let resumed = await resume.value

        XCTAssertFalse(resumed)
        XCTAssertTrue(fixture.store.isHistoryPresented)
        XCTAssertEqual(
            fixture.store.errorMessage,
            "Error más nuevo del contexto actual."
        )
    }

    func testLatestHistoryQueryWinsWhileThePreviousSearchIsLoading() async throws {
        let fixture = try makeFixture(historyDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let previousSearch = Task {
            await fixture.store.loadHistory(text: "anterior")
        }
        try await waitUntil { fixture.store.isLoadingHistory }
        let latestSearch = Task {
            await fixture.store.loadHistory(text: "actual")
        }

        await previousSearch.value
        await latestSearch.value

        XCTAssertFalse(fixture.store.isLoadingHistory)
        XCTAssertEqual(fixture.store.historyItems.count, 1)
        XCTAssertEqual(fixture.store.historyItems.first?.item.sessionName, "Historia actual")
    }

    func testHistoryTotalFailureIsNotReportedAsAnAuthoritativeEmptyResult() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        fixture.store.selectProfile(.puky)
        await fixture.store.loadHistory(text: "existente")

        XCTAssertEqual(
            fixture.store.historyLoadState,
            .failed("No se pudo cargar el historial.")
        )
        XCTAssertTrue(fixture.store.historyItems.isEmpty)
        XCTAssertEqual(fixture.store.historyTotal, 0)
        XCTAssertFalse(fixture.store.isLoadingHistory)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testHistoryRetryClearsItsStaleFailureAndPreservesAnUnrelatedGlobalError() async throws {
        let fixture = try makeFixture(
            historyDelayNanoseconds: 20_000_000,
            historyFailureFetches: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.errorMessage = "Otro error sigue vigente."

        await fixture.store.loadHistory(text: "actual")
        XCTAssertEqual(
            fixture.store.historyLoadState,
            .failed("No se pudo cargar el historial.")
        )
        XCTAssertEqual(fixture.store.errorMessage, "Otro error sigue vigente.")

        let retry = Task {
            await fixture.store.loadHistory(text: "actual")
        }
        try await waitUntil { fixture.store.historyLoadState == .loading }

        XCTAssertNil(fixture.store.historyLoadState.failureMessage)
        XCTAssertEqual(fixture.store.errorMessage, "Otro error sigue vigente.")

        await retry.value

        XCTAssertEqual(fixture.store.historyLoadState, .loaded)
        XCTAssertFalse(fixture.store.isLoadingHistory)
        XCTAssertEqual(fixture.store.historyItems.first?.item.sessionName, "Historia actual")
        XCTAssertEqual(fixture.store.errorMessage, "Otro error sigue vigente.")
    }

    func testHistoryPartialResultKeepsRowsAndScopesTheWarningToHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        fixture.store.selectProfile(.todo)
        await fixture.store.loadHistory()

        XCTAssertEqual(fixture.store.historyItems.count, 1)
        XCTAssertEqual(fixture.store.historyTotal, 1)
        XCTAssertEqual(
            fixture.store.historyLoadState.partialMessage,
            "Historial parcial: no respondió Secondary."
        )
        XCTAssertNil(fixture.store.historyLoadState.failureMessage)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testHistoryLifecycleInvalidationRejectsLateResponseAndRestoresPartialRows() async throws {
        let fixture = try makeFixture(historyDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        fixture.store.selectProfile(.todo)
        await fixture.store.loadHistory(text: "estable")
        let stableItems = fixture.store.historyItems
        let stableTotal = fixture.store.historyTotal
        let stableState = fixture.store.historyLoadState
        fixture.store.errorMessage = "Otro error sigue vigente."

        let lateLoad = Task {
            await fixture.store.loadHistory(text: "tardía")
        }
        try await waitUntil { fixture.store.historyLoadState == .revalidating }

        fixture.store.invalidateHistoryRequestForLifecycle()

        XCTAssertEqual(fixture.store.historyItems, stableItems)
        XCTAssertEqual(fixture.store.historyTotal, stableTotal)
        XCTAssertEqual(fixture.store.historyLoadState, stableState)
        XCTAssertEqual(fixture.store.errorMessage, "Otro error sigue vigente.")

        await lateLoad.value

        XCTAssertEqual(fixture.store.historyItems, stableItems)
        XCTAssertEqual(fixture.store.historyTotal, stableTotal)
        XCTAssertEqual(fixture.store.historyLoadState, stableState)
        XCTAssertEqual(fixture.store.errorMessage, "Otro error sigue vigente.")
    }

    func testCancelledHistoryTaskCannotPublishFailureOrReplaceStableRows() async throws {
        let fixture = try makeFixture(historyDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        await fixture.store.loadHistory(text: "estable")
        let stableItems = fixture.store.historyItems
        let stableTotal = fixture.store.historyTotal

        let cancelledLoad = Task {
            await fixture.store.loadHistory(text: "cancelada")
        }
        try await waitUntil { fixture.store.historyLoadState == .revalidating }
        cancelledLoad.cancel()
        await cancelledLoad.value

        XCTAssertEqual(fixture.store.historyItems, stableItems)
        XCTAssertEqual(fixture.store.historyTotal, stableTotal)
        XCTAssertEqual(fixture.store.historyLoadState, .loaded)
        XCTAssertNil(fixture.store.historyLoadState.failureMessage)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testAStalePreferenceLoadCannotOverwriteANewerSave() async throws {
        let fixture = try makeFixture(preferenceDelayNanoseconds: 20_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { fixture.store.promptPreferences[.personal] != nil }

        let initialFetches = await fixture.relay.preferenceFetches()
        let staleLoad = Task { await fixture.store.loadPromptPreferences() }
        try await waitUntilAsync {
            await fixture.relay.preferenceFetches() > initialFetches
        }
        let saved = await fixture.store.setPromptPreference(.motivational)
        await staleLoad.value

        XCTAssertTrue(saved)
        XCTAssertEqual(
            fixture.store.promptPreferences[.personal]?.variant,
            .motivational
        )
    }

    func testGoalSelectionStaysLocalUntilExplicitComposerSend() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = "Objetivo explícito"

        fixture.store.stageGoalMode(true)

        XCTAssertTrue(fixture.store.selectedGoalModeEnabled)
        XCTAssertTrue(fixture.store.hasPendingSelectedGoalModeDraft)
        let valuesBeforeSend = await fixture.relay.sentGoalModeValues()
        let messagesBeforeSend = await fixture.relay.sentMessageCount()
        XCTAssertEqual(valuesBeforeSend, [])
        XCTAssertEqual(messagesBeforeSend, 0)

        let sent = await fixture.store.sendComposer()

        XCTAssertTrue(sent)
        XCTAssertFalse(fixture.store.hasPendingSelectedGoalModeDraft)
        let valuesAfterSend = await fixture.relay.sentGoalModeValues()
        let messagesAfterSend = await fixture.relay.sentMessageCount()
        let operationOrder = await fixture.relay.composerOperationOrder()
        XCTAssertEqual(valuesAfterSend, [true])
        XCTAssertEqual(messagesAfterSend, 1)
        XCTAssertEqual(operationOrder, ["run-mode", "message"])
    }

    func testFailedGoalCommitKeepsComposerAndDoesNotSendMessage() async throws {
        let fixture = try makeFixture(goalMutationShouldFail: true)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.composerText = "Conservar si GOAL falla"
        fixture.store.stageGoalMode(true)

        let sent = await fixture.store.sendComposer()

        XCTAssertFalse(sent)
        XCTAssertEqual(fixture.store.composerText, "Conservar si GOAL falla")
        XCTAssertTrue(fixture.store.hasPendingSelectedGoalModeDraft)
        let values = await fixture.relay.sentGoalModeValues()
        let messageCount = await fixture.relay.sentMessageCount()
        let operationOrder = await fixture.relay.composerOperationOrder()
        XCTAssertEqual(values, [true])
        XCTAssertEqual(messageCount, 0)
        XCTAssertEqual(operationOrder, ["run-mode"])
    }

    func testGoalModeCanBeActivatedAndDeactivatedWithoutVisualRollback() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        await fixture.store.setGoalMode(true)
        XCTAssertTrue(fixture.store.selectedGoalModeEnabled)

        await fixture.store.setGoalMode(false)
        XCTAssertFalse(fixture.store.selectedGoalModeEnabled)

        let values = await fixture.relay.sentGoalModeValues()
        XCTAssertEqual(values, [true, false])
    }

    func testRapidGoalModeReversalKeepsTheLatestIntent() async throws {
        let fixture = try makeFixture(goalMutationDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let activation = Task { await fixture.store.setGoalMode(true) }
        try await waitUntil { fixture.store.isUpdatingSelectedGoalMode }

        await fixture.store.setGoalMode(false)
        XCTAssertFalse(fixture.store.selectedGoalModeEnabled)

        await activation.value
        try await waitUntil { !fixture.store.isUpdatingSelectedGoalMode }

        XCTAssertFalse(fixture.store.selectedGoalModeEnabled)
        let values = await fixture.relay.sentGoalModeValues()
        XCTAssertEqual(values, [true, false])
    }

    func testGoalModeIntentSurvivesLeavingAndReturningToItsSession() async throws {
        let fixture = try makeFixture(goalMutationDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let originalSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        let activation = Task { await fixture.store.setGoalMode(true) }
        try await waitUntil { fixture.store.isUpdatingSelectedGoalMode }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)
        fixture.store.selectSession(originalSession)

        XCTAssertTrue(fixture.store.selectedGoalModeEnabled)
        XCTAssertTrue(fixture.store.isUpdatingSelectedGoalMode)
        await fixture.store.setGoalMode(false)
        await activation.value

        XCTAssertFalse(fixture.store.selectedGoalModeEnabled)
        XCTAssertFalse(fixture.store.isUpdatingSelectedGoalMode)
        let values = await fixture.relay.sentGoalModeValues()
        XCTAssertEqual(values, [true, false])
    }

    func testGoalMutationDoesNotBlockOrErrorTheNextSession() async throws {
        let fixture = try makeFixture(
            goalMutationDelayNanoseconds: 60_000_000,
            goalMutationShouldFail: true
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let toggleTask = Task {
            await fixture.store.setGoalMode(true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedGoalMode }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isUpdatingSelectedGoalMode)
        await toggleTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testRenameProgressDoesNotBlockTheNextSession() async throws {
        let fixture = try makeFixture(refreshDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let renameTask = Task {
            await fixture.store.renameSelectedSession("Nuevo nombre")
        }
        try await waitUntil { fixture.store.isRenamingSelectedSession }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isRenamingSelectedSession)
        let renamed = await renameTask.value
        XCTAssertTrue(renamed)
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testSessionVisibilityProgressDoesNotBlockTheNextSession() async throws {
        let fixture = try makeFixture(lifecycleMutationDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let minimizeTask = Task {
            await fixture.store.setSelectedSessionMinimized(true)
        }
        try await waitUntil { fixture.store.isUpdatingSelectedSessionVisibility }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isUpdatingSelectedSessionVisibility)
        fixture.store.composerText = "Mensaje de la sesión siguiente"
        XCTAssertTrue(fixture.store.canInvokeComposerShortcut)
        await minimizeTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testArchiveCompletionDoesNotClearTheNextSession() async throws {
        let fixture = try makeFixture(lifecycleMutationDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let archiveTask = Task {
            await fixture.store.archiveSelectedSession()
        }
        try await waitUntil { fixture.store.isArchivingSelectedSession }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isArchivingSelectedSession)
        await archiveTask.value
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testRuntimeModelSelectionStaysVisibleUntilAuthorityConfirmsIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let applied = await fixture.store.setRuntimeModel(
            model: "gpt-5.6-sol",
            effort: "max"
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(fixture.store.selectedRuntimeModel, "gpt-5.6-sol")
        XCTAssertEqual(fixture.store.selectedReasoningEffort, "max")
    }

    func testRuntimeModelResultReturnsToItsSessionAfterNavigatingAway() async throws {
        let fixture = try makeFixture(modelMutationDelayNanoseconds: 60_000_000)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let originalSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        let applyTask = Task {
            await fixture.store.setRuntimeModel(model: "gpt-5.6-sol", effort: "max")
        }
        try await waitUntil { fixture.store.isApplyingSelectedRuntimeModel }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)
        let applied = await applyTask.value
        XCTAssertTrue(applied)

        fixture.store.selectSession(originalSession)
        XCTAssertEqual(fixture.store.selectedRuntimeModel, "gpt-5.6-sol")
        XCTAssertEqual(fixture.store.selectedReasoningEffort, "max")
        XCTAssertFalse(fixture.store.isApplyingSelectedRuntimeModel)
    }

    func testLateModelCatalogFailureCannotClearTheNewSessionCatalog() async throws {
        let fixture = try makeFixture(
            modelFetchDelaysNanoseconds: [0, 60_000_000, 0],
            modelFailureFetches: [2]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil {
            !fixture.store.isLoadingModels && !fixture.store.models.isEmpty
        }
        let baseSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        fixture.store.selectSession(baseSession)
        try await waitUntilAsync { await fixture.relay.modelFetches() >= 2 }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                model: "gpt-5.6-sol",
                reasoningEffort: "max",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertTrue(fixture.store.models.isEmpty)
        XCTAssertTrue(fixture.store.isLoadingModels)
        try await waitUntilAsync { await fixture.relay.modelFetches() >= 3 }
        try await waitUntil {
            !fixture.store.isLoadingModels && !fixture.store.models.isEmpty
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(fixture.store.models.map(\.model), ["gpt-5.6-sol"])
        XCTAssertFalse(fixture.store.isLoadingModels)
    }

    func testModelCatalogCanRecoverInPlaceAfterItsInitialLoadFails() async throws {
        let fixture = try makeFixture(modelFailureFetches: [1])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingModels }
        XCTAssertTrue(fixture.store.models.isEmpty)

        let recovered = await fixture.store.reloadModelCatalog()

        XCTAssertTrue(recovered)
        XCTAssertFalse(fixture.store.models.isEmpty)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testModelCatalogRetryErrorDoesNotFollowTheNextSession() async throws {
        let fixture = try makeFixture(modelFailureFetches: [1, 2])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingModels }

        let recovered = await fixture.store.reloadModelCatalog()
        XCTAssertFalse(recovered)
        XCTAssertNotNil(fixture.store.errorMessage)

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "model-error-next-window",
                sessionID: "model-error-next-session",
                model: "gpt-5.6-sol",
                reasoningEffort: "max",
                displayName: "Sesión sin error anterior",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "model-error-next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testLateConversationFailureCannotAffectTheNewSelection() async throws {
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [40_000_000, 500_000_000],
            detailFailureFetches: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }
        let baseSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(baseSession)
        try await waitUntilAsync { await fixture.relay.detailFetches() >= 1 }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "session-next-window",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)
        XCTAssertTrue(fixture.store.isLoadingDetail)
        try await waitUntilAsync { await fixture.relay.detailFetches() >= 2 }
        try await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)

        try await waitUntil { !fixture.store.isLoadingDetail }
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testLateAttachmentPreviewCannotCrossAReusedWindowWithDifferentSessionID() async throws {
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 500_000_000],
            attachmentDelayNanoseconds: 150_000_000
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        let attachmentTask = Task {
            await fixture.store.openRemotePath(
                path: "/attachment/late-image.png",
                name: "late-image.png",
                mimeType: "image/png"
            )
        }
        try await waitUntilAsync { await fixture.relay.attachmentFetches() == 1 }

        let replacement = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "base-window",
                sessionID: "replacement-session",
                displayName: "Sesión reemplazada",
                messages: []
            )
        )
        fixture.store.selectSession(replacement)
        await attachmentTask.value

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertTrue(fixture.store.selectedSessionInstanceID?.contains("replacement-session") == true)
        XCTAssertNil(fixture.store.preview)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testLateAttachmentFailureCannotOverwriteTheNextSessionError() async throws {
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 500_000_000],
            attachmentDelayNanoseconds: 150_000_000,
            attachmentFailureFetches: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        let attachmentTask = Task {
            await fixture.store.openRemotePath(
                path: "/attachment/late-failure.png",
                name: "late-failure.png",
                mimeType: "image/png"
            )
        }
        try await waitUntilAsync { await fixture.relay.attachmentFetches() == 1 }

        let replacement = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "base-window",
                sessionID: "replacement-session",
                displayName: "Sesión reemplazada",
                messages: []
            )
        )
        fixture.store.selectSession(replacement)
        fixture.store.errorMessage = "Error vigente de la sesión nueva."
        await attachmentTask.value

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertTrue(fixture.store.selectedSessionInstanceID?.contains("replacement-session") == true)
        XCTAssertNil(fixture.store.preview)
        XCTAssertEqual(fixture.store.errorMessage, "Error vigente de la sesión nueva.")
    }

    func testConversationFailurePreservesVisibleSummaryAndUsesContextualError() async throws {
        let fixture = try makeFixture(detailFailureFetches: [1])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let cachedMessage = FerminRelayMessage(
            id: "cached-message",
            role: "assistant",
            content: "Contexto que ya estaba visible",
            timestamp: 99,
            status: "completed"
        )
        let summary = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "base-window",
                sessionID: "base-session",
                displayName: "Sesión con contexto",
                activityStatus: "ready",
                messageCount: 1,
                canSend: true,
                messages: [cachedMessage]
            )
        )

        fixture.store.selectSession(summary)
        try await waitUntil { !fixture.store.isLoadingDetail }

        XCTAssertNotNil(fixture.store.detailErrorMessage)
        XCTAssertEqual(fixture.store.selectedSession?.messages.map(\.id), ["cached-message"])
        XCTAssertEqual(fixture.store.displayedMessages.map(\.message.content), ["Contexto que ya estaba visible"])
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testSuccessfulConversationRetryClearsOnlyItsContextualError() async throws {
        let fixture = try makeFixture(detailFailureFetches: [1])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingDetail }
        XCTAssertNotNil(fixture.store.detailErrorMessage)

        fixture.store.errorMessage = "Otro error que debe conservarse"
        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertEqual(fixture.store.errorMessage, "Otro error que debe conservarse")
    }

    func testFailedDetailBackgroundRevalidationEntersLoadingAndPreventsDuplicateRetry() async throws {
        let cachedMessage = FerminRelayMessage(
            id: "failed-background-visible",
            role: "assistant",
            content: "Este contexto debe seguir visible",
            timestamp: 99,
            status: "completed"
        )
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 500_000_000],
            detailFailureFetches: [1]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        fixture.store.selectSession(
            FerminCodeRelaySourcedSession(
                source: .personal,
                session: FerminRelaySession(
                    windowID: "base-window",
                    sessionID: "base-session",
                    displayName: "Sesión con contexto",
                    activityStatus: "ready",
                    messageCount: 1,
                    canSend: true,
                    messages: [cachedMessage]
                )
            )
        )
        try await waitUntil { fixture.store.detailLoadState.errorMessage != nil }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), [cachedMessage.id])

        let refreshTask = Task { await fixture.store.refreshAll() }
        try await waitUntilAsync { await fixture.relay.detailFetches() == 2 }

        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertTrue(fixture.store.isLoadingDetail)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), [cachedMessage.id])
        XCTAssertNil(fixture.store.errorMessage)
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_FAILED_BACKGROUND_REVALIDATION_SNAPSHOT_PATH"
        )

        await refreshTask.value

        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 2)
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testBackgroundRefreshFailureCannotLeaveSupersededDetailLoading() async throws {
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [500_000_000],
            detailFailureFetches: [2]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let baseSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        fixture.store.selectSession(baseSession)
        try await waitUntilAsync { await fixture.relay.detailFetches() >= 1 }
        XCTAssertTrue(fixture.store.isLoadingDetail)

        await fixture.store.refreshAll()

        XCTAssertFalse(fixture.store.isLoadingDetail)
        XCTAssertEqual(
            fixture.store.detailErrorMessage,
            "Fallo tardío de conversación simulado."
        )
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertFalse(fixture.store.isLoadingDetail)
        XCTAssertNotNil(fixture.store.detailErrorMessage)
    }

    func testLoadedConversationBackgroundRevalidationFailureShowsContextualRetry() async throws {
        let visibleMessage = FerminRelayMessage(
            id: "background-visible",
            role: "assistant",
            content: "Este contexto debe seguir visible",
            timestamp: 100,
            status: "completed"
        )
        let recoveredMessage = FerminRelayMessage(
            id: "background-recovered",
            role: "assistant",
            content: "La revalidación volvió a estar al día",
            timestamp: 101,
            status: "completed"
        )
        let visibleDetail = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión visible",
            messages: [visibleMessage]
        )
        let recoveredDetail = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión recuperada",
            messages: [visibleMessage, recoveredMessage]
        )
        let fixture = try makeFixture(
            heldDetailFetches: [2],
            detailFailureFetches: [2],
            detailResponseItems: [visibleDetail, visibleDetail, recoveredDetail]
        )
        defer {
            fixture.store.stop()
            Task { await fixture.relay.releaseAllHeldDetailFetches() }
        }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["background-visible"])

        let refreshTask = Task { await fixture.store.refreshAll() }
        try await waitUntilAsync { await fixture.relay.detailFetches() == 2 }

        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["background-visible"])

        await fixture.relay.releaseDetailFetch(2)
        await refreshTask.value

        XCTAssertEqual(
            fixture.store.detailErrorMessage,
            "Fallo tardío de conversación simulado."
        )
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["background-visible"])
        XCTAssertFalse(fixture.store.isLoadingDetail)
        XCTAssertNil(fixture.store.errorMessage)
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_BACKGROUND_REVALIDATION_FAILURE_SNAPSHOT_PATH"
        )

        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(
            fixture.store.displayedMessages.map(\.id),
            ["background-visible", "background-recovered"]
        )
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)
    }

    func testBackgroundDetailMismatchLeavesRetryableStaleState() async throws {
        let visibleMessage = FerminRelayMessage(
            id: "mismatch-visible",
            role: "assistant",
            content: "La sesión correcta permanece visible",
            timestamp: 100,
            status: "completed"
        )
        let visibleDetail = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión correcta",
            messages: [visibleMessage]
        )
        let fixture = try makeFixture(
            detailMismatchFetches: [2],
            detailResponseItems: [visibleDetail]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        let selectedInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        await fixture.store.refreshAll()

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "base-session")
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, selectedInstanceID)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["mismatch-visible"])
        XCTAssertTrue(fixture.store.detailErrorMessage?.contains("no coincide") == true)
        XCTAssertFalse(fixture.store.isLoadingDetail)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.selectedSourceStatus?.phase, .stale)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 2)
    }

    func testBackgroundSnapshotCannotRebindAnEmptyReplacementSession() async throws {
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [500_000_000, 0]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let replacement = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "base-window",
                sessionID: "replacement-session",
                displayName: "Sesión reemplazada vacía",
                messages: []
            )
        )

        fixture.store.selectSession(replacement)
        try await waitUntilAsync { await fixture.relay.detailFetches() == 1 }
        let replacementInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertEqual(fixture.store.detailLoadState, .loading)

        await fixture.store.refreshAll()

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, replacementInstanceID)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertTrue(fixture.store.detailErrorMessage?.contains("no coincide") == true)
        XCTAssertFalse(fixture.store.isLoadingDetail)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, replacementInstanceID)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 2)
    }

    func testAuthoritativeEmptyBackgroundFailureBecomesRetryableInsteadOfFalseEmpty() async throws {
        let emptyDetail = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión vacía autoritativa",
            messages: []
        )
        let fixture = try makeFixture(
            detailFailureFetches: [2],
            detailResponseItems: [emptyDetail, emptyDetail, emptyDetail]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertNil(fixture.store.detailErrorMessage)

        await fixture.store.refreshAll()

        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertNotNil(fixture.store.detailErrorMessage)
        XCTAssertFalse(fixture.store.isLoadingDetail)
        XCTAssertFalse(fixture.store.hasReportedMessagesMissingFromDetail)
        XCTAssertNil(fixture.store.errorMessage)
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_BACKGROUND_EMPTY_FAILURE_SNAPSHOT_PATH"
        )

        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertFalse(fixture.store.hasReportedMessagesMissingFromDetail)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)
    }

    func testSessionRemovedWithBothIDsPreservesReplacementAndItsCache() async throws {
        let message = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "La conversación B sigue visible",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [message]
        )
        let updatedSessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B actualizada",
            messages: [message]
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailFetchDelaysNanoseconds: [0, 200_000_000],
            detailResponseItems: [sessionB, sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        let row = try XCTUnwrap(fixture.store.sourcedSessions.first)
        fixture.store.selectSession(row)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        let selectedIdentity = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        await fixture.relay.emitStreamEvent(
            .sessionRemoved(
                FerminRelaySessionRemovedEvent(
                    windowID: "reused-window",
                    sessionID: "session-a"
                )
            )
        )
        await fixture.relay.emitStreamEvent(.sessionUpserted(updatedSessionB))
        try await waitUntil {
            fixture.store.visibleSessions.first?.session.displayName == "Sesión B actualizada"
        }

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, selectedIdentity)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-message"])

        fixture.store.clearSelection()
        let refreshedRow = try XCTUnwrap(fixture.store.visibleSessions.first)
        fixture.store.selectSession(refreshedRow)
        try await waitUntilAsync { await fixture.relay.detailFetches() == 2 }

        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-message"])
        try await waitUntil { fixture.store.detailLoadState == .loaded }
    }

    func testSessionRemovedBySessionIDClearsExactSelection() async throws {
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        await fixture.relay.emitStreamEvent(
            .sessionRemoved(
                FerminRelaySessionRemovedEvent(windowID: nil, sessionID: "session-b")
            )
        )
        try await waitUntil { fixture.store.selectedSession == nil }

        XCTAssertTrue(fixture.store.visibleSessions.isEmpty)
        XCTAssertNil(fixture.store.selectedRoute)
        XCTAssertEqual(fixture.store.detailLoadState, .idle)
        XCTAssertTrue(fixture.store.liveMessages.isEmpty)
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
    }

    func testSessionRemovedByWindowOnlyRemainsBroadAndFailClosed() async throws {
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        await fixture.relay.emitStreamEvent(
            .sessionRemoved(
                FerminRelaySessionRemovedEvent(windowID: "reused-window", sessionID: nil)
            )
        )
        try await waitUntil { fixture.store.selectedRoute == nil }

        XCTAssertTrue(fixture.store.visibleSessions.isEmpty)
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertEqual(fixture.store.detailLoadState, .idle)
    }

    func testSessionRemovedWithoutIdentityRevalidatesWithoutWildcardMutation() async throws {
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        await fixture.relay.enqueueSnapshot([sessionB], held: true)

        await fixture.relay.emitStreamEvent(
            .sessionRemoved(FerminRelaySessionRemovedEvent())
        )
        try await waitUntilAsync { await fixture.relay.sessionFetches() == 2 }

        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .stale)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(fixture.store.visibleSessions.first?.session.sessionID, "session-b")

        await fixture.relay.releaseNextSnapshot()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
    }

    func testSessionUpsertedDifferentIdentityClearsBeforeAuthoritativeSnapshot() async throws {
        let messageB = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [messageB]
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A tardía",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        await fixture.relay.enqueueSnapshot([sessionB], held: true)

        await fixture.relay.emitStreamEvent(.sessionUpserted(sessionA))
        try await waitUntilAsync { await fixture.relay.sessionFetches() == 2 }

        XCTAssertNil(fixture.store.selectedRoute)
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertEqual(fixture.store.visibleSessions.first?.session.sessionID, "session-a")
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .stale)

        await fixture.relay.releaseNextSnapshot()
        try await waitUntil {
            fixture.store.sourceStatuses[.personal]?.phase == .online
                && fixture.store.visibleSessions.first?.session.sessionID == "session-b"
        }
        XCTAssertNil(fixture.store.selectedSession)
    }

    func testSessionUpsertedLegitimateReplacementStillFailsClosed() async throws {
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: []
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        await fixture.relay.enqueueSnapshot([sessionA], held: true)

        await fixture.relay.emitStreamEvent(.sessionUpserted(sessionA))
        try await waitUntilAsync { await fixture.relay.sessionFetches() == 2 }
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertEqual(fixture.store.visibleSessions.first?.session.sessionID, "session-a")

        await fixture.relay.releaseNextSnapshot()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        XCTAssertEqual(fixture.store.visibleSessions.first?.session.sessionID, "session-a")
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertTrue(fixture.store.liveMessages.isEmpty)
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
    }

    func testSessionUpsertedSameIdentityDoesNotClearSelection() async throws {
        let message = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [message]
        )
        let updatedSessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B actualizada",
            messages: [message]
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        let selectedIdentity = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        await fixture.relay.emitStreamEvent(.sessionUpserted(updatedSessionB))
        try await waitUntil {
            fixture.store.visibleSessions.first?.session.displayName == "Sesión B actualizada"
        }

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(fixture.store.selectedSessionInstanceID, selectedIdentity)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-message"])
        let sessionFetches = await fixture.relay.sessionFetches()
        XCTAssertEqual(sessionFetches, 1)
    }

    func testSessionRemovedWithBothIDsRemovesOnlyTheExactCoexistingRoute() async throws {
        let sessionA = makeDetailSession(
            windowID: "window-a",
            sessionID: "session-a",
            displayName: "Sesión A",
            messages: []
        )
        let sessionB = makeDetailSession(
            windowID: "window-b",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionA, sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        let rowB = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.sessionID == "session-b" }
        )
        fixture.store.selectSession(rowB)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        await fixture.relay.emitStreamEvent(
            .sessionRemoved(
                FerminRelaySessionRemovedEvent(
                    windowID: "window-a",
                    sessionID: "session-a"
                )
            )
        )
        try await waitUntil {
            !fixture.store.visibleSessions.contains { $0.session.sessionID == "session-a" }
        }

        XCTAssertTrue(
            fixture.store.visibleSessions.contains { $0.session.sessionID == "session-b" }
        )
        XCTAssertFalse(
            fixture.store.visibleSessions.contains { $0.session.sessionID == "session-a" }
        )
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "window-b")
    }

    func testSessionSnapshotCannotPublishAReplacementUnderALoadedTranscript() async throws {
        let messageB = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B cargado",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [messageB]
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A autoritativa",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-message"])

        await fixture.relay.emitStreamEvent(
            .snapshot(FerminRelaySessionsEnvelope(items: [sessionA], cursor: 1))
        )
        try await waitUntil {
            fixture.store.visibleSessions.first?.session.sessionID == "session-a"
        }

        XCTAssertNil(fixture.store.selectedRoute)
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertEqual(fixture.store.detailLoadState, .idle)
    }

    func testPeriodicRefreshCannotPublishAReplacementUnderALoadedTranscript() async throws {
        let messageB = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B cargado",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [messageB]
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A autoritativa",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        await fixture.relay.enqueueSnapshot([sessionA], held: false)

        await fixture.store.refreshAll()

        XCTAssertEqual(fixture.store.visibleSessions.map(\.session.sessionID), ["session-a"])
        XCTAssertNil(fixture.store.selectedRoute)
        XCTAssertNil(fixture.store.selectedSession)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertEqual(fixture.store.detailLoadState, .idle)
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .online)
    }

    func testPeriodicRefreshRejectsDuplicateRoutesWithoutPublishingAmbiguousRows() async throws {
        let messageB = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B cargado",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [messageB]
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A ambigua",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            detailResponseItems: [sessionB, sessionB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        await fixture.relay.enqueueSnapshot([sessionB, sessionA], held: false)

        await fixture.store.refreshAll()

        XCTAssertEqual(fixture.store.visibleSessions.map(\.session.sessionID), ["session-b"])
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-message"])
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .stale)
        XCTAssertTrue(
            fixture.store.sourceStatuses[.personal]?.detail?.contains("repitió una ventana")
                == true
        )
    }

    func testSessionIdentityCapturedBeforeSendMergesFailureAheadOfStashedNextDraft() async throws {
        let messageB = FerminRelayMessage(
            id: "b-message",
            role: "assistant",
            content: "Detalle B",
            timestamp: 100,
            status: "completed"
        )
        let sessionB = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-b",
            displayName: "Sesión B",
            messages: [messageB]
        )
        let sessionA = makeDetailSession(
            windowID: "reused-window",
            sessionID: "session-a",
            displayName: "Sesión A",
            messages: []
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [sessionB],
            sendShouldFail: true,
            sendDelayNanoseconds: 100_000_000,
            detailResponseItems: [sessionB, sessionA]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        fixture.store.selectSession(try XCTUnwrap(fixture.store.sourcedSessions.first))
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        fixture.store.composerText = "Borrador que pertenece a B"
        let sendTask = Task { await fixture.store.sendComposer() }
        try await waitUntil { fixture.store.isSending }
        fixture.store.composerText = "Siguiente borrador de B"
        await fixture.relay.enqueueSnapshot([sessionA], held: true)

        await fixture.relay.emitStreamEvent(.sessionUpserted(sessionA))
        try await waitUntilAsync { await fixture.relay.sessionFetches() == 2 }
        XCTAssertNil(fixture.store.selectedSession)

        let sent = await sendTask.value
        XCTAssertFalse(sent)
        let rowA = try XCTUnwrap(fixture.store.visibleSessions.first)
        fixture.store.selectSession(rowA)
        XCTAssertTrue(fixture.store.composerText.isEmpty)

        await fixture.relay.releaseNextSnapshot()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        fixture.store.clearSelection()
        fixture.store.selectSession(
            FerminCodeRelaySourcedSession(source: .personal, session: sessionB)
        )

        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "session-b")
        XCTAssertEqual(
            fixture.store.composerText,
            "Borrador que pertenece a B\n\nSiguiente borrador de B"
        )
    }

    func testFailedSendMergesTheOriginalAheadOfANewerCurrentDraft() async throws {
        let fixture = try makeFixture(
            sendShouldFail: true,
            sendDelayNanoseconds: 60_000_000
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "Mensaje que fallará"
        let sendTask = Task { await fixture.store.sendComposer() }
        try await waitUntil { fixture.store.isSending }
        fixture.store.composerText = "Borrador escrito durante el envío"

        let sent = await sendTask.value
        XCTAssertFalse(sent)
        XCTAssertEqual(
            fixture.store.composerText,
            "Mensaje que fallará\n\nBorrador escrito durante el envío"
        )
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
    }

    func testReportedMessageCountDoesNotPretendUnloadedRowsAreLocallyAvailable() async throws {
        let fixture = try makeFixture(detailFetchDelaysNanoseconds: [250_000_000])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        let summary = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "base-window",
                sessionID: "base-session",
                displayName: "Sesión con historial remoto",
                activityStatus: "ready",
                messageCount: 4,
                canSend: true,
                messages: []
            )
        )
        fixture.store.selectSession(summary)
        try await waitUntilAsync { await fixture.relay.detailFetches() >= 1 }

        XCTAssertEqual(fixture.store.displayedMessageCount, 4)
        XCTAssertEqual(fixture.store.loadedMessageCount, 0)
        XCTAssertTrue(fixture.store.hasReportedMessagesMissingFromDetail)
        XCTAssertTrue(fixture.store.isLoadingDetail)
    }

    func testAuthoritativePartialTailKeepsReportedAndLoadedCountsDistinct() async throws {
        let messages = (1...4).map { index in
            FerminRelayMessage(
                id: "partial-tail-\(index)",
                role: index.isMultiple(of: 2) ? "assistant" : "user",
                content: "Mensaje reciente \(index)",
                timestamp: Double(index),
                status: "completed"
            )
        }
        let partialDetail = FerminRelaySession(
            windowID: "base-window",
            sessionID: "base-session",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "max",
            projectPath: "/Users/test/projects/fermin-code",
            projectName: "fermin-code",
            displayName: "Tail parcial",
            activityStatus: "ready",
            messageCount: 100,
            updatedAt: 100,
            canSend: true,
            messages: messages
        )
        let fixture = try makeFixture(detailResponseItems: [partialDetail])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }

        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        XCTAssertEqual(fixture.store.loadedMessageCount, 4)
        XCTAssertEqual(fixture.store.displayedMessageCount, 100)
        XCTAssertTrue(fixture.store.hasReportedMessagesMissingFromDetail)
        XCTAssertEqual(
            FerminCodeDesktopTranscriptAvailabilityPresentation.incompleteSummary(
                loadedCount: fixture.store.loadedMessageCount,
                reportedCount: fixture.store.displayedMessageCount
            ),
            "4 de 100 mensajes cargados. Los anteriores todavía no están disponibles."
        )

        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_PARTIAL_TAIL_SNAPSHOT_PATH"
        )
    }

    func testRecentTailReturnsImmediatelyWhileABARouteRevalidates() async throws {
        let cachedMessage = FerminRelayMessage(
            id: "a-old",
            role: "assistant",
            content: "Tail reciente de A",
            timestamp: 100,
            status: "completed",
            imageAttachments: [
                FerminRelayMessageImageAttachment(
                    id: "cached-image",
                    name: "evidencia.png",
                    size: 32,
                    mimeType: "image/png",
                    previewData: Data(repeating: 7, count: 32)
                ),
            ]
        )
        let cachedA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A",
            messages: [cachedMessage]
        )
        let detailB = makeDetailSession(
            windowID: "cache-window-b",
            sessionID: "cache-session-b",
            displayName: "Sesión B",
            messages: [
                FerminRelayMessage(
                    id: "b-only",
                    role: "assistant",
                    content: "Mensaje exclusivo de B",
                    timestamp: 101,
                    status: "completed"
                ),
            ]
        )
        let refreshedA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A",
            messages: [
                cachedMessage,
                FerminRelayMessage(
                    id: "a-new",
                    role: "assistant",
                    content: "Respuesta autoritativa nueva",
                    timestamp: 102,
                    status: "completed"
                ),
            ]
        )
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 0, 750_000_000],
            detailResponseItems: [cachedA, detailB, refreshedA]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let summaryA = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )

        fixture.store.selectSession(summaryA)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["a-old"])

        let summaryB = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "cache-window-b",
                sessionID: "cache-session-b",
                displayName: "Sesión B",
                messages: []
            )
        )
        fixture.store.selectSession(summaryB)
        try await waitUntil {
            fixture.store.selectedRoute?.windowID == "cache-window-b"
                && fixture.store.detailLoadState == .loaded
        }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["b-only"])

        fixture.store.selectSession(summaryA)

        XCTAssertTrue(fixture.store.isLoadingDetail)
        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["a-old"])
        XCTAssertFalse(fixture.store.displayedMessages.map(\.id).contains("b-only"))
        XCTAssertNil(
            fixture.store.selectedSession?.messages.first?
                .imageAttachments.first?.previewData
        )
        try await waitUntilAsync { await fixture.relay.detailFetches() == 3 }
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_CACHE_REFRESH_SNAPSHOT_PATH"
        )

        try await waitUntil(timeoutIterations: 700) {
            fixture.store.detailLoadState == .loaded
        }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["a-old", "a-new"])
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)
    }

    func testCachedTailSurvivesFailedRevalidationWithoutStartingAnotherFetch() async throws {
        let detailA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A",
            messages: [
                FerminRelayMessage(
                    id: "a-cached",
                    role: "assistant",
                    content: "Contexto de A que debe conservarse",
                    timestamp: 100,
                    status: "completed"
                ),
            ]
        )
        let detailB = makeDetailSession(
            windowID: "cache-failure-window-b",
            sessionID: "cache-failure-session-b",
            displayName: "Sesión B",
            messages: [
                FerminRelayMessage(
                    id: "b-cached",
                    role: "assistant",
                    content: "Contexto de B",
                    timestamp: 101,
                    status: "completed"
                ),
            ]
        )
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 0, 80_000_000],
            detailFailureFetches: [3],
            detailResponseItems: [detailA, detailB]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let summaryA = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(summaryA)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        let summaryB = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "cache-failure-window-b",
                sessionID: "cache-failure-session-b",
                displayName: "Sesión B",
                messages: []
            )
        )
        fixture.store.selectSession(summaryB)
        try await waitUntil { fixture.store.detailLoadState == .loaded }

        fixture.store.selectSession(summaryA)
        XCTAssertTrue(fixture.store.isLoadingDetail)
        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["a-cached"])
        try await waitUntil { fixture.store.detailLoadState.errorMessage != nil }

        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["a-cached"])
        XCTAssertFalse(fixture.store.displayedMessages.map(\.id).contains("b-cached"))
        XCTAssertEqual(
            fixture.store.detailErrorMessage,
            "Fallo tardío de conversación simulado."
        )
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_CACHE_FAILURE_SNAPSHOT_PATH"
        )
        try await Task.sleep(nanoseconds: 120_000_000)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)
    }

    func testCachedTailNeverCrossesAReusedWindowWithADifferentSessionID() async throws {
        let original = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión original",
            messages: [
                FerminRelayMessage(
                    id: "old-session-message",
                    role: "assistant",
                    content: "No debe cruzar al reemplazo",
                    timestamp: 100,
                    status: "completed"
                ),
            ]
        )
        let fixture = try makeFixture(
            detailFetchDelaysNanoseconds: [0, 150_000_000],
            detailResponseItems: [original, original]
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        let originalSummary = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(originalSummary)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        let originalInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)
        XCTAssertTrue(originalInstanceID.contains("base-session"))
        fixture.store.composerText = "Borrador de la instancia original"

        let replacementSummary = FerminCodeRelaySourcedSession(
            source: .personal,
            session: makeDetailSession(
                windowID: "base-window",
                sessionID: "replacement-session",
                displayName: "Sesión reemplazada",
                model: "gpt-5.6-luna",
                reasoningEffort: "low",
                messages: []
            )
        )
        fixture.store.selectSession(replacementSummary)

        XCTAssertTrue(fixture.store.isLoadingDetail)
        XCTAssertEqual(fixture.store.detailLoadState, .loading)
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        let replacementInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)
        XCTAssertTrue(replacementInstanceID.contains("replacement-session"))
        XCTAssertNotEqual(replacementInstanceID, originalInstanceID)
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, originalSummary.session.windowID)
        XCTAssertTrue(fixture.store.composerText.isEmpty)
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_REUSED_SESSION_SNAPSHOT_PATH"
        )
        try await waitUntil { fixture.store.detailLoadState.errorMessage != nil }
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "replacement-session")
        XCTAssertTrue(fixture.store.displayedMessages.isEmpty)
        XCTAssertTrue(fixture.store.detailErrorMessage?.contains("no coincide") == true)
    }

    func testMismatchedConversationDetailCannotReplaceTheSelectedSummary() async throws {
        let fixture = try makeFixture(detailMismatchFetches: [1])
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { !fixture.store.isBootstrapping }
        try await selectBaseSession(in: fixture)
        try await waitUntil { !fixture.store.isLoadingDetail }

        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "base-window")
        XCTAssertEqual(fixture.store.selectedSession?.windowID, "base-window")
        XCTAssertTrue(fixture.store.detailErrorMessage?.contains("no coincide") == true)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.selectedSourceStatus?.phase, .stale)
    }

    func testModelMutationDoesNotBlockOrErrorTheNextSession() async throws {
        let fixture = try makeFixture(
            modelMutationDelayNanoseconds: 60_000_000,
            modelMutationShouldFail: true
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let applyTask = Task {
            await fixture.store.setRuntimeModel(model: "gpt-5.6-sol", effort: "max")
        }
        try await waitUntil { fixture.store.isApplyingSelectedRuntimeModel }

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)

        XCTAssertFalse(fixture.store.isApplyingSelectedRuntimeModel)
        let applied = await applyTask.value
        XCTAssertFalse(applied)
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testPromptPreferenceApplyUpdatesTheSelectedRelay() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let applied = await fixture.store.setPromptPreference(.motivational)

        XCTAssertTrue(applied)
        XCTAssertEqual(fixture.store.promptPreferences[.personal]?.variant, .motivational)
        XCTAssertEqual(fixture.store.promptPreferenceLabel, "Motivacional")
        XCTAssertEqual(fixture.store.selectedPromptPreferenceLabel, "Motivacional")
        XCTAssertFalse(fixture.store.activeMutations.contains("prompt-preference"))
    }

    func testNewErrorClearsAnOlderSuccessNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }

        let saved = await fixture.store.saveCredential("token reemplazado", for: .personal)
        XCTAssertTrue(saved)
        XCTAssertNotNil(fixture.store.notice)

        fixture.store.errorMessage = "Fallo posterior"

        XCTAssertNil(fixture.store.notice)
        XCTAssertEqual(fixture.store.errorMessage, "Fallo posterior")
    }

    func testAuthoritativeUserMessageClearsOnlyItsPendingSendIndicator() async throws {
        let fixture = try makeFixture(sendCommandState: .accepted)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        fixture.store.composerText = "mensaje confirmado por transcript"
        let sent = await fixture.store.sendComposer()

        XCTAssertTrue(sent)
        XCTAssertEqual(fixture.store.pendingCommands.count, 1)

        await fixture.store.refreshDetail()

        XCTAssertTrue(fixture.store.pendingCommands.isEmpty)
        XCTAssertTrue(fixture.store.optimisticMessages.isEmpty)
        XCTAssertEqual(
            fixture.store.selectedSession?.messages.first?.content,
            "mensaje confirmado por transcript"
        )
    }

    func testCreateWaitsPastSixtyVirtualSecondsForRustSession() async throws {
        let clock = LockedVirtualClock()
        let fixture = try makeFixture(
            clock: clock,
            slowCreatePolls: 125
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        fixture.store.selectProfile(.personal)

        let created = await fixture.store.createSession(
            projectPath: "/Users/test/projects/fermin-code",
            name: "Rust lento"
        )

        XCTAssertTrue(created)
        XCTAssertGreaterThanOrEqual(clock.now(), 60)
        XCTAssertEqual(fixture.store.selectedSession?.displayName, "Rust lento")
        let runtime = await fixture.relay.createdSessionRuntime()
        XCTAssertEqual(runtime.model, "gpt-5.6-sol")
        XCTAssertEqual(runtime.reasoningEffort, "max")
        let pollCount = await fixture.relay.pollsAfterCreate()
        XCTAssertGreaterThanOrEqual(pollCount, 121)
    }

    func testConfirmedCreatedSessionClearsNonterminalCreateCommand() async throws {
        let fixture = try makeFixture(createCommandState: .sentToChild)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        fixture.store.selectProfile(.personal)

        let created = await fixture.store.createSession(
            projectPath: "/Users/test/projects/fermin-code",
            name: "Creación confirmada"
        )

        XCTAssertTrue(created)
        XCTAssertTrue(fixture.store.pendingCommands.isEmpty)
    }

    func testAuthoritativeSnapshotResetsPersistedHigherCursor() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        let key = "fermin.code.desktop.sse.personal.\(FerminCodeRelaySource.personal.productionBaseURL.absoluteString).cursor"
        fixture.defaults.set("99", forKey: key)

        fixture.store.start()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }

        XCTAssertEqual(fixture.defaults.string(forKey: key), "0")
    }

    func testStreamOverflowForcesAuthoritativeRefetchBeforeReconnect() async throws {
        let fixture = try makeFixture(streamOverflowOnce: true)
        defer { fixture.store.stop() }
        fixture.store.start()
        var fetchCount = 0
        for _ in 0..<800 {
            fetchCount = await fixture.relay.sessionFetches()
            if fetchCount >= 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertGreaterThanOrEqual(fetchCount, 2)
    }

    func testStreamOverflowAlignsOldCursorWithAuthoritativeRecoveryBeforeReconnect() async throws {
        let fixture = try makeFixture(
            streamOverflowOnDemand: true,
            authoritativeSnapshotCursor: 199_422
        )
        defer { fixture.store.stop() }
        let key = "fermin.code.desktop.sse.personal.\(FerminCodeRelaySource.personal.productionBaseURL.absoluteString).cursor"
        fixture.defaults.set("94731", forKey: key)

        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntilAsync {
            await fixture.relay.activeStreamCount() == 1
        }
        let initialCursorRequests = await fixture.relay.streamCursorRequests()
        XCTAssertEqual(initialCursorRequests.count, 1)
        XCTAssertEqual(initialCursorRequests[0], UInt64(94_731))
        XCTAssertTrue(fixture.store.selectedSession?.messages.isEmpty == true)

        await fixture.relay.triggerStreamOverflow()

        try await waitUntil(timeoutIterations: 1_500) {
            fixture.defaults.string(forKey: key) == "199422"
                && fixture.store.selectedSession?.displayName == "Snapshot autoritativo"
                && fixture.store.selectedSession?.messages.first?.content == "Detalle autoritativo"
        }
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.streamCursorRequests().count >= 2
        }

        let requestedCursors = await fixture.relay.streamCursorRequests()
        XCTAssertGreaterThanOrEqual(requestedCursors.count, 2)
        XCTAssertEqual(requestedCursors[0], UInt64(94_731))
        XCTAssertEqual(requestedCursors[1], UInt64(199_422))
        XCTAssertEqual(requestedCursors.filter { $0 == 94_731 }.count, 1)
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .online)
        XCTAssertEqual(
            fixture.store.sourcedSessions.first { $0.source == .personal }?.session.displayName,
            "Snapshot autoritativo"
        )
        let sessionFetches = await fixture.relay.sessionFetches()
        let detailFetches = await fixture.relay.detailFetches()
        XCTAssertGreaterThanOrEqual(sessionFetches, 2)
        XCTAssertGreaterThanOrEqual(detailFetches, 2)
    }

    func testLateOmittedRecoveryDetailCannotOverwriteNewerRefresh() async throws {
        let initialMessage = FerminRelayMessage(
            id: "omitted-initial",
            role: "assistant",
            content: "Detalle inicial",
            timestamp: 100,
            status: "completed"
        )
        let staleMessage = FerminRelayMessage(
            id: "omitted-stale",
            role: "assistant",
            content: "Recovery anterior",
            timestamp: 101,
            status: "completed"
        )
        let freshMessage = FerminRelayMessage(
            id: "omitted-fresh",
            role: "assistant",
            content: "Recarga más nueva",
            timestamp: 102,
            status: "completed"
        )
        let initial = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Detalle inicial",
            messages: [initialMessage]
        )
        let stale = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recovery anterior",
            messages: [staleMessage]
        )
        let fresh = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recarga más nueva",
            messages: [freshMessage]
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [initial],
            heldDetailFetches: [2, 4],
            detailResponseItems: [initial, stale, fresh, fresh]
        )
        defer {
            fixture.store.stop()
            Task { await fixture.relay.releaseAllHeldDetailFetches() }
        }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        let selectedInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        await fixture.relay.emitStreamEvent(
            .eventOmitted(
                FerminRelayOmittedEvent(
                    ok: false,
                    code: "payload_omitted",
                    reason: "fixture",
                    originalEvent: "snapshot",
                    originalBytes: 1,
                    refetchRequired: true
                )
            )
        )
        try await waitUntilAsync { await fixture.relay.isDetailFetchHeld(2) }

        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["omitted-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        await fixture.relay.releaseDetailFetch(2)
        try await waitUntilAsync { await fixture.relay.didCompleteDetailFetch(2) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(fixture.store.selectedSessionInstanceID, selectedInstanceID)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["omitted-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)

        fixture.store.clearSelection()
        let row = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(row)
        try await waitUntilAsync { await fixture.relay.isDetailFetchHeld(4) }

        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["omitted-fresh"])
        try renderConversation(
            store: fixture.store,
            snapshotEnvironmentKey: "FERMIN_DESKTOP_DETAIL_RECOVERY_OWNER_SNAPSHOT_PATH"
        )
        await fixture.relay.releaseDetailFetch(4)
        try await waitUntilAsync { await fixture.relay.didCompleteDetailFetch(4) }
    }

    func testUnknownOmittedRecoveryDetailCannotOverwriteNewerRefresh() async throws {
        let initialMessage = FerminRelayMessage(
            id: "unknown-omitted-initial",
            role: "assistant",
            content: "Detalle inicial legacy",
            timestamp: 100,
            status: "completed"
        )
        let staleMessage = FerminRelayMessage(
            id: "unknown-omitted-stale",
            role: "assistant",
            content: "Recovery legacy anterior",
            timestamp: 101,
            status: "completed"
        )
        let freshMessage = FerminRelayMessage(
            id: "unknown-omitted-fresh",
            role: "assistant",
            content: "Recarga legacy más nueva",
            timestamp: 102,
            status: "completed"
        )
        let initial = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Detalle inicial legacy",
            messages: [initialMessage]
        )
        let stale = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recovery legacy anterior",
            messages: [staleMessage]
        )
        let fresh = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recarga legacy más nueva",
            messages: [freshMessage]
        )
        let fixture = try makeFixture(
            initialSnapshotItems: [initial],
            heldDetailFetches: [2, 4],
            detailResponseItems: [initial, stale, fresh, fresh]
        )
        defer {
            fixture.store.stop()
            Task { await fixture.relay.releaseAllHeldDetailFetches() }
        }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        let selectedInstanceID = try XCTUnwrap(fixture.store.selectedSessionInstanceID)

        await fixture.relay.emitStreamEvent(
            .unknown(name: "event_omitted", data: Data())
        )
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.detailFetches() >= 2
        }

        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["unknown-omitted-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        await fixture.relay.releaseDetailFetch(2)
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.didCompleteDetailFetch(2)
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(fixture.store.selectedSessionInstanceID, selectedInstanceID)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["unknown-omitted-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
        let completedFetches = await fixture.relay.detailFetches()
        XCTAssertEqual(completedFetches, 3)

        fixture.store.clearSelection()
        let row = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(row)
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.detailFetches() >= 4
        }

        XCTAssertEqual(fixture.store.detailLoadState, .revalidating)
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["unknown-omitted-fresh"])
        await fixture.relay.releaseDetailFetch(4)
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.didCompleteDetailFetch(4)
        }
    }

    func testSupersededOverflowDetailFailureStillPersistsSnapshotCursorAndReconnects() async throws {
        let initialMessage = FerminRelayMessage(
            id: "overflow-initial",
            role: "assistant",
            content: "Detalle inicial",
            timestamp: 100,
            status: "completed"
        )
        let staleMessage = FerminRelayMessage(
            id: "overflow-stale",
            role: "assistant",
            content: "Recovery anterior",
            timestamp: 101,
            status: "completed"
        )
        let freshMessage = FerminRelayMessage(
            id: "overflow-fresh",
            role: "assistant",
            content: "Recarga vigente",
            timestamp: 102,
            status: "completed"
        )
        let initial = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Detalle inicial",
            messages: [initialMessage]
        )
        let stale = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recovery anterior",
            messages: [staleMessage]
        )
        let fresh = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Recarga vigente",
            messages: [freshMessage]
        )
        let authoritativeSummary = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Snapshot autoritativo",
            messages: []
        )
        let fixture = try makeFixture(
            streamOverflowOnDemand: true,
            authoritativeSnapshotCursor: 199_422,
            initialSnapshotItems: [initial],
            heldDetailFetches: [2],
            detailFailureFetches: [2],
            detailResponseItems: [initial, stale, fresh]
        )
        defer {
            fixture.store.stop()
            Task { await fixture.relay.releaseAllHeldDetailFetches() }
        }
        let key = "fermin.code.desktop.sse.personal.\(FerminCodeRelaySource.personal.productionBaseURL.absoluteString).cursor"
        fixture.defaults.set("94731", forKey: key)
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        await fixture.relay.enqueueSnapshot([authoritativeSummary], held: false)

        await fixture.relay.triggerStreamOverflow()
        try await waitUntilAsync { await fixture.relay.isDetailFetchHeld(2) }

        await fixture.store.refreshDetail()

        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["overflow-fresh"])
        await fixture.relay.releaseDetailFetch(2)
        try await waitUntilAsync { await fixture.relay.didCompleteDetailFetch(2) }
        try await waitUntil(timeoutIterations: 1_500) {
            fixture.defaults.string(forKey: key) == "199422"
                && fixture.store.sourceStatuses[.personal]?.phase == .online
        }
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.streamCursorRequests().count >= 2
        }

        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["overflow-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(
            fixture.store.sourcedSessions.first { $0.source == .personal }?.session.displayName,
            "Snapshot autoritativo"
        )
        let requestedCursors = await fixture.relay.streamCursorRequests()
        XCTAssertEqual(requestedCursors[0], UInt64(94_731))
        XCTAssertEqual(requestedCursors[1], UInt64(199_422))
        XCTAssertEqual(requestedCursors.filter { $0 == 94_731 }.count, 1)
    }

    func testStreamOverflowRecoveryAtoBDoesNotMarkSourceOfflineOrLoseAuthoritativeCursor() async throws {
        let initialA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A inicial",
            messages: [
                FerminRelayMessage(
                    id: "overflow-a-initial",
                    role: "assistant",
                    content: "Detalle inicial de A",
                    timestamp: 100,
                    status: "completed"
                ),
            ]
        )
        let staleA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A anterior",
            messages: [
                FerminRelayMessage(
                    id: "overflow-a-stale",
                    role: "assistant",
                    content: "Recovery anterior de A",
                    timestamp: 101,
                    status: "completed"
                ),
            ]
        )
        let initialB = makeDetailSession(
            windowID: "handoff-b-window",
            sessionID: "handoff-b-session",
            displayName: "Sesión B inicial",
            messages: []
        )
        let freshB = makeDetailSession(
            windowID: "handoff-b-window",
            sessionID: "handoff-b-session",
            displayName: "Sesión B vigente",
            messages: [
                FerminRelayMessage(
                    id: "overflow-b-fresh",
                    role: "assistant",
                    content: "Detalle vigente de B",
                    timestamp: 102,
                    status: "completed"
                ),
            ]
        )
        let authoritativeA = makeDetailSession(
            windowID: "base-window",
            sessionID: "base-session",
            displayName: "Sesión A autoritativa",
            messages: []
        )
        let authoritativeB = makeDetailSession(
            windowID: "handoff-b-window",
            sessionID: "handoff-b-session",
            displayName: "Sesión B autoritativa",
            messages: []
        )
        let fixture = try makeFixture(
            streamOverflowOnDemand: true,
            authoritativeSnapshotCursor: 199_422,
            initialSnapshotItems: [initialA, initialB],
            heldDetailFetches: [2],
            detailResponseItems: [initialA, staleA, freshB]
        )
        defer {
            fixture.store.stop()
            Task { await fixture.relay.releaseAllHeldDetailFetches() }
        }
        let key = "fermin.code.desktop.sse.personal.\(FerminCodeRelaySource.personal.productionBaseURL.absoluteString).cursor"
        fixture.defaults.set("94731", forKey: key)
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        try await waitUntil { fixture.store.detailLoadState == .loaded }
        try await waitUntilAsync { await fixture.relay.activeStreamCount() == 1 }
        await fixture.relay.enqueueSnapshot(
            [authoritativeA, authoritativeB],
            held: false
        )

        await fixture.relay.triggerStreamOverflow()
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.detailFetches() >= 2
        }

        let sessionB = try XCTUnwrap(
            fixture.store.sourcedSessions.first {
                $0.source == .personal
                    && $0.session.windowID == "handoff-b-window"
            }
        )
        fixture.store.selectSession(sessionB)
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.didCompleteDetailFetch(3)
        }
        try await waitUntil {
            fixture.store.selectedRoute?.windowID == "handoff-b-window"
                && fixture.store.detailLoadState == .loaded
        }
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["overflow-b-fresh"])

        await fixture.relay.releaseDetailFetch(2)
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.didCompleteDetailFetch(2)
        }
        try await waitUntil(timeoutIterations: 1_500) {
            fixture.defaults.string(forKey: key) == "199422"
                && fixture.store.sourceStatuses[.personal]?.phase == .online
        }
        try await waitUntilAsync(timeoutIterations: 1_500) {
            await fixture.relay.streamCursorRequests().count >= 2
        }

        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "handoff-b-window")
        XCTAssertEqual(fixture.store.selectedSession?.sessionID, "handoff-b-session")
        XCTAssertEqual(fixture.store.displayedMessages.map(\.id), ["overflow-b-fresh"])
        XCTAssertEqual(fixture.store.detailLoadState, .loaded)
        XCTAssertNil(fixture.store.detailErrorMessage)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.sourceStatuses[.personal]?.phase, .online)
        XCTAssertEqual(fixture.defaults.string(forKey: key), "199422")
        let requestedCursors = await fixture.relay.streamCursorRequests()
        XCTAssertEqual(requestedCursors[0], UInt64(94_731))
        XCTAssertEqual(requestedCursors[1], UInt64(199_422))
        XCTAssertEqual(requestedCursors.filter { $0 == 94_731 }.count, 1)
    }

    func testOrdinaryRefreshDoesNotAdvanceCursorWithoutAuthoritativeDetailRecovery() async throws {
        let fixture = try makeFixture(authoritativeSnapshotCursor: 199_422)
        defer { fixture.store.stop() }
        let key = "fermin.code.desktop.sse.personal.\(FerminCodeRelaySource.personal.productionBaseURL.absoluteString).cursor"
        fixture.defaults.set("94731", forKey: key)

        fixture.store.start()
        try await waitUntil { fixture.store.sourceStatuses[.personal]?.phase == .online }
        try await waitUntilAsync {
            !(await fixture.relay.streamCursorRequests()).isEmpty
        }
        await fixture.store.refreshAll()

        XCTAssertEqual(fixture.defaults.string(forKey: key), "94731")
        let requestedCursors = await fixture.relay.streamCursorRequests()
        XCTAssertFalse(requestedCursors.isEmpty)
        XCTAssertEqual(requestedCursors[0], UInt64(94_731))
    }

    func testSubagentFailsClosedWhenAcceptedChildNeverAppears() async throws {
        let clock = LockedVirtualClock()
        let fixture = try makeFixture(clock: clock)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.isSubagentPresented = true

        let created = await fixture.store.createSubagent(
            message: "Investigá el contrato sin enviarlo como chat.",
            displayName: "Auditor"
        )

        XCTAssertFalse(created)
        XCTAssertTrue(fixture.store.isSubagentPresented)
        XCTAssertEqual(fixture.store.selectedSession?.windowID, "base-window")
        XCTAssertGreaterThanOrEqual(clock.now(), 150)
        XCTAssertTrue(fixture.store.errorMessage?.contains("150 segundos") == true)
        let sentMessageCount = await fixture.relay.sentMessageCount()
        XCTAssertEqual(sentMessageCount, 0)
    }

    func testSubagentStartsAndNavigatesOnlyAfterExecutionIsVisible() async throws {
        let fixture = try makeFixture(subagentAppearsAfterPolls: 3)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.isSubagentPresented = true
        fixture.store.composerText = "borrador para enviar manualmente"
        fixture.store.subagentDisplayNameDraft = "Auditor"
        fixture.store.subagentTaskDraft = "Revisá el flujo Personal."
        XCTAssertFalse(fixture.store.canInvokeComposerShortcut)

        let created = await fixture.store.createSubagent(
            message: fixture.store.subagentTaskDraft,
            displayName: fixture.store.subagentDisplayNameDraft
        )

        XCTAssertTrue(created)
        XCTAssertFalse(fixture.store.isSubagentPresented)
        XCTAssertEqual(fixture.store.selectedSession?.windowID, "child-window")
        XCTAssertEqual(fixture.store.composerText, "")
        XCTAssertEqual(fixture.store.subagentTaskDraft, "")
        XCTAssertEqual(fixture.store.subagentDisplayNameDraft, "")
        XCTAssertEqual(fixture.store.selectedSession?.runtimeStatus, "WORKING")
        XCTAssertNotNil(fixture.store.selectedSession?.pendingSubagent?.childMessageSentAt)
        let originalSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(originalSession)
        XCTAssertEqual(fixture.store.composerText, "borrador para enviar manualmente")
        let sentMessageCount = await fixture.relay.sentMessageCount()
        let subagentMessage = await fixture.relay.createdSubagentMessage()
        XCTAssertEqual(sentMessageCount, 0)
        XCTAssertEqual(subagentMessage, "Revisá el flujo Personal.")
    }

    func testBackgroundSubagentDoesNotHijackOrClearTheNextSessionDraft() async throws {
        let fixture = try makeFixture(
            subagentAppearsAfterPolls: 1,
            refreshDelayNanoseconds: 60_000_000
        )
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        let originalSession = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.isSubagentPresented = true
        fixture.store.subagentDisplayNameDraft = "Auditor original"
        fixture.store.subagentTaskDraft = "Revisá la sesión original."

        let creation = Task {
            await fixture.store.createSubagent(
                message: fixture.store.subagentTaskDraft,
                displayName: fixture.store.subagentDisplayNameDraft
            )
        }
        try await waitUntil { fixture.store.isCreatingSubagentForSelectedSession }
        fixture.store.isSubagentPresented = false

        let nextSession = FerminCodeRelaySourcedSession(
            source: .personal,
            session: FerminRelaySession(
                windowID: "next-window",
                sessionID: "next-session",
                displayName: "Sesión siguiente",
                activityStatus: "ready",
                canSend: true
            )
        )
        fixture.store.selectSession(nextSession)
        XCTAssertFalse(fixture.store.isCreatingSubagentForSelectedSession)
        XCTAssertEqual(fixture.store.subagentTaskDraft, "")
        fixture.store.subagentDisplayNameDraft = "Auditor siguiente"
        fixture.store.subagentTaskDraft = "Revisá la sesión siguiente."

        let created = await creation.value

        XCTAssertTrue(created)
        XCTAssertEqual(fixture.store.selectedRoute?.windowID, "next-window")
        XCTAssertEqual(fixture.store.subagentDisplayNameDraft, "Auditor siguiente")
        XCTAssertEqual(fixture.store.subagentTaskDraft, "Revisá la sesión siguiente.")
        XCTAssertTrue(fixture.store.notice?.contains("Sesión base") == true)

        fixture.store.selectSession(originalSession)
        XCTAssertEqual(fixture.store.subagentDisplayNameDraft, "")
        XCTAssertEqual(fixture.store.subagentTaskDraft, "")
        fixture.store.selectSession(nextSession)
        XCTAssertEqual(fixture.store.subagentDisplayNameDraft, "Auditor siguiente")
        XCTAssertEqual(fixture.store.subagentTaskDraft, "Revisá la sesión siguiente.")
    }

    func testSubagentRejectsAnOverlongOptionalNameBeforeCallingTheRelay() async throws {
        let fixture = try makeFixture(subagentAppearsAfterPolls: 1)
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)

        let created = await fixture.store.createSubagent(
            message: "Revisá el límite.",
            displayName: String(
                repeating: "x",
                count: FerminCodeDesktopSessionNamePolicy.maximumLength + 1
            )
        )

        XCTAssertFalse(created)
        let createdMessage = await fixture.relay.createdSubagentMessage()
        XCTAssertNil(createdMessage)
        XCTAssertTrue(fixture.store.errorMessage?.contains("64") == true)
    }

    func testSubagentRejectsAndRendersAnOversizedTaskBeforeTransport() async throws {
        let fixture = try makeFixture()
        defer { fixture.store.stop() }
        fixture.store.start()
        try await selectBaseSession(in: fixture)
        fixture.store.subagentTaskDraft = String(
            repeating: "a",
            count: FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes + 1
        )
        fixture.store.isSubagentPresented = true

        let created = await fixture.store.createSubagent(
            message: fixture.store.subagentTaskDraft,
            displayName: nil
        )
        XCTAssertFalse(created)
        XCTAssertEqual(
            fixture.store.subagentTaskDraft.utf8.count,
            FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes + 1
        )
        let createdMessage = await fixture.relay.createdSubagentMessage()
        XCTAssertNil(createdMessage)
        fixture.store.errorMessage = nil

        let size = NSSize(width: 520, height: 460)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopSubagentView()
                .environmentObject(fixture.store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment[
            "FERMIN_DESKTOP_OVERSIZED_SUBAGENT_SNAPSHOT_PATH"
        ], !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func makeDetailSession(
        windowID: String,
        sessionID: String,
        displayName: String,
        model: String = "gpt-5.6-sol",
        reasoningEffort: String = "max",
        activityStatus: String = "ready",
        messages: [FerminRelayMessage],
        features: FerminRelaySessionFeatures? = nil
    ) -> FerminRelaySession {
        return FerminRelaySession(
            windowID: windowID,
            sessionID: sessionID,
            engine: "codex",
            model: model,
            reasoningEffort: reasoningEffort,
            projectPath: "/Users/test/projects/fermin-code",
            projectName: "fermin-code",
            displayName: displayName,
            activityStatus: activityStatus,
            features: features,
            messageCount: messages.count,
            updatedAt: 100,
            canSend: true,
            messages: messages
        )
    }

    private func renderConversation(
        store: FerminCodeDesktopStore,
        snapshotEnvironmentKey: String
    ) throws {
        let size = NSSize(width: 720, height: 560)
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopConversationView()
                .environmentObject(store)
                .frame(width: size.width, height: size.height)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        if let path = ProcessInfo.processInfo.environment[snapshotEnvironmentKey],
           !path.isEmpty {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func makeFixture(
        clock: LockedVirtualClock = LockedVirtualClock(),
        slowCreatePolls: Int = 0,
        streamOverflowOnce: Bool = false,
        streamOverflowOnDemand: Bool = false,
        authoritativeSnapshotCursor: UInt64? = nil,
        initialSnapshotItems: [FerminRelaySession]? = nil,
        subagentAppearsAfterPolls: Int? = nil,
        createCommandState: FerminRelayDurableCommandState = .completed,
        sendCommandState: FerminRelayDurableCommandState = .completed,
        sendShouldFail: Bool = false,
        sendAcceptedButResponseLostOnce: Bool = false,
        sendDelayNanoseconds: UInt64 = 0,
        projectDelayNanoseconds: UInt64 = 0,
        projectFailureFetches: Set<Int> = [],
        refreshDelayNanoseconds: UInt64 = 0,
        historyDelayNanoseconds: UInt64 = 0,
        historyFailureFetches: Set<Int> = [],
        resumeHistoryDelayNanoseconds: UInt64 = 0,
        resumeHistoryShouldFail: Bool = false,
        preferenceDelayNanoseconds: UInt64 = 0,
        modelFetchDelaysNanoseconds: [UInt64] = [],
        modelFailureFetches: Set<Int> = [],
        heldDetailFetches: Set<Int> = [],
        detailFetchDelaysNanoseconds: [UInt64] = [],
        detailFailureFetches: Set<Int> = [],
        detailMismatchFetches: Set<Int> = [],
        detailResponseItems: [FerminRelaySession] = [],
        attachmentDelayNanoseconds: UInt64 = 0,
        attachmentFailureFetches: Set<Int> = [],
        featureDelayNanoseconds: UInt64 = 0,
        heldFeatureCalls: Set<Int> = [],
        featureShouldFail: Bool = false,
        featureFailureCalls: Set<Int> = [],
        goalMutationDelayNanoseconds: UInt64 = 0,
        goalMutationShouldFail: Bool = false,
        modelMutationDelayNanoseconds: UInt64 = 0,
        modelMutationShouldFail: Bool = false,
        lifecycleMutationDelayNanoseconds: UInt64 = 0,
        createDelayNanoseconds: UInt64 = 0,
        profile: FerminCodeRelayProfile = .personal,
        personalToken: String? = "test-token",
        pukyToken: String? = nil
    ) throws -> StoreFixture {
        let relay = FerminCodeDesktopRelayMock(
            slowCreatePolls: slowCreatePolls,
            streamOverflowOnce: streamOverflowOnce,
            streamOverflowOnDemand: streamOverflowOnDemand,
            authoritativeSnapshotCursor: authoritativeSnapshotCursor,
            initialSnapshotItems: initialSnapshotItems,
            subagentAppearsAfterPolls: subagentAppearsAfterPolls,
            createCommandState: createCommandState,
            sendCommandState: sendCommandState,
            sendShouldFail: sendShouldFail,
            sendAcceptedButResponseLostOnce: sendAcceptedButResponseLostOnce,
            sendDelayNanoseconds: sendDelayNanoseconds,
            projectDelayNanoseconds: projectDelayNanoseconds,
            projectFailureFetches: projectFailureFetches,
            refreshDelayNanoseconds: refreshDelayNanoseconds,
            historyDelayNanoseconds: historyDelayNanoseconds,
            historyFailureFetches: historyFailureFetches,
            resumeHistoryDelayNanoseconds: resumeHistoryDelayNanoseconds,
            resumeHistoryShouldFail: resumeHistoryShouldFail,
            preferenceDelayNanoseconds: preferenceDelayNanoseconds,
            modelFetchDelaysNanoseconds: modelFetchDelaysNanoseconds,
            modelFailureFetches: modelFailureFetches,
            heldDetailFetches: heldDetailFetches,
            detailFetchDelaysNanoseconds: detailFetchDelaysNanoseconds,
            detailFailureFetches: detailFailureFetches,
            detailMismatchFetches: detailMismatchFetches,
            detailResponseItems: detailResponseItems,
            attachmentDelayNanoseconds: attachmentDelayNanoseconds,
            attachmentFailureFetches: attachmentFailureFetches,
            featureDelayNanoseconds: featureDelayNanoseconds,
            heldFeatureCalls: heldFeatureCalls,
            featureShouldFail: featureShouldFail,
            featureFailureCalls: featureFailureCalls,
            goalMutationDelayNanoseconds: goalMutationDelayNanoseconds,
            goalMutationShouldFail: goalMutationShouldFail,
            modelMutationDelayNanoseconds: modelMutationDelayNanoseconds,
            modelMutationShouldFail: modelMutationShouldFail,
            lifecycleMutationDelayNanoseconds: lifecycleMutationDelayNanoseconds,
            createDelayNanoseconds: createDelayNanoseconds
        )
        let credentialStore = FerminCodeCredentialStore(
            vaults: [
                .personal: InMemoryCredentialVault(token: personalToken),
                .puky: InMemoryCredentialVault(token: pukyToken),
            ],
            bootstrapDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        )
        let suiteName = "FerminCodeDesktopStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(profile.rawValue, forKey: FerminCodeDesktopPreferences.profileKey)
        let timing = FerminCodeDesktopTiming(
            now: { clock.now() },
            sleep: { nanoseconds in clock.advance(nanoseconds: nanoseconds) }
        )
        let store = FerminCodeDesktopStore(
            relay: relay,
            credentialStore: credentialStore,
            defaults: defaults,
            timing: timing,
            createConfirmationTimeout: 150,
            createPollNanoseconds: 500_000_000
        )
        return StoreFixture(store: store, relay: relay, defaults: defaults, suiteName: suiteName)
    }

    private func selectBaseSession(in fixture: StoreFixture) async throws {
        try await waitUntil { !fixture.store.sourcedSessions.isEmpty }
        fixture.store.selectProfile(.personal)
        let session = try XCTUnwrap(
            fixture.store.sourcedSessions.first { $0.session.windowID == "base-window" }
        )
        fixture.store.selectSession(session)
        try await waitUntil { fixture.store.selectedSession?.windowID == "base-window" }
    }

    private func loadPersonalHistoryItem(
        in fixture: StoreFixture
    ) async throws -> FerminCodeDesktopSourcedHistoryItem {
        fixture.store.isHistoryPresented = true
        await fixture.store.loadHistory()
        return try XCTUnwrap(
            fixture.store.historyItems.first { $0.source == .personal }
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 300,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("La condición esperada no se cumplió.")
    }

    private func waitUntilAsync(
        timeoutIterations: Int = 300,
        _ predicate: () async -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("La condición async esperada no se cumplió.")
    }
}

private struct StoreFixture {
    let store: FerminCodeDesktopStore
    let relay: FerminCodeDesktopRelayMock
    let defaults: UserDefaults
    let suiteName: String

    init(
        store: FerminCodeDesktopStore,
        relay: FerminCodeDesktopRelayMock,
        defaults: UserDefaults,
        suiteName: String
    ) {
        self.store = store
        self.relay = relay
        self.defaults = defaults
        self.suiteName = suiteName
    }
}

private struct HistoryLifecycleHarness: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore

    var body: some View {
        Group {
            if store.isHistoryPresented {
                FerminCodeDesktopHistoryView()
            } else {
                Color.clear
            }
        }
    }
}

private final class LockedVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        value += TimeInterval(nanoseconds) / 1_000_000_000
        lock.unlock()
    }
}

private final class InMemoryCredentialVault: FerminCodeCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func save(_ token: String) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        token = nil
        lock.unlock()
    }
}

private actor FerminCodeDesktopRelayMock: FerminCodeDesktopRelayServing {
    private let slowCreatePolls: Int
    private let streamOverflowOnce: Bool
    private let streamOverflowOnDemand: Bool
    private let authoritativeSnapshotCursor: UInt64?
    private let initialSnapshotItems: [FerminRelaySession]?
    private let subagentAppearsAfterPolls: Int?
    private let createCommandState: FerminRelayDurableCommandState
    private let sendCommandState: FerminRelayDurableCommandState
    private let sendShouldFail: Bool
    private let sendAcceptedButResponseLostOnce: Bool
    private let sendDelayNanoseconds: UInt64
    private let projectDelayNanoseconds: UInt64
    private let projectFailureFetches: Set<Int>
    private let refreshDelayNanoseconds: UInt64
    private let historyDelayNanoseconds: UInt64
    private let historyFailureFetches: Set<Int>
    private let resumeHistoryDelayNanoseconds: UInt64
    private let resumeHistoryShouldFail: Bool
    private let preferenceDelayNanoseconds: UInt64
    private let modelFetchDelaysNanoseconds: [UInt64]
    private let modelFailureFetches: Set<Int>
    private let heldDetailFetches: Set<Int>
    private let detailFetchDelaysNanoseconds: [UInt64]
    private let detailFailureFetches: Set<Int>
    private let detailMismatchFetches: Set<Int>
    private let detailResponseItems: [FerminRelaySession]
    private let attachmentDelayNanoseconds: UInt64
    private let attachmentFailureFetches: Set<Int>
    private let featureDelayNanoseconds: UInt64
    private let heldFeatureCalls: Set<Int>
    private let featureShouldFail: Bool
    private let featureFailureCalls: Set<Int>
    private let goalMutationDelayNanoseconds: UInt64
    private let goalMutationShouldFail: Bool
    private let modelMutationDelayNanoseconds: UInt64
    private let modelMutationShouldFail: Bool
    private let lifecycleMutationDelayNanoseconds: UInt64
    private let createDelayNanoseconds: UInt64
    private var createRequest: FerminRelayCreateSessionRequest?
    private var createRequestSource: FerminCodeRelaySource?
    private var subagentRequest: FerminRelayCreateSubagentRequest?
    private var postCreatePollCount = 0
    private var postSubagentPollCount = 0
    private var sessionFetchCount = 0
    private var didEmitStreamOverflow = false
    private var streamRequestedCursors: [UInt64?] = []
    private var sentRequests: [FerminRelaySendMessageRequest] = []
    private var featurePatches: [FerminRelayFeaturePatch] = []
    private var featureReleaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var goalModeValues: [Bool] = []
    private var orderedComposerOperations: [String] = []
    private var projectFetchCount = 0
    private var historyFetchCount = 0
    private var preferenceFetchCount = 0
    private var modelFetchCount = 0
    private var detailFetchCount = 0
    private var detailFetchReleaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var detailFetchStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var detailFetchCompletionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completedDetailFetches: Set<Int> = []
    private var attachmentFetchCount = 0
    private var createRequestCount = 0
    private var createSources: [FerminCodeRelaySource] = []
    private var fetchedProjectSources: [FerminCodeRelaySource] = []
    private var deletedWindowIDs: [String] = []
    private var pinnedChanges: [Bool] = []
    private var promptPreferenceVariant = FerminRelayPromptImproverVariant.standard
    private var streamContinuations: [
        UUID: AsyncThrowingStream<FerminRelayStreamDelivery, Error>.Continuation
    ] = [:]
    private var queuedSnapshots: [(items: [FerminRelaySession], held: Bool)] = []
    private var snapshotReleaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        slowCreatePolls: Int,
        streamOverflowOnce: Bool,
        streamOverflowOnDemand: Bool,
        authoritativeSnapshotCursor: UInt64?,
        initialSnapshotItems: [FerminRelaySession]?,
        subagentAppearsAfterPolls: Int?,
        createCommandState: FerminRelayDurableCommandState,
        sendCommandState: FerminRelayDurableCommandState,
        sendShouldFail: Bool,
        sendAcceptedButResponseLostOnce: Bool,
        sendDelayNanoseconds: UInt64,
        projectDelayNanoseconds: UInt64,
        projectFailureFetches: Set<Int>,
        refreshDelayNanoseconds: UInt64,
        historyDelayNanoseconds: UInt64,
        historyFailureFetches: Set<Int>,
        resumeHistoryDelayNanoseconds: UInt64,
        resumeHistoryShouldFail: Bool,
        preferenceDelayNanoseconds: UInt64,
        modelFetchDelaysNanoseconds: [UInt64],
        modelFailureFetches: Set<Int>,
        heldDetailFetches: Set<Int>,
        detailFetchDelaysNanoseconds: [UInt64],
        detailFailureFetches: Set<Int>,
        detailMismatchFetches: Set<Int>,
        detailResponseItems: [FerminRelaySession],
        attachmentDelayNanoseconds: UInt64,
        attachmentFailureFetches: Set<Int>,
        featureDelayNanoseconds: UInt64,
        heldFeatureCalls: Set<Int>,
        featureShouldFail: Bool,
        featureFailureCalls: Set<Int>,
        goalMutationDelayNanoseconds: UInt64,
        goalMutationShouldFail: Bool,
        modelMutationDelayNanoseconds: UInt64,
        modelMutationShouldFail: Bool,
        lifecycleMutationDelayNanoseconds: UInt64,
        createDelayNanoseconds: UInt64
    ) {
        self.slowCreatePolls = slowCreatePolls
        self.streamOverflowOnce = streamOverflowOnce
        self.streamOverflowOnDemand = streamOverflowOnDemand
        self.authoritativeSnapshotCursor = authoritativeSnapshotCursor
        self.initialSnapshotItems = initialSnapshotItems
        self.subagentAppearsAfterPolls = subagentAppearsAfterPolls
        self.createCommandState = createCommandState
        self.sendCommandState = sendCommandState
        self.sendShouldFail = sendShouldFail
        self.sendAcceptedButResponseLostOnce = sendAcceptedButResponseLostOnce
        self.sendDelayNanoseconds = sendDelayNanoseconds
        self.projectDelayNanoseconds = projectDelayNanoseconds
        self.projectFailureFetches = projectFailureFetches
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.historyDelayNanoseconds = historyDelayNanoseconds
        self.historyFailureFetches = historyFailureFetches
        self.resumeHistoryDelayNanoseconds = resumeHistoryDelayNanoseconds
        self.resumeHistoryShouldFail = resumeHistoryShouldFail
        self.preferenceDelayNanoseconds = preferenceDelayNanoseconds
        self.modelFetchDelaysNanoseconds = modelFetchDelaysNanoseconds
        self.modelFailureFetches = modelFailureFetches
        self.heldDetailFetches = heldDetailFetches
        self.detailFetchDelaysNanoseconds = detailFetchDelaysNanoseconds
        self.detailFailureFetches = detailFailureFetches
        self.detailMismatchFetches = detailMismatchFetches
        self.detailResponseItems = detailResponseItems
        self.attachmentDelayNanoseconds = attachmentDelayNanoseconds
        self.attachmentFailureFetches = attachmentFailureFetches
        self.featureDelayNanoseconds = featureDelayNanoseconds
        self.heldFeatureCalls = heldFeatureCalls
        self.featureShouldFail = featureShouldFail
        self.featureFailureCalls = featureFailureCalls
        self.goalMutationDelayNanoseconds = goalMutationDelayNanoseconds
        self.goalMutationShouldFail = goalMutationShouldFail
        self.modelMutationDelayNanoseconds = modelMutationDelayNanoseconds
        self.modelMutationShouldFail = modelMutationShouldFail
        self.lifecycleMutationDelayNanoseconds = lifecycleMutationDelayNanoseconds
        self.createDelayNanoseconds = createDelayNanoseconds
    }

    func sentFastModes() -> [Bool?] {
        sentRequests.map(\.fastModeEnabled)
    }

    func sentMessageCount() -> Int {
        sentRequests.count
    }

    func sentMessageRequests() -> [FerminRelaySendMessageRequest] {
        sentRequests
    }

    func sentPromptImproverValues() -> [Bool?] {
        featurePatches.map(\.promptImproverEnabled)
    }

    func releaseFeatureCall(_ call: Int) {
        featureReleaseWaiters.removeValue(forKey: call)?.resume()
    }

    func sentGoalModeValues() -> [Bool] {
        goalModeValues
    }

    func composerOperationOrder() -> [String] {
        orderedComposerOperations
    }

    func projectFetches() -> Int {
        projectFetchCount
    }

    func preferenceFetches() -> Int {
        preferenceFetchCount
    }

    func createdSubagentMessage() -> String? {
        subagentRequest?.message
    }

    func pollsAfterCreate() -> Int {
        postCreatePollCount
    }

    func createdSessionRuntime() -> (model: String?, reasoningEffort: String?) {
        (createRequest?.model, createRequest?.reasoningEffort)
    }

    func sessionFetches() -> Int {
        sessionFetchCount
    }

    func historyFetches() -> Int {
        historyFetchCount
    }

    func streamCursorRequests() -> [UInt64?] {
        streamRequestedCursors
    }

    func activeStreamCount() -> Int {
        streamContinuations.count
    }

    func enqueueSnapshot(_ items: [FerminRelaySession], held: Bool) {
        queuedSnapshots.append((items: items, held: held))
    }

    func releaseNextSnapshot() {
        guard !snapshotReleaseContinuations.isEmpty else { return }
        snapshotReleaseContinuations.removeFirst().resume()
    }

    func emitStreamEvent(_ event: FerminRelayDecodedStreamEvent) {
        let delivery = FerminRelayStreamDelivery(
            eventID: nil,
            event: event,
            rawEvent: FerminRelaySSEEvent(id: nil, name: "test", data: Data())
        )
        for continuation in streamContinuations.values {
            _ = continuation.yield(delivery)
        }
    }

    func triggerStreamOverflow() {
        guard streamOverflowOnDemand, !didEmitStreamOverflow else { return }
        didEmitStreamOverflow = true
        let continuations = Array(streamContinuations.values)
        streamContinuations.removeAll()
        for continuation in continuations {
            continuation.finish(
                throwing: FerminRelayHTTPError.streamBufferOverflow(stage: .deliveries)
            )
        }
    }

    func modelFetches() -> Int {
        modelFetchCount
    }

    func detailFetches() -> Int {
        detailFetchCount
    }

    func isDetailFetchHeld(_ fetchNumber: Int) -> Bool {
        detailFetchReleaseWaiters[fetchNumber] != nil
    }

    func waitForDetailFetchStart(_ fetchNumber: Int) async {
        guard detailFetchCount < fetchNumber else { return }
        await withCheckedContinuation { continuation in
            if detailFetchCount >= fetchNumber {
                continuation.resume()
            } else {
                detailFetchStartWaiters[fetchNumber, default: []].append(continuation)
            }
        }
    }

    func waitForDetailFetchCompletion(_ fetchNumber: Int) async {
        guard !completedDetailFetches.contains(fetchNumber) else { return }
        await withCheckedContinuation { continuation in
            if completedDetailFetches.contains(fetchNumber) {
                continuation.resume()
            } else {
                detailFetchCompletionWaiters[fetchNumber, default: []].append(continuation)
            }
        }
    }

    func didCompleteDetailFetch(_ fetchNumber: Int) -> Bool {
        completedDetailFetches.contains(fetchNumber)
    }

    func releaseDetailFetch(_ fetchNumber: Int) {
        detailFetchReleaseWaiters.removeValue(forKey: fetchNumber)?.resume()
    }

    func releaseAllHeldDetailFetches() {
        let waiters = detailFetchReleaseWaiters.values
        detailFetchReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func attachmentFetches() -> Int {
        attachmentFetchCount
    }

    func createRequests() -> Int {
        createRequestCount
    }

    func createdSessionSources() -> [FerminCodeRelaySource] {
        createSources
    }

    func projectSources() -> [FerminCodeRelaySource] {
        fetchedProjectSources
    }

    func permanentlyDeletedWindowIDs() -> [String] {
        deletedWindowIDs
    }

    func pinnedStateChanges() -> [Bool] {
        pinnedChanges
    }

    func fetchHealth(source: FerminCodeRelaySource, token: String) async throws -> FerminRelayHealth {
        FerminRelayHealth(
            ok: true,
            ready: true,
            service: "fermin-code",
            version: "test",
            schemaVersion: 1,
            role: source.rawValue
        )
    }

    func fetchSessions(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelaySessionsEnvelope {
        sessionFetchCount += 1
        if refreshDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        guard source == .personal || createRequestSource == source else {
            return FerminRelaySessionsEnvelope(items: [])
        }
        if !queuedSnapshots.isEmpty {
            let snapshot = queuedSnapshots.removeFirst()
            if snapshot.held {
                await withCheckedContinuation { continuation in
                    snapshotReleaseContinuations.append(continuation)
                }
            }
            return FerminRelaySessionsEnvelope(
                now: Date().timeIntervalSince1970 * 1_000,
                items: snapshot.items,
                cursor: authoritativeSnapshotCursor ?? UInt64(postCreatePollCount)
            )
        }
        var items: [FerminRelaySession] = source == .personal
            ? initialSnapshotItems ?? [
                authoritativeSnapshotCursor != nil && sessionFetchCount > 1
                    ? Self.authoritativeRecoverySummary
                    : Self.baseSession
            ]
            : []
        items.removeAll { deletedWindowIDs.contains($0.windowID) }
        if let request = createRequest, createRequestSource == source {
            postCreatePollCount += 1
            if postCreatePollCount >= slowCreatePolls {
                items.insert(Self.createdSession(request), at: 0)
            }
        }
        if let request = subagentRequest, let subagentAppearsAfterPolls {
            postSubagentPollCount += 1
            if postSubagentPollCount >= subagentAppearsAfterPolls {
                items.insert(Self.childSession(request), at: 0)
            } else {
                items.insert(Self.stagedChildSession(request), at: 0)
            }
        }
        return FerminRelaySessionsEnvelope(
            now: Date().timeIntervalSince1970 * 1_000,
            items: items,
            cursor: authoritativeSnapshotCursor ?? UInt64(postCreatePollCount)
        )
    }

    func fetchSession(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelaySessionDetailEnvelope {
        detailFetchCount += 1
        let fetchNumber = detailFetchCount
        let startWaiters = detailFetchStartWaiters.removeValue(forKey: fetchNumber) ?? []
        for waiter in startWaiters {
            waiter.resume()
        }
        defer {
            completedDetailFetches.insert(fetchNumber)
            let completionWaiters = detailFetchCompletionWaiters.removeValue(forKey: fetchNumber) ?? []
            for waiter in completionWaiters {
                waiter.resume()
            }
        }
        if heldDetailFetches.contains(fetchNumber) {
            await withCheckedContinuation { continuation in
                detailFetchReleaseWaiters[fetchNumber] = continuation
            }
        }
        if detailFetchDelaysNanoseconds.indices.contains(fetchNumber - 1) {
            await waitIgnoringCancellation(
                nanoseconds: detailFetchDelaysNanoseconds[fetchNumber - 1]
            )
        }
        if detailFailureFetches.contains(fetchNumber) {
            throw FerminCodeDesktopUserError("Fallo tardío de conversación simulado.")
        }
        if detailMismatchFetches.contains(fetchNumber) {
            return FerminRelaySessionDetailEnvelope(item: Self.mismatchedSession)
        }
        if detailResponseItems.indices.contains(fetchNumber - 1) {
            return FerminRelaySessionDetailEnvelope(
                item: detailResponseItems[fetchNumber - 1]
            )
        }
        if authoritativeSnapshotCursor != nil,
           didEmitStreamOverflow,
           windowID == Self.baseSession.windowID {
            return FerminRelaySessionDetailEnvelope(item: Self.authoritativeRecoveryDetail)
        }
        if let request = createRequest, windowID == "created-window" {
            return FerminRelaySessionDetailEnvelope(item: Self.createdSession(request))
        }
        if let request = subagentRequest, windowID == "child-window" {
            return FerminRelaySessionDetailEnvelope(item: Self.childSession(request))
        }
        if windowID == Self.baseSession.windowID,
           !sendShouldFail,
           sendCommandState.isFailure == false,
           let request = sentRequests.last,
           let clientMessageID = request.clientMessageID {
            return FerminRelaySessionDetailEnvelope(
                item: Self.makeBaseSession(messages: [
                    FerminRelayMessage(
                        id: clientMessageID,
                        role: "user",
                        content: request.message,
                        timestamp: 101,
                        status: "completed"
                    ),
                ])
            )
        }
        if windowID == Self.baseSession.windowID {
            return FerminRelaySessionDetailEnvelope(item: Self.baseSession)
        }
        return FerminRelaySessionDetailEnvelope(
            item: Self.fallbackSession(windowID: windowID)
        )
    }

    func fetchModels(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayModelCatalogEnvelope {
        modelFetchCount += 1
        let fetchNumber = modelFetchCount
        if modelFetchDelaysNanoseconds.indices.contains(fetchNumber - 1) {
            await waitIgnoringCancellation(
                nanoseconds: modelFetchDelaysNanoseconds[fetchNumber - 1]
            )
        }
        if modelFailureFetches.contains(fetchNumber) {
            throw FerminCodeDesktopUserError("Fallo tardío de catálogo simulado.")
        }
        return FerminRelayModelCatalogEnvelope(
            ok: true,
            data: [
                FerminRelayAvailableModel(
                    id: "gpt-5.6-sol",
                    model: "gpt-5.6-sol",
                    modelProvider: "openai",
                    displayName: "GPT 5.6 SOL",
                    defaultReasoningEffort: "max",
                    supportedReasoningEfforts: [
                        FerminRelayReasoningEffortOption(
                            reasoningEffort: "max",
                            description: "Máxima profundidad"
                        ),
                    ],
                    isDefault: true
                ),
            ]
        )
    }

    func fetchProjects(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayProjectDirectoryEnvelope {
        projectFetchCount += 1
        fetchedProjectSources.append(source)
        if projectDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: projectDelayNanoseconds)
        }
        if projectFailureFetches.contains(projectFetchCount) {
            throw FerminCodeDesktopUserError("Fallo de proyectos simulado.")
        }
        return FerminRelayProjectDirectoryEnvelope(
            rootPath: "/Users/test/projects",
            items: [
                FerminRelayProjectDirectory(
                    name: "fermin-code",
                    path: "/Users/test/projects/fermin-code"
                ),
            ]
        )
    }

    func fetchHistory(
        source: FerminCodeRelaySource,
        token: String,
        query: FerminRelaySessionHistoryQuery
    ) async throws -> FerminRelaySessionHistoryEnvelope {
        historyFetchCount += 1
        let fetchNumber = historyFetchCount
        if historyDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: historyDelayNanoseconds)
        }
        if historyFailureFetches.contains(fetchNumber) {
            throw FerminCodeDesktopUserError("Fallo de historial simulado.")
        }
        let items = source == .personal
            ? [FerminRelaySessionHistoryItem(
                id: "personal-history",
                projectName: "fermin-code",
                sessionID: "history-session",
                sessionName: query.text.isEmpty ? "Historia Personal" : "Historia \(query.text)",
                updatedAt: 100,
                state: .active,
                canResume: true
            )]
            : []
        return FerminRelaySessionHistoryEnvelope(items: items, total: items.count)
    }

    func fetchPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope {
        preferenceFetchCount += 1
        let capturedVariant = promptPreferenceVariant
        if preferenceDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: preferenceDelayNanoseconds)
        }
        return FerminRelayPromptImproverPreferenceEnvelope(
            preference: FerminRelayPromptImproverPreference(variant: capturedVariant)
        )
    }

    func filePreview(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayFilePreview {
        attachmentFetchCount += 1
        let fetchNumber = attachmentFetchCount
        await waitIgnoringCancellation(nanoseconds: attachmentDelayNanoseconds)
        if attachmentFailureFetches.contains(fetchNumber) {
            throw FerminCodeDesktopUserError("Fallo tardío de adjunto simulado.")
        }
        return FerminRelayFilePreview(
            path: path,
            name: "file",
            content: "",
            kind: "text",
            sizeBytes: 0
        )
    }

    func fetchAttachmentContent(
        source: FerminCodeRelaySource,
        token: String,
        path: String
    ) async throws -> FerminRelayAttachmentContent {
        attachmentFetchCount += 1
        let fetchNumber = attachmentFetchCount
        await waitIgnoringCancellation(nanoseconds: attachmentDelayNanoseconds)
        if attachmentFailureFetches.contains(fetchNumber) {
            throw FerminCodeDesktopUserError("Fallo tardío de adjunto simulado.")
        }
        return FerminRelayAttachmentContent(data: Data(), mimeType: "image/png")
    }

    func createSession(
        source: FerminCodeRelaySource,
        token: String,
        request: FerminRelayCreateSessionRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        createRequestCount += 1
        createSources.append(source)
        await waitIgnoringCancellation(nanoseconds: createDelayNanoseconds)
        createRequest = request
        createRequestSource = source
        postCreatePollCount = 0
        return acknowledgement(
            commandID: "create-command",
            sessionID: request.sessionID,
            state: createCommandState
        )
    }

    func sendMessage(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelaySendMessageRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        orderedComposerOperations.append("message")
        sentRequests.append(request)
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if sendAcceptedButResponseLostOnce, sentRequests.count == 1 {
            throw FerminRelayHTTPError.transport(code: URLError.networkConnectionLost.rawValue)
        }
        if sendShouldFail {
            throw FerminCodeDesktopUserError("Fallo de envío simulado.")
        }
        return acknowledgement(
            commandID: "send-\(sentRequests.count)",
            windowID: windowID,
            sessionID: Self.baseSession.sessionID,
            clientMessageID: request.clientMessageID,
            state: sendCommandState
        )
    }

    func interrupt(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        acknowledgement(commandID: "interrupt", windowID: windowID)
    }

    func rename(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        name: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        acknowledgement(commandID: "rename", windowID: windowID)
    }

    func setMinimized(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        minimized: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        if lifecycleMutationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: lifecycleMutationDelayNanoseconds)
        }
        return acknowledgement(commandID: "minimized", windowID: windowID)
    }

    func setPinned(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        pinned: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        pinnedChanges.append(pinned)
        return acknowledgement(
            commandID: "pinned-\(pinnedChanges.count)",
            windowID: windowID,
            sessionID: Self.baseSession.sessionID
        )
    }

    func archive(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        if lifecycleMutationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: lifecycleMutationDelayNanoseconds)
        }
        return acknowledgement(commandID: "archive", windowID: windowID)
    }

    func deletePermanently(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        if lifecycleMutationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: lifecycleMutationDelayNanoseconds)
        }
        deletedWindowIDs.append(windowID)
        return acknowledgement(commandID: "delete", windowID: windowID)
    }

    func setFeatures(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        patch: FerminRelayFeaturePatch
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        featurePatches.append(patch)
        let call = featurePatches.count
        if heldFeatureCalls.contains(call) {
            await withCheckedContinuation { continuation in
                featureReleaseWaiters[call] = continuation
            }
        } else {
            await waitIgnoringCancellation(nanoseconds: featureDelayNanoseconds)
        }
        if featureShouldFail || featureFailureCalls.contains(call) {
            throw FerminCodeDesktopUserError("Fallo de funciones simulado.")
        }
        return acknowledgement(commandID: "features", windowID: windowID)
    }

    func setRunMode(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        enabled: Bool,
        idempotencyKey: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        orderedComposerOperations.append("run-mode")
        goalModeValues.append(enabled)
        await waitIgnoringCancellation(nanoseconds: goalMutationDelayNanoseconds)
        if goalMutationShouldFail {
            throw FerminCodeDesktopUserError("Fallo de Goal simulado.")
        }
        return acknowledgement(commandID: "run-mode", windowID: windowID)
    }

    func setModelSettings(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayModelSettingsRequest
    ) async throws -> FerminRelayModelSettingsEnvelope {
        await waitIgnoringCancellation(nanoseconds: modelMutationDelayNanoseconds)
        if modelMutationShouldFail {
            throw FerminCodeDesktopUserError("Fallo de modelo simulado.")
        }
        return FerminRelayModelSettingsEnvelope(
            modelSettings: FerminRelayRuntimeModelSettings(
                model: request.model,
                effort: request.reasoningEffort
            ),
            command: acknowledgement(commandID: "model", windowID: windowID)
        )
    }

    func createSubagent(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        request: FerminRelayCreateSubagentRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        subagentRequest = request
        postSubagentPollCount = 0
        return acknowledgement(commandID: "subagent", windowID: windowID, sessionID: request.sessionID)
    }

    func retryPromptTransform(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        messageID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        acknowledgement(commandID: "retry", windowID: windowID)
    }

    func setPromptImproverPreference(
        source: FerminCodeRelaySource,
        token: String,
        variant: FerminRelayPromptImproverVariant
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope {
        promptPreferenceVariant = variant
        return FerminRelayPromptImproverPreferenceEnvelope(
            preference: FerminRelayPromptImproverPreference(variant: variant)
        )
    }

    func resumeHistory(
        source: FerminCodeRelaySource,
        token: String,
        id: String
    ) async throws -> FerminRelayHistoryResumeEnvelope {
        await waitIgnoringCancellation(nanoseconds: resumeHistoryDelayNanoseconds)
        if resumeHistoryShouldFail {
            throw FerminCodeDesktopUserError("Fallo tardío de reanudación simulado.")
        }
        return FerminRelayHistoryResumeEnvelope(
            ok: true,
            queued: true,
            commandID: "resume",
            queuedAt: 1,
            state: .completed,
            sessionID: Self.baseSession.sessionID
        )
    }

    func uploadAttachment(
        source: FerminCodeRelaySource,
        token: String,
        windowID: String,
        attachment: FerminRelayAttachmentUpload
    ) async throws -> FerminRelayAttachmentUploadEnvelope {
        FerminRelayAttachmentUploadEnvelope(
            path: "/attachment/\(attachment.fileName)",
            bytes: attachment.data.count,
            mimeType: attachment.mimeType
        )
    }

    func stream(
        source: FerminCodeRelaySource,
        token: String,
        lastEventID: UInt64?
    ) async throws -> AsyncThrowingStream<FerminRelayStreamDelivery, Error> {
        streamRequestedCursors.append(lastEventID)
        if streamOverflowOnce, !didEmitStreamOverflow {
            didEmitStreamOverflow = true
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: FerminRelayHTTPError.streamBufferOverflow(stage: .deliveries)
                )
            }
        }
        let id = UUID()
        return AsyncThrowingStream { continuation in
            Task { self.retain(continuation, id: id) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.release(id: id) }
            }
        }
    }

    private func retain(
        _ continuation: AsyncThrowingStream<FerminRelayStreamDelivery, Error>.Continuation,
        id: UUID
    ) {
        streamContinuations[id] = continuation
    }

    private func release(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    private func acknowledgement(
        commandID: String,
        windowID: String? = nil,
        sessionID: String? = nil,
        clientMessageID: String? = nil,
        state: FerminRelayDurableCommandState = .completed
    ) -> FerminRelayDurableCommandAcknowledgement {
        FerminRelayDurableCommandAcknowledgement(
            ok: true,
            commandID: commandID,
            commandState: state,
            inserted: true,
            durable: true,
            queuedAt: 1,
            windowID: windowID,
            sessionID: sessionID,
            clientMessageID: clientMessageID
        )
    }

    private func waitIgnoringCancellation(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Double(nanoseconds) / 1_000_000_000
            ) {
                continuation.resume()
            }
        }
    }

    private static let baseSession = makeBaseSession(messages: [])

    private static let authoritativeRecoverySummary = makeBaseSession(
        messages: [],
        displayName: "Snapshot autoritativo"
    )

    private static let authoritativeRecoveryDetail = makeBaseSession(
        messages: [
            FerminRelayMessage(
                id: "authoritative-message",
                role: "assistant",
                content: "Detalle autoritativo",
                timestamp: 102,
                status: "completed"
            ),
        ],
        displayName: "Snapshot autoritativo"
    )

    private static let mismatchedSession = FerminRelaySession(
        windowID: "other-window",
        sessionID: "other-session",
        engine: "codex",
        model: "gpt-5.6-sol",
        reasoningEffort: "high",
        projectPath: "/Users/test/projects/other",
        projectName: "other",
        displayName: "Sesión cruzada",
        activityStatus: "ready",
        updatedAt: 100,
        canSend: true,
        messages: []
    )

    private static func fallbackSession(windowID: String) -> FerminRelaySession {
        FerminRelaySession(
            windowID: windowID,
            sessionID: "session-\(windowID)",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            projectPath: "/Users/test/projects/fermin-code",
            projectName: "fermin-code",
            displayName: "Sesión \(windowID)",
            activityStatus: "ready",
            updatedAt: 100,
            canSend: true,
            messages: []
        )
    }

    private static func makeBaseSession(
        messages: [FerminRelayMessage],
        displayName: String = "Sesión base"
    ) -> FerminRelaySession {
        FerminRelaySession(
            windowID: "base-window",
            sessionID: "base-session",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            projectPath: "/Users/test/projects/fermin-code",
            projectName: "fermin-code",
            displayName: displayName,
            activityStatus: "ready",
            messageCount: messages.count,
            updatedAt: 100,
            canSend: true,
            messages: messages
        )
    }

    private static func createdSession(
        _ request: FerminRelayCreateSessionRequest
    ) -> FerminRelaySession {
        FerminRelaySession(
            windowID: "created-window",
            sessionID: request.sessionID ?? "created-session",
            engine: "codex",
            projectPath: request.projectPath,
            projectName: "fermin-code",
            windowName: request.sessionName,
            displayName: request.sessionName ?? "Rust lento",
            activityStatus: "ready",
            messageCount: 0,
            updatedAt: 200,
            canSend: true,
            messages: []
        )
    }

    private static func childSession(
        _ request: FerminRelayCreateSubagentRequest
    ) -> FerminRelaySession {
        let delegatedMessage = FerminRelayMessage(
            id: "subagent-task",
            role: "user",
            content: request.message,
            timestamp: 300,
            status: "completed"
        )
        return FerminRelaySession(
            windowID: "child-window",
            sessionID: request.sessionID ?? "child-session",
            engine: "codex",
            projectPath: baseSession.projectPath,
            projectName: baseSession.projectName,
            displayName: request.displayName ?? "Subagente",
            activityStatus: "working",
            runtimeStatus: "WORKING",
            messageCount: 1,
            updatedAt: 300,
            canSend: true,
            messages: [delegatedMessage],
            pendingSubagent: FerminRelayPendingSubagent(
                displayMessage: request.message,
                childMessageSentAt: 300
            )
        )
    }

    private static func stagedChildSession(
        _ request: FerminRelayCreateSubagentRequest
    ) -> FerminRelaySession {
        FerminRelaySession(
            windowID: "child-window",
            sessionID: request.sessionID ?? "child-session",
            engine: "codex",
            projectPath: baseSession.projectPath,
            projectName: baseSession.projectName,
            displayName: request.displayName ?? "Subagente",
            activityStatus: "ready",
            runtimeStatus: "WAITING",
            messageCount: 0,
            updatedAt: 250,
            canSend: true,
            messages: [],
            pendingSubagent: FerminRelayPendingSubagent(
                displayMessage: request.message
            )
        )
    }
}
