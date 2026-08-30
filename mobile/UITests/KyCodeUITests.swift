import XCTest

final class KyCodeUITests: XCTestCase {
    func testSubagentParentNoteRequiresARealChangeBeforeSaving() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_SUBAGENT_PARENT_NOTE"] = "1"
        app.launch()

        let editor = app.textViews["subagent-parent-note-editor"]
        let save = app.buttons["subagent-parent-note-save"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(save.exists)
        XCTAssertEqual(save.label, "Sin cambios")
        XCTAssertFalse(save.isEnabled)

        editor.tap()
        editor.typeText(" Compartir resumen.")
        XCTAssertEqual(save.label, "Guardar")
        XCTAssertTrue(save.isEnabled)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "subagent-parent-note-real-change"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        save.tap()
        let saved = app.staticTexts["subagent-parent-note-saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 2))
        XCTAssertEqual(
            saved.label,
            "Guardado: Avisar al padre cuando el análisis esté listo. Compartir resumen."
        )
    }

    func testRenameEditorRequiresARealChangeBeforeSaving() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RENAME_EDITOR"] = "1"
        app.launch()

        let field = app.textFields["rename-session-field"]
        let cancel = app.buttons["rename-session-cancel"]
        let save = app.buttons["rename-session-save"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(save.exists)
        XCTAssertEqual(save.label, "Sin cambios")
        XCTAssertFalse(save.isEnabled)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(save.frame.width, 44)
        XCTAssertLessThanOrEqual(cancel.frame.maxX, save.frame.minX)

        let clear = app.buttons["rename-session-clear"]
        XCTAssertTrue(clear.exists)
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        clear.tap()
        XCTAssertTrue(app.staticTexts["Nombre requerido"].exists)
        XCTAssertFalse(save.isEnabled)

        field.tap()
        field.typeText("Plan mensual")
        XCTAssertEqual(save.label, "Guardar")
        XCTAssertTrue(save.isEnabled)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "rename-session-real-change"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        save.tap()
        let saved = app.staticTexts["rename-session-saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 2))
        XCTAssertEqual(saved.label, "Guardado: Plan mensual")
    }

    func testRenameFailurePreservesDraftForRetry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RENAME_EDITOR"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_RENAME_FAIL_ONCE"] = "1"
        app.launch()

        let field = app.textFields["rename-session-field"]
        let save = app.buttons["rename-session-save"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        app.buttons["rename-session-clear"].tap()
        field.tap()
        field.typeText("Plan recuperado")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let alert = app.alerts["No se pudo renombrar"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(alert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "listo para reintentar")
        ).firstMatch.exists)
        alert.buttons["Cerrar"].tap()

        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertEqual(field.value as? String, "Plan recuperado")
        XCTAssertEqual(save.label, "Guardar")
        XCTAssertTrue(save.isEnabled)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "rename-session-recovered-draft"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        save.tap()
        let saved = app.staticTexts["rename-session-saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 2))
        XCTAssertEqual(saved.label, "Guardado: Plan recuperado")
    }

    func testRenameImplicitDismissalProtectsUnsavedName() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RENAME_EDITOR"] = "1"
        app.launch()

        let field = app.textFields["rename-session-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["rename-session-clear"].tap()
        field.tap()
        field.typeText("Borrador seguro")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let alert = app.alerts["¿Descartar el nuevo nombre?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(alert.staticTexts["El cambio todavía no se guardó."].exists)
        alert.buttons["Seguir editando"].tap()

        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertEqual(field.value as? String, "Borrador seguro")
        XCTAssertTrue(app.buttons["rename-session-save"].isEnabled)
    }

    func testDashboardKeepsBothRustTargetsInsideCompactFilters() {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let filterMenu = app.buttons["dashboard-filter-menu"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 10))
        XCTAssertTrue((filterMenu.value as? String)?.contains("Todo") == true)
        XCTAssertFalse(app.descendants(matching: .any)["dashboard-server-switcher"].exists)
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let todo = app.buttons["dashboard-target-all"]
        XCTAssertTrue(todo.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dashboard-target-personal"].exists)
        XCTAssertTrue(app.buttons["dashboard-target-puky"].exists)
        XCTAssertFalse(app.staticTexts["Mobile"].exists)
        XCTAssertFalse(app.buttons["Connect"].exists)
        XCTAssertFalse(app.buttons["Connect to the server"].exists)
    }

    func testDesktopPreferencesUseConsistentSpanishActions() throws {
        let app = XCUIApplication()
        app.launch()

        let dashboardMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 10))
        dashboardMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let preferences = app.buttons["Desktop y preferencias"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3))
        preferences.tap()

