import XCTest
@testable import KyCode

final class ExplanationViewerTests: XCTestCase {
    func testPolicyRecognizesFinishedExplainerMessage() {
        let message = makeMessage(
            id: "explainer-123",
            content: "# Una explicación\n\nContenido útil."
        )

        let document = KycodeExplanationPolicy.document(for: message)

        XCTAssertEqual(document?.id, "explainer-123")
        XCTAssertEqual(document?.content, "# Una explicación\n\nContenido útil.")
        XCTAssertEqual(document?.title, "Explicación")
        XCTAssertEqual(document?.kind, .explanation)
    }

    func testImprovedPromptPolicyCreatesReaderDocumentWithoutReplacingOriginal() {
        let message = makeMessage(
            id: "user-123",
            role: "user",
            content: "Contame el estado.",
            originalPrompt: "Contame el estado.",
            improvedPrompt: "# Objetivo\n\nExplicá el estado con evidencia."
        )

        let document = KycodeImprovedPromptPolicy.document(for: message)

        XCTAssertEqual(document?.id, "improved-prompt-user-123")
        XCTAssertEqual(document?.messageId, "user-123")
        XCTAssertEqual(document?.kind, .improvedPrompt)
        XCTAssertEqual(document?.title, "Prompt mejorado")
        XCTAssertEqual(document?.content, "# Objetivo\n\nExplicá el estado con evidencia.")
        XCTAssertEqual(message.content, "Contame el estado.")
    }

    func testImprovedPromptPolicyRejectsAssistantEmptyAndEquivalentPrompts() {
        XCTAssertNil(
            KycodeImprovedPromptPolicy.document(
                for: makeMessage(
                    id: "assistant",
                    content: "Original",
                    improvedPrompt: "Mejorado"
                )
            )
        )
        XCTAssertNil(
            KycodeImprovedPromptPolicy.document(
                for: makeMessage(
                    id: "same",
                    role: "user",
                    content: "Mismo",
                    improvedPrompt: "Mismo"
                )
            )
        )
        XCTAssertNil(
            KycodeImprovedPromptPolicy.document(
                for: makeMessage(id: "empty", role: "user", content: "Original")
            )
        )
    }

    func testScrollButtonAlwaysClearsMeasuredComposer() {
        XCTAssertEqual(
            TranscriptFloatingControlLayout.scrollButtonBottomPadding(composerHeight: 0),
            TranscriptFloatingControlLayout.minimumBottomPadding
        )
        XCTAssertEqual(
            TranscriptFloatingControlLayout.scrollButtonBottomPadding(composerHeight: 60),
            70
        )
        XCTAssertEqual(
            TranscriptFloatingControlLayout.scrollButtonBottomPadding(composerHeight: 120),
            130
        )
    }

    func testTranscriptTailAlwaysClearsTheRealComposerHeight() {
        XCTAssertEqual(
            TranscriptFloatingControlLayout.transcriptTailClearance(
                composerHeight: 0,
                baseline: 92
            ),
            92
        )
        XCTAssertEqual(
            TranscriptFloatingControlLayout.transcriptTailClearance(
                composerHeight: 60,
                baseline: 92
            ),
            92
        )
        XCTAssertEqual(
            TranscriptFloatingControlLayout.transcriptTailClearance(
                composerHeight: 120,
                baseline: 92
            ),
            144
        )
    }

    func testPolicyRejectsOrdinaryAndUnavailableMessages() {
        XCTAssertNil(
            KycodeExplanationPolicy.document(
                for: makeMessage(id: "assistant-123", content: "Respuesta común")
            )
        )
        XCTAssertNil(
            KycodeExplanationPolicy.document(
                for: makeMessage(id: "explainer-loading", content: "Generating explanation...")
            )
        )
        XCTAssertNil(
            KycodeExplanationPolicy.document(
                for: makeMessage(
                    id: "explainer-failed",
                    content: "No se pudo generar.",
                    status: "failed"
                )
            )
        )
    }

    @MainActor
    func testViewModelTracksLatestPresentsUpdatesAndDismisses() {
        let first = makeMessage(id: "explainer-first", content: "Versión inicial")
        let latest = makeMessage(id: "explainer-latest", content: "Contenido nuevo", timestamp: 20)
        let model = ExplanationViewerViewModel()

        model.sync(messages: [first, latest])
        XCTAssertTrue(model.hasAvailableExplanation)
        XCTAssertEqual(model.latestDocument?.id, "explainer-latest")

        model.present(KycodeExplanationPolicy.document(for: first)!)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.presentedDocument?.content, "Versión inicial")

        let updated = makeMessage(id: "explainer-first", content: "Versión final")
        model.sync(messages: [updated, latest])
        XCTAssertEqual(model.presentedDocument?.content, "Versión final")

        model.dismiss()
        XCTAssertFalse(model.isPresented)
    }

    @MainActor
    func testThemeToggleIsLocalAndReversible() {
        let model = ExplanationViewerViewModel()
        XCTAssertEqual(model.theme, .light)

        model.toggleTheme()
        XCTAssertEqual(model.theme, .dark)

        model.toggleTheme()
        XCTAssertEqual(model.theme, .light)
    }

    private func makeMessage(
        id: String,
        role: String = "assistant",
        content: String,
        originalPrompt: String? = nil,
        improvedPrompt: String? = nil,
        status: String? = nil,
        timestamp: Double = 10
    ) -> KycodeMessage {
        KycodeMessage(
            id: id,
            role: role,
            type: "codex",
            content: content,
            originalPrompt: originalPrompt,
            transformedPrompt: nil,
            improvedPrompt: improvedPrompt,
            timestamp: timestamp,
            status: status,
            imageAttachments: nil
        )
    }
}
