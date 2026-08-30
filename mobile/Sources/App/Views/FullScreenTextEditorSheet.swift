import SwiftUI
import UIKit

struct FullScreenTextEditorRecovery: Codable, Equatable {
    let baseline: String
    let workingText: String
}

enum FullScreenTextEditorDraftPolicy {
    static func hasChanges(baseline: String, workingText: String) -> Bool {
        baseline != workingText
    }

    static func recover(
        _ recovery: FullScreenTextEditorRecovery?,
        currentBaseline: String
    ) -> String? {
        guard let recovery,
              recovery.baseline == currentBaseline,
              recovery.workingText != currentBaseline else {
            return nil
        }
        return recovery.workingText
    }

    static func shouldFocusAutomatically(voiceOverRunning: Bool) -> Bool {
        !voiceOverRunning
    }
}

struct FullScreenTextEditorMetrics: Equatable {
    let characters: Int
    let words: Int
    let lines: Int

    init(text: String) {
        characters = text.count
        words = text.split { $0.isWhitespace || $0.isNewline }.count
        lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    }

    var accessibilitySummary: String {
        "\(characters) caracteres, \(words) palabras, \(lines) líneas"
    }
}

enum FullScreenTextEditorFooterLayout: Equatable {
    case compact
    case stacked
}

enum FullScreenTextEditorFooterLayoutPolicy {
    static func layout(for dynamicTypeSize: DynamicTypeSize) -> FullScreenTextEditorFooterLayout {
        dynamicTypeSize.isAccessibilitySize ? .stacked : .compact
    }
}

struct FullScreenTextEditorDraftStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storageKey(for identifier: String) -> String {
        "kycode.mobile.fullScreenEditor.recovery.\(identifier)"
    }

    func save(_ recovery: FullScreenTextEditorRecovery, identifier: String) {
        guard let data = try? encoder.encode(recovery) else { return }
        defaults.set(data, forKey: storageKey(for: identifier))
    }

    func load(identifier: String) -> FullScreenTextEditorRecovery? {
        guard let data = defaults.data(forKey: storageKey(for: identifier)) else {
            return nil
        }
        return try? decoder.decode(FullScreenTextEditorRecovery.self, from: data)
    }

    func clear(identifier: String) {
        defaults.removeObject(forKey: storageKey(for: identifier))
    }
}

private struct ComposerMessageAccessibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .accessibilityLabel("Mensaje")
            .accessibilityHint("Para textos largos, usá el botón de pantalla completa")
    }
}

extension View {
    func composerMessageAccessibility() -> some View {
        modifier(ComposerMessageAccessibilityModifier())
    }
}

struct ComposerInlineEditorControls: View {
    let canClear: Bool
    let onExpand: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 40, height: 44)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editar en pantalla completa")
            .accessibilityHint("Abre un editor cómodo para textos largos")
            .accessibilityIdentifier("composer-expand-editor")

            if canClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.inkMuted)
                        .frame(width: 40, height: 44)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpiar mensaje")
                .accessibilityHint("Borra el borrador; después podés deshacer")
                .accessibilityIdentifier("composer-clear-text")
            }
        }
    }
}

struct ComposerContextActionCluster<VoiceControl: View, SendControl: View>: View {
    let showsSend: Bool
    private let voiceControl: VoiceControl
    private let sendControl: SendControl

    init(
        showsSend: Bool,
        @ViewBuilder voiceControl: () -> VoiceControl,
        @ViewBuilder sendControl: () -> SendControl
    ) {
        self.showsSend = showsSend
        self.voiceControl = voiceControl()
        self.sendControl = sendControl()
    }

    var body: some View {
        HStack(spacing: 4) {
            voiceControl
            if showsSend {
                sendControl
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct FullScreenTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var editorFocused: Bool

    private let recoveryIdentifier: String
    private let onSave: (String) -> Void
    private let draftStore: FullScreenTextEditorDraftStore

    @State private var baseline: String
    @State private var workingText: String
    @State private var metrics: FullScreenTextEditorMetrics
    @State private var showDiscardConfirmation = false
    @State private var metricsTask: Task<Void, Never>?
    @State private var recoveryTask: Task<Void, Never>?

    init(
        text: String,
        recoveryIdentifier: String,
        draftStore: FullScreenTextEditorDraftStore = FullScreenTextEditorDraftStore(),
        onSave: @escaping (String) -> Void
    ) {
        self.recoveryIdentifier = recoveryIdentifier
        self.draftStore = draftStore
        self.onSave = onSave
        _baseline = State(initialValue: text)
        _workingText = State(initialValue: text)
        _metrics = State(initialValue: FullScreenTextEditorMetrics(text: text))
    }

    private var hasChanges: Bool {
        FullScreenTextEditorDraftPolicy.hasChanges(
            baseline: baseline,
            workingText: workingText
        )
    }

    var body: some View {
        NavigationStack {
            editorSurface
                .navigationTitle("Editar mensaje")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar }
                .toolbarBackground(AppTheme.backgroundSolid, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .interactiveDismissDisabled(hasChanges)
        .alert("¿Descartar cambios?", isPresented: $showDiscardConfirmation) {
            Button("Seguir editando", role: .cancel) {}
            Button("Descartar", role: .destructive) {
                draftStore.clear(identifier: recoveryIdentifier)
                dismiss()
            }
        } message: {
            Text("El borrador del chat no se modificará.")
        }
        .onAppear {
            if let recovered = FullScreenTextEditorDraftPolicy.recover(
                draftStore.load(identifier: recoveryIdentifier),
                currentBaseline: baseline
            ) {
                workingText = recovered
                metrics = FullScreenTextEditorMetrics(text: recovered)
            }
            guard FullScreenTextEditorDraftPolicy.shouldFocusAutomatically(
                voiceOverRunning: UIAccessibility.isVoiceOverRunning
            ) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                editorFocused = true
            }
        }
        .onChange(of: workingText) { _, newValue in
            scheduleMetrics(for: newValue)
            scheduleRecovery(for: newValue)
        }
        .onDisappear {
            metricsTask?.cancel()
            recoveryTask?.cancel()
        }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            TextEditor(text: $workingText)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(AppTheme.ink)
                .tint(AppTheme.accent)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .focused($editorFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel("Texto del mensaje")
                .accessibilityHint("Editor de texto largo. Los cambios se aplican al tocar Guardar.")
                .accessibilityIdentifier("full-screen-text-editor")

            Divider()
                .overlay(AppTheme.divider)

            editorFooter
            .font(.footnote.monospacedDigit())
            .foregroundStyle(AppTheme.inkMuted)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("full-screen-editor-footer")
        }
        .background(AppTheme.backgroundSolid)
    }

    @ViewBuilder
    private var editorFooter: some View {
        if FullScreenTextEditorFooterLayoutPolicy.layout(for: dynamicTypeSize) == .stacked {
            VStack(alignment: .leading, spacing: 2) {
                stackedMetrics
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    hideKeyboardButton
                }
            }
        } else {
            HStack(spacing: 12) {
                compactMetrics
                Spacer(minLength: 12)
                hideKeyboardButton
            }
        }
    }

    private var compactMetrics: some View {
        HStack(spacing: 12) {
            Text("\(metrics.words) palabras")
                .lineLimit(1)
            Text("·")
                .accessibilityHidden(true)
            Text("\(metrics.characters) caracteres")
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metrics.accessibilitySummary)
        .accessibilityIdentifier("full-screen-editor-metrics")
    }

    private var stackedMetrics: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(metrics.words) palabras")
                .lineLimit(1)
            Text("\(metrics.characters) caracteres")
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metrics.accessibilitySummary)
        .accessibilityIdentifier("full-screen-editor-metrics")
    }