        let done = app.buttons["connection-sheet-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Listo")
        XCTAssertTrue(app.navigationBars["Preferencias"].exists)
        XCTAssertTrue(app.staticTexts["MAC ACTIVA"].exists)
        XCTAssertFalse(app.navigationBars["Desktop"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertFalse(app.buttons["Disconnect"].exists)
        XCTAssertFalse(app.buttons["Connect"].exists)
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        XCTAssertFalse(app.staticTexts["Connected via"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "desktop-preferences-consistent-spanish-copy"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 2))
    }

    func testConnectionTokenCanBeRevealedAndHiddenWithoutChangingIt() throws {
        let app = XCUIApplication()
        app.launch()

        let dashboardMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 10))
        dashboardMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let preferences = app.buttons["Desktop y preferencias"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3))
        preferences.tap()

        let secureToken = app.secureTextFields["remote-hub-token-field"]
        if !secureToken.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(secureToken.waitForExistence(timeout: 3))

        let visibility = app.buttons["remote-hub-token-field-visibility"]
        XCTAssertTrue(visibility.exists)
        XCTAssertEqual(visibility.label, "Mostrar token")
        XCTAssertGreaterThanOrEqual(visibility.frame.width, 44)
        XCTAssertGreaterThanOrEqual(visibility.frame.height, 44)
        visibility.tap()

        let visibleToken = app.textFields["remote-hub-token-field"]
        XCTAssertTrue(visibleToken.waitForExistence(timeout: 2))
        XCTAssertEqual(visibility.label, "Ocultar token")
        visibility.tap()
        XCTAssertTrue(secureToken.waitForExistence(timeout: 2))
        XCTAssertEqual(visibility.label, "Mostrar token")
    }

    func testServerSwitcherSitsBesideFloatingMenuAndShowsBothRustTargets() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_SERVER_SWITCHER"] = "1"
        app.launch()

        let switcher = app.descendants(matching: .any)["dashboard-server-switcher"]
        let floatingMenu = app.buttons["server-switcher-floating-menu"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(floatingMenu.exists)
        XCTAssertLessThanOrEqual(switcher.frame.maxX, floatingMenu.frame.minX)
        let personal = app.buttons["dashboard-target-personal"]
        let puky = app.buttons["dashboard-target-puky"]
        let all = app.buttons["dashboard-target-all"]
        XCTAssertTrue(personal.exists)
        XCTAssertTrue(puky.exists)
        XCTAssertTrue(all.exists)
        XCTAssertFalse(app.buttons["dashboard-server-option-this-mac"].exists)
        XCTAssertFalse(app.buttons["dashboard-server-option-remote-hub"].exists)

        let personalSelected = NSPredicate(format: "value CONTAINS %@", "Seleccionado")
        expectation(for: personalSelected, evaluatedWith: personal)
        waitForExpectations(timeout: 3)

        let sourceStatus = app.descendants(matching: .any)["all-sources-status"]
        XCTAssertFalse(sourceStatus.exists)
        XCTAssertFalse(app.staticTexts["AMBAS MACS"].exists)
        XCTAssertFalse(app.staticTexts["Cada acción vuelve a su origen"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "server-switcher-rust-targets"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVoiceIsolationSettingsExplainSafeFallbackAndProfileState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_VOICE_ISOLATION"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["voice-isolation-settings"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.navigationBars["Mi voz"].exists)
        XCTAssertTrue(app.buttons["Solo mi voz"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["voice-profile-card"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["voice-isolation-safety-card"].exists)
        XCTAssertTrue(
            element(containing: "PICOVOICE_ACCESS_KEY", in: app).exists
        )
        XCTAssertTrue(
            element(containing: "texto completo", in: app).exists
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "voice-isolation-settings-no-credential"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    func testPhoneRecordingIndicatorStaysSafeNavigatesAndReturnsWithoutHomeHeader() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PHONE_RECORDING_PARITY"] = "1"
        app.launch()

        let indicator = app.buttons["background-recording-indicator"]
        let floatingMenu = app.buttons["phone-parity-floating-menu"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.isHittable)
        XCTAssertTrue(floatingMenu.exists)
        XCTAssertFalse(indicator.frame.intersects(floatingMenu.frame))
        XCTAssertEqual(app.navigationBars.count, 0, "Home must not reserve a navigation header on iPhone.")

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(indicator.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(indicator.frame.maxY, windowFrame.maxY)

        indicator.tap()
        XCTAssertTrue(
            app.staticTexts["phone-parity-recording-detail"]
                .waitForExistence(timeout: 2)
        )

        app.buttons["phone-parity-back-home"].tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 2))
        XCTAssertTrue(indicator.isHittable)
        XCTAssertEqual(app.navigationBars.count, 0)
    }

    func testVoiceCaptureTouchDownAndActionStayInLockstep() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_VOICE_CAPTURE_LATENCY"] = "1"
        app.launch()

        var microphone = app.buttons["voice-latency-microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.value as? String, "idle contact=0 action=0")

        microphone.tap()
        microphone = app.buttons["voice-latency-microphone"]
        XCTAssertEqual(microphone.label, "Detener grabación")
        XCTAssertEqual(microphone.value as? String, "recording contact=1 action=1")

        microphone.tap()
        microphone = app.buttons["voice-latency-microphone"]
        XCTAssertEqual(microphone.label, "Grabar mensaje de voz")
        XCTAssertEqual(microphone.value as? String, "idle contact=2 action=2")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func dismissPastePermissionIfNeeded(in app: XCUIApplication) {
        for label in ["Don’t Allow Paste", "Don't Allow Paste", "No permitir pegar"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 0.5) {
                button.tap()
                return
            }
        }
    }

    private func resetDashboardPresentation(in app: XCUIApplication) {
        let filterMenu = app.buttons["dashboard-filter-menu"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 12))
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let allSessions = app.buttons["dashboard-menu-filter-all"]
        XCTAssertTrue(allSessions.waitForExistence(timeout: 2))
        allSessions.tap()
        XCTAssertTrue(allSessions.waitForNonExistence(timeout: 2))
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 2))
    }

    private func launchDashboardFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] = "1"
        app.launch()
        return app
    }

    private func openHistory(in app: XCUIApplication) {
        let dashboardMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 12))
        dashboardMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let openHistory = app.buttons["session-history-open"]
        XCTAssertTrue(openHistory.waitForExistence(timeout: 3))
        openHistory.tap()
    }

    private func launchHistoryFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_HISTORY_FIXTURE"] = "1"
        app.launch()
        return app
    }

    func testFullScreenEditorSavesIntoComposerDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR"] = "1"
        app.launch()

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.label, "Mensaje")

        let expand = app.buttons["composer-expand-editor"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        let clear = app.buttons["composer-clear-text"]
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        XCTAssertLessThanOrEqual(expand.frame.maxX, clear.frame.minX)
        expand.tap()

        let editor = app.textViews["full-screen-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let save = app.buttons["full-screen-editor-save"]
        XCTAssertTrue(save.exists)
        XCTAssertEqual(save.label, "Sin cambios")
        XCTAssertFalse(save.isEnabled)

        editor.tap()
        editor.typeText(" Cambio guardado.")
        XCTAssertEqual(save.label, "Guardar")
        XCTAssertTrue(save.isEnabled)

        let hideKeyboard = app.buttons["full-screen-editor-hide-keyboard"]
        let metrics = app.descendants(matching: .any)["full-screen-editor-metrics"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 2))
        XCTAssertTrue(metrics.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(metrics.frame.maxX, hideKeyboard.frame.minX)
        XCTAssertLessThan(abs(metrics.frame.midY - hideKeyboard.frame.midY), 12)
        XCTAssertGreaterThanOrEqual(hideKeyboard.frame.height, 44)
        XCTAssertTrue(hideKeyboard.isHittable)
        hideKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))

        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.tap()

        let result = app.staticTexts["full-screen-editor-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertTrue(result.label.contains("Cambio guardado."))
    }

    func testFullScreenEditorAccessibilityTextReflowsAboveKeyboard() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR_AUTO_OPEN"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR_ACCESSIBILITY_TEXT"] = "1"
        app.launch()

        let editor = app.textViews["full-screen-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        let keyboardDeadline = Date().addingTimeInterval(3)
        while Date() < keyboardDeadline,
              (!keyboard.exists || !keyboard.frame.intersects(window.frame)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            keyboard.frame.intersects(window.frame),
            "The software keyboard existed in the hierarchy but never became visible onscreen."
        )
        let footer = app.descendants(matching: .any)["full-screen-editor-footer"]
        let metrics = app.descendants(matching: .any)["full-screen-editor-metrics"]
        let hideKeyboard = app.buttons["full-screen-editor-hide-keyboard"]
        XCTAssertTrue(footer.waitForExistence(timeout: 2))
        XCTAssertTrue(metrics.waitForExistence(timeout: 2))
        XCTAssertEqual(metrics.label, "44 caracteres, 7 palabras, 1 líneas")
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(hideKeyboard.frame.width, 44)
        XCTAssertGreaterThanOrEqual(hideKeyboard.frame.height, 44)
        XCTAssertTrue(hideKeyboard.isHittable)
        XCTAssertLessThanOrEqual(editor.frame.maxY, footer.frame.minY + 1)
        XCTAssertLessThanOrEqual(footer.frame.maxY, keyboard.frame.minY + 1)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "full-screen-editor-accessibility5-reflow"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        hideKeyboard.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
    }

    func testFullScreenEditorCancelDiscardsWorkingCopy() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR"] = "1"
        app.launch()

        let result = app.staticTexts["full-screen-editor-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let original = result.label

        app.buttons["composer-expand-editor"].tap()
        let editor = app.textViews["full-screen-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" Cambio descartado.")
        app.buttons["full-screen-editor-cancel"].tap()

        let discard = app.buttons["Descartar"]
        XCTAssertTrue(discard.waitForExistence(timeout: 2))
        discard.tap()

        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(result.label, original)
    }

    func testComposerClearOffersPredictableUndo() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR"] = "1"
        app.launch()

        let result = app.staticTexts["full-screen-editor-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let original = result.label
        app.buttons["composer-clear-text"].tap()

        let notice = app.descendants(matching: .any)["composer-undo-notice"]
        let undo = app.buttons["composer-undo"]
        XCTAssertTrue(notice.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Texto limpiado"].exists)
        XCTAssertTrue(undo.exists)
        XCTAssertGreaterThanOrEqual(undo.frame.width, 44)
        XCTAssertGreaterThanOrEqual(undo.frame.height, 44)
        XCTAssertTrue(undo.isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "composer-clear-predictable-undo"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        undo.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 2))
        XCTAssertEqual(result.label, original)
    }

    func testFileViewerOpensWithinBudgetRendersCodeAndCloses() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FILE_VIEWER"] = "1"
        app.launch()

        let link = app.buttons["file-viewer-test-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let viewer = app.descendants(matching: .any)["file-viewer-sheet"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 1))
        let latencyLabel = app.staticTexts["file-viewer-open-latency"]
        XCTAssertTrue(latencyLabel.waitForExistence(timeout: 1))
        let latencyMilliseconds = Int(
            latencyLabel.label
                .replacingOccurrences(of: "Latencia de apertura: ", with: "")
                .replacingOccurrences(of: " ms", with: "")
        )
        XCTAssertNotNil(latencyMilliseconds, latencyLabel.debugDescription)
        XCTAssertLessThan(latencyMilliseconds ?? .max, 500)

        XCTAssertTrue(app.navigationBars["FileViewerSheet.swift"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["file-viewer-content"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["SWIFT"].exists)

        let themeToggle = app.buttons["file-viewer-theme-toggle"]
        let close = app.buttons["file-viewer-close"]
        XCTAssertTrue(themeToggle.exists)
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(themeToggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(themeToggle.frame.height, 44)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertLessThanOrEqual(themeToggle.frame.maxX, close.frame.minX)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "mobile-file-viewer-code"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        close.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["FileViewerSheet.swift"].exists)

        link.tap()
        XCTAssertTrue(app.navigationBars["FileViewerSheet.swift"].waitForExistence(timeout: 1))
        let grabber = app.descendants(matching: .any)["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 1))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        XCTAssertTrue(link.waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["FileViewerSheet.swift"].exists)
    }

    func testExplanationStaysOutOfChatAndOpensInThemedFullScreenReader() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_EXPLANATION_VIEWER"] = "1"
        app.launch()

        let launcher = app.buttons["explanation-open-explainer-ui-test"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Claridad progresiva"].exists)

        launcher.tap()
        let viewer = app.descendants(matching: .any)["explanation-viewer-sheet"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Claridad progresiva"].waitForExistence(timeout: 2))

        let lightScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        lightScreenshot.name = "explanation-viewer-light"
        lightScreenshot.lifetime = .keepAlways
        add(lightScreenshot)

        let themeToggle = app.buttons["Usar modo oscuro"]
        XCTAssertTrue(themeToggle.waitForExistence(timeout: 2))
        XCTAssertEqual(themeToggle.value as? String, "Claro")
        themeToggle.tap()
        let darkThemeToggle = app.buttons["Usar modo claro"]
        XCTAssertTrue(darkThemeToggle.waitForExistence(timeout: 2))
        XCTAssertEqual(darkThemeToggle.value as? String, "Oscuro")
        // Xcode 16 can publish the updated accessibility value one display
        // frame before the animated palette redraw. Wait only for visual
        // evidence; production interaction itself remains immediate.
        usleep(400_000)

        let darkScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        darkScreenshot.name = "explanation-viewer-dark"
        darkScreenshot.lifetime = .keepAlways
        add(darkScreenshot)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Claridad progresiva"].waitForExistence(timeout: 2))
        usleep(300_000)
        let landscapeScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeScreenshot.name = "explanation-viewer-landscape"
        landscapeScreenshot.lifetime = .keepAlways
        add(landscapeScreenshot)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Claridad progresiva"].waitForExistence(timeout: 2))

        app.buttons["Cerrar lector"].tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Claridad progresiva"].exists)
    }

    func testImprovedPromptStaysOutOfChatAndOpensInSharedReader() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_READER"] = "1"
        app.launch()

        let launcher = app.buttons["improved-prompt-open-user-ui-test"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(launcher.frame.height, 44)
        XCTAssertLessThanOrEqual(launcher.frame.height, 46)
        XCTAssertFalse(app.staticTexts["Comparar en el lector"].exists)
        XCTAssertTrue(app.staticTexts["Necesito un resumen corto del estado."].exists)
        XCTAssertFalse(app.staticTexts["Prompt mejorado confidencial"].exists)

        launcher.tap()
        let viewer = app.descendants(matching: .any)["explanation-viewer-sheet"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Prompt mejorado confidencial"].waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "improved-prompt-shared-reader"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Cerrar lector"].tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Necesito un resumen corto del estado."].exists)
        XCTAssertFalse(app.staticTexts["Prompt mejorado confidencial"].exists)
    }

    func testPromptImproverStopsPendingWhenResolvedOutputArrivesWithoutReload() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_RECONCILIATION"] = "1"
        app.launch()

        let loading = app.descendants(matching: .any)[
            "prompt-improver-loading-user-ui-test-reconciliation"
        ]
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        app.buttons["prompt-reconciliation-resolve"].tap()

        let launcher = app.buttons["improved-prompt-open-user-ui-test-reconciliation"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(launcher.frame.height, 44)
        XCTAssertLessThanOrEqual(launcher.frame.height, 46)
        XCTAssertFalse(app.staticTexts["Comparar en el lector"].exists)
        XCTAssertTrue(loading.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ordená los próximos pasos de esta sesión."].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "prompt-improver-resolved-without-reload"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPromptImproverTimeoutPreservesOriginalAndOffersWorkingRetry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_TIMEOUT"] = "1"
        app.launch()

        let messageID = "user-ui-test-timeout"
        let error = app.descendants(matching: .any)["prompt-improver-error-\(messageID)"]
        let retry = app.buttons["prompt-improver-retry-\(messageID)"]
        let loading = app.descendants(matching: .any)["prompt-improver-loading-\(messageID)"]

        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No llegó el resultado de la mejora"].exists)
        XCTAssertTrue(app.staticTexts["Ordená los riesgos de esta entrega."].exists)
        XCTAssertTrue(retry.exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertFalse(loading.exists)

        let timeoutScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        timeoutScreenshot.name = "prompt-improver-timeout-actionable"
        timeoutScreenshot.lifetime = .keepAlways
        add(timeoutScreenshot)

        retry.tap()
        XCTAssertTrue(app.staticTexts["Enviando reintento…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Reintento aceptado…"].waitForExistence(timeout: 3))
        XCTAssertTrue(error.waitForNonExistence(timeout: 2))

        let launcher = app.buttons["improved-prompt-open-\(messageID)"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 4))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ordená los riesgos de esta entrega."].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "message-\(messageID)")
        ).count, 1)
    }

    func testPromptImproverFailureOffersRetryWithoutAddingAnotherMessage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_FAILURE"] = "1"
        app.launch()

        let error = app.descendants(matching: .any)["prompt-improver-error-user-ui-test-failure"]
        let retry = app.buttons["prompt-improver-retry-user-ui-test-failure"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "message-user-ui-test-failure")
        ).count, 1)

        retry.tap()
        XCTAssertTrue(app.staticTexts["Enviando reintento…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Reintento aceptado…"].waitForExistence(timeout: 3))
        XCTAssertFalse(error.exists)
        XCTAssertTrue(app.buttons["improved-prompt-open-user-ui-test-failure"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "message-user-ui-test-failure")
        ).count, 1)
    }

    func testPromptRetrySessionFallbackClearsAcceptedWaitWithoutMessageMutation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_RETRY_FALLBACK"] = "1"
        app.launch()

        let messageID = "user-ui-test-retry-fallback"
        let error = app.descendants(matching: .any)["prompt-improver-error-\(messageID)"]
        let retry = app.buttons["prompt-improver-retry-\(messageID)"]
        let loading = app.descendants(matching: .any)["prompt-improver-loading-\(messageID)"]
        let launcher = app.buttons["improved-prompt-open-\(messageID)"]

        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(launcher.exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "message-\(messageID)")
        ).count, 1)

        retry.tap()
        XCTAssertTrue(app.staticTexts["Enviando reintento…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Reintento aceptado…"].waitForExistence(timeout: 2))
        XCTAssertTrue(loading.exists)

        app.buttons["prompt-retry-publish-new-fallback"].tap()

        XCTAssertTrue(launcher.waitForExistence(timeout: 2))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 2))
        XCTAssertTrue(error.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Prepará un resumen de la sesión."].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "message-\(messageID)")
        ).count, 1)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "prompt-retry-session-fallback-resolved"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        launcher.tap()
        XCTAssertTrue(app.staticTexts[
            "Prepará un resumen ejecutivo con avances, riesgos y próximos pasos."
        ].waitForExistence(timeout: 2))
    }

    func testPromptRetryRepeatedFallbackBaselineDoesNotResolveAgain() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PROMPT_RETRY_STALE_FALLBACK"] = "1"
        app.launch()

        let messageID = "user-ui-test-retry-stale-fallback"
        let error = app.descendants(matching: .any)["prompt-improver-error-\(messageID)"]
        let retry = app.buttons["prompt-improver-retry-\(messageID)"]
        let loading = app.descendants(matching: .any)["prompt-improver-loading-\(messageID)"]

        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Reintento aceptado…"].waitForExistence(timeout: 3))

        app.buttons["prompt-retry-reemit-stale-fallback"].tap()

        XCTAssertTrue(loading.exists)
        XCTAssertTrue(app.staticTexts["Reintento aceptado…"].exists)
        XCTAssertFalse(error.exists)

        app.buttons["prompt-retry-publish-new-fallback"].tap()

        XCTAssertTrue(loading.waitForNonExistence(timeout: 2))
        XCTAssertTrue(error.waitForNonExistence(timeout: 2))
        let launcher = app.buttons["improved-prompt-open-\(messageID)"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 2))
        launcher.tap()
        XCTAssertTrue(app.staticTexts[
            "Prepará un resumen ejecutivo con avances, riesgos y próximos pasos."
        ].waitForExistence(timeout: 2))
    }

    func testCompactSecondaryActionsKeepComfortableTouchTargets() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPACT_ACTION_TARGETS"] = "1"
        app.launch()

        let reconnect = app.buttons["connection-notice-action"]
        let copy = app.buttons["connection-error-copy"]
        let dismiss = app.buttons["connection-error-dismiss"]
        let voiceRetry = app.buttons["voice-message-retry-voice-touch-target"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(dismiss.exists)
        XCTAssertTrue(voiceRetry.exists)

        for action in [reconnect, copy, dismiss, voiceRetry] {
            XCTAssertGreaterThanOrEqual(action.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(action.frame.height, 43.5)
            XCTAssertTrue(action.isHittable)
        }

        reconnect.tap()
        copy.tap()
        voiceRetry.tap()
        XCTAssertTrue(app.staticTexts["reconectar=1 copiar=1 voz=1"].waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "compact-secondary-actions-44pt-targets"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 2))
    }

    func testScrollToBottomButtonNeverOverlapsMicrophoneOrComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_OVERLAP"] = "1"
        app.launch()

        let scrollButton = app.buttons["transcript-scroll-to-bottom"]
        let microphone = app.buttons["composer-microphone"]
        let composer = app.descendants(matching: .any)["composer-occlusion-surface"]
        let toggleHeight = app.buttons["composer-toggle-height"]

        XCTAssertTrue(scrollButton.waitForExistence(timeout: 5))
        XCTAssertTrue(microphone.exists)
        XCTAssertTrue(composer.exists)
        XCTAssertTrue(toggleHeight.exists)
        XCTAssertFalse(scrollButton.frame.intersects(microphone.frame))
        XCTAssertLessThanOrEqual(scrollButton.frame.maxY, composer.frame.minY)

        let compactScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compactScreenshot.name = "scroll-button-clears-microphone-compact"
        compactScreenshot.lifetime = .keepAlways
        add(compactScreenshot)

        toggleHeight.tap()
        usleep(300_000)

        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertFalse(send.frame.intersects(microphone.frame))
        XCTAssertFalse(scrollButton.frame.intersects(microphone.frame))
        XCTAssertLessThanOrEqual(scrollButton.frame.maxY, composer.frame.minY)

        let attachmentPreview = app.buttons["composer-attachment-fixture-preview"]
        let attachmentRemove = app.buttons["composer-remove-attachment-fixture"]
        XCTAssertTrue(attachmentPreview.exists)
        XCTAssertTrue(attachmentRemove.exists)
        XCTAssertGreaterThanOrEqual(attachmentPreview.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attachmentPreview.frame.height, 44)
        XCTAssertGreaterThanOrEqual(attachmentRemove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attachmentRemove.frame.height, 44)
        XCTAssertFalse(attachmentPreview.frame.intersects(attachmentRemove.frame))

        let expandedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedScreenshot.name = "scroll-button-clears-microphone-expanded"
        expandedScreenshot.lifetime = .keepAlways
        add(expandedScreenshot)
    }

    func testComposerKeepsPrimaryActionsReadableAndMovesSubagentIntoMore() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launch()

        let composerField = app.textFields["composer-message"]
        let moreActions = app.buttons["composer-more-actions"]
        let improver = app.buttons["Improver"]
        let explainer = app.buttons["Explainer"]

        XCTAssertTrue(composerField.waitForExistence(timeout: 5))
        XCTAssertTrue(moreActions.exists)
        XCTAssertTrue(improver.exists)
        XCTAssertTrue(explainer.exists)
        XCTAssertGreaterThanOrEqual(moreActions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(moreActions.frame.height, 44)
        XCTAssertGreaterThanOrEqual(improver.frame.width, 44)
        XCTAssertGreaterThanOrEqual(improver.frame.height, 44)
        XCTAssertGreaterThanOrEqual(explainer.frame.width, 44)
        XCTAssertGreaterThanOrEqual(explainer.frame.height, 44)
        XCTAssertGreaterThanOrEqual(composerField.frame.width, 96)
        XCTAssertFalse(app.buttons["composer-create-subagent"].exists)

        composerField.tap()
        composerField.typeText("Revisá este caso borde")
        moreActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["composer-create-subagent"].waitForExistence(timeout: 2))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "composer-primary-actions-and-more-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLongSessionComposerAndScrollStayResponsive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_LONG_SESSION_PERFORMANCE"] = "1"
        app.launch()

        let composer = app.textFields["composer-message"]
        let transcript = app.scrollViews["session-transcript-scroll"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))

        let typingStartedAt = ProcessInfo.processInfo.systemUptime
        composer.tap()
        composer.typeText("La escritura debe seguir cada tecla sin bloquearse incluso con un historial muy largo.")
        let typingDuration = ProcessInfo.processInfo.systemUptime - typingStartedAt

        let scrollingStartedAt = ProcessInfo.processInfo.systemUptime
        transcript.swipeUp(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        let scrollingDuration = ProcessInfo.processInfo.systemUptime - scrollingStartedAt

        XCTContext.runActivity(named: "Long-session responsiveness") { activity in
            let metrics = XCTAttachment(
                string: String(
                    format: "typing=%.3fs scrolling=%.3fs messages=1395",
                    typingDuration,
                    scrollingDuration
                )
            )
            metrics.name = "long-session-performance-metrics"
            metrics.lifetime = .keepAlways
            activity.add(metrics)
        }

        XCTAssertLessThan(typingDuration, 8.0)
        XCTAssertLessThan(scrollingDuration, 4.0)
        XCTAssertTrue(
            (composer.value as? String)?.contains("historial muy largo") == true
        )
    }

    func testConversationComposerSurvivesRepeatedColdLaunches() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"

        for attempt in 1...3 {
            app.launch()

            let composerField = app.textFields["composer-message"]
            XCTAssertTrue(
                composerField.waitForExistence(timeout: 5),
                "El composer debe seguir vivo al abrir una conversación (intento \(attempt))."
            )
            XCTAssertEqual(app.state, .runningForeground)

            app.terminate()
        }
    }

    func testLiveStreamRestoresMicrophoneDespiteStaleReconnectFlags() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_STALE_RECONNECT_WITH_LIVE_STREAM"] = "1"
        app.launch()

        let microphone = app.buttons["composer-microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.label, "Grabar mensaje de voz")
        XCTAssertTrue(microphone.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["composer-reconnect-status"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "live-stream-wins-over-stale-reconnect-spinner"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTransientReconnectStaysCompactPreservesDraftAndRestoresSend() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_RECONNECT"] = "1"
        app.launch()

        let composerField = app.textFields["composer-message"]
        let reconnectStatus = app.descendants(matching: .any)
            .matching(identifier: "composer-reconnect-status")
            .firstMatch
        XCTAssertTrue(composerField.waitForExistence(timeout: 5))
        XCTAssertTrue(reconnectStatus.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Reconectando... intento 3/5"].exists)
        XCTAssertFalse(
            app.staticTexts["Modo de lectura: reconectá para enviar mensajes, audios o imágenes."].exists
        )
        XCTAssertFalse(
            app.staticTexts.matching(identifier: "composer-connection-blocked-reason").firstMatch.exists
        )

        composerField.tap()
        composerField.typeText("Borrador que no se pierde")

        let reconnectScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reconnectScreenshot.name = "composer-transient-reconnect-compact"
        reconnectScreenshot.lifetime = .keepAlways
        add(reconnectScreenshot)

        XCTAssertTrue(reconnectStatus.waitForNonExistence(timeout: 10))
        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(
            (composerField.value as? String)?.contains("Borrador que no se pierde") == true
        )

        let restoredScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        restoredScreenshot.name = "composer-reconnect-restored-send"
        restoredScreenshot.lifetime = .keepAlways
        add(restoredScreenshot)
    }

    func testExhaustedReconnectOffersOneCompactRetryWithoutBlockingDraft() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_RETRY_REQUIRED"] = "1"
        app.launch()

        let composerField = app.textFields["composer-message"]
        let retry = app.buttons["composer-reconnect-action"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertFalse(
            app.staticTexts["Reconexión automática falló. Tocá para reintentar."].exists
        )
        XCTAssertFalse(
            app.staticTexts["Modo de lectura: reconectá para enviar mensajes, audios o imágenes."].exists
        )

        composerField.tap()
        composerField.typeText("Borrador también guardado sin conexión")
        retry.tap()

        let reconnectStatus = app.descendants(matching: .any)
            .matching(identifier: "composer-reconnect-status")
            .firstMatch
        XCTAssertTrue(reconnectStatus.waitForExistence(timeout: 2))
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(
            (composerField.value as? String)?.contains("Borrador también guardado sin conexión") == true
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "composer-exhausted-retry-remains-compact"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testComposerWaitsForPhotoImportBeforeSendingText() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_COMPOSER_IMPORT_IN_FLIGHT"] = "1"
        app.launch()

        let composerField = app.textFields["composer-message"]
        let send = app.buttons["composer-send-message"]
        let moreActions = app.buttons["composer-more-actions"]

        XCTAssertTrue(composerField.waitForExistence(timeout: 5))
        composerField.tap()
        composerField.typeText("Enviá el texto junto con esta imagen")
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(moreActions.isEnabled)

        composerField.typeText("\n")
        XCTAssertTrue(
            (composerField.value as? String)?.contains(
                "Enviá el texto junto con esta imagen"
            ) == true
        )
        XCTAssertFalse(send.isEnabled)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "composer-waits-for-photo-import"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSessionCardKeepsCompactModelAndSourceMetadataVisible() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_SESSION_METADATA"] = "1"
        app.launch()

        let metadata = app.descendants(matching: .any)["session-metadata-metadata-harness"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 5))
        XCTAssertEqual(metadata.label, "Modelo, razonamiento y origen SOL · MAX · PERSONAL")
        XCTAssertTrue(metadata.isHittable)
        XCTAssertGreaterThanOrEqual(metadata.frame.height, 13)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "session-card-model-and-source-metadata"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testScrollToBottomReachesTheRealTailBehindTallComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_TRANSCRIPT_BOTTOM_JUMP"] = "1"
        app.launch()

        let transcript = app.scrollViews["session-transcript-scroll"]
        let newestMessage = app.staticTexts["FINAL DEL TIMELINE — contenido más reciente"]
        let oldRetryA = app.staticTexts["RETRY VIEJO A — debe conservar su lugar cronológico"]
        let oldRetryB = app.staticTexts["RETRY VIEJO B — no debe aparecer al final"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(newestMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(newestMessage.isHittable)
        XCTAssertFalse(oldRetryA.isHittable)
        XCTAssertFalse(oldRetryB.isHittable)

        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)

        let scrollButton = app.buttons["transcript-scroll-to-bottom"]
        XCTAssertTrue(scrollButton.waitForExistence(timeout: 2))
        XCTAssertFalse(newestMessage.isHittable)

        scrollButton.tap()
        XCTAssertTrue(
            NSPredicate(format: "hittable == true")
                .evaluate(with: newestMessage),
            newestMessage.debugDescription
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "scroll-button-reaches-real-tail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTranscriptFailureNeverLooksEmptyAndRetryRestoresMessages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_TRANSCRIPT_AVAILABILITY"] = "1"
        app.launch()

        let failure = app.descendants(matching: .any)["session-transcript-failed"]
        let retry = app.buttons["session-transcript-retry"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.descendants(matching: .any)["session-transcript-empty"].exists)
        XCTAssertFalse(app.staticTexts["Sin mensajes."].exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)

        let failureScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failureScreenshot.name = "transcript-failure-is-not-empty"
        failureScreenshot.lifetime = .keepAlways
        add(failureScreenshot)

        retry.tap()
        XCTAssertTrue(
            app.staticTexts["Cargando conversación…"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["RECUPERACIÓN_OK"].waitForExistence(timeout: 5))
        XCTAssertFalse(failure.exists)
        XCTAssertFalse(app.descendants(matching: .any)["session-transcript-empty"].exists)

        let recoveredScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        recoveredScreenshot.name = "transcript-retry-restores-content"
        recoveredScreenshot.lifetime = .keepAlways
        add(recoveredScreenshot)
    }

    func testHistoryOpensAndClosesFromDashboard() throws {
        let app = launchHistoryFixture()
        openHistory(in: app)
        XCTAssertTrue(app.textFields["history-search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["history-results"].exists)
        app.buttons["history-close"].tap()
        XCTAssertTrue(app.buttons["dashboard-floating-menu"].waitForExistence(timeout: 3))
    }

    func testHistoryFailureShowsRetryAndRecoversWithoutFalseOfflineState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_HISTORY_RETRY"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Buscando en tus conversaciones…"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sin conexión"].waitForExistence(timeout: 7))

        let retry = app.buttons["history-retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Buscando en tus conversaciones…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["history-session-fixture-repetidor"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Sin conexión"].exists)
    }

    func testHistoryPrefixSearchAndClear() throws {
        let app = launchHistoryFixture()
        openHistory(in: app)
        let search = app.textFields["history-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("repet")
        dismissPastePermissionIfNeeded(in: app)
        XCTAssertTrue(app.buttons["history-session-fixture-repetidor"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["history-session-fixture-mobile"].exists)
        app.buttons["history-search-clear"].tap()
        XCTAssertTrue(app.buttons["history-session-fixture-mobile"].waitForExistence(timeout: 2))
    }

    func testHistorySearchFoldsCaseAndAccents() throws {
        let app = launchHistoryFixture()
        openHistory(in: app)
        let search = app.textFields["history-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("NAVEGACION")
        dismissPastePermissionIfNeeded(in: app)
        XCTAssertTrue(app.buttons["history-session-fixture-acentos"].waitForExistence(timeout: 2))
    }

    func testHistoryStateFiltersAndAdvancedMenu() throws {
        let app = launchHistoryFixture()
        openHistory(in: app)
        XCTAssertTrue(app.buttons["history-filter-active"].waitForExistence(timeout: 3))
        app.buttons["history-filter-active"].tap()
        XCTAssertTrue(app.buttons["history-session-fixture-mobile"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["history-session-fixture-repetidor"].exists)
        app.buttons["history-filter-archived"].tap()
        XCTAssertTrue(app.buttons["history-session-fixture-repetidor"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["history-session-fixture-mobile"].exists)
        let advancedFilters = app.buttons["history-advanced-filters"]
        XCTAssertTrue(advancedFilters.waitForExistence(timeout: 2))
        // SwiftUI toolbar menus can report an invalid AX scroll target even
        // when their visible hit region is correct. A direct center coordinate
        // exercises the same user tap without asking XCTest to scroll it.
        advancedFilters.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Nombre"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["7 días"].exists)
    }

    func testDashboardSearchFiltersRenamePinAndDetailControls() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let searchAction = app.buttons["dashboard-search-action"]
        let filterMenu = app.buttons["dashboard-filter-menu"]
        XCTAssertTrue(searchAction.waitForExistence(timeout: 12))
        XCTAssertTrue(filterMenu.exists)
        XCTAssertFalse(app.descendants(matching: .any)["dashboard-server-switcher"].exists)
        searchAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let search = app.textFields["dashboard-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        let dashboardScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dashboardScreenshot.name = "compact-dashboard-search"
        dashboardScreenshot.lifetime = .keepAlways
        add(dashboardScreenshot)

        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bilingualKeyboardOnboarding = app.buttons["Continue"]
        if bilingualKeyboardOnboarding.waitForExistence(timeout: 2) {
            bilingualKeyboardOnboarding.tap()
        }
        search.typeText("zzzz-no-session")
        dismissPastePermissionIfNeeded(in: app)
        XCTAssertTrue(app.staticTexts["Sin resultados"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["0 sesiones coinciden"].exists)
        app.buttons["Limpiar búsqueda"].tap()

        let cards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-'")
        )
        let renameButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'rename-session-'")
        )
        let pinButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'pin-session-'")
        )
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 8))
        let cardActions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-actions-'")
        ).firstMatch
        XCTAssertTrue(cardActions.waitForExistence(timeout: 2))
        cardActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(renameButtons.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(pinButtons.firstMatch.exists)

        renameButtons.firstMatch.tap()
        XCTAssertTrue(app.textFields["rename-session-field"].waitForExistence(timeout: 2))
        let renameScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        renameScreenshot.name = "session-rename-editor"
        renameScreenshot.lifetime = .keepAlways
        add(renameScreenshot)
        app.buttons["rename-session-cancel"].tap()

        cardActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(pinButtons.firstMatch.waitForExistence(timeout: 2))
        pinButtons.firstMatch.tap()

        let unpinnedDisclosure = app.buttons["dashboard-unpinned-disclosure"]
        XCTAssertTrue(unpinnedDisclosure.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'pin-unpinned-session-'")
            ).firstMatch.exists
        )
        unpinnedDisclosure.tap()
        let restorePinButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'pin-unpinned-session-'")
        ).firstMatch
        XCTAssertTrue(restorePinButton.waitForExistence(timeout: 2))
        restorePinButton.tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 2))

        cards.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let composerField = app.textFields["composer-message"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 5))
        let moreActions = app.buttons["composer-more-actions"]
        XCTAssertTrue(moreActions.exists)
        XCTAssertGreaterThanOrEqual(moreActions.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Improver"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Explainer"].frame.height, 44)
        XCTAssertFalse(app.buttons["composer-create-subagent"].exists)
        XCTAssertFalse(app.buttons["composer-expand-editor"].exists)
        XCTAssertGreaterThanOrEqual(composerField.frame.width, 96)
        moreActions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["composer-create-subagent"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["composer-expand-editor"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.44)).tap()
        XCTAssertFalse(app.buttons["composer-create-subagent"].waitForExistence(timeout: 2))
        let microphoneButton = app.buttons["Grabar mensaje de voz"]
        XCTAssertGreaterThanOrEqual(microphoneButton.frame.height, 48)
        XCTAssertLessThanOrEqual(microphoneButton.frame.height, 49)
        XCTAssertEqual(microphoneButton.value as? String, "Listo")
        XCTAssertTrue(app.buttons["detail-runtime-model-switcher"].exists)
        XCTAssertFalse(app.buttons["Renombrar sesión"].exists)
        XCTAssertFalse(app.buttons["transcript-search-toggle"].exists)
        let detailScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detailScreenshot.name = "session-detail-controls"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
    }

    func testDashboardCompactSearchAndFiltersReplacePermanentComputerSwitcher() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let searchAction = app.buttons["dashboard-search-action"]
        let filterMenu = app.buttons["dashboard-filter-menu"]
        let moreMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(searchAction.waitForExistence(timeout: 30))
        XCTAssertTrue(filterMenu.exists)
        XCTAssertTrue(moreMenu.exists)
        XCTAssertFalse(app.descendants(matching: .any)["dashboard-server-switcher"].exists)
        XCTAssertGreaterThanOrEqual(filterMenu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(filterMenu.frame.height, 44)

        let personalMetadata = app.descendants(matching: .any)["session-metadata-messaging-fixture-0"]
        let pukyMetadata = app.descendants(matching: .any)["session-metadata-messaging-fixture-1"]
        XCTAssertTrue(personalMetadata.waitForExistence(timeout: 3))
        XCTAssertTrue(pukyMetadata.exists)
        XCTAssertEqual(personalMetadata.label, "Modelo, razonamiento y origen SOL · MAX · PERSONAL")
        XCTAssertEqual(pukyMetadata.label, "Modelo, razonamiento y origen LUNA · MAX · PUKY")

        let compactScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compactScreenshot.name = "dashboard-compact-search-and-filters"
        compactScreenshot.lifetime = .keepAlways
        add(compactScreenshot)

        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["dashboard-target-all"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dashboard-target-puky"].exists)
        XCTAssertTrue(app.buttons["dashboard-target-personal"].exists)
        XCTAssertTrue(app.buttons["dashboard-menu-filter-all"].exists)
        XCTAssertTrue(app.buttons["dashboard-menu-filter-attention"].exists)

        let menuScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuScreenshot.name = "dashboard-computer-and-attention-filter-menu"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)

        app.buttons["dashboard-menu-filter-all"].tap()
        searchAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let search = app.textFields["dashboard-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue((search.value as? String)?.contains("nombre, proyecto o mensaje") == true)
        XCTAssertTrue(app.buttons["Cerrar búsqueda"].exists)
        let searchScope = app.buttons["dashboard-search-scope"]
        XCTAssertTrue(searchScope.waitForExistence(timeout: 2))
        XCTAssertTrue(searchScope.isHittable)
        XCTAssertGreaterThanOrEqual(searchScope.frame.width, 44)
        XCTAssertGreaterThanOrEqual(searchScope.frame.height, 44)
        XCTAssertFalse(filterMenu.isHittable)
        XCTAssertTrue((searchScope.value as? String)?.contains("Todas") == true)

        let searchScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        searchScreenshot.name = "dashboard-search-scope-copy"
        searchScreenshot.lifetime = .keepAlways
        add(searchScreenshot)

        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        search.typeText("zzzz-scope-persist")
        dismissPastePermissionIfNeeded(in: app)
        searchScope.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let attention = app.buttons["dashboard-search-menu-filter-attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dashboard-search-target-all"].exists)
        XCTAssertTrue(app.buttons["dashboard-search-target-puky"].exists)
        XCTAssertTrue(app.buttons["dashboard-search-target-personal"].exists)
        attention.tap()
        XCTAssertEqual(search.value as? String, "zzzz-scope-persist")
        XCTAssertTrue(searchScope.waitForExistence(timeout: 2))
        XCTAssertTrue((searchScope.value as? String)?.contains("Atención") == true)
        XCTAssertFalse(searchAction.isHittable)

        app.buttons["Limpiar búsqueda"].tap()
        app.buttons["Cerrar búsqueda"].tap()
        XCTAssertTrue(searchAction.waitForExistence(timeout: 2))
        let restoredSearchHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: searchAction
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [restoredSearchHittable], timeout: 3),
            .completed
        )
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 2))
        XCTAssertTrue(filterMenu.isEnabled)
        // SwiftUI Menu inside this floating dock can report false for
        // `isHittable` even while its physical touch target is active.
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            app.buttons["dashboard-menu-filter-attention"].waitForExistence(timeout: 3)
        )
        let allSessions = app.buttons["dashboard-menu-filter-all"]
        XCTAssertTrue(allSessions.waitForExistence(timeout: 2))
        allSessions.tap()
        XCTAssertTrue(allSessions.waitForNonExistence(timeout: 2))
    }

    func testDashboardSearchImmediateCloseCannotLeaveFocusLatched() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_DASHBOARD_FIXTURE"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_DASHBOARD_SEARCH_FOCUS_DELAY_MS"] = "5000"
        app.launch()
        resetDashboardPresentation(in: app)

        let searchAction = app.buttons["dashboard-search-action"]
        let filterMenu = app.buttons["dashboard-filter-menu"]
        let newSession = app.buttons["dashboard-new-session"]
        XCTAssertTrue(searchAction.waitForExistence(timeout: 30))

        searchAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let search = app.textFields["dashboard-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        let closeSearch = app.buttons["Cerrar búsqueda"]
        XCTAssertTrue(closeSearch.exists)
        closeSearch.tap()

        XCTAssertFalse(search.waitForExistence(timeout: 1))
        // Assert after the injected five-second focus deadline. Before the fix,
        // the uncancelled task would have re-latched focus by this point.
        Thread.sleep(forTimeInterval: 5.5)
        let restoredSearchHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: searchAction
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [restoredSearchHittable], timeout: 2),
            .completed
        )
        XCTAssertTrue(filterMenu.exists)
        XCTAssertTrue(filterMenu.isEnabled)
        XCTAssertTrue(newSession.exists)
        XCTAssertTrue(newSession.isHittable)

        let restoredDockScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        restoredDockScreenshot.name = "dashboard-search-focus-restored-after-immediate-close"
        restoredDockScreenshot.lifetime = .keepAlways
        add(restoredDockScreenshot)

        searchAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(search.waitForExistence(timeout: 2))
    }

    func testGoalModeToggleUpdatesImmediatelyAndStaysInteractive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_GOAL_MODE"] = "1"
        app.launch()

        let goalButton = app.buttons["detail-goal-mode-toggle"]
        XCTAssertTrue(goalButton.waitForExistence(timeout: 5))
        XCTAssertTrue(goalButton.isEnabled)
        XCTAssertTrue(goalButton.isHittable)
        XCTAssertEqual(goalButton.frame.height, 44, accuracy: 0.5)
        let initialValue = try XCTUnwrap(goalButton.value as? String)
        let toggledValue = initialValue == "Activado" ? "Desactivado" : "Activado"
        let composer = app.textFields["goal-mode-harness-composer"]
        let counts = app.staticTexts["goal-mode-harness-counts"]
        let acknowledgement = app.staticTexts["goal-mode-harness-acknowledgement"]
        let send = app.buttons["goal-mode-harness-send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(counts.exists)
        XCTAssertEqual(counts.label, "goal=0, message=0")

        composer.tap()
        composer.typeText("Objetivo escrito, todavía sin enviar")

        goalButton.tap()
        XCTAssertEqual(
            goalButton.value as? String,
            toggledValue,
            "GOAL must publish its new accessibility state in the same interaction."
        )
        XCTAssertEqual(
            counts.label,
            "goal=0, message=0",
            "Selecting GOAL must not issue a goal command or send the draft."
        )
        XCTAssertEqual(
            acknowledgement.label,
            "GOAL preparado; todavía no se envió nada"
        )
        XCTAssertTrue(goalButton.isEnabled)
        let goalCenter = goalButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        goalCenter.tap()
        XCTAssertEqual(goalButton.value as? String, initialValue)
        XCTAssertEqual(counts.label, "goal=0, message=0")
        goalCenter.tap()
        XCTAssertEqual(goalButton.value as? String, toggledValue)
        XCTAssertEqual(counts.label, "goal=0, message=0")

        let preparedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        preparedScreenshot.name = "goal-selected-with-draft-no-send"
        preparedScreenshot.lifetime = .keepAlways
        add(preparedScreenshot)

        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertEqual(counts.label, "goal=1, message=1")
        XCTAssertEqual(
            acknowledgement.label,
            "Procesando después del envío explícito"
        )

        let portraitScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portraitScreenshot.name = "goal-processing-after-explicit-send"
        portraitScreenshot.lifetime = .keepAlways
        add(portraitScreenshot)

        goalButton.tap()
        XCTAssertEqual(goalButton.value as? String, initialValue)
        XCTAssertTrue(goalButton.isEnabled)

        goalButton.tap()
        goalButton.tap()
        XCTAssertEqual(goalButton.value as? String, initialValue)
        XCTAssertTrue(goalButton.isHittable)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(goalButton.waitForExistence(timeout: 3))
        XCTAssertTrue(goalButton.isHittable)
        usleep(300_000)
        let landscapeScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeScreenshot.name = "goal-mode-restored-landscape"
        landscapeScreenshot.lifetime = .keepAlways
        add(landscapeScreenshot)
        XCUIDevice.shared.orientation = .portrait
    }

    func testFeatureTogglesKeepLatestIntentInteractiveDuringSynchronization() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FEATURE_TOGGLES"] = "1"
        app.launch()

        let improver = app.buttons["feature-harness-improver"]
        let explainer = app.buttons["feature-harness-explainer"]
        XCTAssertTrue(improver.waitForExistence(timeout: 5))
        XCTAssertTrue(explainer.exists)
        XCTAssertEqual(improver.frame.height, 44, accuracy: 0.5)
        XCTAssertEqual(improver.value as? String, "Desactivado")

        improver.tap()
        XCTAssertEqual(improver.value as? String, "Activado, sincronizando")
        XCTAssertTrue(improver.isEnabled)
        XCTAssertTrue(improver.isHittable)

        improver.tap()
        XCTAssertEqual(improver.value as? String, "Desactivado, sincronizando")
        explainer.tap()
        XCTAssertEqual(explainer.value as? String, "Activado, sincronizando")
        XCTAssertTrue(explainer.isHittable)

        let finalServerState = NSPredicate(
            format: "label == %@",
            "Servidor: Improver desactivado · Explainer activado · 2 envíos"
        )
        expectation(
            for: finalServerState,
            evaluatedWith: app.staticTexts["feature-harness-server-state"]
        )
        waitForExpectations(timeout: 4)
        XCTAssertEqual(improver.value as? String, "Desactivado")
        XCTAssertEqual(explainer.value as? String, "Activado")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "feature-toggle-latest-intent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFeatureToggleFailureRollsBackAndRetriesTheRequestedState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_FEATURE_TOGGLES"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_FEATURE_TOGGLES_FAIL_ONCE"] = "1"
        app.launch()

        let improver = app.buttons["feature-harness-improver"]
        XCTAssertTrue(improver.waitForExistence(timeout: 5))
        XCTAssertEqual(improver.value as? String, "Desactivado")

        improver.tap()
        XCTAssertEqual(improver.value as? String, "Activado, sincronizando")

        let error = app.descendants(matching: .any)["feature-harness-retry-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(improver.value as? String, "Desactivado")

        let retry = app.buttons["Reintentar cambio"]
        XCTAssertTrue(retry.exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)

        let failureScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failureScreenshot.name = "feature-toggle-failure-retry"
        failureScreenshot.lifetime = .keepAlways
        add(failureScreenshot)

        retry.tap()

        let retriedState = NSPredicate(
            format: "label == %@",
            "Servidor: Improver activado · Explainer desactivado · 2 envíos"
        )
        expectation(
            for: retriedState,
            evaluatedWith: app.staticTexts["feature-harness-server-state"]
        )
        waitForExpectations(timeout: 3)
        XCTAssertEqual(improver.value as? String, "Activado")
        XCTAssertTrue(error.waitForNonExistence(timeout: 2))
    }

    func testDashboardFloatingCreateButtonKeepsLastSessionReachable() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let createButton = app.buttons["dashboard-new-session"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 12))
        XCTAssertTrue(createButton.isHittable)
        XCTAssertFalse(app.buttons["Enviar broadcast"].exists)

        let cards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-'")
        )
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 12))
        XCTAssertGreaterThan(cards.count, 0)
        let lastCard = cards.element(boundBy: cards.count - 1)
        for _ in 0..<6 {
            if lastCard.exists,
               lastCard.isHittable,
               !lastCard.frame.intersects(createButton.frame) {
                break
            }
            app.swipeUp()
        }

        XCTAssertTrue(lastCard.waitForExistence(timeout: 3))
        XCTAssertTrue(lastCard.isHittable)
        XCTAssertFalse(
            lastCard.frame.intersects(createButton.frame),
            "La última tarjeta debe poder quedar libre del botón +. card=\(lastCard.frame), fab=\(createButton.frame)"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "floating-fab-scroll"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTodoNewSessionOffersPersonalAndPukyWithoutNetwork() {
        let app = launchDashboardFixture()
        defer { app.terminate() }
        resetDashboardPresentation(in: app)

        let filterMenu = app.buttons["dashboard-filter-menu"]
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let todo = app.buttons["dashboard-target-all"]
        XCTAssertTrue(todo.waitForExistence(timeout: 3))
        todo.tap()

        let create = app.buttons["dashboard-new-session"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(create.isHittable)
        create.tap()

        XCTAssertTrue(app.buttons["Mac personal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Puky"].exists)
    }

    func testPendingCreationCardExplainsTheBackgroundHandoffInSpanish() {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_PENDING_SESSION"] = "1"
        app.launch()
        defer { app.terminate() }

        let card = app.descendants(matching: .any)["pending-created-session-ui-pending"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertEqual(card.label, "Creando Auditar onboarding…")
        XCTAssertEqual(card.value as? String, "Puky aceptó el pedido · projects")
        XCTAssertTrue(card.isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "pending-session-background-handoff"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testImageAttachmentPickerOpensFromComposer() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let firstCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-messaging-'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 12))
        firstCard.tap()

        let attachButton = app.buttons["composer-more-actions"]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 5))
        // SwiftUI Menu inside a floating overlay can report false for
        // `isHittable` even though its physical touch target is active.
        attachButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let choosePhotosButton = app.buttons["Elegir de Fotos"]
        XCTAssertTrue(choosePhotosButton.waitForExistence(timeout: 2))
        choosePhotosButton.tap()

        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Cancel", "Cancelar"])
        ).firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))

        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        let firstPhoto = photos.element(boundBy: 0)
        let secondPhoto = photos.element(boundBy: 1)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 3))
        firstPhoto.tap()

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))
        XCTAssertTrue(addButton.isEnabled)
        addButton.tap()

        let oneImageLabel = app.descendants(matching: .any)["composer-attachment-count"]
        XCTAssertTrue(oneImageLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(oneImageLabel.label, "1 imagen adjunta")
        let expandedComposerHeight = attachButton.frame.maxY - oneImageLabel.frame.minY
        XCTAssertLessThanOrEqual(expandedComposerHeight, 120)
        let oneImageScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        oneImageScreenshot.name = "single-image-preview"
        oneImageScreenshot.lifetime = .keepAlways
        add(oneImageScreenshot)
        app.buttons["composer-remove-all-attachments"].tap()
        XCTAssertFalse(oneImageLabel.waitForExistence(timeout: 2))

        attachButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(choosePhotosButton.waitForExistence(timeout: 2))
        choosePhotosButton.tap()
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        let multiplePhotos = app.images.matching(identifier: "PXGGridLayout-Info")
        let multipleFirstPhoto = multiplePhotos.element(boundBy: 0)
        let multipleSecondPhoto = multiplePhotos.element(boundBy: 1)
        XCTAssertTrue(multipleFirstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(multipleSecondPhoto.waitForExistence(timeout: 3))
        multipleFirstPhoto.tap()
        multipleSecondPhoto.tap()
        XCTAssertTrue(addButton.isEnabled)
        addButton.tap()

        let twoImagesLabel = app.descendants(matching: .any)["composer-attachment-count"]
        XCTAssertTrue(twoImagesLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(twoImagesLabel.label, "2 imágenes adjuntas")
        XCTAssertLessThanOrEqual(attachButton.frame.maxY - twoImagesLabel.frame.minY, 120)
        let twoImagesScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        twoImagesScreenshot.name = "multiple-image-preview"
        twoImagesScreenshot.lifetime = .keepAlways
        add(twoImagesScreenshot)
        app.buttons["composer-remove-all-attachments"].tap()
        XCTAssertFalse(twoImagesLabel.waitForExistence(timeout: 2))
        XCTAssertTrue(attachButton.exists)
    }

    func testImageAttachmentPickerStaysUsableDuringRecording() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let firstCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-messaging-'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 12))
        firstCard.tap()

        let removeExistingAttachments = app.buttons["composer-remove-all-attachments"]
        if removeExistingAttachments.waitForExistence(timeout: 1) {
            removeExistingAttachments.tap()
        }

        let microphone = app.buttons["composer-microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 8))
        microphone.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for permissionLabel in ["Allow While Using App", "Permitir al usar la app", "Allow"] {
            let permission = springboard.buttons[permissionLabel]
            if permission.waitForExistence(timeout: 1) {
                permission.tap()
                break
            }
        }

        XCTAssertEqual(app.buttons["composer-microphone"].label, "Detener grabación")
        let attachButton = app.buttons["composer-more-actions"]
        XCTAssertTrue(
            attachButton.waitForExistence(timeout: 3),
            "The image control must remain mounted while audio is recording."
        )
        attachButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let choosePhotosButton = app.buttons["Elegir de Fotos"]
        XCTAssertTrue(choosePhotosButton.waitForExistence(timeout: 2))
        XCTAssertTrue(choosePhotosButton.isEnabled)
        let cameraButton = app.buttons["Tomar foto"]
        XCTAssertTrue(cameraButton.exists)
        XCTAssertFalse(cameraButton.isEnabled)
        let pasteImageButton = app.buttons["Pegar imagen"]
        XCTAssertTrue(pasteImageButton.exists)
        XCTAssertTrue(pasteImageButton.isEnabled)
        XCTAssertEqual(
            app.buttons["composer-microphone"].label,
            "Detener grabación",
            "Opening the attachment controls must not stop or finalize the active audio recording."
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "recording-with-image-controls-available"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.12)).tap()
        XCTAssertFalse(choosePhotosButton.waitForExistence(timeout: 2))
        app.buttons["Cancelar grabación"].tap()
        XCTAssertTrue(app.buttons["composer-microphone"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["composer-microphone"].label, "Grabar mensaje de voz")
    }

    func testMessageActionsRemainAvailableWithoutHeaderSearch() throws {
        let app = launchDashboardFixture()
        resetDashboardPresentation(in: app)

        let firstCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-messaging-'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 12))
        firstCard.tap()
        XCTAssertTrue(app.buttons["detail-runtime-model-switcher"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transcript-search-toggle"].exists)
        XCTAssertFalse(app.buttons["Renombrar sesión"].exists)
        let message = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'message-'")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Responder citando"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Guardar mensaje"].exists || app.buttons["Quitar de guardados"].exists)
        XCTAssertTrue(app.buttons["Compartir"].exists)
        XCTAssertTrue(app.buttons["Copiar mensaje"].exists)
    }

    func testRuntimeModelSwitcherUsesCatalogRollsBackAndRetries() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_SWITCHER"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_SWITCHER_FAIL_FIRST"] = "1"
        app.launch()

        let switcher = app.buttons["detail-runtime-model-switcher"]
        let goal = app.buttons["detail-goal-mode-toggle"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(goal.exists)
        XCTAssertLessThanOrEqual(switcher.frame.maxX, goal.frame.minX)
        XCTAssertLessThanOrEqual(switcher.frame.width, 72)
        XCTAssertEqual(switcher.frame.height, 44, accuracy: 0.5)
        XCTAssertEqual(goal.frame.height, 44, accuracy: 0.5)
        XCTAssertEqual(switcher.value as? String, "SOL, HIGH")
        XCTAssertFalse(app.buttons["transcript-search-toggle"].exists)
        XCTAssertFalse(app.buttons["Renombrar sesión"].exists)

        switcher.tap()
        let apply = app.buttons["runtime-settings-apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(apply.label, "Sin cambios")
        XCTAssertTrue(app.buttons["Cerrar"].exists)
        XCTAssertFalse(app.buttons["Cancelar"].exists)

        let initialModelPicker = app.buttons["runtime-model-picker"]
        let initialEffortPicker = app.buttons["runtime-reasoning-picker"]
        XCTAssertTrue(initialModelPicker.exists)
        XCTAssertTrue(initialEffortPicker.exists)
        XCTAssertGreaterThanOrEqual(initialModelPicker.frame.height, 44)
        XCTAssertGreaterThanOrEqual(initialEffortPicker.frame.height, 44)

        let initialSheetScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        initialSheetScreenshot.name = "runtime-model-settings-initial"
        initialSheetScreenshot.lifetime = .keepAlways
        add(initialSheetScreenshot)

        let modelPicker = app.buttons["runtime-model-picker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 3))
        modelPicker.tap()
        let luna = app.buttons["GPT-5.6-LUNA"]
        XCTAssertTrue(luna.waitForExistence(timeout: 2))
        luna.tap()
        XCTAssertTrue(apply.isEnabled)
        XCTAssertEqual(apply.label, "Aplicar a la sesión")
        XCTAssertTrue(app.buttons["Cancelar"].exists)
        XCTAssertFalse(app.buttons["Cerrar"].exists)

        modelPicker.tap()
        let sol = app.buttons["GPT-5.6-SOL"]
        XCTAssertTrue(sol.waitForExistence(timeout: 2))
        sol.tap()
        XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(apply.label, "Sin cambios")
        XCTAssertTrue(app.buttons["Cerrar"].exists)

        modelPicker.tap()
        XCTAssertTrue(luna.waitForExistence(timeout: 2))
        luna.tap()

        let effortPicker = app.buttons["runtime-reasoning-picker"]
        XCTAssertTrue(effortPicker.waitForExistence(timeout: 2))
        effortPicker.tap()
        let maximum = app.buttons["MAX"]
        XCTAssertTrue(maximum.waitForExistence(timeout: 2))
        maximum.tap()

        XCTAssertTrue(apply.isEnabled)
        XCTAssertEqual(apply.label, "Aplicar a la sesión")
        apply.tap()
        let runtimeError = app.staticTexts["runtime-settings-error"]
        XCTAssertTrue(runtimeError.waitForExistence(timeout: 3))
        XCTAssertTrue(runtimeError.label.contains("El runtime de prueba rechazó el cambio"))
        XCTAssertEqual(app.buttons["runtime-settings-apply"].label, "Reintentar cambio")

        app.buttons["runtime-settings-apply"].tap()
        XCTAssertFalse(app.buttons["runtime-settings-apply"].waitForExistence(timeout: 3))
        XCTAssertEqual(switcher.value as? String, "LUNA, MAX")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "runtime-model-switcher-luna-max"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRuntimeCatalogRetryHasComfortableTargetAndRecovers() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_SWITCHER"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_CATALOG_FAIL_FIRST"] = "1"
        app.launch()

        let switcher = app.buttons["detail-runtime-model-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        switcher.tap()

        let retry = app.buttons["runtime-catalog-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(app.staticTexts["runtime-settings-error"].exists)

        retry.tap()
        XCTAssertTrue(app.buttons["runtime-model-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(retry.waitForNonExistence(timeout: 2))
    }

    func testRuntimeModelSheetKeepsControlsVisibleWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_SWITCHER"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_RUNTIME_ACCESSIBILITY_TEXT"] = "1"
        app.launch()

        let switcher = app.buttons["detail-runtime-model-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        switcher.tap()

        let modelPicker = app.buttons["runtime-model-picker"]
        let effortPicker = app.buttons["runtime-reasoning-picker"]
        let modelLabel = app.staticTexts["runtime-model-label"]
        let effortLabel = app.staticTexts["runtime-reasoning-label"]
        let apply = app.buttons["runtime-settings-apply"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(effortPicker.exists)
        XCTAssertTrue(modelLabel.exists)
        XCTAssertTrue(effortLabel.exists)
        XCTAssertTrue(apply.exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "runtime-model-settings-accessibility-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let frames = XCTAttachment(
            string: "modelLabel=\(modelLabel.frame) modelPicker=\(modelPicker.frame) "
                + "effortLabel=\(effortLabel.frame) effortPicker=\(effortPicker.frame)"
        )
        frames.name = "runtime-model-settings-accessibility-frames"
        frames.lifetime = .keepAlways
        add(frames)

        XCTAssertTrue(modelPicker.isHittable)
        XCTAssertTrue(effortPicker.isHittable)
        XCTAssertGreaterThanOrEqual(modelPicker.frame.height, 44)
        XCTAssertGreaterThanOrEqual(effortPicker.frame.height, 44)
        XCTAssertGreaterThanOrEqual(apply.frame.height, 48)
        XCTAssertLessThanOrEqual(
            modelLabel.frame.intersection(modelPicker.frame).height,
            4
        )
        XCTAssertFalse(modelPicker.frame.intersects(effortLabel.frame))
        XCTAssertLessThanOrEqual(
            effortLabel.frame.intersection(effortPicker.frame).height,
            4
        )
        XCTAssertLessThanOrEqual(modelPicker.frame.maxY, effortLabel.frame.minY)

    }

    func testLiveDedicatedQAMicrophoneFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KYCODE_RUN_LIVE_QA"] == "1",
              let qaWindowId = environment["KYCODE_LIVE_QA_WINDOW_ID"],
              !qaWindowId.isEmpty else {
            throw XCTSkip("Live QA requires an explicit disposable session window id.")
        }

        let app = XCUIApplication()
        app.launch()

        let qaCard = app.buttons["session-card-messaging-\(qaWindowId)"]
        XCTAssertTrue(qaCard.waitForExistence(timeout: 12))
        qaCard.tap()

        let microphone = app.buttons["composer-microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["composer-send-message"].exists)

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("layout qa")
        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(microphone.exists)
        XCTAssertLessThanOrEqual(composer.frame.maxX, microphone.frame.minX)
        XCTAssertLessThanOrEqual(microphone.frame.maxX, send.frame.minX)
        XCTAssertFalse(app.buttons["Cerrar teclado"].exists)
        let keyboardLayoutScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        keyboardLayoutScreenshot.name = "qa-composer-keyboard-no-overlap"
        keyboardLayoutScreenshot.lifetime = .keepAlways
        add(keyboardLayoutScreenshot)
        app.buttons["composer-clear-text"].tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 2))
        app.swipeDown()

        microphone.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for permissionLabel in ["Allow While Using App", "Permitir al usar la app", "Allow"] {
            let permission = springboard.buttons[permissionLabel]
            if permission.waitForExistence(timeout: 1) {
                permission.tap()
                break
            }
        }

        let stop = app.buttons["composer-microphone"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertEqual(stop.label, "Detener grabación")
        XCTAssertGreaterThanOrEqual(stop.frame.height, 52)
        let recordingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        recordingScreenshot.name = "qa-microphone-recording"
        recordingScreenshot.lifetime = .keepAlways
        add(recordingScreenshot)

        sleep(1)
        stop.tap()
        let microphoneAfterStop = app.buttons["composer-microphone"]
        XCTAssertTrue(microphoneAfterStop.waitForExistence(timeout: 5))
        let settledValue = microphoneAfterStop.value as? String
        XCTAssertTrue(
            settledValue == "Transcribiendo" ||
                settledValue == "Listo" ||
                settledValue == "No disponible"
        )
        let transitionScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        transitionScreenshot.name = "qa-microphone-transition-result"
        transitionScreenshot.lifetime = .keepAlways
        add(transitionScreenshot)
    }

    func testLiveAudioTranscriptionV2ReleasesUIAndSurvivesNavigation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KYCODE_RUN_LIVE_AUDIO_QA"] == "1",
              let fixture = environment["KYCODE_STABILITY_AUDIO_FIXTURE"],
              !fixture.isEmpty else {
            throw XCTSkip("Live audio QA requires an explicit disposable fixture.")
        }
        let qaSearch = environment["KYCODE_LIVE_AUDIO_QA_SEARCH"]
            ?? "audio flow QA 2026-07-28"

        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_STABILITY_AUDIO_FIXTURE"] = fixture
        app.launchEnvironment["KYCODE_STABILITY_AUDIO_SECONDS"] =
            environment["KYCODE_STABILITY_AUDIO_SECONDS"] ?? "10"
        app.launch()

        let dashboardSearch = app.textFields["dashboard-search"]
        XCTAssertTrue(dashboardSearch.waitForExistence(timeout: 15))
        dashboardSearch.tap()
        dashboardSearch.typeText(qaSearch)
        dismissPastePermissionIfNeeded(in: app)

        let qaCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-card-messaging-'")
        ).firstMatch
        let targetCard: XCUIElement
        if qaCard.waitForExistence(timeout: 8) {
            targetCard = qaCard
        } else {
            // Keep live QA isolated even when the previous disposable session
            // was closed by desktop between test runs.
            let clearSearch = app.buttons["Limpiar búsqueda"]
            XCTAssertTrue(clearSearch.waitForExistence(timeout: 2))
            clearSearch.tap()
            app.swipeDown()

            let messagingCards = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'session-card-messaging-'")
            )
            let existingIdentifiers = messagingCards.allElementsBoundByIndex.map(\.identifier)
            let create = app.buttons["dashboard-new-session"]
            XCTAssertTrue(create.waitForExistence(timeout: 3))
            create.tap()

            let projectSearch = app.textFields["create-session-search"]
            XCTAssertTrue(projectSearch.waitForExistence(timeout: 10))
            projectSearch.tap()
            projectSearch.typeText("kycode-mobile")
            let project = app.buttons["create-project-kycode-mobile"]
            XCTAssertTrue(project.waitForExistence(timeout: 5))
            project.tap()
            app.buttons["create-session-confirm"].tap()

            let newCard = messagingCards.matching(
                NSPredicate(format: "NOT (identifier IN %@)", existingIdentifiers)
            ).firstMatch
            XCTAssertTrue(
                newCard.waitForExistence(timeout: 20),
                "Desktop did not publish the disposable audio QA session."
            )
            targetCard = newCard
        }
        targetCard.tap()

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(
            composer.waitForExistence(timeout: 15),
            "The disposable QA session never exposed its composer."
        )
        let clearDraft = app.buttons["composer-clear-text"]
        if clearDraft.waitForExistence(timeout: 1) {
            clearDraft.tap()
        }

        let microphone = app.buttons["composer-microphone"]
        XCTAssertTrue(
            microphone.waitForExistence(timeout: 15),
            "The microphone did not replace the send action after clearing the composer."
        )
        let startedAt = Date()
        microphone.tap()

        let pendingStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'voice-message-status-'")
        ).firstMatch
        XCTAssertTrue(
            pendingStatus.waitForExistence(timeout: 2),
            "The inline acknowledgement never became visible."
        )
        let voiceMessageMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'message-voice-'")
        ).firstMatch
        XCTAssertTrue(
            voiceMessageMarker.waitForExistence(timeout: 1),
            "The pending voice message did not expose its acknowledgement marker."
        )
        let acknowledgementTimestamp = (voiceMessageMarker.value as? String)
            .flatMap { value -> Double? in
                guard value.hasPrefix("ack-timestamp-ms:") else { return nil }
                return Double(value.dropFirst("ack-timestamp-ms:".count))
            }
        XCTAssertNotNil(
            acknowledgementTimestamp,
            "The acknowledgement did not expose its production timestamp."
        )
        let acknowledgementMilliseconds = (acknowledgementTimestamp ?? .infinity)
            - startedAt.timeIntervalSince1970 * 1_000
        print(
            String(
                format: "[AudioQA] acknowledgement_ms=%.1f",
                acknowledgementMilliseconds
            )
        )
        XCTAssertLessThan(acknowledgementMilliseconds, 500)

        XCTAssertTrue(composer.exists)
        XCTAssertTrue(composer.isHittable)
        composer.tap()
        composer.typeText("UI libre")
        XCTAssertEqual(composer.value as? String, "UI libre")
        app.buttons["composer-clear-text"].tap()

        let pendingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pendingScreenshot.name = "audio-pending-ui-released"
        pendingScreenshot.lifetime = .keepAlways
        add(pendingScreenshot)

        let navigationBar = app.navigationBars.firstMatch
        let backButton = navigationBar.buttons.firstMatch
        XCTAssertTrue(backButton.exists)
        backButton.tap()
        XCTAssertTrue(dashboardSearch.waitForExistence(timeout: 2))

        sleep(5)
        XCTAssertTrue(targetCard.waitForExistence(timeout: 5))
        targetCard.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // The optimistic `voice-*` ID is intentionally replaced by the
        // server's canonical message ID after acknowledgement. User-visible
        // continuity is the transcript itself; delta identity is covered by
        // the store unit tests before reconciliation.
        let voiceMessage = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                "Esta es una prueba de audio de 10 segundos"
            )
        ).firstMatch
        XCTAssertTrue(
            voiceMessage.waitForExistence(timeout: 5),
            "The transcribed voice message did not survive navigation."
        )

        let returnedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        returnedScreenshot.name = "audio-after-navigation-return"
        returnedScreenshot.lifetime = .keepAlways
        add(returnedScreenshot)
    }

    func testLiveDedicatedQAProgressivelyRevealsAssistantResponse() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KYCODE_RUN_LIVE_QA"] == "1",
              let qaWindowId = environment["KYCODE_LIVE_QA_WINDOW_ID"],
              !qaWindowId.isEmpty else {
            throw XCTSkip("Set KYCODE_RUN_LIVE_QA=1 and KYCODE_LIVE_QA_WINDOW_ID to run live QA.")
        }
        let qaSearchText = environment["KYCODE_LIVE_QA_SEARCH"] ?? "QA"

        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_VISUAL_STREAM"] = "1"
        app.launch()

        let dashboardSearch = app.textFields["dashboard-search"]
        XCTAssertTrue(dashboardSearch.waitForExistence(timeout: 15))
        let clearDashboardSearch = app.buttons["Limpiar búsqueda"]
        if clearDashboardSearch.exists {
            clearDashboardSearch.tap()
        }
        dashboardSearch.tap()
        dashboardSearch.typeText(qaSearchText)
        dismissPastePermissionIfNeeded(in: app)

        let qaCard = app.buttons["session-card-messaging-\(qaWindowId)"]
        XCTAssertTrue(qaCard.waitForExistence(timeout: 8))
        qaCard.tap()

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))

        let explainer = app.buttons["Explainer"]
        if explainer.exists, (explainer.value as? String) == "Activado" {
            explainer.tap()
            let explainerDisabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Desactivado"),
                object: explainer
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [explainerDisabled], timeout: 8),
                .completed,
                "The dedicated QA session could not disable Explainer before the streaming test."
            )
        }

        composer.tap()
        composer.typeText(
            "QA visual streaming: respondé una sola vez, sin listas, con un texto continuo de 2600 a 3000 caracteres sobre por qué una interfaz móvil fluida ayuda a coordinar agentes."
        )
        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        let streamingResponse = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'progressive-message-' AND value BEGINSWITH 'streaming-'"
            )
        ).firstMatch
        let enteredProgressiveStream = streamingResponse.waitForExistence(timeout: 120)
        XCTAssertTrue(
            enteredProgressiveStream,
            "A new assistant response never entered the progressive visual stream."
        )

        let streamingIdentifier = streamingResponse.identifier
        let streamingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        streamingScreenshot.name = "live-assistant-progressive-stream"
        streamingScreenshot.lifetime = .keepAlways
        add(streamingScreenshot)

        let completedResponse = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND value BEGINSWITH 'complete-'",
                streamingIdentifier
            )
        ).firstMatch
        XCTAssertTrue(
            completedResponse.waitForExistence(timeout: 30),
            "The progressive assistant response did not settle to its complete state."
        )
    }

    func testLiveFerminRelayCreatesSessionReceivesReplyAndCleansUp() throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedProfileId = environment["KYCODE_LIVE_SELECTED_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard requestedProfileId.isEmpty
                || requestedProfileId == "personal"
                || requestedProfileId == "puky" else {
            throw XCTSkip("KYCODE_LIVE_SELECTED_PROFILE must be personal or puky for this optional live run.")
        }
        let profileId = requestedProfileId.isEmpty ? "personal" : requestedProfileId
        let tokenEnvironmentKey = profileId == "personal"
            ? "KYCODE_LIVE_PERSONAL_TOKEN"
            : "KYCODE_LIVE_PUKY_TOKEN"
        guard let token = environment[tokenEnvironmentKey],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("\(tokenEnvironmentKey) is required for the authorized clean-relay QA run.")
        }
        let displayName = profileId == "personal" ? "Mac personal" : "Puky"
        let baseURL = profileId == "personal"
            ? "https://relay.example.com/fermin-code"
            : "https://relay.example.com/fermin-code-puky"
        let suffix = String(Int(Date().timeIntervalSince1970)).suffix(8)
        let sessionName = "QA Mobile \(profileId) \(suffix)"
        let responseMarker = "MOBILE_\(profileId.uppercased())_\(suffix)"

        let app = XCUIApplication()
        if profileId == "personal" {
            app.launchEnvironment["KYCODE_UI_TEST_LIVE_PERSONAL"] = "1"
            app.launchEnvironment["KYCODE_UI_TEST_LIVE_PERSONAL_TOKEN"] = token
        } else {
            app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY"] = "1"
            app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY_TOKEN"] = token
        }
        app.launchEnvironment["KYCODE_UI_TEST_SELECTED_PROFILE"] = profileId
        app.launchEnvironment["KYCODE_UI_TEST_FORCE_INTERNET"] = "1"
        app.launch()
        defer { app.terminate() }

        let filterMenu = app.buttons["dashboard-filter-menu"]
        let selectedTarget = app.buttons["dashboard-target-\(profileId)"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 30))
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(selectedTarget.waitForExistence(timeout: 3))
        selectedTarget.tap()
        let selectedAndConnected = NSPredicate(format: "value CONTAINS %@", "Conectado")
        expectation(for: selectedAndConnected, evaluatedWith: filterMenu)
        waitForExpectations(timeout: 60)

        let dashboardMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 10))
        dashboardMenu.tap()
        let preferences = app.buttons["Desktop y preferencias"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5))
        preferences.tap()
        XCTAssertTrue(
            app.staticTexts["\(displayName) · Internet"].waitForExistence(timeout: 10),
            "\(displayName) connected, but did not prove the canonical Fermín internet route."
        )
        XCTAssertTrue(
            app.staticTexts[baseURL].waitForExistence(timeout: 10),
            "\(displayName) did not expose its canonical production relay URL."
        )
        let done = app.buttons["connection-sheet-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        let messagingCards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session-card-messaging-")
        )
        XCTAssertTrue(
            app.staticTexts["Sin sesiones"].waitForExistence(timeout: 90),
            "\(displayName) must begin from an authoritative empty Fermín Code snapshot."
        )
        XCTAssertEqual(
            messagingCards.count,
            0,
            "\(displayName) exposed sessions that were not created by Fermín Code after the clean reset."
        )
        let create = app.buttons["dashboard-new-session"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let createReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: create
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [createReady], timeout: 10),
            .completed,
            "Nueva sesión must be accessible and enabled from the empty dashboard."
        )
        create.tap()

        let name = app.textFields["create-session-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        name.tap()
        name.typeText(sessionName)
        let defaultProject = app.descendants(matching: .any)["create-session-default-project"]
        XCTAssertTrue(defaultProject.waitForExistence(timeout: 60))
        let confirm = app.buttons["create-session-confirm"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 60)
        confirm.tap()

        let newCard = messagingCards.firstMatch
        XCTAssertTrue(
            newCard.waitForExistence(timeout: 120),
            "The Fermín relay did not publish the new Simulator session."
        )
        let cardIdentifier = newCard.identifier
        let cardPrefix = "session-card-messaging-"
        XCTAssertTrue(cardIdentifier.hasPrefix(cardPrefix))
        let windowId = String(cardIdentifier.dropFirst(cardPrefix.count))
        newCard.tap()

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText(
            "Reply exactly \(responseMarker). No punctuation, explanation, or tools."
        )
        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        let responses = app.staticTexts.matching(
            NSPredicate(format: "label == %@", responseMarker)
        )
        let response = responses.firstMatch
        XCTAssertTrue(
            response.waitForExistence(timeout: 180),
            "\(displayName) did not render Codex's exact reply through the Fermín relay."
        )
        let processingMatches = app.descendants(matching: .any).matching(
            identifier: "session-processing-indicator"
        )
        let processing = processingMatches.firstMatch
        XCTAssertTrue(
            processing.waitForNonExistence(timeout: 60),
            "The assistant reply rendered, but the Fermín turn never reached a settled state."
        )
        let messageMarkers = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "message-")
        )
        let userMarkers = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "message-mobile-user-")
        )
        XCTAssertEqual(messageMarkers.count, 2, "Expected exactly one user and one assistant message.")
        XCTAssertEqual(userMarkers.count, 1, "Expected exactly one user message.")
        XCTAssertEqual(messageMarkers.count - userMarkers.count, 1, "Expected exactly one assistant message.")
        XCTAssertEqual(responses.count, 1, "Expected exactly one \(responseMarker) reply.")
        XCTAssertEqual(processingMatches.count, 0, "Processing indicator must be absent.")

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "fermin-live-simulator-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "fermin-live-simulator-reply"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let navigationBar = app.navigationBars.firstMatch
        let back = navigationBar.buttons.firstMatch
        XCTAssertTrue(back.exists)
        back.tap()
        let delete = app.buttons["delete-session-\(windowId)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15))
        delete.tap()
        let deleteConfirm = app.buttons.matching(identifier: "delete-session-confirm").firstMatch
        XCTAssertTrue(deleteConfirm.waitForExistence(timeout: 5))
        deleteConfirm.tap()
        XCTAssertTrue(newCard.waitForNonExistence(timeout: 60))
        XCTAssertTrue(
            app.staticTexts["Sin sesiones"].waitForExistence(timeout: 90),
            "\(displayName) did not return to its authoritative empty state after archive."
        )
        XCTAssertEqual(messagingCards.count, 0, "The archived Fermín Code session returned as a stale card.")
    }

    func testLiveFailedSessionDisplaysDurableDiagnosticWithoutSending() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["KYCODE_LIVE_PUKY_TOKEN"],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let windowId = environment["KYCODE_LIVE_DIAGNOSTIC_WINDOW_ID"],
              !windowId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip(
                "KYCODE_LIVE_PUKY_TOKEN and KYCODE_LIVE_DIAGNOSTIC_WINDOW_ID are required for this read-only live run."
            )
        }
        let expectedDetail = environment["KYCODE_LIVE_DIAGNOSTIC_FRAGMENT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detailFragment = expectedDetail?.isEmpty == false
            ? expectedDetail!
            : "El mensaje llegó correctamente a Fermín"

        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY_TOKEN"] = token
        app.launchEnvironment["KYCODE_UI_TEST_SELECTED_PROFILE"] = "puky"
        app.launchEnvironment["KYCODE_UI_TEST_FORCE_INTERNET"] = "1"
        app.launch()
        defer { app.terminate() }

        let card = app.buttons["session-card-messaging-\(windowId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 90), "The failed live session never appeared.")
        card.tap()

        let diagnostic = app.descendants(matching: .any)["session-runtime-error-card"]
        XCTAssertTrue(
            diagnostic.waitForExistence(timeout: 30),
            "The failed session opened without its durable runtime diagnostic."
        )
        XCTAssertTrue(app.staticTexts["No se pudo completar el turno"].exists)
        let detail = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", detailFragment)
        ).firstMatch
        XCTAssertTrue(
            detail.waitForExistence(timeout: 5),
            "The diagnostic did not explain that Fermín delivered the message before the provider failure."
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "live-failed-session-diagnostic"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLiveDualFerminRelaysCreateReplyAggregateRouteAndCleanUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let personalToken = environment["KYCODE_LIVE_PERSONAL_TOKEN"],
              !personalToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pukyToken = environment["KYCODE_LIVE_PUKY_TOKEN"],
              !pukyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Both authorized Fermín relay tokens are required for dual-host live QA.")
        }

        let runSuffix = String(Int(Date().timeIntervalSince1970)).suffix(8)
        let personalTarget = LiveFerminTarget(
            profileId: "personal",
            displayName: "Mac personal",
            baseURL: "https://relay.example.com/fermin-code",
            sessionName: "QA Personal \(runSuffix)",
            responseMarker: "PERSONAL_\(runSuffix)"
        )
        let pukyTarget = LiveFerminTarget(
            profileId: "puky",
            displayName: "Puky",
            baseURL: "https://relay.example.com/fermin-code-puky",
            sessionName: "QA Puky \(runSuffix)",
            responseMarker: "PUKY_\(runSuffix)"
        )

        let app = XCUIApplication()
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PERSONAL"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PERSONAL_TOKEN"] = personalToken
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY"] = "1"
        app.launchEnvironment["KYCODE_UI_TEST_LIVE_PUKY_TOKEN"] = pukyToken
        app.launchEnvironment["KYCODE_UI_TEST_SELECTED_PROFILE"] = personalTarget.profileId
        app.launchEnvironment["KYCODE_UI_TEST_FORCE_INTERNET"] = "1"
        app.launch()
        defer { app.terminate() }

        let personalSession = try exerciseLiveFerminTarget(personalTarget, in: app)
        let pukySession = try exerciseLiveFerminTarget(pukyTarget, in: app)

        try selectLiveTarget(profileId: "all", in: app, timeout: 90)
        try assertCombinedSession(
            personalSession,
            excludesMarker: pukySession.target.responseMarker,
            in: app
        )
        try assertCombinedSession(
            pukySession,
            excludesMarker: personalSession.target.responseMarker,
            in: app
        )

        try deleteCombinedSession(personalSession, in: app)
        try deleteCombinedSession(pukySession, in: app)

        try await waitForExactSessionCleanup(personalSession, token: personalToken)
        try await waitForExactSessionCleanup(pukySession, token: pukyToken)
    }

    private struct LiveFerminTarget {
        let profileId: String
        let displayName: String
        let baseURL: String
        let sessionName: String
        let responseMarker: String
    }

    private struct LiveFerminSession {
        let target: LiveFerminTarget
        let remoteWindowId: String

        var combinedWindowId: String {
            "\(target.profileId)::\(remoteWindowId)"
        }
    }

    private func exerciseLiveFerminTarget(
        _ target: LiveFerminTarget,
        in app: XCUIApplication
    ) throws -> LiveFerminSession {
        closeDashboardSearchIfNeeded(in: app)
        try selectLiveTarget(profileId: target.profileId, in: app, timeout: 90)
        try assertCanonicalLiveURL(target, in: app)

        let create = app.buttons["dashboard-new-session"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let createReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: create
        )
        XCTAssertEqual(XCTWaiter.wait(for: [createReady], timeout: 10), .completed)
        create.tap()

        let name = app.textFields["create-session-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        name.tap()
        name.typeText(target.sessionName)
        let defaultProject = app.descendants(matching: .any)["create-session-default-project"]
        XCTAssertTrue(defaultProject.waitForExistence(timeout: 90))
        let confirm = app.buttons["create-session-confirm"]
        let confirmEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: confirm
        )
        XCTAssertEqual(XCTWaiter.wait(for: [confirmEnabled], timeout: 90), .completed)
        confirm.tap()
        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 180),
            "\(target.displayName) left the create-session sheet stuck after the durable command completed."
        )
        XCTAssertFalse(
            app.staticTexts[
                "La sesión quedó pendiente y la Mac todavía no confirmó el nombre. Revisá la lista antes de reintentar."
            ].exists
        )

        let card = try searchForSession(named: target.sessionName, in: app)
        let cardPrefix = "session-card-messaging-"
        XCTAssertTrue(card.identifier.hasPrefix(cardPrefix))
        let remoteWindowId = String(card.identifier.dropFirst(cardPrefix.count))
        XCTAssertFalse(remoteWindowId.isEmpty)
        card.tap()

        let composer = app.textFields["composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 90))
        composer.tap()
        composer.typeText(
            "Reply exactly \(target.responseMarker). No punctuation, explanation, or tools."
        )
        let send = app.buttons["composer-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        send.tap()

        let responses = app.staticTexts.matching(
            NSPredicate(format: "label == %@", target.responseMarker)
        )
        XCTAssertTrue(
            responses.firstMatch.waitForExistence(timeout: 240),
            "\(target.displayName) did not return its unique assistant marker."
        )
        let processingMatches = app.descendants(matching: .any).matching(
            identifier: "session-processing-indicator"
        )
        XCTAssertTrue(
            processingMatches.firstMatch.waitForNonExistence(timeout: 90),
            "\(target.displayName) returned text but never settled."
        )
        let messageMarkers = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "message-")
        )
        let userMarkers = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "message-mobile-user-")
        )
        XCTAssertEqual(messageMarkers.count, 2)
        XCTAssertEqual(userMarkers.count, 1)
        XCTAssertEqual(messageMarkers.count - userMarkers.count, 1)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(processingMatches.count, 0)

        let navigationBar = app.navigationBars.firstMatch
        let back = navigationBar.buttons.firstMatch
        XCTAssertTrue(back.exists)
        back.tap()
        closeDashboardSearchIfNeeded(in: app)

        return LiveFerminSession(target: target, remoteWindowId: remoteWindowId)
    }

    private func selectLiveTarget(
        profileId: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws {
        closeDashboardSearchIfNeeded(in: app)
        let filterMenu = app.buttons["dashboard-filter-menu"]
        let target = app.buttons["dashboard-target-\(profileId)"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: timeout))
        filterMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Conectado"),
            object: filterMenu
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [connected], timeout: timeout),
            .completed,
            "The \(profileId) target did not connect."
        )
    }

    private func assertCanonicalLiveURL(
        _ target: LiveFerminTarget,
        in app: XCUIApplication
    ) throws {
        let dashboardMenu = app.buttons["dashboard-floating-menu"]
        XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 15))
        dashboardMenu.tap()
        let preferences = app.buttons["Desktop y preferencias"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 10))
        preferences.tap()

        var canonicalURL = app.staticTexts[target.baseURL]
        if !canonicalURL.waitForExistence(timeout: 5) {
            app.swipeUp()
            canonicalURL = app.staticTexts[target.baseURL]
        }
        XCTAssertTrue(
            canonicalURL.waitForExistence(timeout: 10),
            "\(target.displayName) did not expose its exact canonical Fermín URL."
        )
        XCTAssertFalse(app.staticTexts["https://relay.example.com/legacy-hub"].exists)
        XCTAssertFalse(app.staticTexts["https://relay.example.com/sidecar"].exists)
        let done = app.buttons["connection-sheet-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    private func searchForSession(
        named sessionName: String,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        closeDashboardSearchIfNeeded(in: app)
        let search = app.textFields["dashboard-search"]
        let searchAction = app.buttons["Buscar sesiones"]
        if !search.exists {
            if !searchAction.exists {
                let dashboardMenu = app.buttons["dashboard-floating-menu"]
                XCTAssertTrue(dashboardMenu.waitForExistence(timeout: 30))
                let dashboardMenuHittable = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"),
                    object: dashboardMenu
                )
                XCTAssertEqual(
                    XCTWaiter.wait(for: [dashboardMenuHittable], timeout: 150),
                    .completed
                )
                guard dashboardMenu.isHittable else {
                    throw NSError(
                        domain: "KyCodeUITests.LiveFermin",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Dashboard menu did not become interactive."]
                    )
                }
                dashboardMenu.tap()
            }
            XCTAssertTrue(searchAction.waitForExistence(timeout: 30))
            guard searchAction.exists else {
                throw NSError(
                    domain: "KyCodeUITests.LiveFermin",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Dashboard search action did not become available."]
                )
            }
            searchAction.tap()
        }

        XCTAssertTrue(search.waitForExistence(timeout: 30))
        guard search.exists else {
            throw NSError(
                domain: "KyCodeUITests.LiveFermin",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Dashboard search field did not become available."]
            )
        }
        search.tap()
        search.typeText(sessionName)
        let card = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "session-card-messaging-",
                sessionName
            )
        ).firstMatch
        XCTAssertTrue(
            card.waitForExistence(timeout: 90),
            "The newly created session \(sessionName) did not appear in search."
        )
        return card
    }

    private func assertCombinedSession(
        _ session: LiveFerminSession,
        excludesMarker otherMarker: String,
        in app: XCUIApplication
    ) throws {
        let card = try searchForSession(named: session.target.sessionName, in: app)
        XCTAssertEqual(
            card.identifier,
            "session-card-messaging-\(session.combinedWindowId)",
            "Todo did not preserve \(session.target.displayName)'s source identity."
        )
        card.tap()

        let expected = app.staticTexts.matching(
            NSPredicate(format: "label == %@", session.target.responseMarker)
        )
        XCTAssertTrue(expected.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(expected.count, 1)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", otherMarker)).count,
            0,
            "Todo mixed replies from the two Macs."
        )

        let navigationBar = app.navigationBars.firstMatch
        let back = navigationBar.buttons.firstMatch
        XCTAssertTrue(back.exists)
        back.tap()
        closeDashboardSearchIfNeeded(in: app)
    }

    private func deleteCombinedSession(
        _ session: LiveFerminSession,
        in app: XCUIApplication
    ) throws {
        let card = try searchForSession(named: session.target.sessionName, in: app)
        XCTAssertEqual(card.identifier, "session-card-messaging-\(session.combinedWindowId)")
        let delete = app.buttons["delete-session-\(session.combinedWindowId)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let confirm = app.buttons.matching(identifier: "delete-session-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(
            card.waitForNonExistence(timeout: 90),
            "Todo did not remove \(session.target.displayName)'s exact session."
        )
        closeDashboardSearchIfNeeded(in: app)
    }

    private func closeDashboardSearchIfNeeded(in app: XCUIApplication) {
        for label in ["Limpiar y cerrar búsqueda", "Cerrar búsqueda"] {
            let close = app.buttons[label]
            if close.waitForExistence(timeout: 0.5) {
                close.tap()
                _ = app.textFields["dashboard-search"].waitForNonExistence(timeout: 5)
                return
            }
        }
    }

    private func waitForExactSessionCleanup(
        _ session: LiveFerminSession,
        token: String
    ) async throws {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/?#")
        let encodedWindowId = try XCTUnwrap(
            session.remoteWindowId.addingPercentEncoding(withAllowedCharacters: pathAllowed)
        )
        let url = try XCTUnwrap(
            URL(string: "\(session.target.baseURL)/api/mobile/sessions/\(encodedWindowId)")
        )

        for _ in 0..<45 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Mozilla/5.0 (compatible; FerminCodeMobileUITest/1.0)",
                forHTTPHeaderField: "User-Agent"
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            if http.statusCode == 404 {
                return
            }
            XCTAssertEqual(
                http.statusCode,
                200,
                "Unexpected cleanup verification status for \(session.target.displayName)."
            )
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTFail("The exact \(session.target.displayName) session still existed after cleanup.")
    }
}
