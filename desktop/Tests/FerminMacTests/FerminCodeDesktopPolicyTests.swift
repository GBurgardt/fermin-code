import Darwin
import AppKit
import FerminCore
import SwiftUI
import XCTest
@testable import FerminMac

final class FerminCodeDesktopPolicyTests: XCTestCase {
    func testHTTP404ExplainsRelayVersionMismatch() {
        let message = FerminCodeDesktopErrorPresentation.message(
            for: FerminRelayHTTPError.httpStatus(
                statusCode: 404,
                serverCode: nil,
                message: "Not Found"
            ),
            action: "eliminar definitivamente la sesión"
        )

        XCTAssertEqual(
            message,
            "El relay activo no admite eliminar definitivamente la sesión. Actualizá el servicio e intentá de nuevo."
        )
    }

    func testRelayTransportTimeoutKeepsActionableCopy() {
        XCTAssertEqual(
            FerminCodeDesktopErrorPresentation.message(
                for: FerminRelayHTTPError.transport(code: URLError.timedOut.rawValue),
                action: "crear la sesión"
            ),
            "Se agotó el tiempo al intentar crear la sesión."
        )
    }

    func testFeatureConfirmationIgnoresUnrelatedAuthoritativeChanges() {
        let patch = FerminRelayFeaturePatch(promptImproverEnabled: true)
        let authoritative = FerminRelaySessionFeatures(
            promptImproverEnabled: true,
            explainerEnabled: true,
            codeContextEnabled: false
        )

        XCTAssertTrue(
            FerminCodeDesktopFeatureConfirmationPolicy.confirms(
                patch: patch,
                authoritative: authoritative
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopFeatureConfirmationPolicy.confirms(
                patch: FerminRelayFeaturePatch(promptImproverEnabled: false),
                authoritative: authoritative
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopFeatureConfirmationPolicy.confirms(
                patch: FerminRelayFeaturePatch(),
                authoritative: authoritative
            )
        )
    }

    func testPromptPreferenceSelectionOnlyAdoptsACompleteCommonValue() {
        let standard = FerminRelayPromptImproverPreference(variant: .standard)
        let motivational = FerminRelayPromptImproverPreference(variant: .motivational)

        XCTAssertEqual(
            FerminCodeDesktopPromptPreferenceSelectionPolicy.commonVariant(
                profile: .personal,
                preferences: [.personal: motivational]
            ),
            .motivational
        )
        XCTAssertNil(
            FerminCodeDesktopPromptPreferenceSelectionPolicy.commonVariant(
                profile: .todo,
                preferences: [.personal: standard]
            )
        )
        XCTAssertNil(
            FerminCodeDesktopPromptPreferenceSelectionPolicy.commonVariant(
                profile: .todo,
                preferences: [.personal: standard, .puky: motivational]
            )
        )
    }

    func testPromptPreferenceCopySeparatesVariantFromSessionActivation() {
        XCTAssertTrue(
            FerminCodeDesktopPromptPreferencePresentation.scopeHelp.contains(
                "no activa «Mejorar»"
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopPromptPreferencePresentation.scopeHelp.contains(
                "próximos mensajes"
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptPreferencePresentation.persistenceHelp(profile: .todo),
            "Se guarda en Personal y Puky; cualquier resultado parcial se informa."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptPreferencePresentation.persistenceHelp(profile: .puky),
            "Se guarda sólo en Secondary."
        )
    }

    func testPromptImproverHelpNamesVariantAndCurrentMessageScope() {
        XCTAssertEqual(
            FerminCodeDesktopPromptImproverControlPresentation.help(
                canControl: true,
                isEnabled: false,
                variantLabel: "Estándar"
            ),
            "Mejorar próximos mensajes · Estándar"
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptImproverControlPresentation.help(
                canControl: true,
                isEnabled: true,
                variantLabel: "Motivacional"
            ),
            "Próximos mensajes · Motivacional. La mejora actual continúa al apagarlo."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptImproverControlPresentation.help(
                canControl: false,
                isEnabled: true,
                variantLabel: "Estándar"
            ),
            "Esta sesión no permite cambiar el mejorador."
        )
    }

    func testFeatureControlValueStaysBinaryWhileGroupProgressIsSeparate() {
        XCTAssertEqual(
            FerminCodeDesktopFeatureControlPresentation.accessibilityValue(
                isEnabled: true
            ),
            "Activado"
        )
        XCTAssertEqual(
            FerminCodeDesktopFeatureControlPresentation.accessibilityValue(
                isEnabled: false
            ),
            "Desactivado"
        )
    }

    func testFailedCommandsOnlyRevertTheSessionTheyTargeted() throws {
        let selected = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "current-window"
        )
        let currentContext = FerminRelayTrackedCommandContext(
            operation: .setFeatures,
            source: .personal,
            windowID: "current-window"
        )
        let previousContext = FerminRelayTrackedCommandContext(
            operation: .setFeatures,
            source: .personal,
            windowID: "previous-window"
        )

        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.targetsSelectedSession(
                context: currentContext,
                eventSource: .personal,
                selectedRoute: selected
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.targetsSelectedSession(
                context: previousContext,
                eventSource: .personal,
                selectedRoute: selected
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.targetsSelectedSession(
                context: currentContext,
                eventSource: .puky,
                selectedRoute: selected
            )
        )
    }

    func testCommandFailureFeedbackStaysInTheContextItBelongsTo() throws {
        let selected = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "current-window"
        )
        let currentContext = FerminRelayTrackedCommandContext(
            operation: .setModel,
            source: .personal,
            windowID: "current-window"
        )
        let previousContext = FerminRelayTrackedCommandContext(
            operation: .setModel,
            source: .personal,
            windowID: "previous-window"
        )
        let globalContext = FerminRelayTrackedCommandContext(
            operation: .createSession,
            source: .personal
        )

        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.shouldPresentFailure(
                context: currentContext,
                eventSource: .personal,
                selectedRoute: selected
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.shouldPresentFailure(
                context: previousContext,
                eventSource: .personal,
                selectedRoute: selected
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.shouldPresentFailure(
                context: globalContext,
                eventSource: .personal,
                selectedRoute: selected
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.shouldPresentFailure(
                context: currentContext,
                eventSource: .puky,
                selectedRoute: selected
            )
        )
    }

    func testOnlyTheCurrentFeatureMutationCanRevertItsOptimisticToggle() throws {
        let selected = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "current-window"
        )
        let firstToggle = FerminRelayTrackedCommandContext(
            operation: .setFeatures,
            source: .personal,
            windowID: "current-window",
            mutationID: "first-toggle"
        )
        let secondToggle = FerminRelayTrackedCommandContext(
            operation: .setFeatures,
            source: .personal,
            windowID: "current-window",
            mutationID: "second-toggle"
        )

        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentFeatureOverride(
                context: firstToggle,
                eventSource: .personal,
                selectedRoute: selected,
                currentMutationID: "second-toggle"
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentFeatureOverride(
                context: secondToggle,
                eventSource: .personal,
                selectedRoute: selected,
                currentMutationID: "second-toggle"
            )
        )
    }

    func testOnlyTheCurrentModelMutationCanRevertItsOptimisticSelection() throws {
        let selected = try FerminCodeRelaySessionRoute(
            source: .puky,
            windowID: "model-window"
        )
        let oldSelection = FerminRelayTrackedCommandContext(
            operation: .setModel,
            source: .puky,
            windowID: "model-window",
            mutationID: "old-model"
        )
        let currentSelection = FerminRelayTrackedCommandContext(
            operation: .setModel,
            source: .puky,
            windowID: "model-window",
            mutationID: "current-model"
        )

        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentRuntimeModelOverride(
                context: oldSelection,
                eventSource: .puky,
                selectedRoute: selected,
                currentMutationID: "current-model"
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentRuntimeModelOverride(
                context: currentSelection,
                eventSource: .puky,
                selectedRoute: selected,
                currentMutationID: "current-model"
            )
        )
    }

    func testOnlyTheCurrentGoalMutationCanRevertItsOptimisticToggle() throws {
        let selected = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "goal-window"
        )
        let oldToggle = FerminRelayTrackedCommandContext(
            operation: .setRunMode,
            source: .personal,
            windowID: "goal-window",
            mutationID: "old-goal"
        )
        let currentToggle = FerminRelayTrackedCommandContext(
            operation: .setRunMode,
            source: .personal,
            windowID: "goal-window",
            mutationID: "current-goal"
        )

        XCTAssertFalse(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentGoalModeOverride(
                context: oldToggle,
                eventSource: .personal,
                selectedRoute: selected,
                currentMutationID: "current-goal"
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopCommandTargetPolicy.targetsCurrentGoalModeOverride(
                context: currentToggle,
                eventSource: .personal,
                selectedRoute: selected,
                currentMutationID: "current-goal"
            )
        )
    }

    func testCredentialCoverageIdentifiesTheMissingSourceInTodo() {
        let presence: [FerminCodeRelaySource: Bool] = [
            .personal: true,
            .puky: false,
        ]

        XCTAssertTrue(
            FerminCodeDesktopCredentialCoveragePolicy.hasConfiguredSource(
                profile: .todo,
                presence: presence
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopCredentialCoveragePolicy.missingSources(
                profile: .todo,
                presence: presence
            ),
            [.puky]
        )
        XCTAssertTrue(
            FerminCodeDesktopCredentialCoveragePolicy.missingSources(
                profile: .personal,
                presence: presence
            ).isEmpty
        )
    }

    func testCredentialFocusFollowsLoadedCoverageWithoutStealingTypedInput() {
        XCTAssertEqual(
            FerminCodeDesktopCredentialFocusPolicy.preferredSource(
                presence: [:],
                current: nil,
                unsavedSources: []
            ),
            .personal
        )

        let loadedPresence: [FerminCodeRelaySource: Bool] = [
            .personal: true,
            .puky: false,
        ]
        XCTAssertEqual(
            FerminCodeDesktopCredentialFocusPolicy.preferredSource(
                presence: loadedPresence,
                current: .personal,
                unsavedSources: []
            ),
            .puky
        )
        XCTAssertEqual(
            FerminCodeDesktopCredentialFocusPolicy.preferredSource(
                presence: loadedPresence,
                current: .personal,
                unsavedSources: [.personal]
            ),
            .personal
        )
        XCTAssertNil(
            FerminCodeDesktopCredentialFocusPolicy.preferredSource(
                presence: [.personal: true, .puky: true],
                current: .puky,
                unsavedSources: []
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopCredentialFocusPolicy.preferredSource(
                presence: loadedPresence,
                current: .personal,
                unsavedSources: [.puky]
            ),
            .puky
        )
    }

    func testComposerFocusReturnsOnlyAfterClosingAModalWithASelectedSession() {
        XCTAssertTrue(
            FerminCodeDesktopComposerFocusPolicy.shouldRestoreAfterModal(
                isModalPresented: false,
                hasSelectedSession: true
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopComposerFocusPolicy.shouldRestoreAfterModal(
                isModalPresented: true,
                hasSelectedSession: true
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopComposerFocusPolicy.shouldRestoreAfterModal(
                isModalPresented: false,
                hasSelectedSession: false
            )
        )
    }

    func testComposerStatusOnlySuggestsSendingWhenThereIsADraft() {
        XCTAssertNil(
            FerminCodeDesktopComposerStatusPresentation.label(
                isSending: false,
                isAddingAttachments: false,
                blockingMessage: nil,
                hasDraft: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopComposerStatusPresentation.label(
                isSending: false,
                isAddingAttachments: false,
                blockingMessage: nil,
                hasDraft: true
            ),
            "BORRADOR GUARDADO · ⌘↩"
        )
        XCTAssertEqual(
            FerminCodeDesktopComposerStatusPresentation.label(
                isSending: true,
                isAddingAttachments: false,
                blockingMessage: "No disponible",
                hasDraft: false
            ),
            "Enviando…"
        )
        XCTAssertEqual(
            FerminCodeDesktopComposerStatusPresentation.label(
                isSending: false,
                isAddingAttachments: false,
                blockingMessage: "La sesión no admite mensajes.",
                hasDraft: false
            ),
            "La sesión no admite mensajes."
        )
    }

    func testSubagentConfirmationExplainsTheFirstBlockingField() {
        XCTAssertFalse(
            FerminCodeDesktopSubagentFormPolicy.canConfirm(
                task: "   ",
                nameValidationMessage: nil,
                isCreating: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopSubagentFormPolicy.confirmHelp(
                task: "   ",
                nameValidationMessage: nil,
                isCreating: false
            ),
            "Describí una tarea para continuar."
        )
        XCTAssertEqual(
            FerminCodeDesktopSubagentFormPolicy.confirmHelp(
                task: "Revisá los casos borde.",
                nameValidationMessage: "Usá hasta 64 caracteres.",
                isCreating: false
            ),
            "Usá hasta 64 caracteres."
        )
        XCTAssertTrue(
            FerminCodeDesktopSubagentFormPolicy.canConfirm(
                task: "Revisá los casos borde.",
                nameValidationMessage: nil,
                isCreating: false
            )
        )
    }

    func testSubagentTaskUsesTheBackendUTF8LimitBeforeConfirmation() {
        let oversized = String(
            repeating: "á",
            count: FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes / 2 + 1
        )

        XCTAssertFalse(
            FerminCodeDesktopSubagentFormPolicy.canConfirm(
                task: oversized,
                nameValidationMessage: nil,
                isCreating: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopSubagentFormPolicy.confirmHelp(
                task: oversized,
                nameValidationMessage: nil,
                isCreating: false
            ),
            "La tarea supera el límite de 256 KB. Reducila antes de crear."
        )
    }

    func testComposerTreatsWhitespaceOnlyDraftsAsVisuallyEmpty() {
        XCTAssertFalse(
            FerminCodeDesktopComposerTextPresentation.hasVisibleContent("  \n\t  ")
        )
        XCTAssertTrue(
            FerminCodeDesktopComposerTextPresentation.hasVisibleContent("  Revisar\n")
        )
    }

    func testComposerValidatesTheBackendMessageLimitInUTF8Bytes() {
        let maximum = FerminCodeDesktopComposerTextPresentation.maximumUTF8Bytes
        let valid = String(repeating: "a", count: maximum)
        let oversized = valid + "a"
        let multibyteOversized = String(repeating: "á", count: maximum / 2 + 1)

        XCTAssertNil(FerminCodeDesktopComposerTextPresentation.validationMessage(for: valid))
        XCTAssertNotNil(
            FerminCodeDesktopComposerTextPresentation.validationMessage(for: oversized)
        )
        XCTAssertNotNil(
            FerminCodeDesktopComposerTextPresentation.validationMessage(
                for: multibyteOversized
            )
        )
        XCTAssertNil(FerminCodeDesktopComposerTextPresentation.usageLabel(for: "breve"))
        XCTAssertEqual(
            FerminCodeDesktopComposerTextPresentation.usageLabel(for: oversized),
            "257 KB · máximo 256 KB"
        )
    }

    func testRenameConfirmationStaysAlignedWithValidation() {
        XCTAssertFalse(
            FerminCodeDesktopRenameFormPolicy.canConfirm(
                name: "Sesión actual",
                currentName: "Sesión actual",
                isRenaming: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopRenameFormPolicy.confirmHelp(
                name: "Sesión actual",
                currentName: "Sesión actual",
                isRenaming: false
            ),
            "Escribí un nombre distinto al actual."
        )
        XCTAssertEqual(
            FerminCodeDesktopRenameFormPolicy.validationMessage(
                name: "  Sesión actual  ",
                currentName: "Sesión actual"
            ),
            "El nombre no cambia después de quitar los espacios exteriores."
        )
        XCTAssertTrue(
            FerminCodeDesktopRenameFormPolicy.canConfirm(
                name: "Sesión nueva",
                currentName: "Sesión actual",
                isRenaming: false
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopRenameFormPolicy.canConfirm(
                name: "Sesión nueva",
                currentName: "Sesión actual",
                isRenaming: true
            )
        )
    }

    func testCreateConfirmationExplainsNameThenProjectThenProgress() {
        XCTAssertEqual(
            FerminCodeDesktopCreateFormPolicy.confirmHelp(
                name: "",
                projectPath: "",
                isLoadingProjects: true,
                creationPhase: .idle
            ),
            "Escribí un nombre para la sesión."
        )
        XCTAssertEqual(
            FerminCodeDesktopCreateFormPolicy.confirmHelp(
                name: "Sesión nueva",
                projectPath: "",
                isLoadingProjects: true,
                creationPhase: .idle
            ),
            "Esperá a que terminen de cargar los proyectos."
        )
        XCTAssertEqual(
            FerminCodeDesktopCreateFormPolicy.confirmHelp(
                name: "Sesión nueva",
                projectPath: "",
                isLoadingProjects: false,
                creationPhase: .idle
            ),
            "Elegí un proyecto."
        )
        XCTAssertTrue(
            FerminCodeDesktopCreateFormPolicy.canConfirm(
                name: "Sesión nueva",
                projectPath: "/Users/test/projects/fermin-code",
                isCreating: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopCreateFormPolicy.confirmHelp(
                name: "Sesión nueva",
                projectPath: "/Users/test/projects/fermin-code",
                isLoadingProjects: false,
                creationPhase: .waitingForConfirmation
            ),
            "Preparando la sesión…"
        )
    }

    func testCredentialSaveExplainsEmptyReplacementAndBusyStates() {
        XCTAssertFalse(
            FerminCodeDesktopCredentialActionPolicy.canSave(
                token: "   ",
                isSaving: false,
                isDeleting: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopCredentialActionPolicy.saveHelp(
                token: "",
                isConfigured: true,
                isSaving: false,
                isDeleting: false
            ),
            "Pegá un token nuevo para reemplazar el actual."
        )
        XCTAssertTrue(
            FerminCodeDesktopCredentialActionPolicy.canSave(
                token: "nuevo-token",
                isSaving: false,
                isDeleting: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopCredentialActionPolicy.saveHelp(
                token: "nuevo-token",
                isConfigured: false,
                isSaving: true,
                isDeleting: false
            ),
            "Guardando el token en Keychain…"
        )
    }

    func testNewSessionActionExplainsProfileTokenAndBackgroundCreation() {
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.help(
                profile: .todo,
                credentialPresence: [:],
                isBootstrapping: false,
                creationPhase: .idle
            ),
            "Configurá al menos un token para crear una sesión."
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.help(
                profile: .todo,
                credentialPresence: [.personal: true, .puky: true],
                isBootstrapping: false,
                creationPhase: .idle
            ),
            "Crear una sesión y elegir entre Personal o Puky"
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.help(
                profile: .puky,
                credentialPresence: [.puky: false],
                isBootstrapping: false,
                creationPhase: .idle
            ),
            "Configurá el token de Secondary para crear una sesión."
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.help(
                profile: .personal,
                credentialPresence: [.personal: true],
                isBootstrapping: false,
                creationPhase: .submitting
            ),
            "Enviando la solicitud a Primary. Podés seguir usando la app."
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.help(
                profile: .puky,
                credentialPresence: [.puky: true],
                isBootstrapping: false,
                creationPhase: .waitingForConfirmation
            ),
            "Secondary aceptó la solicitud. Esperando que la sesión quede lista."
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.title(
                creationPhase: .submitting
            ),
            "Enviando solicitud…"
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.title(
                creationPhase: .waitingForConfirmation
            ),
            "Esperando confirmación…"
        )
        XCTAssertEqual(
            FerminCodeDesktopNewSessionActionPresentation.accessibilityValue(
                creationPhase: .waitingForConfirmation
            ),
            "Solicitud aceptada; sesión pendiente"
        )
    }

    func testAttachmentPolicyAcceptsDisplayedFormatsAndRejectsExcessCount() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(FerminCodeDesktopAttachmentPolicy.detectedMIMEType(for: png), "image/png")
        XCTAssertNil(
            FerminCodeDesktopAttachmentPolicy.detectedMIMEType(
                for: Data("not-an-image".utf8)
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopAttachmentPolicy.capacityDescription(existingCount: 10),
            "Límite alcanzado. Quitá una imagen para adjuntar otra."
        )
        XCTAssertEqual(
            FerminCodeDesktopAttachmentPolicy.capacityDescription(existingCount: 9),
            "1 imagen disponible."
        )

        let tooMany = (0...FerminCodeDesktopAttachmentPolicy.maximumCount).map {
            FerminCodeDesktopAttachmentDraft(
                name: "image-\($0).png",
                mimeType: "image/png",
                data: png
            )
        }
        XCTAssertThrowsError(try FerminCodeDesktopAttachmentPolicy.validate(tooMany))
        XCTAssertEqual(
            FerminCodeDesktopAttachmentPolicy.remainingCount(existingCount: 8),
            2
        )
        XCTAssertNoThrow(
            try FerminCodeDesktopAttachmentPolicy.validateAdditionCount(
                existingCount: 8,
                incomingCount: 2
            )
        )
        XCTAssertThrowsError(
            try FerminCodeDesktopAttachmentPolicy.validateAdditionCount(
                existingCount: 8,
                incomingCount: 3
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Podés adjuntar 2 imágenes más.")
        }
        XCTAssertTrue(
            FerminCodeDesktopAttachmentPolicy.supportsDropCandidate(
                URL(fileURLWithPath: "/tmp/foto.JPG")
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopAttachmentPolicy.supportsDropCandidate(
                URL(fileURLWithPath: "/tmp/foto.webp")
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopAttachmentPolicy.supportsDropCandidate(
                URL(fileURLWithPath: "/tmp/notas.txt")
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopAttachmentPolicy.supportsDropCandidate(
                URL(string: "https://example.com/foto.png")!
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopAttachmentPolicy.isLocalFileDropPayload([
                URL(fileURLWithPath: "/tmp/foto.png"),
                URL(fileURLWithPath: "/tmp/notas.txt"),
            ])
        )
        XCTAssertFalse(
            FerminCodeDesktopAttachmentPolicy.isLocalFileDropPayload([
                URL(string: "https://example.com/foto.png")!,
            ])
        )
    }

    func testConnectionPhasesHaveTextAndNonColorSymbols() {
        let phases: [FerminCodeDesktopConnectionPhase] = [
            .missingCredential, .loading, .online, .stale, .offline,
        ]
        XCTAssertEqual(Set(phases.map(\.symbolName)).count, phases.count)
        XCTAssertTrue(phases.allSatisfy { !$0.label.isEmpty })
    }

    func testConnectionBadgeKeepsStableGeometryAcrossPhaseChanges() {
        let sizes = [
            FerminCodeDesktopConnectionPhase.missingCredential,
            .loading,
            .online,
            .stale,
            .offline,
        ].map { phase in
            let view = NSHostingView(
                rootView: FerminCodeDesktopConnectionBadge(
                    status: FerminCodeDesktopSourceStatus(
                        source: .personal,
                        phase: phase,
                        sessionCount: 4,
                        detail: nil,
                        lastUpdatedAt: nil
                    )
                )
            )
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }

        for size in sizes.dropFirst() {
            XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.01)
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.01)
        }
        XCTAssertEqual(sizes[0].width, 150, accuracy: 0.01)
        XCTAssertEqual(sizes[0].height, 24, accuracy: 0.01)
    }

    func testHistoryPresentationLocalizesStateAndScopesResumeProgress() {
        XCTAssertEqual(FerminCodeDesktopHistoryPresentation.stateLabel(.active), "ACTIVA")
        XCTAssertEqual(FerminCodeDesktopHistoryPresentation.stateLabel(.archived), "ARCHIVADA")
        XCTAssertEqual(
            FerminCodeDesktopHistoryPresentation.resumeMutationKey(
                source: .puky,
                itemID: "history-7"
            ),
            "resume-puky-history-7"
        )
    }

    func testHistorySearchEscapeClearsThenDismissesOnlyWhenUnfocused() {
        XCTAssertEqual(
            FerminCodeDesktopHistoryEscapePolicy.action(
                queryIsEmpty: false,
                isSearchFocused: true
            ),
            .clearQuery
        )
        XCTAssertEqual(
            FerminCodeDesktopHistoryEscapePolicy.action(
                queryIsEmpty: false,
                isSearchFocused: false
            ),
            .clearQuery,
            "A non-empty query must never dismiss History, regardless of focus."
        )
        XCTAssertEqual(
            FerminCodeDesktopHistoryEscapePolicy.action(
                queryIsEmpty: true,
                isSearchFocused: true
            ),
            .resignFocus
        )
        XCTAssertEqual(
            FerminCodeDesktopHistoryEscapePolicy.action(
                queryIsEmpty: true,
                isSearchFocused: false
            ),
            .dismissSheet
        )
    }

    func testPromptTransformPresentationCoversBackendStatusVocabulary() {
        XCTAssertTrue(
            FerminCodeDesktopPromptTransformPresentation.ongoingHelp.contains(
                "próximos mensajes"
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopPromptTransformPresentation.reconciliationHelp.contains(
                "esta mejora"
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "pending",
                errorReason: nil
            ),
            .pending
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "error",
                errorReason: nil
            ),
            .failed
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "cancelled",
                errorReason: nil
            ),
            .failed
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                status: "aborted",
                errorReason: nil
            ),
            "La mejora se canceló antes de terminar."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "done",
                errorReason: "error anterior"
            ),
            .hidden
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "pending",
                errorReason: nil,
                hasResult: true
            ),
            .hidden
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "processing",
                errorReason: nil,
                timestamp: 1_000_000,
                now: 1_000_000 + FerminCodeDesktopPromptTransformPresentation.reconciliationThreshold
            ),
            .reconciling
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "in_progress",
                errorReason: nil,
                timestamp: 2_500_000,
                now: 2_500_000
            ),
            .pending
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "pending",
                errorReason: nil,
                timestamp: 0,
                observedAt: 2_000_000,
                now: 2_000_000
                    + FerminCodeDesktopPromptTransformPresentation.reconciliationThreshold
            ),
            .reconciling
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "queued",
                errorReason: nil,
                timestamp: 9_999_999_999_999,
                observedAt: 3_000_000,
                now: 3_000_000
                    + FerminCodeDesktopPromptTransformPresentation.reconciliationThreshold
            ),
            .reconciling
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "running",
                errorReason: nil,
                timestamp: 4_000_000,
                now: 4_000_000
                    + FerminCodeDesktopPromptTransformPresentation.stalledThreshold
            ),
            .stalled
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "processing",
                errorReason: nil,
                timestamp: 1_000_000,
                attemptStartedAt: 2_000_000,
                now: 2_000_000
            ),
            .pending
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.state(
                status: "processing",
                errorReason: nil,
                timestamp: 1_000_000,
                attemptStartedAt: 2_000_000,
                now: 2_000_000
                    + FerminCodeDesktopPromptTransformPresentation.reconciliationThreshold
            ),
            .reconciling
        )
        XCTAssertTrue(
            FerminCodeDesktopPromptTransformPresentation.State.stalled.needsReconciliation
        )
        XCTAssertTrue(
            FerminCodeDesktopPromptTransformPresentation.shouldRefreshLocally(.pending)
        )
        XCTAssertTrue(
            FerminCodeDesktopPromptTransformPresentation.shouldRefreshLocally(.reconciling)
        )
        XCTAssertFalse(
            FerminCodeDesktopPromptTransformPresentation.shouldRefreshLocally(.stalled)
        )
        XCTAssertFalse(
            FerminCodeDesktopPromptTransformPresentation.shouldRefreshLocally(.failed)
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "observer_error"
            ),
            "No se pudo mejorar el prompt; el original quedó intacto."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "sidecar_unavailable"
            ),
            "El servicio de mejora no está disponible."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "observer_timeout"
            ),
            "La mejora o su verificación tardaron demasiado y se interrumpieron."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "prompt_improver_timeout"
            ),
            "La mejora superó seis minutos y se interrumpió."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "prompt_fidelity_timeout"
            ),
            "La verificación de fidelidad superó seis minutos y se interrumpió."
        )
        XCTAssertEqual(
            FerminCodeDesktopPromptTransformPresentation.failureDetail(
                errorReason: "cancelled"
            ),
            "La mejora se canceló antes de terminar."
        )
        XCTAssertGreaterThanOrEqual(
            FerminCodeDesktopPromptTransformPresentation.stalledThreshold,
            12 * 60
        )
    }

    func testRuntimeModelPresentationMatchesMobileCompactLabels() {
        XCTAssertEqual(
            FerminCodeDesktopRuntimeModelPresentation.compactModelLabel("gpt-5.6-sol"),
            "SOL"
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeModelPresentation.compactEffortLabel("max"),
            "MAX"
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeModelPresentation.accessibilityValue(
                model: "gpt-5.6-sol",
                effort: "max"
            ),
            "SOL, MAX"
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeModelPresentation.effortDescription(
                "max",
                fallback: "Maximum"
            ),
            "Usa el máximo razonamiento disponible."
        )
    }

    func testRuntimeSelectionSyncPreservesEditedPopoverWork() {
        XCTAssertFalse(
            FerminCodeDesktopRuntimeSelectionSyncPolicy.shouldAdoptStoreSelection(
                isPresented: true,
                isApplying: false,
                hasPendingSelection: true
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopRuntimeSelectionSyncPolicy.shouldAdoptStoreSelection(
                isPresented: true,
                isApplying: true,
                hasPendingSelection: false
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopRuntimeSelectionSyncPolicy.shouldAdoptStoreSelection(
                isPresented: true,
                isApplying: false,
                hasPendingSelection: false
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopRuntimeSelectionSyncPolicy.shouldAdoptStoreSelection(
                isPresented: false,
                isApplying: false,
                hasPendingSelection: true
            )
        )
    }

    func testRuntimeDraftExistsOnlyForACompleteChangedSelection() {
        XCTAssertEqual(
            FerminCodeDesktopRuntimeDraftPolicy.draft(
                model: "gpt-5.6-sol",
                effort: "max",
                baselineModel: "gpt-5.6-sol",
                baselineEffort: "high"
            ),
            FerminCodeDesktopRuntimeDraft(model: "gpt-5.6-sol", effort: "max")
        )
        XCTAssertNil(
            FerminCodeDesktopRuntimeDraftPolicy.draft(
                model: "gpt-5.6-sol",
                effort: "MAX",
                baselineModel: "gpt-5.6-sol",
                baselineEffort: "max"
            )
        )
        XCTAssertNil(
            FerminCodeDesktopRuntimeDraftPolicy.draft(
                model: "",
                effort: "max",
                baselineModel: "gpt-5.6-sol",
                baselineEffort: "high"
            )
        )
    }

    func testRuntimePopoverAllowsAutomaticDismissalExceptWhileApplying() {
        XCTAssertFalse(
            FerminCodeDesktopRuntimePopoverPolicy.blocksInteractiveDismiss(
                isApplying: false
            )
        )
        XCTAssertTrue(
            FerminCodeDesktopRuntimePopoverPolicy.blocksInteractiveDismiss(
                isApplying: true
            )
        )
    }

    func testRuntimeApplyExplainsTheFirstBlockingSelection() {
        XCTAssertFalse(
            FerminCodeDesktopRuntimeApplyPolicy.canApply(
                model: "",
                effort: "",
                hasChange: true,
                isApplying: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeApplyPolicy.help(
                model: "",
                effort: "",
                hasChange: true,
                isApplying: false
            ),
            "Elegí un modelo."
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeApplyPolicy.help(
                model: "gpt-5.6-sol",
                effort: "",
                hasChange: true,
                isApplying: false
            ),
            "Elegí un nivel de razonamiento."
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeApplyPolicy.help(
                model: "gpt-5.6-sol",
                effort: "max",
                hasChange: false,
                isApplying: false
            ),
            "El modelo y el razonamiento ya están aplicados."
        )
        XCTAssertTrue(
            FerminCodeDesktopRuntimeApplyPolicy.canApply(
                model: "gpt-5.6-sol",
                effort: "max",
                hasChange: true,
                isApplying: false
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeApplyPolicy.help(
                model: "gpt-5.6-sol",
                effort: "max",
                hasChange: true,
                isApplying: true
            ),
            "Aplicando modelo y razonamiento…"
        )
    }

    func testRuntimeCatalogSelectionFallsBackToAVisibleGPTModel() {
        let sol = FerminRelayAvailableModel(
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            defaultReasoningEffort: "max",
            isDefault: true
        )
        let terra = FerminRelayAvailableModel(
            id: "gpt-5.6-terra",
            model: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            defaultReasoningEffort: "medium"
        )

        XCTAssertEqual(
            FerminCodeDesktopRuntimeCatalogSelectionPolicy.resolvedModel(
                requested: terra.model,
                models: [sol, terra]
            ),
            terra.model
        )
        XCTAssertEqual(
            FerminCodeDesktopRuntimeCatalogSelectionPolicy.resolvedModel(
                requested: "retired-model",
                models: [terra, sol]
            ),
            sol.model
        )
        XCTAssertNil(
            FerminCodeDesktopRuntimeCatalogSelectionPolicy.resolvedModel(
                requested: "retired-model",
                models: []
            )
        )
    }

    func testActivityPresentationLocalizesKnownStatesAndKeepsUnknownNeutral() {
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.state(for: "WAITING"), .ready)
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.label(for: "ready"), "Lista")
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.state(for: "WORKING"), .busy)
        XCTAssertEqual(
            FerminCodeDesktopActivityPresentation.symbol(for: "processing"),
            "circle.dotted"
        )
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.symbol(for: "ready"), "circle.fill")
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.state(for: "failed"), .failed)
        XCTAssertEqual(FerminCodeDesktopActivityPresentation.state(for: "future-state"), .unknown)
        XCTAssertEqual(
            FerminCodeDesktopActivityPresentation.label(for: "future-state"),
            "Estado desconocido"
        )
    }

    func testRuntimeFailurePresentationRequiresAFailedStateAndConcreteDetail() {
        XCTAssertEqual(
            FerminCodeDesktopRuntimeFailurePresentation.message(
                activityStatus: "error",
                detail: "  El mensaje llegó, pero Codex bloqueó el hilo.  "
            ),
            "El mensaje llegó, pero Codex bloqueó el hilo."
        )
        XCTAssertNil(
            FerminCodeDesktopRuntimeFailurePresentation.message(
                activityStatus: "working",
                detail: "No debe interrumpir un turno activo"
            )
        )
        XCTAssertNil(
            FerminCodeDesktopRuntimeFailurePresentation.message(
                activityStatus: "failed",
                detail: "  "
            )
        )
    }

    func testSessionNamePolicyTrimsAndEnforcesTheVisibleLimit() {
        XCTAssertFalse(FerminCodeDesktopSessionNamePolicy.isValid("   \n"))
        XCTAssertEqual(
            FerminCodeDesktopSessionNamePolicy.validationMessage(for: "   \n"),
            "Escribí un nombre para la sesión."
        )
        XCTAssertEqual(FerminCodeDesktopSessionNamePolicy.normalized("  Sesión útil  "), "Sesión útil")
        XCTAssertTrue(
            FerminCodeDesktopSessionNamePolicy.isValid(
                String(repeating: "a", count: FerminCodeDesktopSessionNamePolicy.maximumLength)
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopSessionNamePolicy.isValid(
                String(repeating: "a", count: FerminCodeDesktopSessionNamePolicy.maximumLength + 1)
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopSessionNamePolicy.validationMessage(
                for: String(
                    repeating: "a",
                    count: FerminCodeDesktopSessionNamePolicy.maximumLength + 1
                )
            ),
            "Usá hasta 64 caracteres."
        )
    }

    func testComposerAvailabilityExplainsWhySendingIsUnavailable() {
        XCTAssertEqual(
            FerminCodeDesktopComposerAvailability.blockingMessage(for: nil),
            "Elegí una sesión para enviar."
        )
        XCTAssertNil(
            FerminCodeDesktopComposerAvailability.blockingMessage(
                for: FerminRelaySession(
                    windowID: "ready-window",
                    sessionID: "ready-session",
                    canSend: true
                )
            )
        )
        XCTAssertEqual(
            FerminCodeDesktopComposerAvailability.blockingMessage(
                for: FerminRelaySession(
                    windowID: "unsupported-window",
                    sessionID: "unsupported-session",
                    canSend: false,
                    unsupportedReason: "  Requiere una sesión GPT compatible.  "
                )
            ),
            "Requiere una sesión GPT compatible."
        )
        XCTAssertEqual(
            FerminCodeDesktopComposerAvailability.blockingMessage(
                for: FerminRelaySession(
                    windowID: "archived-window",
                    sessionID: "archived-session",
                    isMinimized: true,
                    canSend: false
                )
            ),
            "Restaurá la sesión para volver a enviar."
        )
    }

    func testTodoFiltersBySearchAndSortsAcrossSources() {
        let personal = sourced(
            .personal,
            windowID: "personal-1",
            name: "API personal",
            project: "fermin-code",
            updatedAt: 200
        )
        let puky = sourced(
            .puky,
            windowID: "puky-1",
            name: "Relay Puky",
            project: "fermin-code",
            updatedAt: 300
        )
        let unrelated = sourced(
            .personal,
            windowID: "other",
            name: "Marketing",
            project: "website",
            updatedAt: 400
        )

        let result = FerminCodeDesktopSessionListPolicy.filterAndSort(
            [personal, unrelated, puky],
            profile: .todo,
            searchText: "fermin",
            includeMinimized: true
        )

        XCTAssertEqual(result.map(\.id), [puky.id, personal.id])
    }

    func testSingleProfileRejectsSessionFromOtherSource() {
        let personal = sourced(.personal, windowID: "one", name: "One", updatedAt: 1)
        let puky = sourced(.puky, windowID: "two", name: "Two", updatedAt: 2)

        let result = FerminCodeDesktopSessionListPolicy.filterAndSort(
            [personal, puky],
            profile: .personal,
            searchText: "",
            includeMinimized: true
        )

        XCTAssertEqual(result.map(\.source), [.personal])
    }

    func testHiddenMinimizedMatchesRespectProfileAndSearch() {
        let matching = sourced(
            .personal,
            windowID: "matching",
            name: "Fermín oculto",
            updatedAt: 3,
            isMinimized: true
        )
        let visible = sourced(
            .personal,
            windowID: "visible",
            name: "Fermín visible",
            updatedAt: 2
        )
        let otherSource = sourced(
            .puky,
            windowID: "puky",
            name: "Fermín Puky",
            updatedAt: 4,
            isMinimized: true
        )

        let result = FerminCodeDesktopSessionListPolicy.hiddenMinimizedMatches(
            [visible, otherSource, matching],
            profile: .personal,
            searchText: "oculto"
        )

        XCTAssertEqual(result.map(\.id), [matching.id])
    }

    func testLivePatchNeverRegressesToOlderPrefix() {
        var live = FerminCodeDesktopLiveMessage(
            message: message(id: "assistant-1", content: "respuesta completa", timestamp: 2),
            revision: 8,
            updatedAt: 80,
            isFinal: false
        )

        XCTAssertFalse(live.apply(FerminRelayLiveMessagePatch(
            windowID: "window",
            message: message(id: "assistant-1", content: "respuesta", timestamp: 2),
            revision: 7,
            updatedAt: 90,
            isFinal: false
        )))
        XCTAssertEqual(live.message.content, "respuesta completa")

        XCTAssertTrue(live.apply(FerminRelayLiveMessagePatch(
            windowID: "window",
            message: message(id: "assistant-1", content: "respuesta completa final", timestamp: 2),
            revision: 9,
            updatedAt: 100,
            isFinal: true
        )))
        XCTAssertEqual(live.message.content, "respuesta completa final")
    }

    func testAuthoritativeMessageReconcilesOptimisticMessageByID() {
        let optimistic = FerminCodeDesktopOptimisticMessage(
            message: message(id: "client-1", role: "user", content: "hola", timestamp: 1),
            delivery: .accepted
        )
        let authoritative = message(
            id: "client-1",
            role: "user",
            content: "hola",
            timestamp: 1
        )

        let result = FerminCodeDesktopTranscriptPolicy.merge(
            authoritative: [authoritative],
            live: [:],
            optimistic: [optimistic]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].delivery)
    }

    func testAuthoritativeCompletedResponseBeatsStaleNonFinalLivePrefix() throws {
        let marker = "FERMIN_DESKTOP_PERSONAL_20260815-194332-2D80C5"
        let authoritative = message(
            id: "assistant-1",
            content: marker,
            timestamp: 2
        )
        let live = FerminCodeDesktopLiveMessage(
            message: message(
                id: "assistant-1",
                content: "FERMIN_DESKTOP_PERSONAL_20260815-194332",
                timestamp: 2
            ),
            revision: 4,
            updatedAt: 80,
            isFinal: false
        )

        let result = FerminCodeDesktopTranscriptPolicy.merge(
            authoritative: [authoritative],
            live: [live.message.id: live],
            optimistic: []
        )

        XCTAssertEqual(try XCTUnwrap(result.first).message.content, marker)
        XCTAssertFalse(try XCTUnwrap(result.first).isStreaming)
    }

    func testPresentedTranscriptKeepsTheRelayStreamingSignal() throws {
        let live = FerminCodeDesktopLiveMessage(
            message: message(id: "assistant-live", content: "respuesta parcial", timestamp: 2),
            revision: 4,
            updatedAt: 80,
            isFinal: false
        )

        let result = FerminCodeDesktopTranscriptPolicy.merge(
            authoritative: [],
            live: [live.message.id: live],
            optimistic: []
        )

        XCTAssertTrue(try XCTUnwrap(result.first).isStreaming)
    }

    func testTranscriptWindowLoadsRecentMessagesInStablePages() {
        XCTAssertEqual(FerminCodeDesktopTranscriptWindowPolicy.initialLimit, 80)
        XCTAssertEqual(
            FerminCodeDesktopTranscriptWindowPolicy.hiddenCount(total: 250, visible: 80),
            170
        )
        XCTAssertEqual(
            FerminCodeDesktopTranscriptWindowPolicy.nextLimit(current: 80, total: 250),
            160
        )
        XCTAssertEqual(
            FerminCodeDesktopTranscriptWindowPolicy.nextLimit(current: 240, total: 250),
            250
        )
    }

    func testIncompleteTranscriptCopyOnlyAppearsForALoadedPartialTail() {
        XCTAssertEqual(
            FerminCodeDesktopTranscriptAvailabilityPresentation.incompleteSummary(
                loadedCount: 4,
                reportedCount: 100
            ),
            "4 de 100 mensajes cargados. Los anteriores todavía no están disponibles."
        )
        XCTAssertNil(
            FerminCodeDesktopTranscriptAvailabilityPresentation.incompleteSummary(
                loadedCount: 0,
                reportedCount: 100
            )
        )
        XCTAssertNil(
            FerminCodeDesktopTranscriptAvailabilityPresentation.incompleteSummary(
                loadedCount: 4,
                reportedCount: 4
            )
        )
        XCTAssertNil(
            FerminCodeDesktopTranscriptAvailabilityPresentation.incompleteSummary(
                loadedCount: 5,
                reportedCount: 4
            )
        )
    }

    func testTranscriptMessageIdentityIsScopedToItsSessionRoute() throws {
        let personal = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "shared-window"
        )
        let puky = try FerminCodeRelaySessionRoute(
            source: .puky,
            windowID: "shared-window"
        )

        let personalID = FerminCodeDesktopTranscriptIdentityPolicy.messageRowID(
            route: personal,
            messageID: "shared-message"
        )
        let pukyID = FerminCodeDesktopTranscriptIdentityPolicy.messageRowID(
            route: puky,
            messageID: "shared-message"
        )

        XCTAssertNotEqual(personalID, pukyID)
        XCTAssertEqual(
            personalID,
            FerminCodeDesktopTranscriptIdentityPolicy.messageRowID(
                route: personal,
                messageID: "shared-message"
            )
        )
    }

    func testTranscriptEarlierAnchorUsesTheRenderedRowID() throws {
        let personal = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "shared-window"
        )
        let puky = try FerminCodeRelaySessionRoute(
            source: .puky,
            windowID: "shared-window"
        )

        let personalAnchor = FerminCodeDesktopTranscriptIdentityPolicy.earlierMessagesAnchorID(
            route: personal,
            firstVisibleMessageID: "m80"
        )
        let pukyAnchor = FerminCodeDesktopTranscriptIdentityPolicy.earlierMessagesAnchorID(
            route: puky,
            firstVisibleMessageID: "m80"
        )

        XCTAssertEqual(
            personalAnchor,
            FerminCodeDesktopTranscriptIdentityPolicy.messageRowID(
                route: personal,
                messageID: "m80"
            )
        )
        XCTAssertNotEqual(personalAnchor, "m80")
        XCTAssertNotEqual(personalAnchor, pukyAnchor)
        XCTAssertNil(
            FerminCodeDesktopTranscriptIdentityPolicy.earlierMessagesAnchorID(
                route: personal,
                firstVisibleMessageID: nil
            )
        )
    }

    func testTranscriptEarlierDropsQueuedAnchorAfterSameRouteSessionChange() {
        let originalInstanceID = "personal::session::base-session::shared-window"
        let replacementInstanceID = "personal::session::replacement-session::shared-window"

        XCTAssertTrue(
            FerminCodeDesktopTranscriptIdentityPolicy.shouldApplyQueuedEarlierMessagesAnchor(
                expectedSessionInstanceID: originalInstanceID,
                currentSessionInstanceID: originalInstanceID
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopTranscriptIdentityPolicy.shouldApplyQueuedEarlierMessagesAnchor(
                expectedSessionInstanceID: originalInstanceID,
                currentSessionInstanceID: replacementInstanceID
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopTranscriptIdentityPolicy.shouldApplyQueuedEarlierMessagesAnchor(
                expectedSessionInstanceID: nil,
                currentSessionInstanceID: replacementInstanceID
            )
        )
    }

    func testMessageContentSeparatesClosedCodeFencesWithoutLosingSurroundingText() {
        let content = """
        Antes **importante**.

        ```swift
        let value = await load()
        print(value)
        ```

        Después.
        """

        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(in: content),
            [
                .markdown("Antes **importante**."),
                .code(language: "swift", content: "let value = await load()\nprint(value)"),
                .markdown("Después."),
            ]
        )
        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(in: "```swift\nlet value = 1"),
            [.markdown("```swift\nlet value = 1")]
        )
        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(
                in: "```swift\nlet value = 1",
                allowsUnclosedFence: true
            ),
            [.code(language: "swift", content: "let value = 1")]
        )
    }

    func testMessageContentExposesHeadingsListsAndQuotesAsReadableStructure() {
        let content = """
        ## Resumen

        - Primer punto
        - Segundo **punto**

        3. Tercero
        4. Cuarto

        > Una cita útil.
        """

        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(in: content),
            [
                .heading(level: 2, content: "Resumen"),
                .list([
                    FerminCodeDesktopMessageListItem(marker: "•", content: "Primer punto"),
                    FerminCodeDesktopMessageListItem(marker: "•", content: "Segundo **punto**"),
                ]),
                .list([
                    FerminCodeDesktopMessageListItem(marker: "3.", content: "Tercero"),
                    FerminCodeDesktopMessageListItem(marker: "4.", content: "Cuarto"),
                ]),
                .quote("Una cita útil."),
            ]
        )
    }

