import XCTest
@testable import KyCode

final class AppHapticCatalogTests: XCTestCase {
    func testCatalogContainsEveryActiveHaptic() {
        XCTAssertEqual(AppHapticEvent.allCases.count, 19)
        XCTAssertEqual(AppHapticCatalog.descriptors.count, 19)
        XCTAssertEqual(Set(AppHapticCatalog.descriptors.keys), Set(AppHapticEvent.allCases))
    }

    func testCatalogNumbersAreUniqueAndContinuous() {
        let numbers = AppHapticCatalog.descriptors.values.map(\.number).sorted()
        XCTAssertEqual(numbers, Array(1...19))
    }

    func testCriticalEventsUseOutcomeSemantics() {
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .messageSendSuccess).pattern, .notificationSuccess)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .messageSendError).pattern, .notificationError)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .destructiveDiscard).pattern, .notificationWarning)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .profileSelection).pattern, .selection)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .voiceButtonPress).pattern, .impactLight)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .voiceRecordingStart).pattern, .impactRigid)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .voiceRecordingStop).pattern, .impactSoft)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .voiceStateTransition).pattern, .selection)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .sessionDeleteRequest).pattern, .notificationWarning)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .sessionDeleteSuccess).pattern, .notificationSuccess)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .sessionDeleteError).pattern, .notificationError)
        XCTAssertEqual(AppHapticCatalog.descriptor(for: .goalModeToggle).pattern, .impactRigid)
    }

    func testEveryCatalogEventIsWiredIntoTheMainExperience() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootViewURL = projectRoot
            .appendingPathComponent("Sources/App/Views/KycodeRootView.swift")
        let source = try String(contentsOf: rootViewURL, encoding: .utf8)

        for event in AppHapticEvent.allCases {
            let marker = ".\(event.rawValue)"
            XCTAssertTrue(
                source.contains(marker),
                "El evento #\(AppHapticCatalog.descriptor(for: event).number) \(event.rawValue) no esta cableado en KycodeRootView"
            )
        }

        XCTAssertTrue(source.contains("Button(action: presentCreateSession)"))
        XCTAssertTrue(source.contains("onCreateSession: {\n                        presentCreateSession()"))
        XCTAssertTrue(source.contains("onCreateSession: {"))
        XCTAssertTrue(source.contains("accessibilityHint(\"Abre Nueva sesión en un toque\")"))
    }

    @MainActor
    func testHapticsDefaultOnAndCanBeDisabled() {
        let suiteName = "AppHapticCatalogTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("No se pudo crear UserDefaults aislado")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = AppHaptics(defaults: defaults)
        XCTAssertTrue(engine.isEnabled)

        defaults.set(false, forKey: AppHaptics.enabledDefaultsKey)
        XCTAssertFalse(engine.isEnabled)
    }
}
