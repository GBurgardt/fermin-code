import XCTest
import SwiftUI
@testable import KyCode

final class FullScreenTextEditorTests: XCTestCase {
    func testUnchangedDraftHasNoChanges() {
        XCTAssertFalse(
            FullScreenTextEditorDraftPolicy.hasChanges(
                baseline: "Hola",
                workingText: "Hola"
            )
        )
    }

    func testChangedDraftHasChanges() {
        XCTAssertTrue(
            FullScreenTextEditorDraftPolicy.hasChanges(
                baseline: "Hola",
                workingText: "Hola mundo"
            )
        )
    }

    func testRecoveryRequiresMatchingBaseline() {
        let recovery = FullScreenTextEditorRecovery(
            baseline: "Original",
            workingText: "Edición recuperada"
        )

        XCTAssertEqual(
            FullScreenTextEditorDraftPolicy.recover(
                recovery,
                currentBaseline: "Original"
            ),
            "Edición recuperada"
        )
        XCTAssertNil(
            FullScreenTextEditorDraftPolicy.recover(
                recovery,
                currentBaseline: "Otro borrador"
            )
        )
    }

    func testRecoveryIgnoresAnUnchangedWorkingCopy() {
        let recovery = FullScreenTextEditorRecovery(
            baseline: "Sin cambios",
            workingText: "Sin cambios"
        )

        XCTAssertNil(
            FullScreenTextEditorDraftPolicy.recover(
                recovery,
                currentBaseline: "Sin cambios"
            )
        )
    }

    func testMetricsCountCharactersWordsAndLines() {
        let metrics = FullScreenTextEditorMetrics(text: "Hola mundo\nSegunda línea")

        XCTAssertEqual(metrics.characters, 24)
        XCTAssertEqual(metrics.words, 4)
        XCTAssertEqual(metrics.lines, 2)
    }

    func testEmptyMetricsAreZero() {
        let metrics = FullScreenTextEditorMetrics(text: "")
        XCTAssertEqual(metrics.characters, 0)
        XCTAssertEqual(metrics.words, 0)
        XCTAssertEqual(metrics.lines, 0)
    }

    func testDraftStoreRoundTripsAndClearsRecovery() throws {
        let suiteName = "FullScreenTextEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FullScreenTextEditorDraftStore(defaults: defaults)
        let recovery = FullScreenTextEditorRecovery(
            baseline: "Base",
            workingText: "Trabajo"
        )

        store.save(recovery, identifier: "session-a")
        XCTAssertEqual(store.load(identifier: "session-a"), recovery)

        store.clear(identifier: "session-a")
        XCTAssertNil(store.load(identifier: "session-a"))
    }

    func testRecoveryKeysAreScopedPerSession() throws {
        let suiteName = "FullScreenTextEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FullScreenTextEditorDraftStore(defaults: defaults)

        store.save(
            FullScreenTextEditorRecovery(baseline: "A", workingText: "A1"),
            identifier: "session-a"
        )
        store.save(
            FullScreenTextEditorRecovery(baseline: "B", workingText: "B1"),
            identifier: "session-b"
        )

        XCTAssertEqual(store.load(identifier: "session-a")?.workingText, "A1")
        XCTAssertEqual(store.load(identifier: "session-b")?.workingText, "B1")
    }

    func testVoiceOverDoesNotForceKeyboardFocus() {
        XCTAssertFalse(
            FullScreenTextEditorDraftPolicy.shouldFocusAutomatically(
                voiceOverRunning: true
            )
        )
        XCTAssertTrue(
            FullScreenTextEditorDraftPolicy.shouldFocusAutomatically(
                voiceOverRunning: false
            )
        )
    }

    func testFooterStacksForEveryAccessibilityTextSize() {
        for size in DynamicTypeSize.allCases {
            let expected: FullScreenTextEditorFooterLayout =
                size.isAccessibilitySize ? .stacked : .compact
            XCTAssertEqual(
                FullScreenTextEditorFooterLayoutPolicy.layout(for: size),
                expected,
                "Unexpected footer layout for \(size)"
            )
        }
    }
}