    func testMessageContentExposesOnlyValidMarkdownTablesAsStructuredData() {
        let content = """
        | Modelo | Uso |
        |:---|---:|
        | `gpt-5.6-sol` | **Principal** |
        | Texto \\| literal | Secundario |

        Después de la tabla.
        """

        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(in: content),
            [
                .table(
                    headers: ["Modelo", "Uso"],
                    rows: [
                        ["`gpt-5.6-sol`", "**Principal**"],
                        ["Texto \\| literal", "Secundario"],
                    ]
                ),
                .markdown("Después de la tabla."),
            ]
        )
        XCTAssertEqual(
            FerminCodeDesktopMessageContentPolicy.segments(
                in: "Usá A | B para comparar."
            ),
            [.markdown("Usá A | B para comparar.")]
        )
    }

    func testSessionDetailMustMatchTheRequestedRoute() throws {
        let route = try FerminCodeRelaySessionRoute(
            source: .personal,
            windowID: "requested-window"
        )
        let matching = FerminRelaySession(
            windowID: "requested-window",
            sessionID: "matching-session",
            displayName: "Correcta",
            activityStatus: "ready"
        )
        let crossed = FerminRelaySession(
            windowID: "other-window",
            sessionID: "crossed-session",
            displayName: "Cruzada",
            activityStatus: "ready"
        )
        let reusedWindow = FerminRelaySession(
            windowID: "requested-window",
            sessionID: "replacement-session",
            displayName: "Otra instancia",
            activityStatus: "ready"
        )

        XCTAssertTrue(FerminCodeDesktopSessionDetailPolicy.matches(matching, route: route))
        XCTAssertFalse(FerminCodeDesktopSessionDetailPolicy.matches(crossed, route: route))
        XCTAssertTrue(
            FerminCodeDesktopSessionDetailPolicy.matches(
                matching,
                route: route,
                expectedSessionID: "matching-session"
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopSessionDetailPolicy.matches(
                reusedWindow,
                route: route,
                expectedSessionID: "matching-session"
            )
        )
    }

    func testTimestampAcceptsRelayMilliseconds() {
        let milliseconds = 1_800_000_000_000.0
        XCTAssertEqual(
            FerminCodeDesktopTimestamp.date(millisecondsOrSeconds: milliseconds),
            Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func sourced(
        _ source: FerminCodeRelaySource,
        windowID: String,
        name: String,
        project: String = "",
        updatedAt: Double,
        isMinimized: Bool = false
    ) -> FerminCodeRelaySourcedSession {
        FerminCodeRelaySourcedSession(
            source: source,
            session: FerminRelaySession(
                windowID: windowID,
                sessionID: "session-\(windowID)",
                engine: "codex",
                projectName: project,
                displayName: name,
                activityStatus: "ready",
                updatedAt: updatedAt,
                isMinimized: isMinimized,
                canSend: true
            )
        )
    }

    private func message(
        id: String,
        role: String = "assistant",
        content: String,
        timestamp: Double
    ) -> FerminRelayMessage {
        FerminRelayMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp
        )
    }
}

@MainActor
final class FerminCodeDesktopTextEditorAppearanceTests: XCTestCase {
    func testNativeBridgeKeepsTypedTextReadableInAquaAndDarkAqua() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let hostingView = NSHostingView(
                rootView: TextEditor(text: .constant("Texto visible"))
                    .ferminDesktopTextEditorAppearance()
                    .frame(width: 360, height: 96)
            )
            hostingView.appearance = NSAppearance(named: appearanceName)
            hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 96)

            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                hostingView.layoutSubtreeIfNeeded()
            }

            let textView = try XCTUnwrap(
                editableTextView(in: hostingView),
                "Debe existir el NSTextView editable en \(appearanceName.rawValue)"
            )
            try assertColor(
                textView.textColor,
                matches: FerminCodeDesktopNativeTextEditorAppearance.textColor
            )
            try assertColor(
                textView.backgroundColor,
                matches: FerminCodeDesktopNativeTextEditorAppearance.backgroundColor
            )
            XCTAssertTrue(textView.drawsBackground)
            XCTAssertTrue(textView.isEditable)
            XCTAssertTrue(textView.isSelectable)

            let scrollView = try XCTUnwrap(textView.enclosingScrollView)
            try assertColor(
                scrollView.backgroundColor,
                matches: FerminCodeDesktopNativeTextEditorAppearance.backgroundColor
            )
            try assertColor(
                scrollView.contentView.backgroundColor,
                matches: FerminCodeDesktopNativeTextEditorAppearance.backgroundColor
            )
            XCTAssertTrue(scrollView.drawsBackground)
            XCTAssertTrue(scrollView.contentView.drawsBackground)

            textView.setSelectedRange(NSRange(location: 1, length: 4))
            FerminCodeDesktopNativeTextEditorAppearance.apply(to: textView)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 4))
            window.contentView = nil
        }
    }

    func testNativeBridgeDoesNotCrossTwoNearbyEditors() throws {
        let firstTextColor = NSColor.systemRed
        let firstBackgroundColor = NSColor.black
        let secondTextColor = NSColor.systemGreen
        let secondBackgroundColor = NSColor.darkGray
        let hostingView = NSHostingView(
            rootView: HStack(spacing: 12) {
                TextEditor(text: .constant("Editor uno"))
                    .ferminDesktopTextEditorAppearance(
                        textColor: firstTextColor,
                        backgroundColor: firstBackgroundColor
                    )
                TextEditor(text: .constant("Editor dos"))
                    .ferminDesktopTextEditorAppearance(
                        textColor: secondTextColor,
                        backgroundColor: secondBackgroundColor
                    )
            }
            .frame(width: 520, height: 120)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 120)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }

        let textViews = allTextViews(in: hostingView)
        let first = try XCTUnwrap(textViews.first { $0.string == "Editor uno" })
        let second = try XCTUnwrap(textViews.first { $0.string == "Editor dos" })
        try assertColor(first.textColor, matches: firstTextColor)
        try assertColor(first.backgroundColor, matches: firstBackgroundColor)
        try assertColor(second.textColor, matches: secondTextColor)
        try assertColor(second.backgroundColor, matches: secondBackgroundColor)
        window.contentView = nil
    }

    func testNativeAppearancePreservesDisabledInteractionState() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        textView.string = "No reactivar"
        textView.isEditable = false
        textView.isSelectable = false

        FerminCodeDesktopNativeTextEditorAppearance.apply(to: textView)

        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isSelectable)
        XCTAssertEqual(textView.string, "No reactivar")
    }

    func testNativeAppearanceStopsMutatingAfterConverging() {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 96)
        )
        let textView = NSTextView(frame: scrollView.bounds)
        scrollView.documentView = textView

        textView.textColor = .systemRed
        textView.backgroundColor = .systemBlue
        textView.drawsBackground = false
        scrollView.backgroundColor = .systemGreen
        scrollView.drawsBackground = false
        scrollView.contentView.backgroundColor = .systemOrange
        scrollView.contentView.drawsBackground = false

        XCTAssertTrue(FerminCodeDesktopNativeTextEditorAppearance.apply(to: textView))
        XCTAssertFalse(
            FerminCodeDesktopNativeTextEditorAppearance.apply(to: textView),
            "Una actualización ya convergida no debe volver a invalidar AppKit ni SwiftUI"
        )
    }

    func testNativeBridgeStylesDisabledEditorWithoutChangingInteractionState() throws {
        let textColor = NSColor.systemOrange
        let backgroundColor = NSColor.black
        let baselineHostingView = NSHostingView(
            rootView: TextEditor(text: .constant("Editor base bloqueado"))
                .disabled(true)
                .frame(width: 320, height: 96)
        )
        baselineHostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        let baselineWindow = NSWindow(
            contentRect: baselineHostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        baselineWindow.contentView = baselineHostingView
        baselineHostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let baselineTextView = try XCTUnwrap(
            allTextViews(in: baselineHostingView).first { $0.string == "Editor base bloqueado" }
        )
        let baselineIsEditable = baselineTextView.isEditable
        let baselineIsSelectable = baselineTextView.isSelectable
        baselineWindow.contentView = nil

        let hostingView = NSHostingView(
            rootView: TextEditor(text: .constant("Editor bloqueado"))
                .disabled(true)
                .ferminDesktopTextEditorAppearance(
                    textColor: textColor,
                    backgroundColor: backgroundColor
                )
                .frame(width: 320, height: 96)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }

        let textView = try XCTUnwrap(
            allTextViews(in: hostingView).first { $0.string == "Editor bloqueado" }
        )
        try assertColor(textView.textColor, matches: textColor)
        try assertColor(textView.backgroundColor, matches: backgroundColor)
        XCTAssertEqual(textView.isEditable, baselineIsEditable)
        XCTAssertEqual(textView.isSelectable, baselineIsSelectable)
        window.contentView = nil
    }

    func testDismantledBridgeCannotStyleAReplacementEditor() throws {
        let staleTextColor = NSColor.systemRed
        let staleBackgroundColor = NSColor.black
        let size = NSSize(width: 320, height: 96)
        let hostingView = NSHostingView(
            rootView: AnyView(
                TextEditor(text: .constant("Editor anterior"))
                    .ferminDesktopTextEditorAppearance(
                        textColor: staleTextColor,
                        backgroundColor: staleBackgroundColor
                    )
                    .frame(width: size.width, height: size.height)
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        hostingView.rootView = AnyView(
            TextEditor(text: .constant("Editor reemplazo"))
                .frame(width: size.width, height: size.height)
        )
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }

        let replacement = try XCTUnwrap(
            allTextViews(in: hostingView).first { $0.string == "Editor reemplazo" }
        )
        XCTAssertFalse(colorsMatch(replacement.textColor, staleTextColor))
        XCTAssertFalse(colorsMatch(replacement.backgroundColor, staleBackgroundColor))
        window.contentView = nil
    }

    private func editableTextView(in root: NSView) -> NSTextView? {
        if let textView = root as? NSTextView, textView.isEditable {
            return textView
        }
        for subview in root.subviews {
            if let textView = editableTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func allTextViews(in root: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = root as? NSTextView, !textView.isFieldEditor {
            result.append(textView)
        }
        for subview in root.subviews {
            result.append(contentsOf: allTextViews(in: subview))
        }
        return result
    }

    private func assertColor(
        _ actual: NSColor?,
        matches expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualRGB = try XCTUnwrap(actual?.usingColorSpace(.sRGB), file: file, line: line)
        let expectedRGB = try XCTUnwrap(expected.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(
            actualRGB.redComponent,
            expectedRGB.redComponent,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualRGB.greenComponent,
            expectedRGB.greenComponent,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualRGB.blueComponent,
            expectedRGB.blueComponent,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualRGB.alphaComponent,
            expectedRGB.alphaComponent,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }

    private func colorsMatch(_ actual: NSColor?, _ expected: NSColor) -> Bool {
        guard let actualRGB = actual?.usingColorSpace(.sRGB),
              let expectedRGB = expected.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(actualRGB.redComponent - expectedRGB.redComponent) < 0.001
            && abs(actualRGB.greenComponent - expectedRGB.greenComponent) < 0.001
            && abs(actualRGB.blueComponent - expectedRGB.blueComponent) < 0.001
            && abs(actualRGB.alphaComponent - expectedRGB.alphaComponent) < 0.001
    }
}

final class FerminCodeDesktopSessionPinningPolicyTests: XCTestCase {
    func testSessionsBeginPinnedAndMoveReversiblyBetweenSections() {
        let personal = sourcedSession(
            source: .personal,
            windowID: "window-personal",
            sessionID: "shared-session"
        )
        let puky = sourcedSession(
            source: .puky,
            windowID: "window-puky",
            sessionID: "shared-session"
        )
        let sessions = [personal, puky]

        XCTAssertEqual(
            FerminCodeDesktopSessionPinningPolicy.pinnedSessions(
                in: sessions,
                unpinnedSessionIDs: []
            ),
            sessions
        )

        let personalIdentifier = FerminCodeDesktopSessionPinningPolicy.identifier(for: personal)
        let unpinned = Set([personalIdentifier])
        XCTAssertEqual(
            FerminCodeDesktopSessionPinningPolicy.pinnedSessions(
                in: sessions,
                unpinnedSessionIDs: unpinned
            ),
            [puky]
        )
        XCTAssertEqual(
            FerminCodeDesktopSessionPinningPolicy.unpinnedSessions(
                in: sessions,
                unpinnedSessionIDs: unpinned
            ),
            [personal]
        )
        XCTAssertNotEqual(
            personalIdentifier,
            FerminCodeDesktopSessionPinningPolicy.identifier(for: puky),
            "La misma sesión lógica en dos relays debe conservar estados independientes."
        )
    }

    func testRelayStateOverridesLegacyLocalPreference() {
        let serverPinned = sourcedSession(
            source: .personal,
            windowID: "server-pinned",
            sessionID: "server-pinned",
            isPinned: true
        )
        let serverUnpinned = sourcedSession(
            source: .personal,
            windowID: "server-unpinned",
            sessionID: "server-unpinned",
            isPinned: false
        )
        let staleLegacy = Set([
            FerminCodeDesktopSessionPinningPolicy.identifier(for: serverPinned),
        ])

        XCTAssertTrue(
            FerminCodeDesktopSessionPinningPolicy.isPinned(
                serverPinned,
                unpinnedSessionIDs: staleLegacy
            )
        )
        XCTAssertFalse(
            FerminCodeDesktopSessionPinningPolicy.isPinned(
                serverUnpinned,
                unpinnedSessionIDs: []
            )
        )
    }

    func testUnpinnedIdentifiersPersistDeterministically() throws {
        let suiteName = "FerminCodeDesktopSessionPinningPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identifiers: Set<String> = ["puky::session-b", "personal::session-a"]
        FerminCodeDesktopPreferences.saveUnpinnedSessionIDs(identifiers, to: defaults)

        XCTAssertEqual(
            defaults.stringArray(forKey: FerminCodeDesktopPreferences.unpinnedSessionIDsKey),
            ["personal::session-a", "puky::session-b"]
        )
        XCTAssertEqual(
            FerminCodeDesktopPreferences.unpinnedSessionIDs(from: defaults),
            identifiers
        )
    }

    private func sourcedSession(
        source: FerminCodeRelaySource,
        windowID: String,
        sessionID: String,
        isPinned: Bool? = nil
    ) -> FerminCodeRelaySourcedSession {
        FerminCodeRelaySourcedSession(
            source: source,
            session: FerminRelaySession(
                windowID: windowID,
                sessionID: sessionID,
                displayName: windowID,
                isPinned: isPinned
            )
        )
    }
}

@MainActor
final class FerminCodeDesktopTranscriptRenderingTests: XCTestCase {
    func testMessageBodyDoesNotInstallSwiftUISelectionOverlay() {
        let content = Array(repeating: "Línea de historial estable", count: 120)
            .joined(separator: "\n")
        let hostingView = NSHostingView(
            rootView: FerminCodeDesktopMessageBody(
                content: content,
                isUser: false,
                isStreaming: false
            )
            .frame(width: 720)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 1_200)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.contentView = nil }

        for _ in 0..<20 {
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }

        let platformViewNames = allSubviewTypeNames(in: hostingView)
        XCTAssertFalse(
            platformViewNames.contains { $0.contains("SelectionOverlay") },
            "El historial dinámico no debe reinstalar SelectionOverlay: \(platformViewNames)"
        )
    }

    private func allSubviewTypeNames(in root: NSView) -> [String] {
        [String(describing: type(of: root))]
            + root.subviews.flatMap(allSubviewTypeNames(in:))
    }
}

final class FerminCodeCredentialsTests: XCTestCase {
    func testSharedBootstrapImportsOnceIntoBothKeychainSlotsAndDeletesFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenURL = directory.appendingPathComponent("bootstrap-token")
        try Data("shared-secret".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, mode_t(0o600)), 0)
        let personalVault = CredentialVaultSpy()
        let pukyVault = CredentialVaultSpy()
        let store = FerminCodeCredentialStore(
            vaults: [.personal: personalVault, .puky: pukyVault],
            bootstrapDirectory: directory
        )

        let snapshot = try await store.load()

        XCTAssertEqual(snapshot.token(for: .personal), "shared-secret")
        XCTAssertEqual(snapshot.token(for: .puky), "shared-secret")
        XCTAssertEqual(snapshot.importedSources, Set(FerminCodeRelaySource.allCases))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
        XCTAssertEqual(personalVault.value, "shared-secret")
        XCTAssertEqual(pukyVault.value, "shared-secret")
    }

    func testSecureBootstrapTokenRequiresAndAcceptsMode0600() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenURL = directory.appendingPathComponent("bootstrap-token")
        try Data("  secret-token\n".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, mode_t(0o600)), 0)

        XCTAssertEqual(
            try FerminCodeCredentialStore.readSecureBootstrapToken(at: tokenURL),
            "secret-token"
        )
    }

    func testBootstrapTokenRejectsGroupReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenURL = directory.appendingPathComponent("bootstrap-token")
        try Data("secret-token".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, mode_t(0o640)), 0)

        XCTAssertThrowsError(
            try FerminCodeCredentialStore.readSecureBootstrapToken(at: tokenURL)
        ) { error in
            XCTAssertEqual(
                error as? FerminCodeCredentialError,
                .bootstrapInsecurePermissions
            )
        }
    }

    func testBootstrapTokenRejectsSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("target")
        let linkURL = directory.appendingPathComponent("bootstrap-token")
        try Data("secret-token".utf8).write(to: targetURL)
        XCTAssertEqual(chmod(targetURL.path, mode_t(0o600)), 0)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(
            try FerminCodeCredentialStore.readSecureBootstrapToken(at: linkURL)
        ) { error in
            XCTAssertEqual(error as? FerminCodeCredentialError, .bootstrapNotRegularFile)
        }
    }
}

private final class CredentialVaultSpy: FerminCodeCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func read() throws -> String? { value }

    func save(_ token: String) throws {
        lock.lock()
        storage = token
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        storage = nil
        lock.unlock()
    }
}