    private var hideKeyboardButton: some View {
        Button("Ocultar teclado") {
            editorFocused = false
        }
        .lineLimit(1)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityHint("Deja el texto visible para revisarlo antes de guardar")
        .accessibilityIdentifier("full-screen-editor-hide-keyboard")
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancelar") {
                requestClose()
            }
            .accessibilityIdentifier("full-screen-editor-cancel")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(hasChanges ? "Guardar" : "Sin cambios") {
                recoveryTask?.cancel()
                draftStore.clear(identifier: recoveryIdentifier)
                onSave(workingText)
                baseline = workingText
                dismiss()
            }
            .fontWeight(.semibold)
            .foregroundStyle(hasChanges ? AppTheme.accent : AppTheme.inkMuted)
            .disabled(!hasChanges)
            .accessibilityHint(hasChanges ? "Aplica el texto al mensaje" : "Editá el texto para guardar")
            .accessibilityIdentifier("full-screen-editor-save")
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                undoManager?.undo()
            } label: {
                Label("Deshacer", systemImage: "arrow.uturn.backward")
            }
            .disabled(!(undoManager?.canUndo ?? false))

            Button {
                undoManager?.redo()
            } label: {
                Label("Rehacer", systemImage: "arrow.uturn.forward")
            }
            .disabled(!(undoManager?.canRedo ?? false))

            Spacer()

            Button("Listo") {
                editorFocused = false
            }
        }
    }

    private func requestClose() {
        guard hasChanges else {
            draftStore.clear(identifier: recoveryIdentifier)
            dismiss()
            return
        }
        showDiscardConfirmation = true
    }

    private func scheduleMetrics(for text: String) {
        metricsTask?.cancel()
        metricsTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            metrics = FullScreenTextEditorMetrics(text: text)
        }
    }

    private func scheduleRecovery(for text: String) {
        recoveryTask?.cancel()
        guard text != baseline else {
            draftStore.clear(identifier: recoveryIdentifier)
            return
        }
        recoveryTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            draftStore.save(
                FullScreenTextEditorRecovery(
                    baseline: baseline,
                    workingText: text
                ),
                identifier: recoveryIdentifier
            )
        }
    }
}

#if DEBUG
struct FullScreenTextEditorUITestHarness: View {
    @State private var text = "Un borrador largo para editar con comodidad."
    @State private var editorPresented = false
    @State private var clearedText: String?
    private let usesAccessibilityText =
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR_ACCESSIBILITY_TEXT"] == "1"

    var body: some View {
        VStack(spacing: 24) {
            TextField(
                "",
                text: $text,
                prompt: Text("Mensaje").foregroundStyle(AppTheme.inkMuted),
                axis: .vertical
            )
            .composerMessageAccessibility()
            .accessibilityIdentifier("composer-message")

            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("full-screen-editor-result")

            if clearedText != nil {
                ComposerUndoBanner(
                    message: "Texto limpiado",
                    accessibilityHint: "Restaura el texto anterior"
                ) {
                    text = clearedText ?? ""
                    clearedText = nil
                }
            }

            ComposerInlineEditorControls(
                canClear: !text.isEmpty,
                onExpand: { editorPresented = true },
                onClear: {
                    clearedText = text
                    text = ""
                }
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .onAppear {
            if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR_AUTO_OPEN"] == "1" {
                editorPresented = true
            }
        }
        .fullScreenCover(isPresented: $editorPresented) {
            FullScreenTextEditorSheet(
                text: text,
                recoveryIdentifier: "ui-test-editor"
            ) { updatedText in
                text = updatedText
            }
            .dynamicTypeSize(usesAccessibilityText ? .accessibility5 : .large)
        }
    }
}
#endif
